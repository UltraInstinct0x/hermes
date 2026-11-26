import Foundation

/// A hard cap on engine restarts so a configuration-change storm can never spin: at most `limit` restarts within
/// `window`. Pure; the caller passes a monotonic time.
public struct RestartLimiter: Sendable, Equatable {
    public let limit: Int
    public let window: Duration
    private var times: [Duration] = []

    public init(limit: Int = 3, window: Duration = .seconds(5)) {
        self.limit = limit
        self.window = window
    }

    /// True (and the restart is counted) when another restart is allowed now.
    public mutating func allow(at now: Duration) -> Bool {
        times.removeAll { now - $0 >= window }
        guard times.count < limit else { return false }
        times.append(now)
        return true
    }
}
