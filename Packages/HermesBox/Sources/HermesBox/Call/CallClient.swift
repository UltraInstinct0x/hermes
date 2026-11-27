import Foundation

/// Why the call link gave up for good. Each has one calm sentence in `CallPresentation`.
public enum CallLinkFailure: Sendable, Equatable {
    /// The BFF answered 404: the call route is not turned on for this machine.
    case disabled
    /// 401 or 403: the box did not accept this phone.
    case unauthorized
    /// Another connection of this phone took the call socket (close code 4009).
    case replaced
    /// The first connection never came up.
    case unreachable(detail: String)
    /// The link was down for longer than a call can wait (S19 R40: five minutes ownerless, plus the grace).
    case gaveUp(detail: String)
}

/// What the link reports to its owner.
public enum CallLinkEvent: Sendable, Equatable {
    /// Connected and the hub said hello (also after every reconnect).
    case up(HelloOk)
    /// The socket dropped; the client is trying again by itself.
    case down
    case inbound(CallInbound)
    /// One downlink PCM frame of speech.
    case audio(replyId: UInt32, pcm: Data)
    /// Terminal. Nothing more comes after this.
    case failed(CallLinkFailure)
}

/// The edge the call controller drives; `CallClient` is the real one, tests use a fake.
public protocol CallLink: Sendable {
    var events: AsyncStream<CallLinkEvent> { get }
    func open() async
    func send(_ message: CallOutbound) async
    /// True when the frame was handed to a live socket.
    func sendAudio(epoch: UInt32, pcm: Data) async -> Bool
    func close() async
}

/// How the link retries. Pure.
public struct CallReconnectPolicy: Sendable, Equatable {
    /// Quick first tries: the owner keeps the call for 15 s (S19 R8), so the first seconds matter.
    public var delays: [Duration] = [.zero, .milliseconds(500), .seconds(1), .seconds(2), .seconds(3)]
    public var steadyDelay: Duration = .seconds(5)
    /// An ownerless call lives five minutes; a little more is spent trying.
    public var giveUpAfter: Duration = .seconds(330)

    public init() {}

    public func delay(afterFailures count: Int) -> Duration {
        count < delays.count ? delays[count] : steadyDelay
    }

    public func shouldGiveUp(downFor elapsed: Duration) -> Bool { elapsed >= giveUpAfter }

    /// What a dropped or refused socket means. The close code is an HTTP status when the upgrade was refused.
    public static func classify(_ error: any Error) -> Verdict {
        guard let closed = error as? WebSocketClosed, let code = closed.code else { return .retry }
        switch code {
        case 404: return .fatal(.disabled)
        case 401, 403: return .fatal(.unauthorized)
        case 4009: return .fatal(.replaced)
        case 429: return .retryLater
        default: return .retry
        }
    }

    public enum Verdict: Sendable, Equatable {
        case retry
        /// Rate limited by the BFF: wait the steady delay at least.
        case retryLater
        case fatal(CallLinkFailure)
    }
}

/// The call hub socket through the BFF (`/gw/<id>/api/call/ws`): heartbeat, hello, reconnection. It decides nothing
/// about the call: it hands every frame to its owner and reports when the link drops and comes back.
///
/// Heartbeat (S19 R38): a `ping` every 20 s, the link is dead after 45 s without any frame. A dropped link is
/// redialled by the policy; the owner reads `.down` then `.up` and resumes with `call.join` (the session does that).
public actor CallClient: CallLink {
    public nonisolated let events: AsyncStream<CallLinkEvent>

    private let continuation: AsyncStream<CallLinkEvent>.Continuation
    private let url: @Sendable () async throws -> URL
    private let headers: @Sendable () async -> [String: String]
    private let connector: any WebSocketConnector
    private let time: any TimeSource
    private let policy: CallReconnectPolicy
    private let pingEvery: Duration
    private let deadAfter: Duration
    private let helloTimeout: Duration
    private var socket: (any WebSocketConnection)?
    private var supervisor: Task<Void, Never>?
    private var lastReceived: Duration = .zero
    private var closed = false

    public init(
        url: @escaping @Sendable () async throws -> URL, headers: @escaping @Sendable () async -> [String: String],
        connector: any WebSocketConnector, time: any TimeSource, policy: CallReconnectPolicy = CallReconnectPolicy(),
        pingEvery: Duration = .seconds(20), deadAfter: Duration = .seconds(45), helloTimeout: Duration = .seconds(10)
    ) {
        self.url = url
        self.headers = headers
        self.connector = connector
        self.time = time
        self.policy = policy
        self.pingEvery = pingEvery
        self.deadAfter = deadAfter
        self.helloTimeout = helloTimeout
        (events, continuation) = AsyncStream.makeStream(of: CallLinkEvent.self, bufferingPolicy: .unbounded)
    }

    public func open() {
        guard supervisor == nil, !closed else { return }
        supervisor = Task { await supervise() }
    }

    public func send(_ message: CallOutbound) async {
        try? await socket?.send(message.json)
    }

    public func sendAudio(epoch: UInt32, pcm: Data) async -> Bool {
        guard let socket else { return false }
        do {
            try await socket.send(binary: CallAudioFrame.encodeUp(epoch: epoch, pcm: pcm))
            return true
        } catch {
            return false
        }
    }

    public func close() async {
        closed = true
        supervisor?.cancel()
        supervisor = nil
        let current = socket
        socket = nil
        await current?.close(code: 1000, reason: "client closed")
        continuation.finish()
    }

    // MARK: supervision

    private func supervise() async {
        var failures = 0
        var wasUp = false
        var everUp = false
        var downSince: Duration?
        while !Task.isCancelled, !closed {
            do {
                let target = try await url()
                let ws = try await connector.connect(to: target, headers: await headers())
                socket = ws
                lastReceived = time.now()
                let hello = try await readHello(ws)
                failures = 0
                downSince = nil
                wasUp = true
                everUp = true
                continuation.yield(.up(hello))
                try await pump(ws)
            } catch {
                socket = nil
                if Task.isCancelled || closed { return }
                var extra: Duration = .zero
                switch CallReconnectPolicy.classify(error) {
                case .fatal(let failure):
                    continuation.yield(.failed(failure))
                    continuation.finish()
                    return
                case .retryLater: extra = policy.steadyDelay
                case .retry: break
                }
                if !everUp {
                    continuation.yield(.failed(.unreachable(detail: Self.describe(error))))
                    continuation.finish()
                    return
                }
                if wasUp {
                    wasUp = false
                    continuation.yield(.down)
                }
                let now = time.now()
                let since = downSince ?? now
                downSince = since
                if policy.shouldGiveUp(downFor: now - since) {
                    continuation.yield(.failed(.gaveUp(detail: Self.describe(error))))
                    continuation.finish()
                    return
                }
                try? await time.sleep(for: max(policy.delay(afterFailures: failures), extra))
                failures += 1
            }
        }
    }

    /// The hub sends `hello.ok` on connect; the first one is what counts.
    private func readHello(_ ws: any WebSocketConnection) async throws -> HelloOk {
        try await withDeadline(helloTimeout, time: time, onTimeout: WebSocketClosed(code: nil, reason: "no hello from the call service")) {
            while true {
                if case .text(let text) = try await ws.receive(), case .helloOk(let hello)? = CallInbound.parse(text) { return hello }
            }
        }
    }

    /// Read until the socket ends; ping while it lives; call it dead after `deadAfter` of silence.
    private func pump(_ ws: any WebSocketConnection) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.readLoop(ws) }
            group.addTask { try await self.heartbeat(ws) }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func readLoop(_ ws: any WebSocketConnection) async throws {
        while true {
            let message = try await ws.receive()
            lastReceived = time.now()
            switch message {
            case .text(let text):
                if let inbound = CallInbound.parse(text) {
                    if case .helloOk = inbound { continue }
                    continuation.yield(.inbound(inbound))
                }
            case .binary(let data):
                if let frame = CallAudioFrame.decodeDown(data) { continuation.yield(.audio(replyId: frame.replyId, pcm: frame.pcm)) }
            }
        }
    }

    private func heartbeat(_ ws: any WebSocketConnection) async throws {
        while true {
            try await time.sleep(for: pingEvery)
            if time.now() - lastReceived > deadAfter {
                await ws.close(code: webSocketAbruptCloseCode, reason: "no frames from the call service")
                throw WebSocketClosed(code: nil, reason: "silent link")
            }
            try await ws.send(CallOutbound.ping.json)
        }
    }

    private static func describe(_ error: any Error) -> String {
        if let closed = error as? WebSocketClosed {
            return "call socket closed code=\(closed.code.map(String.init) ?? "none") reason=\(closed.reason ?? "none")"
        }
        return String(describing: error)
    }
}
