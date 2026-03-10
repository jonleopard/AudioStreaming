import AVFoundation
import CoreAudio
import Foundation
import OSLog

final class OpusStreamProcessor {
    var processorCallback: ((FileStreamProcessorEffect) -> Void)?

    private let playerContext: AudioPlayerContext
    private let rendererContext: AudioRendererContext
    private let outputAudioFormat: AudioStreamBasicDescription

    private let opDecoder = OpusFileDecoder()
    private var isInitialized = false

    private var audioConverter: AVAudioConverter?
    private var pcmBuffer: AVAudioPCMBuffer?
    private let frameCount = 1024

    private var totalFramesProcessed = 0
    private var dataChunkCount = 0

    init(playerContext: AudioPlayerContext,
         rendererContext: AudioRendererContext,
         outputAudioFormat: AudioStreamBasicDescription)
    {
        self.playerContext = playerContext
        self.rendererContext = rendererContext
        self.outputAudioFormat = outputAudioFormat
    }

    deinit {
        cleanup()
    }

    func cleanup() {
        cleanupBuffers()
        audioConverter = nil
        opDecoder.destroy()
        isInitialized = false
        totalFramesProcessed = 0
    }

    func parseOpusData(data: Data) -> OSStatus {
        guard let entry = playerContext.audioReadingEntry else { return 0 }

        dataChunkCount += 1

        if !isInitialized {
            opDecoder.create(capacityBytes: 2_097_152)
            isInitialized = true
            totalFramesProcessed = 0
        }

        opDecoder.push(data)

        if !entry.audioStreamState.processedDataFormat {
            let availableBytes = opDecoder.availableBytes()

            if availableBytes >= 65536 {
                do {
                    try opDecoder.openIfNeeded()

                    if opDecoder.sampleRate > 0 && opDecoder.channels > 0 {
                        setupAudioFormat()

                        if pcmBuffer == nil, let processingFormat = opDecoder.processingFormat {
                            pcmBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: UInt32(frameCount))
                        }
                    }
                } catch {
                    Logger.error("OpusStreamProcessor: open failed (\(error.localizedDescription)), resetting decoder", category: .audioRendering)
                    opDecoder.destroy()
                    opDecoder.create(capacityBytes: 2_097_152)
                    return noErr
                }
            } else {
                return noErr
            }
        }

        guard entry.audioStreamState.processedDataFormat else {
            return noErr
        }

        if let playingEntry = playerContext.audioPlayingEntry,
           playingEntry.seekRequest.requested, playingEntry.calculatedBitrate() > 0
        {
            processorCallback?(.processSource)
            if rendererContext.waiting.value {
                rendererContext.packetsSemaphore.signal()
            }
            return noErr
        }

        var consecutiveNoFrames = 0
        var totalDecoded = 0

        decodeLoop: while true {
            if playerContext.internalState == .disposed
                || playerContext.internalState == .pendingNext
                || playerContext.internalState == .stopped
            {
                break
            }

            rendererContext.lock.lock()
            let totalFrames = rendererContext.bufferContext.totalFrameCount
            let usedFrames = rendererContext.bufferContext.frameUsedCount
            rendererContext.lock.unlock()

            guard usedFrames <= totalFrames else {
                break decodeLoop
            }

            var framesLeft = totalFrames - usedFrames

            if framesLeft == 0 {
                while true {
                    rendererContext.lock.lock()
                    let totalFrames = rendererContext.bufferContext.totalFrameCount
                    let usedFrames = rendererContext.bufferContext.frameUsedCount
                    rendererContext.lock.unlock()

                    if usedFrames > totalFrames {
                        break decodeLoop
                    }

                    framesLeft = totalFrames - usedFrames

                    if framesLeft > 0 {
                        break
                    }

                    if playerContext.internalState == .disposed
                        || playerContext.internalState == .pendingNext
                        || playerContext.internalState == .stopped
                    {
                        break decodeLoop
                    }

                    if let playingEntry = playerContext.audioPlayingEntry,
                       playingEntry.seekRequest.requested, playingEntry.calculatedBitrate() > 0
                    {
                        processorCallback?(.processSource)
                        if rendererContext.waiting.value {
                            rendererContext.packetsSemaphore.signal()
                        }
                        break decodeLoop
                    }

                    rendererContext.waiting.write { $0 = true }
                    rendererContext.packetsSemaphore.wait()
                    rendererContext.waiting.write { $0 = false }
                }
            }

            let status = decodeAndFillBuffer()
            if status != noErr {
                consecutiveNoFrames += 1
                if consecutiveNoFrames >= 3 {
                    break decodeLoop
                }
            } else {
                consecutiveNoFrames = 0
                totalDecoded += 1
            }
        }

        if totalDecoded > 0 && rendererContext.waiting.value {
            rendererContext.packetsSemaphore.signal()
        }

        return noErr
    }

    private func decodeAndFillBuffer() -> OSStatus {
        guard let pcmBuffer = pcmBuffer else {
            return OSStatus(-1)
        }

        let framesRead = opDecoder.readFrames(into: pcmBuffer, frameCount: frameCount)

        if framesRead <= 0 {
            return OSStatus(-1)
        }

        pcmBuffer.frameLength = UInt32(framesRead)
        processDecodedAudio(pcmBuffer: pcmBuffer, framesRead: framesRead)
        totalFramesProcessed += framesRead

        return noErr
    }

    // MARK: - Audio Format

    private func setupAudioFormat() {
        guard let entry = playerContext.audioReadingEntry,
              let processingFormat = opDecoder.processingFormat else { return }

        entry.lock.lock()

        let asbd = processingFormat.streamDescription.pointee

        entry.audioStreamFormat = asbd
        entry.sampleRate = Float(opDecoder.sampleRate)
        entry.packetDuration = Double(1) / Double(opDecoder.sampleRate)

        if opDecoder.totalPcmSamples > 0 {
            entry.audioStreamState.dataPacketOffset = UInt64(opDecoder.totalPcmSamples)
        } else {
            // Opus streaming: estimate duration from content-length and bitrate
            // Use a conservative estimate since we don't have nominal bitrate from Opus headers
            let estimatedBitrate = opDecoder.channels == 2 ? 160_000.0 : 96_000.0
            entry.audioStreamState.bitRate = estimatedBitrate * 0.96
        }
        entry.audioStreamState.processedDataFormat = true
        entry.audioStreamState.readyForDecoding = true
        entry.lock.unlock()

        createAudioConverter(from: processingFormat, to: outputAudioFormat)
    }

    private func createAudioConverter(from sourceFormat: AVAudioFormat, to destFormat: AudioStreamBasicDescription) {
        audioConverter = nil

        var dest = destFormat

        guard let destAVFormat = AVAudioFormat(streamDescription: &dest) else {
            Logger.error("Failed to create output AVAudioFormat for Opus", category: .audioRendering)
            return
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: destAVFormat) else {
            Logger.error("Failed to create AVAudioConverter for Opus", category: .audioRendering)
            return
        }

        audioConverter = converter
    }

    // MARK: - Audio Processing

    private func processDecodedAudio(pcmBuffer: AVAudioPCMBuffer, framesRead: Int) {
        guard playerContext.audioReadingEntry != nil,
              let converter = audioConverter else { return }

        pcmBuffer.frameLength = UInt32(framesRead)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: UInt32(framesRead)
        ) else { return }

        rendererContext.lock.lock()
        let bufferContext = rendererContext.bufferContext
        let used = bufferContext.frameUsedCount
        let totalFrames = bufferContext.totalFrameCount
        rendererContext.lock.unlock()

        guard used <= totalFrames else {
            return
        }

        var framesLeft = totalFrames - used

        if framesLeft == 0 {
            while true {
                rendererContext.lock.lock()
                let currentUsed = rendererContext.bufferContext.frameUsedCount
                let currentTotal = rendererContext.bufferContext.totalFrameCount
                rendererContext.lock.unlock()

                if currentUsed > currentTotal {
                    return
                }

                framesLeft = currentTotal - currentUsed
                if framesLeft > 0 {
                    break
                }

                if playerContext.internalState == .disposed
                    || playerContext.internalState == .pendingNext
                    || playerContext.internalState == .stopped
                {
                    return
                }

                if let playingEntry = playerContext.audioPlayingEntry,
                   playingEntry.seekRequest.requested, playingEntry.calculatedBitrate() > 0
                {
                    processorCallback?(.processSource)
                    if rendererContext.waiting.value {
                        rendererContext.packetsSemaphore.signal()
                    }
                    return
                }

                rendererContext.waiting.write { $0 = true }
                rendererContext.packetsSemaphore.wait()
                rendererContext.waiting.write { $0 = false }
            }
        }

        var error: NSError?
        var inputConsumed = false

        let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return pcmBuffer
        }

        guard status != .error, outputBuffer.frameLength > 0 else {
            return
        }

        rendererContext.lock.lock()
        let currentEnd = (rendererContext.bufferContext.frameStartIndex + rendererContext.bufferContext.frameUsedCount) % rendererContext.bufferContext.totalFrameCount
        let totalFrameCount = rendererContext.bufferContext.totalFrameCount
        let currentUsed = rendererContext.bufferContext.frameUsedCount
        let start = rendererContext.bufferContext.frameStartIndex
        rendererContext.lock.unlock()

        let actualFramesLeft = totalFrameCount - currentUsed
        let framesToCopy = min(UInt32(outputBuffer.frameLength), actualFramesLeft)

        guard let sourceData = outputBuffer.audioBufferList.pointee.mBuffers.mData?.assumingMemoryBound(to: UInt8.self) else { return }
        let bytesPerFrame = Int(rendererContext.bufferContext.sizeInBytes)
        let destData = rendererContext.audioBuffer.mData?.assumingMemoryBound(to: UInt8.self)

        if currentEnd >= start {
            let framesToEnd = totalFrameCount - currentEnd
            let firstChunkFrames = min(framesToCopy, framesToEnd)
            let firstChunkBytes = Int(firstChunkFrames) * bytesPerFrame
            let firstChunkOffset = Int(currentEnd) * bytesPerFrame

            memcpy(destData?.advanced(by: firstChunkOffset), sourceData, firstChunkBytes)

            if firstChunkFrames < framesToCopy {
                let secondChunkFrames = framesToCopy - firstChunkFrames
                let secondChunkBytes = Int(secondChunkFrames) * bytesPerFrame
                memcpy(destData, sourceData.advanced(by: firstChunkBytes), secondChunkBytes)
            }
        } else {
            let chunkBytes = Int(framesToCopy) * bytesPerFrame
            let offset = Int(currentEnd) * bytesPerFrame
            memcpy(destData?.advanced(by: offset), sourceData, chunkBytes)
        }

        fillUsedFrames(framesCount: framesToCopy)
        updateProcessedPackets(inNumberPackets: framesToCopy)
    }

    func processSeek() {
        guard let readingEntry = playerContext.audioReadingEntry else { return }

        guard readingEntry.calculatedBitrate() > 0.0 || readingEntry.length > 0 else {
            return
        }

        let entryDuration = readingEntry.duration()
        let duration = entryDuration < readingEntry.progress && entryDuration > 0
            ? readingEntry.progress : entryDuration
        guard duration > 0.0 else { return }

        let dataLengthInBytes = Double(readingEntry.audioDataLengthBytes())
        var seekByteOffset = Int64((readingEntry.seekRequest.time / duration) * dataLengthInBytes)

        // Clamp to avoid seeking past end
        let safetyMargin = Int64(2 * 65536)
        if seekByteOffset > Int64(readingEntry.length) - safetyMargin {
            seekByteOffset = max(0, Int64(readingEntry.length) - safetyMargin)
        }

        readingEntry.lock.lock()
        readingEntry.seekTime = readingEntry.seekRequest.time
        readingEntry.lock.unlock()

        // Reset the Opus decoder so it re-initializes from fresh data
        opDecoder.destroy()
        isInitialized = false
        totalFramesProcessed = 0
        cleanupBuffers()
        audioConverter = nil

        readingEntry.reset()
        readingEntry.seek(at: Int(seekByteOffset))
        rendererContext.waitingForDataAfterSeekFrameCount.write { $0 = 0 }
        playerContext.setInternalState(to: .waitingForDataAfterSeek)
        rendererContext.resetBuffers()
    }

    // MARK: - Helpers

    private func updateProcessedPackets(inNumberPackets: UInt32) {
        guard let readingEntry = playerContext.audioReadingEntry else { return }
        let processedPackCount = readingEntry.processedPacketsState.count
        let maxPackets = 4096

        if processedPackCount < maxPackets {
            let count = min(Int(inNumberPackets), maxPackets - Int(processedPackCount))
            let packetSize: UInt32 = UInt32(readingEntry.audioStreamFormat.mBytesPerFrame)

            readingEntry.lock.lock()
            readingEntry.processedPacketsState.sizeTotal += (packetSize * UInt32(count))
            readingEntry.processedPacketsState.count += UInt32(count)
            readingEntry.lock.unlock()
        }
    }

    @inline(__always)
    private func fillUsedFrames(framesCount: UInt32) {
        rendererContext.lock.lock()
        rendererContext.bufferContext.frameUsedCount += framesCount
        rendererContext.lock.unlock()

        playerContext.audioReadingEntry?.lock.lock()
        playerContext.audioReadingEntry?.framesState.queued += Int(framesCount)
        playerContext.audioReadingEntry?.lock.unlock()
    }

    private func cleanupBuffers() {
        pcmBuffer = nil
    }
}
