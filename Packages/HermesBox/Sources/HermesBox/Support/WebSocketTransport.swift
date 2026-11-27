import Foundation

public enum WebSocketMessage: Sendable, Equatable {
    case text(String)
    case binary(Data)

    /// The frame as UTF-8 text (the shared client's `wireFrameText`); nil for undecodable binary.
    public var frameText: String? {
        switch self {
        case .text(let text): return text
        case .binary(let data): return String(data: data, encoding: .utf8)
        }
    }
}

/// The socket closed. `code` is the WebSocket close code when the peer sent one.
public struct WebSocketClosed: Error, Sendable, Equatable {
    public var code: Int?
    public var reason: String?

    public init(code: Int? = nil, reason: String? = nil) {
        self.code = code
        self.reason = reason
    }
}

/// One open WebSocket. The gateway client never learns whether it is URLSession or a test fake.
public protocol WebSocketConnection: Sendable {
    func send(_ text: String) async throws
    /// One binary frame (the Bot Screen's RFB stream). Sockets that only speak text keep the default,
    /// which refuses.
    func send(binary: Data) async throws
    /// Next inbound message; throws `WebSocketClosed` (or a transport error) once the socket is gone.
    func receive() async throws -> WebSocketMessage
    func close(code: Int, reason: String?) async
}

extension WebSocketConnection {
    public func send(binary: Data) async throws {
        throw WebSocketClosed(code: nil, reason: "binary frames are not supported")
    }
}

/// Close code that means "drop the link without a close handshake"; the server then sees an abnormal
/// close (1006). The Bot Screen uses it so that leaving the screen never releases the display lease by
/// itself: the gateway releases only on a clean 1000 or 1001 close (`hermes_cli/web_routers/display.py`).
public let webSocketAbruptCloseCode = 1006

/// Opens WebSockets. Production: `URLSessionWebSocketConnector`; tests: a fake.
public protocol WebSocketConnector: Sendable {
    /// Resolves once the handshake completed. Throws on refusal or failure before open.
    func connect(to url: URL, headers: [String: String]) async throws -> any WebSocketConnection
}

/// `URLSessionWebSocketTask` behind the connector protocol.
public struct URLSessionWebSocketConnector: WebSocketConnector {
    public init() {}

    public func connect(to url: URL, headers: [String: String]) async throws -> any WebSocketConnection {
        let connection = URLSessionWebSocketConnection()
        try await connection.open(url: url, headers: headers)
        return connection
    }
}

final class URLSessionWebSocketConnection: NSObject, WebSocketConnection, URLSessionWebSocketDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var closed: WebSocketClosed?

    func open(url: URL, headers: [String: String]) async throws {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        // The gateway sends large history frames: do not cap at URLSession's 1 MiB default.
        task.maximumMessageSize = 64 * 1024 * 1024
        lock.withLock {
            self.session = session
            self.task = task
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock { openContinuation = continuation }
                task.resume()
            }
        } onCancel: {
            self.finish(closed: WebSocketClosed(code: nil, reason: "cancelled"), cancel: true)
        }
    }

    func send(_ text: String) async throws {
        guard let task = lock.withLock({ self.task }) else { throw WebSocketClosed() }
        try await task.send(.string(text))
    }

    func send(binary: Data) async throws {
        guard let task = lock.withLock({ self.task }) else { throw WebSocketClosed() }
        try await task.send(.data(binary))
    }

    func receive() async throws -> WebSocketMessage {
        guard let task = lock.withLock({ self.task }) else { throw WebSocketClosed() }
        do {
            switch try await task.receive() {
            case .string(let text): return .text(text)
            case .data(let data): return .binary(data)
            @unknown default: return .binary(Data())
            }
        } catch {
            throw lock.withLock { closed } ?? error
        }
    }

    func close(code: Int, reason: String?) async {
        finish(closed: WebSocketClosed(code: code, reason: reason), cancel: false)
        if code == webSocketAbruptCloseCode {
            lock.withLock { task }?.cancel()  // no close frame: the peer sees an abnormal close
        } else {
            let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
            lock.withLock { task }?.cancel(with: closeCode, reason: reason?.data(using: .utf8))
        }
        lock.withLock { session }?.finishTasksAndInvalidate()
    }

    private func finish(closed value: WebSocketClosed, cancel: Bool) {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            if closed == nil { closed = value }
            defer { openContinuation = nil }
            return openContinuation
        }
        continuation?.resume(throwing: value)
        if cancel { lock.withLock { task }?.cancel() }
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?
    ) {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            defer { openContinuation = nil }
            return openContinuation
        }
        continuation?.resume()
    }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        let text = reason.flatMap { String(data: $0, encoding: .utf8) }
        finish(closed: WebSocketClosed(code: closeCode.rawValue, reason: text), cancel: false)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let http = task.response as? HTTPURLResponse
        let reason = http.map { "HTTP \($0.statusCode)" } ?? error?.localizedDescription
        finish(closed: WebSocketClosed(code: http?.statusCode, reason: reason), cancel: false)
    }
}
