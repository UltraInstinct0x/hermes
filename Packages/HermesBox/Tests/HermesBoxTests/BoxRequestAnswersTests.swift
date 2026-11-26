import Foundation
import Testing

@testable import HermesBox

@Suite("Hermes Neo: answering a waiting request on the box's gateway socket")
struct BoxRequestAnswersTests {
    private let base = URL(string: "wss://box.example.ts.net:9443")!

    private func answers(_ connector: FakeConnector, timeout: Duration = .seconds(5)) -> BoxRequestAnswers {
        let base = base
        return BoxRequestAnswers(
            url: { base.appending(path: "gw/\($0)/api/ws") }, headers: { ["Authorization": "Bearer TEST-ONLY"] }, connector: connector,
            timeout: timeout)
    }

    /// The gateway answers the newest request it was sent, after an unrelated event.
    private func reply(on connector: FakeConnector, result: String) async throws -> [String: Any] {
        var socket: FakeWebSocket?
        for _ in 0..<300 {
            if let first = connector.sockets.first, !first.sent.isEmpty { socket = first; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let open = try #require(socket)
        let request = try #require(try JSONSerialization.jsonObject(with: Data(open.sent[0].utf8)) as? [String: Any])
        let id = try #require(request["id"] as? Int)
        open.push(#"{"jsonrpc":"2.0","method":"event","params":{"type":"turn.delta"}}"#)
        open.push(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#)
        return request
    }

    @Test func approveOnceIsRequestAnswerWithTheProfileOnThatGatewaysSocket() async throws {
        let connector = FakeConnector()
        let answering = Task { await answers(connector).answerApproval(botKey: "oracle::hermesbot", requestId: "req-1", allow: true) }
        let request = try await reply(on: connector, result: #"{"status":"ok"}"#)
        #expect(await answering.value == .answered)
        #expect(request["method"] as? String == "request.answer")
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["id"] as? String == "req-1" && params["profile"] as? String == "hermesbot")
        #expect((params["result"] as? [String: String]) == ["choice": "once"])
        #expect(connector.urls.first?.absoluteString == "wss://box.example.ts.net:9443/gw/oracle/api/ws")
        #expect(connector.headers.first?["Authorization"] == "Bearer TEST-ONLY")
        #expect(connector.sockets.first?.closeCode == 1000, "one call, then the socket closes")
    }

    @Test func denyIsTheDenyChoice() async throws {
        let connector = FakeConnector()
        let answering = Task { await answers(connector).answerApproval(botKey: "oracle::hermesbot", requestId: "req-2", allow: false) }
        let request = try await reply(on: connector, result: #"{"status":"ok"}"#)
        _ = await answering.value
        #expect(((request["params"] as? [String: Any])?["result"] as? [String: String]) == ["choice": "deny"])
    }

    @Test func aChoiceLocksTheQuestion() async throws {
        let connector = FakeConnector()
        let answering = Task {
            await answers(connector).answerChoice(botKey: "oracle::scout", requestId: "req-3", questionId: "q1", choice: "Tomorrow")
        }
        let request = try await reply(on: connector, result: #"{"status":"ok","remaining":[]}"#)
        #expect(await answering.value == .answered)
        #expect(request["method"] as? String == "clarify.lock")
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["request_id"] as? String == "req-3" && params["question_id"] as? String == "q1")
        #expect(params["answer"] as? String == "Tomorrow" && params["profile"] as? String == "scout")
    }

    @Test func aLateAnswerIsNotWaitingNeverASuccess() async throws {
        let connector = FakeConnector()
        let answering = Task { await answers(connector).answerApproval(botKey: "oracle::hermesbot", requestId: "req-4", allow: true) }
        _ = try await reply(on: connector, result: #"{"status":"expired"}"#)
        #expect(await answering.value == .notWaiting)
    }

    @Test func anUnreachableBoxOrASilentGatewayFails() async {
        let down = FakeConnector(failFirst: 1)
        guard case .failed = await answers(down).answerApproval(botKey: "oracle::hermesbot", requestId: "r", allow: true) else {
            Issue.record("expected a failure")
            return
        }
        let silent = FakeConnector()
        guard case .failed = await answers(silent, timeout: .milliseconds(50)).answerApproval(botKey: "oracle::hermesbot", requestId: "r", allow: true)
        else {
            Issue.record("expected a timeout")
            return
        }
    }

    @Test func aGatewayErrorIsAFailure() {
        let outcome = BoxRequestAnswers.outcome(of: ["id": 1, "error": ["code": -32602, "message": "bad params"]], method: "request.answer")
        #expect(outcome == .failed("request.answer error -32602"))
    }
}
