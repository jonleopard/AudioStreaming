import AudioCodecs
import AVFoundation
import Foundation
import OSLog

final class OpusFileDecoder {
    private var stream: OPStreamRef?
    private var of: OPFileRef?

    private(set) var sampleRate: Int = 0
    private(set) var channels: Int = 0
    private(set) var durationSeconds: Double = -1
    private(set) var totalPcmSamples: Int64 = -1
    private(set) var processingFormat: AVAudioFormat?

    private let decoderLock = NSLock()

    private var interleavedBuffer: UnsafeMutablePointer<Float>?
    private var interleavedBufferCapacity = 0

    func create(capacityBytes: Int) {
        decoderLock.lock()
        defer { decoderLock.unlock() }

        stream = OPStreamCreate(capacityBytes)
    }

    func destroy() {
        decoderLock.lock()
        defer { decoderLock.unlock() }

        if let of = of { OPFree(of) }
        if let stream = stream { OPStreamDestroy(stream) }
        of = nil
        stream = nil

        if let buf = interleavedBuffer {
            buf.deallocate()
            interleavedBuffer = nil
            interleavedBufferCapacity = 0
        }
    }

    deinit {
        destroy()
    }

    func push(_ data: Data) {
        decoderLock.lock()
        defer { decoderLock.unlock() }

        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                  rawBuf.count > 0,
                  let stream = stream else { return }

            OPStreamPush(stream, base, rawBuf.count)
        }
    }

    func availableBytes() -> Int {
        decoderLock.lock()
        defer { decoderLock.unlock() }

        guard let stream = stream else { return 0 }
        return Int(OPStreamAvailableBytes(stream))
    }

    func markEOF() {
        decoderLock.lock()
        defer { decoderLock.unlock() }

        if let stream = stream {
            OPStreamMarkEOF(stream)
        }
    }

    func openIfNeeded() throws {
        decoderLock.lock()
        defer { decoderLock.unlock() }

        guard of == nil, let stream = stream else { return }

        var outOF: OPFileRef?
        let rc = OPOpen(stream, &outOF)
        if rc < 0 {
            Logger.error("Failed to open Opus file: \(rc)", category: .audioRendering)
            throw NSError(domain: "OpusFileDecoder", code: Int(rc),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to open Opus file (error \(rc))"])
        }

        of = outOF

        var info = OPStreamInfo()
        if OPGetInfo(outOF, &info) == 0 {
            sampleRate = 48000
            channels = Int(info.channels)
            totalPcmSamples = Int64(info.total_pcm)
            durationSeconds = info.duration_seconds

            let layoutTag: AudioChannelLayoutTag
            switch channels {
            case 1: layoutTag = kAudioChannelLayoutTag_Mono
            case 2: layoutTag = kAudioChannelLayoutTag_Stereo
            default: layoutTag = kAudioChannelLayoutTag_Unknown | UInt32(channels)
            }

            guard let channelLayout = AVAudioChannelLayout(layoutTag: layoutTag) else { return }

            processingFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(sampleRate),
                interleaved: false,
                channelLayout: channelLayout
            )

            let capacity = 5760 * channels
            interleavedBuffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            interleavedBufferCapacity = capacity
        } else {
            Logger.error("Failed to get Opus stream info", category: .audioRendering)
        }
    }

    func readFrames(into buffer: AVAudioPCMBuffer, frameCount: Int) -> Int {
        decoderLock.lock()
        defer { decoderLock.unlock() }

        guard let of = of, channels > 0, let interleavedBuffer = interleavedBuffer else {
            return generateSilentFrames(into: buffer, frameCount: frameCount)
        }

        guard let floatChannelData = buffer.floatChannelData else {
            return generateSilentFrames(into: buffer, frameCount: frameCount)
        }

        let maxFrames = min(frameCount, interleavedBufferCapacity / channels)
        let samplesPerChannel = Int(OPReadFloat(of, interleavedBuffer, Int32(maxFrames), Int32(channels)))

        if samplesPerChannel <= 0 {
            return generateSilentFrames(into: buffer, frameCount: frameCount)
        }

        // De-interleave: op_read_float returns [L0,R0,L1,R1,...] → separate channels
        let channelCount = min(Int(buffer.format.channelCount), channels)
        for ch in 0..<channelCount {
            let output = floatChannelData[ch]
            for frame in 0..<samplesPerChannel {
                output[frame] = interleavedBuffer[frame * channels + ch]
            }
        }

        return samplesPerChannel
    }

    private func generateSilentFrames(into buffer: AVAudioPCMBuffer, frameCount: Int) -> Int {
        guard let floatChannelData = buffer.floatChannelData,
              channels > 0 else { return 1 }

        let framesToGenerate = min(128, frameCount)

        for ch in 0..<min(Int(buffer.format.channelCount), channels) {
            let dst = floatChannelData[ch]
            memset(dst, 0, framesToGenerate * MemoryLayout<Float>.stride)
        }

        return framesToGenerate
    }

    func reset() {
        destroy()
    }
}
