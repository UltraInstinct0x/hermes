@preconcurrency import AVFAudio
import Foundation

// Hermes Neo: the microphone half of Hermes Bot's `AppleCallAudio`, kept as is. The engine itself is not ported: a call
// records and plays through the app's one `AudioGraph`, owned by `AudioCoordinator` (App/Calls/NeoCallAudio.swift), which
// alone configures the audio session.

/// Turns tap buffers into 16 kHz mono PCM16 samples. Used from the one audio thread of the tap.
///
/// The format is read from EACH buffer, never assumed from the node: with voice processing the format the node
/// reports before the engine starts can differ from what the tap delivers (rate, channels, Int16 or Float32). A
/// buffer in a layout that cannot be read is counted, never silently dropped.
public final class CallTapConverter: @unchecked Sendable {
    private var resampler: PCMResampler?
    private var rate: Double = 0
    private let emit: @Sendable ([Int16]) -> Void
    private let lock = NSLock()
    private var description = "no audio yet"
    private var buffers = 0
    private var unreadable = 0
    private let startedAt = Date()
    private var firstBufferAfter: Double?
    private let onFirstBuffer: @Sendable (String) -> Void

    public init(emit: @escaping @Sendable ([Int16]) -> Void, onFirstBuffer: @escaping @Sendable (String) -> Void = { _ in }) {
        self.emit = emit
        self.onFirstBuffer = onFirstBuffer
    }

    /// Seconds from engine start to the first tap buffer; nil while none came.
    public var timeToFirstBuffer: Double? { lock.withLock { firstBufferAfter } }

    /// "48000 Hz, 1 ch, Float32 planar; 312 buffers, 0 unreadable" for the Details block.
    public var summary: String { lock.withLock { "\(description); \(buffers) buffers, \(unreadable) unreadable" } }

    public func convert(_ buffer: AVAudioPCMBuffer) {
        let format = buffer.format
        let frames = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        guard frames > 0, channelCount > 0, let mono = monoSamples(buffer, frames: frames, channels: channelCount) else {
            lock.withLock { unreadable += 1 }
            return
        }
        var first: String?
        lock.withLock {
            buffers += 1
            if buffers == 1 || rate != format.sampleRate {
                description = "\(Int(format.sampleRate)) Hz, \(channelCount) ch, \(Self.name(format.commonFormat))\(format.isInterleaved ? " interleaved" : " planar")"
            }
            if buffers == 1 {
                let after = Date().timeIntervalSince(startedAt)
                firstBufferAfter = after
                first = "first tap buffer after \(String(format: "%.2f", after)) s: \(description)"
            }
        }
        if let first { onFirstBuffer(first) }
        if resampler == nil || rate != format.sampleRate {
            rate = format.sampleRate
            resampler = PCMResampler(inputRate: rate, outputRate: Double(CallAudioFrame.uplinkSampleRate))
        }
        guard let samples = resampler?.process(mono), !samples.isEmpty else { return }
        emit(samples)
    }

    private func monoSamples(_ buffer: AVAudioPCMBuffer, frames: Int, channels: Int) -> [Float]? {
        let interleaved = buffer.format.isInterleaved
        let stride = interleaved ? channels : 1
        let planes = interleaved ? 1 : channels
        var perChannel: [[Float]] = []
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData else { return nil }
            for plane in 0..<planes {
                let raw = Array(UnsafeBufferPointer(start: data[plane], count: frames * stride))
                for channel in 0..<(interleaved ? channels : 1) {
                    perChannel.append(MicMixer.deinterleave(raw, stride: stride, channel: channel))
                }
            }
        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData else { return nil }
            for plane in 0..<planes {
                let raw = Array(UnsafeBufferPointer(start: data[plane], count: frames * stride))
                for channel in 0..<(interleaved ? channels : 1) {
                    perChannel.append(MicMixer.floats(fromInt16: MicMixer.deinterleave(raw, stride: stride, channel: channel)))
                }
            }
        case .pcmFormatInt32:
            guard let data = buffer.int32ChannelData else { return nil }
            for plane in 0..<planes {
                let raw = Array(UnsafeBufferPointer(start: data[plane], count: frames * stride))
                for channel in 0..<(interleaved ? channels : 1) {
                    perChannel.append(MicMixer.floats(fromInt32: MicMixer.deinterleave(raw, stride: stride, channel: channel)))
                }
            }
        default:
            return nil
        }
        return MicMixer.loudestChannel(perChannel)
    }

    private static func name(_ format: AVAudioCommonFormat) -> String {
        switch format {
        case .pcmFormatFloat32: "Float32"
        case .pcmFormatInt16: "Int16"
        case .pcmFormatInt32: "Int32"
        case .pcmFormatFloat64: "Float64"
        default: "other"
        }
    }
}
