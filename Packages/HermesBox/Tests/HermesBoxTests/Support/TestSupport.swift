import Foundation
import Synchronization

@testable import HermesBox

/// A lock-protected box that can be captured by escaping closures (a bare `Mutex` is noncopyable).
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    @discardableResult
    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R { try mutex.withLock { try body(&$0) } }
}


/// Let queued async work run. Real time, short: the work under test is all in-process.
func settle() async {
    try? await Task.sleep(for: .milliseconds(15))
}

/// Poll until `condition` holds (up to 3 s of real time), then fail loudly.
func eventually(_ message: String = "condition", _ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<300 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

/// A fake WebSocket: records what the client sends, delivers what the test pushes.
final class FakeWebSocket: WebSocketConnection {
    /// A single-reader queue (the client has exactly one reader).
    private final class Inbound: Sendable {
        typealias Item = Result<WebSocketMessage, WebSocketClosed>
        private struct State {
            var queue: [Item] = []
            var waiter: CheckedContinuation<Item?, Never>?
            var finished = false
        }
        private let state = Locked(State())

        func push(_ item: Item) {
            let waiter = state.withLock { s -> CheckedContinuation<Item?, Never>? in
                if s.finished { return nil }
                if let waiter = s.waiter { s.waiter = nil; return waiter }
                s.queue.append(item)
                return nil
            }
            waiter?.resume(returning: item)
        }

        func finish() {
            let waiter = state.withLock { s -> CheckedContinuation<Item?, Never>? in
                s.finished = true
                defer { s.waiter = nil }
                return s.waiter
            }
            waiter?.resume(returning: nil)
        }

        func next() async -> Item? {
            await withCheckedContinuation { (continuation: CheckedContinuation<Item?, Never>) in
                let immediate = state.withLock { s -> (Item?, Bool) in
                    if !s.queue.isEmpty { return (s.queue.removeFirst(), true) }
                    if s.finished { return (nil, true) }
                    s.waiter = continuation
                    return (nil, false)
                }
                if immediate.1 { continuation.resume(returning: immediate.0) }
            }
        }
    }

    private let sentFrames = Locked<[String]>([])
    private let closedWith = Locked<Int?>(nil)
    private let inbound = Inbound()

    init() {}

    var sent: [String] { sentFrames.withLock { $0 } }

    func send(_ text: String) async throws {
        if closedWith.withLock({ $0 }) != nil { throw WebSocketClosed(code: 1006) }
        sentFrames.withLock { $0.append(text) }
    }

    private let sentBinaryFrames = Locked<[Data]>([])

    /// The binary frames the client sent (the Bot Screen's RFB stream), in order.
    var sentBinary: [Data] { sentBinaryFrames.withLock { $0 } }

    func send(binary: Data) async throws {
        if closedWith.withLock({ $0 }) != nil { throw WebSocketClosed(code: 1006) }
        sentBinaryFrames.withLock { $0.append(binary) }
    }

    func pushBinary(_ data: Data) { inbound.push(.success(.binary(data))) }

    func receive() async throws -> WebSocketMessage {
        switch await inbound.next() {
        case .some(.success(let message)): return message
        case .some(.failure(let closed)): throw closed
        case .none: throw WebSocketClosed(code: 1000)
        }
    }

    func close(code: Int, reason: String?) async {
        closedWith.withLock { $0 = code }
        inbound.push(.failure(WebSocketClosed(code: code, reason: reason)))
        inbound.finish()
    }

    var closeCode: Int? { closedWith.withLock { $0 } }

    // MARK: test controls

    func push(_ text: String) { inbound.push(.success(.text(text))) }

    /// The peer goes away (a silent drop or an explicit close with a code).
    func drop(code: Int = 1006) {
        inbound.push(.failure(WebSocketClosed(code: code)))
        inbound.finish()
    }

    /// The peer goes away with no WebSocket close code and the transport's own words (a socket error, not a close frame).
    func dropWithoutCode(reason: String) {
        inbound.push(.failure(WebSocketClosed(code: nil, reason: reason)))
        inbound.finish()
    }

}

/// Hands out fake sockets, or fails on demand.
final class FakeConnector: WebSocketConnector {
    private struct State {
        var sockets: [FakeWebSocket] = []
        var failuresRemaining = 0
        var urls: [URL] = []
        var headers: [[String: String]] = []
    }

    private let state = Locked(State())

    init(failFirst: Int = 0) { state.withLock { $0.failuresRemaining = failFirst } }

    /// The next `count` dials fail (the box is unreachable).
    func failNext(_ count: Int) { state.withLock { $0.failuresRemaining = count } }

    var sockets: [FakeWebSocket] { state.withLock { $0.sockets } }
    var urls: [URL] { state.withLock { $0.urls } }
    var headers: [[String: String]] { state.withLock { $0.headers } }
    var last: FakeWebSocket? { sockets.last }

    func connect(to url: URL, headers: [String: String]) async throws -> any WebSocketConnection {
        let outcome = state.withLock { s -> FakeWebSocket? in
            s.urls.append(url)
            s.headers.append(headers)
            if s.failuresRemaining > 0 {
                s.failuresRemaining -= 1
                return nil
            }
            let socket = FakeWebSocket()
            s.sockets.append(socket)
            return socket
        }
        guard let socket = outcome else { throw WebSocketClosed(code: 403, reason: "HTTP 403") }
        return socket
    }
}
/// Collects an AsyncStream in the background.
final class Collector<Element: Sendable>: Sendable {
    private let items = Locked<[Element]>([])
    private let task: Task<Void, Never>

    init(_ stream: AsyncStream<Element>) {
        let box = items
        task = Task { for await element in stream { box.withLock { $0.append(element) } } }
    }

    var values: [Element] { items.withLock { $0 } }
    func stop() { task.cancel() }
}


/// A time source the test drives by hand: nothing sleeps for real, so "ping at 15 s, dead at 45 s" is
/// asserted exactly.
final class ManualTimeSource: TimeSource {
    private struct Sleeper {
        let id: Int
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct State {
        var now: Duration = .zero
        var nextId = 0
        var sleepers: [Sleeper] = []
    }

    private let state = Locked(State())

    func now() -> Duration { state.withLock { $0.now } }

    func sleep(for duration: Duration) async throws {
        let id = state.withLock { s -> Int in
            s.nextId += 1
            return s.nextId
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let outcome = state.withLock { s -> Result<Void, CancellationError>? in
                    if duration <= .zero { return .success(()) }
                    // The task may have been cancelled before this ran: onCancel already fired and
                    // found nobody to wake, so resume it here (otherwise a task group waits forever).
                    if Task.isCancelled { return .failure(CancellationError()) }
                    s.sleepers.append(Sleeper(id: id, deadline: s.now + duration, continuation: continuation))
                    return nil
                }
                switch outcome {
                case .success?: continuation.resume()
                case .failure(let error)?: continuation.resume(throwing: error)
                case nil: break
                }
            }
        } onCancel: {
            let gone = state.withLock { s -> CheckedContinuation<Void, Error>? in
                guard let index = s.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return s.sleepers.remove(at: index).continuation
            }
            gone?.resume(throwing: CancellationError())
        }
    }

    /// Move time forward, waking sleepers in deadline order and letting each run before the next.
    func advance(by duration: Duration) async {
        let target = state.withLock { $0.now + duration }
        while true {
            let next = state.withLock { s -> Sleeper? in
                guard let index = s.sleepers.indices.min(by: { s.sleepers[$0].deadline < s.sleepers[$1].deadline }),
                    s.sleepers[index].deadline <= target
                else { return nil }
                let sleeper = s.sleepers.remove(at: index)
                s.now = max(s.now, sleeper.deadline)
                return sleeper
            }
            guard let next else { break }
            next.continuation.resume()
            await settle()
        }
        state.withLock { $0.now = target }
        await settle()
    }

    var sleeperCount: Int { state.withLock { $0.sleepers.count } }
}

@MainActor
final class FakeAudioDriver: AudioSessionDriver {
    private(set) var activations: [AudioPurpose] = []
    private(set) var deactivations = 0
    var activationError: (any Error)?
    private var continuation: AsyncStream<AudioSessionEvent>.Continuation?

    func activate(_ purpose: AudioPurpose) throws {
        if let activationError { throw activationError }
        activations.append(purpose)
    }

    func deactivate() throws { deactivations += 1 }

    /// S27: category set without activation (a CallKit call).
    private(set) var configurations: [AudioPurpose] = []
    func configure(_ purpose: AudioPurpose) throws {
        if let activationError { throw activationError }
        configurations.append(purpose)
    }

    func events() -> AsyncStream<AudioSessionEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioSessionEvent.self)
        self.continuation = continuation
        return stream
    }

    func emit(_ event: AudioSessionEvent) { continuation?.yield(event) }
}

