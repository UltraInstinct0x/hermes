import Foundation

/// A smoothed 0...1 level from raw readings: a fast attack so the picture follows the voice, a slower release so it does
/// not flicker. One-pole smoothing with time constants, so the result does not depend on how often it is called. Pure.
public struct LevelMeter: Sendable, Equatable {
    public static let attack: Double = 0.04
    public static let release: Double = 0.2
    /// The quietest sound that still moves the picture and the loudest speech (dBFS).
    public static let floorDb: Double = -55
    public static let ceilingDb: Double = -15

    public private(set) var level: Double = 0

    public init() {}

    /// Maps a dBFS reading (silence is -120) onto 0...1, linear in dB between `floorDb` and `ceilingDb`.
    public static func normalised(db: Double) -> Double {
        min(max((db - floorDb) / (ceilingDb - floorDb), 0), 1)
    }

    /// Moves the level towards `target` (0...1) over `dt` seconds and returns it.
    @discardableResult
    public mutating func advance(toward target: Double, dt: Double) -> Double {
        let goal = min(max(target, 0), 1)
        guard dt > 0 else { return level }
        let tau = goal > level ? Self.attack : Self.release
        level += (goal - level) * (1 - exp(-dt / tau))
        if level < 0.002 { level = 0 }
        return level
    }

    public mutating func reset() { level = 0 }
}

/// The last few levels at a fixed step, newest first, so a row of bars can show a travelling meter: bar `i` reads the level
/// `i * 60 ms` ago. Pure.
public struct LevelTrail: Sendable, Equatable {
    public static let capacity = 8
    public let step: Double
    public private(set) var samples: [Double]

    public init(step: Double = 1.0 / 30) {
        self.step = step
        samples = Array(repeating: 0, count: Self.capacity)
    }

    public var isSilent: Bool { samples.allSatisfy { $0 == 0 } }

    public mutating func push(_ level: Double) {
        samples.insert(min(max(level, 0), 1), at: 0)
        samples.removeLast(samples.count - Self.capacity)
    }

    /// The level `seconds` ago, interpolated between the two nearest samples; older than the trail is the oldest sample.
    public func level(secondsAgo seconds: Double) -> Double {
        let position = max(seconds, 0) / step
        let low = Int(position)
        guard low < samples.count - 1 else { return samples[samples.count - 1] }
        let fraction = position - Double(low)
        return samples[low] * (1 - fraction) + samples[low + 1] * fraction
    }

    public mutating func reset() { samples = Array(repeating: 0, count: Self.capacity) }
}
