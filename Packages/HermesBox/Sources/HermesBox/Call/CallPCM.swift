import Foundation

/// PCM16 little-endian helpers and the resampler that turns the microphone's Float32 into the hub's 16 kHz mono PCM16.
public enum PCM16 {
    public static func data(from samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let value = UInt16(bitPattern: sample)
            data.append(UInt8(value & 0xff))
            data.append(UInt8(value >> 8))
        }
        return data
    }

    public static func samples(from data: Data) -> [Int16] {
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count - 1, by: 2).map { Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8) }
    }

    /// Clamped conversion from [-1, 1].
    public static func sample(from float: Float) -> Int16 {
        Int16((max(-1, min(1, float)) * 32767).rounded())
    }

    /// Root mean square level in dBFS (0 is full scale). Silence is -120.
    public static func levelDb(_ samples: ArraySlice<Int16>) -> Double {
        guard !samples.isEmpty else { return -120 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        let rms = (sum / Double(samples.count)).squareRoot() / 32768
        return rms <= 0.000_001 ? -120 : 20 * log10(rms)
    }
}

/// Area-averaging resampler, with state so it can be fed buffer after buffer. Averaging over each output sample's
/// span is a plain low-pass, enough for speech going from 44.1 or 48 kHz down to 16 kHz.
public struct PCMResampler: Sendable {
    public let inputRate: Double
    public let outputRate: Double
    private var carry: [Float] = []
    /// Where the next output sample starts, in input samples from the start of `carry`.
    private var start: Double = 0

    public init(inputRate: Double, outputRate: Double) {
        self.inputRate = inputRate
        self.outputRate = outputRate
    }

    public mutating func process(_ input: [Float]) -> [Int16] {
        guard inputRate > 0, outputRate > 0 else { return [] }
        let buffer = carry + input
        let step = inputRate / outputRate
        var out: [Int16] = []
        while start + step <= Double(buffer.count) + 1e-9 {
            let end = start + step
            var sum = 0.0
            var index = Int(start.rounded(.down))
            while Double(index) < end, index < buffer.count {
                let overlap = min(end, Double(index + 1)) - max(start, Double(index))
                if overlap > 0 { sum += overlap * Double(buffer[index]) }
                index += 1
            }
            out.append(PCM16.sample(from: Float(sum / step)))
            start = end
        }
        let consumed = min(Int(start.rounded(.down)), buffer.count)
        carry = Array(buffer[consumed...])
        start -= Double(consumed)
        return out
    }
}

/// Turns whatever the microphone tap delivers into ONE mono Float channel. The voice-processing input can be
/// Int16 or Float32, planar or interleaved, one channel or several (only one of them carrying the voice).
/// Averaging channels would lower the level by the channel count and a format the code did not expect used to be
/// dropped without a word, so: pick the loudest channel, and report what could not be read.
public enum MicMixer {
    /// The channel with the most energy; ties go to the first.
    public static func loudestChannel(_ channels: [[Float]]) -> [Float] {
        guard var best = channels.first else { return [] }
        var bestEnergy = energy(best)
        for channel in channels.dropFirst() {
            let e = energy(channel)
            if e > bestEnergy {
                best = channel
                bestEnergy = e
            }
        }
        return best
    }

    /// Channel `channel` of interleaved samples (`stride` values per frame).
    public static func deinterleave<T>(_ samples: [T], stride: Int, channel: Int) -> [T] {
        guard stride > 0, channel >= 0, channel < stride else { return [] }
        return Swift.stride(from: channel, to: samples.count, by: stride).map { samples[$0] }
    }

    public static func floats(fromInt16 samples: [Int16]) -> [Float] { samples.map { Float($0) / 32768 } }
    public static func floats(fromInt32 samples: [Int32]) -> [Float] { samples.map { Float(Double($0) / 2_147_483_648) } }

    private static func energy(_ samples: [Float]) -> Double { samples.reduce(0) { $0 + Double($1) * Double($1) } }
}
