import Foundation

/// Hermes Neo: answers a bot's waiting request (an approval or a question) on the box, from a Live Activity button or a
/// notification action, the way Hermes Bot's Waiting list does: the gateway's own ledger calls, through the box's
/// gateway socket (`wss://<box>/gw/<gatewayId>/api/ws`, device Bearer), one call per answer.
///
/// - Approve once / Deny: `request.answer {id, result: {choice: "once" | "deny"}, profile}`.
/// - A question's choice: `clarify.lock {request_id, question_id, answer, profile}`.
///
/// The gateway decides; an answer that came too late (the desktop was faster, or the request expired) is `.notWaiting`,
/// never a silent success.
public struct BoxRequestAnswers: Sendable {
    public enum Outcome: Sendable, Equatable {
        case answered
        /// The request no longer waits (answered elsewhere, expired).
        case notWaiting
        /// The box or the gateway could not be reached, or refused the call; the detail is for logs only.
        case failed(String)
    }

    private let url: @Sendable (String) -> URL?
    private let headers: @Sendable () async -> [String: String]
    private let connector: any WebSocketConnector
    private let timeout: Duration

    /// - Parameters:
    ///   - url: the gateway socket of a gateway id (`BFFClient.gatewayWebSocketURL`).
    ///   - headers: the device credential (`Authorization: Bearer …`).
    public init(
        url: @escaping @Sendable (String) -> URL?, headers: @escaping @Sendable () async -> [String: String],
        connector: any WebSocketConnector = URLSessionWebSocketConnector(), timeout: Duration = .seconds(30)
    ) {
        self.url = url
        self.headers = headers
        self.connector = connector
        self.timeout = timeout
    }

    /// Approve once (`allow`) or Deny the approval `requestId` of `botKey` (`gateway::profile`).
    public func answerApproval(botKey: String, requestId: String, allow: Bool) async -> Outcome {
        let key = BotKey(rawValue: botKey)
        let params: [String: Any] = ["id": requestId, "result": ["choice": allow ? "once" : "deny"], "profile": key.profileId]
        return await call(gatewayId: key.gatewayId, method: "request.answer", params: params)
    }

    /// Answer the single-select question `questionId` of `requestId` with `choice`.
    public func answerChoice(botKey: String, requestId: String, questionId: String, choice: String) async -> Outcome {
        let key = BotKey(rawValue: botKey)
        let params: [String: Any] = ["request_id": requestId, "question_id": questionId, "answer": choice, "profile": key.profileId]
        return await call(gatewayId: key.gatewayId, method: "clarify.lock", params: params)
    }

    // MARK: the one call

    private func call(gatewayId: String, method: String, params: [String: Any]) async -> Outcome {
        guard !gatewayId.isEmpty, let url = url(gatewayId) else { return .failed("no gateway socket for \(gatewayId)") }
        let id = Int.random(in: 1...999_999)
        let frame: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: frame), let text = String(data: data, encoding: .utf8) else {
            return .failed("could not encode \(method)")
        }
        let socket: any WebSocketConnection
        do {
            socket = try await connector.connect(to: url, headers: await headers())
        } catch {
            return .failed("\(method): could not open the gateway socket (\(Self.describe(error)))")
        }
        let outcome = await Self.exchange(socket: socket, text: text, id: id, method: method, timeout: timeout)
        await socket.close(code: 1000, reason: nil)
        return outcome
    }

    /// Sends the request and reads frames until its response, ignoring events and the gateway's own requests.
    private static func exchange(socket: any WebSocketConnection, text: String, id: Int, method: String, timeout: Duration) async -> Outcome {
        await withTaskGroup(of: Outcome?.self) { group in
            group.addTask {
                do {
                    try await socket.send(text)
                    while !Task.isCancelled {
                        guard let frame = try await socket.receive().frameText,
                            let object = (try? JSONSerialization.jsonObject(with: Data(frame.utf8))) as? [String: Any],
                            (object["id"] as? NSNumber)?.intValue == id, object["method"] == nil
                        else { continue }
                        return outcome(of: object, method: method)
                    }
                    return nil
                } catch {
                    return .failed("\(method): the gateway socket closed (\(describe(error)))")
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .failed("\(method): no answer within \(timeout)")
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            // A read that waits on the socket does not stop for a cancellation: closing the socket ends it.
            await socket.close(code: 1000, reason: nil)
            return first ?? .failed("\(method): cancelled")
        }
    }

    /// `{result: {status: "ok" | "expired", …}}` or `{error: {code, message}}`.
    static func outcome(of response: [String: Any], method: String) -> Outcome {
        if let error = response["error"] as? [String: Any] {
            let code = (error["code"] as? NSNumber).map { "\($0)" } ?? "-"
            return .failed("\(method) error \(code)")
        }
        let status = (response["result"] as? [String: Any])?["status"] as? String
        return status == "ok" ? .answered : .notWaiting
    }

    /// Errors as their type and code: a description can carry a URL.
    static func describe(_ error: any Error) -> String {
        if let closed = error as? WebSocketClosed { return "close \(closed.code.map(String.init) ?? "-")" }
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
}
