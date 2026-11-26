import Foundation

/// A monotonic clock the transport reads and sleeps on. Production uses `SystemTimeSource`; tests
/// drive time by hand so "ping at 15 s, dead at 45 s" is asserted exactly, with no real waiting.
public protocol TimeSource: Sendable {
    /// Monotonic time since an arbitrary origin.
    func now() -> Duration
    func sleep(for duration: Duration) async throws
}

public struct SystemTimeSource: TimeSource {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    public init() { origin = clock.now }

    public func now() -> Duration { origin.duration(to: clock.now) }

    public func sleep(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}

/// Run `operation`, but throw `onTimeout` if it does not finish within `duration` on `time`.
func withDeadline<T: Sendable>(
    _ duration: Duration,
    time: any TimeSource,
    onTimeout: @autoclosure @escaping @Sendable () -> any Error,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await time.sleep(for: duration)
            throw onTimeout()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
    }
}
