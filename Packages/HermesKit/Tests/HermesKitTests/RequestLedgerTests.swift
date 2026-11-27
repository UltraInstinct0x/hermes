import Foundation
import Testing
@testable import HermesKit

@Suite struct RequestLedgerTests {
    @Test func approvalReadsSafetyFromTheExactLiveFrame() throws {
        let row: LedgerRow = try RequestLedgerClient.decode(try #require(JSONValue.parse("""
            {"ledger_id":"target","request_id":"srq-target","profile":"default","kind":"approval","state":"open","created_at":2}
            """)))
        let snapshot = try #require(JSONValue.parse("""
            {"open_requests":[
              {"id":"srq-other","method":"approval","params":{"ledger_id":"target","command":"echo same"}},
              {"id":"srq-target","method":"approval","params":{"command":"echo same","smart_denied":true}}
            ]}
            """))
        let approval = try #require(row.approval(in: snapshot))
        #expect(approval.gatewayRequestID == "srq-target")
        #expect(approval.smartDenied)
        #expect(approval.command == "echo same")
        #expect(row.approval(in: .object([:])) == nil)
    }

    @Test func identicalQuestionsOnlyMatchTheirExactIDs() throws {
        let snapshot = try #require(JSONValue.parse("""
            {"open_requests":[
              {"id":"first","method":"clarify","params":{"questions":[{"qid":"one","question":"Continue?"}]}},
              {"id":"second","method":"clarify","params":{"questions":[{"qid":"two","question":"Continue?"}]}}
            ]}
            """))
        #expect(ExactClarifyAnswer.request(in: snapshot, requestID: "second")?.id == "second")
        #expect(ExactClarifyAnswer.request(in: snapshot, requestID: "expired") == nil)
        #expect(ExactClarifyAnswer.request(in: snapshot, requestID: "") == nil)

        let ledger = try RequestLedgerClient.decode(try #require(JSONValue.parse("""
            {"open":[
              {"ledger_id":"a","request_id":"first","profile":"default","kind":"clarify","state":"open",
               "choices":[{"qid":"one","question":"Continue?"}],"created_at":2},
              {"ledger_id":"b","request_id":"second","profile":"default","kind":"clarify","state":"open",
               "choices":[{"qid":"two","question":"Continue?"}],"created_at":3}],"recent":[],"open_count":2}
            """))) as LedgerSnapshot
        #expect(ExactClarifyAnswer.questions(in: ledger, ledgerID: "b")?.first?["qid"] == .string("two"))
        #expect(ExactClarifyAnswer.questions(in: ledger, ledgerID: "second") == nil)
    }

    private actor Gateway {
        var calls: [[String: JSONValue]] = []
        let identity: JSONValue = .object(["client_id": .string("phone"), "label": .string("iPhone"), "kind": .string("ios")])
        var firstIsOpen = true

        func answer(_ method: String, _ params: [String: JSONValue]) throws -> JSONValue {
            #expect(method == "request.answer")
            calls.append(params)
            #expect(params["profile"] == .string("researcher"))
            if params["id"] == .string("second") || (params["id"] == .string("first") && firstIsOpen) {
                if params["id"] == .string("first") { firstIsOpen = false }
                return .object(["status": .string("ok"), "answered_by": identity])
            }
            throw GatewayRPCError(code: 4065, message: "no longer pending", data: .object([
                "settlement": .object(["ledger_id": .string("first"), "outcome": .string("deny"), "answered_by": identity]),
            ]))
        }
    }

    @Test func repeatedAnswerOnlySettlesTheExactIDAndNamesTheWinner() async throws {
        let gateway = Gateway()
        let client = RequestLedgerClient(transport: { try await gateway.answer($0, $1) })
        let choice = ["choice": JSONValue.string("deny")]
        async let one = client.answer(ledgerID: "first", profile: "researcher", result: choice)
        async let two = client.answer(ledgerID: "first", profile: "researcher", result: choice)
        let answers = try await [one, two]
        let accepted = answers.compactMap { if case .accepted(let identity) = $0 { identity } else { nil } }
        let lost = answers.compactMap { if case .noLongerPending(let settlement) = $0 { settlement } else { nil } }
        #expect(accepted.count == 1)
        #expect(lost.map(\.ledgerID) == ["first"])
        #expect(lost.first?.answeredBy == accepted.first)
        #expect(try await client.answer(ledgerID: "unknown", profile: "researcher", result: choice) == .noLongerPending(nil))
        let called = await gateway.calls
        #expect(called.map { $0["id"] } == [.string("first"), .string("first"), .string("unknown")])
        #expect(called.allSatisfy { $0["result"] == .object(choice) })
        #expect(try await client.answer(ledgerID: "second", profile: "researcher", result: choice) == .accepted(accepted.first))
    }

    @Test func sourceFailureDoesNotHideOtherSourcesOrFallBackOnRefusal() async throws {
        let live = source("live", json: """
            {"open":[
              {"request_id":"ws1","ledger_id":"first","profile":"live","kind":"approval","state":"open","prompt":"Same",
               "session_id":"chat1","created_at":2,"expires_at":55},
              {"request_id":"ws2","ledger_id":"second","profile":"live","kind":"approval","state":"open","prompt":"Same",
               "session_id":"chat2","created_at":3,"expires_at":56}],"recent":[],"open_count":2}
            """)
        let oldID = LedgerSource.ID(gatewayID: "box", profileID: "old")
        let old = source("old", error: GatewayRPCError(code: -32601, message: "Method not found")) {
            let snapshot = try #require(JSONValue.parse("""
                {"open_requests":[{"id":"ws1","method":"approval","params":{"command":"Same"}}]}
                """))
            return RequestLedgerClient.legacyRows(snapshot: snapshot, sessionID: "old chat", source: oldID)
        }
        let privateSource = source("private", error: GatewayRPCError(code: 403, message: "Not authorized"))
        let offline = source("away", error: GatewaySocket.Failure.notConnected)
        let list = try await RequestLedgerClient.snapshot(sources: [live, old, privateSource, offline], federated: { nil })
        #expect(list.openCount == 3)
        #expect(list.open.compactMap(\.ledgerID) == ["first", "second"])
        #expect(list.open.first?.requestID == "ws1")
        #expect(list.open.first?.sessionID == "old chat")
        #expect(list.open.first?.ledgerID == nil)
        #expect(list.open.last?.expiresAt == 56)
        #expect(Dictionary(uniqueKeysWithValues: (list.sources ?? []).compactMap { source in source.profileID.map { ($0, source.state) } }) ==
            ["live": .live, "old": .unsupported, "private": .notAuthorized, "away": .offline])
    }

    @Test func boxSnapshotIsPreferredAndKeepsUnavailableSourcesDistinct() async throws {
        let box = source("box") {
            Issue.record("a covered source must not try legacy snapshots")
            return []
        }
        let snapshot = try await RequestLedgerClient.snapshot(sources: [box], federated: {
            try RequestLedgerClient.decode(try #require(JSONValue.parse("""
                {"open":[],"open_count":0,"recent":[],"sources":[
                  {"gateway_id":"box","profile_id":"box","status":"not_authorized"},
                  {"gateway_id":"remote","profile_id":null,"status":"offline"}]}
                """)))
        })
        #expect(snapshot.sources?.map(\.state) == [.notAuthorized, .offline])
        #expect(snapshot.sources?.last?.profileID == nil)
    }

    @Test func boxHistoryUsesAnOpaqueCursor() throws {
        let page: FederatedLedgerHistory = try RequestLedgerClient.decode(try #require(JSONValue.parse("""
            {"requests":[],"next_before":"eyJib3giOlsxLCJhIl19","sources":[
              {"gateway_id":"box","profile_id":null,"status":"offline"}]}
            """)))
        #expect(page.nextBefore == "eyJib3giOlsxLCJhIl19")
        #expect(page.sources.first?.state == .offline)
    }

    @Test func historyRequestsClosedStatesAndPreservesCursor() async throws {
        let client = RequestLedgerClient { method, params in
            #expect(method == "request.history")
            #expect(params["before"] == .number(20))
            #expect(params["states"] == .array(LedgerHistory.closedStates.map(JSONValue.string)))
            return try #require(JSONValue.parse("""
                {"requests":[{"request_id":"old","ledger_id":"old-id","profile":"test","kind":"clarify",
                "state":"lost_on_restart","created_at":10}],"next_before":10}
                """))
        }
        let page = try await client.history(profile: "test", gatewayID: "box", before: 20)
        #expect(page.nextBefore == 10)
        #expect(page.requests.first?.state == "lost_on_restart")
        #expect(page.requests.first?.answeredBy == nil)
    }

    private func source(
        _ profile: String, json: String? = nil, error: (any Error)? = nil,
        legacy: @escaping @Sendable () async throws -> [LedgerRow] = {
            Issue.record("only an unsupported method should fall back")
            return []
        }
    ) -> RequestLedgerClient.Source {
        .init(id: .init(gatewayID: "box", profileID: profile), client: .init { method, params in
            #expect(method == "request.list")
            #expect(params["profile"] == .string(profile))
            if let error { throw error }
            return try #require(json.flatMap(JSONValue.parse))
        }, legacy: legacy)
    }
}
