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
        // Must NOT hold decoderLock here — OPStreamPush may block waiting
        // for ring buffer space, while OPOpen (called under decoderLock)
        // blocks in op_read_cb waiting for data. The ring buffer has its
        // own pthread mutex for thread safety.
        let s: OPStreamRef?
        decoderLock.lock()
        s = stream
        decoderLock.unlock()

        guard let stream = s else { return }

        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                  rawBuf.count > 0 else { return }
            OPStreamPush(stream, base, rawBuf.count)
        }
    }

    func availableBytes() -> Int {
        decoderLock.lock()
        let s = stream
        decoderLock.unlock()

        guard let stream = s else { return 0 }
        return Int(OPStreamAvailableBytes(stream))
    }

    func markEOF() {
        decoderLock.lock()
        let s = stream
        decoderLock.unlock()

        if let stream = s {
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
            throw NSError(domain: "OpusFileDecoder", code: Int(rc),
                          userInfo: [NSLocalizedDescriptionKey: "OPOpen error \(rc)"])
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
            return 0
        }

        guard let floatChannelData = buffer.floatChannelData else {
            return 0
        }

        let maxFrames = min(frameCount, interleavedBufferCapacity / channels)
        let samplesPerChannel = Int(OPReadFloat(of, interleavedBuffer, Int32(maxFrames), Int32(channels)))

        if samplesPerChannel <= 0 {
            return 0
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

    func reset() {
        destroy()
    }
}
