import Foundation
import HermesKit
import Testing

@MainActor @Test func watchCanReadFirstPublishedRequestsWhileQueuedRefreshIsStillRunning() async {
    let refresh = LedgerRefresh()
    let first = AsyncStream<Void>.makeStream()
    let publish = AsyncStream<Void>.makeStream()
    let second = AsyncStream<Void>.makeStream()
    let finish = AsyncStream<Void>.makeStream()
    var requestID: String?
    var scans = 0
    let watch = Task {
        await refresh.waitForSnapshot(hasSnapshot: false) {
            scans += 1
            if scans == 1 {
                first.continuation.finish()
                var gate = publish.stream.makeAsyncIterator()
                _ = await gate.next()
                requestID = "srq-first"
            } else {
                second.continuation.finish()
                var gate = finish.stream.makeAsyncIterator()
                _ = await gate.next()
                requestID = "srq-second"
            }
            return true
        }
        return requestID
    }

    var started = first.stream.makeAsyncIterator()
    _ = await started.next()
    await refresh.refresh {
        Issue.record("The overlapping refresh should queue a pass, not start another scan")
        return true
    }
    publish.continuation.finish()
    var queued = second.stream.makeAsyncIterator()
    _ = await queued.next()

    let timeout = Task {
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
        finish.continuation.finish()
    }
    #expect(await watch.value == "srq-first")
    await refresh.waitForSnapshot(hasSnapshot: requestID != nil) {
        Issue.record("The Watch should reuse a completed snapshot during the queued pass")
        return true
    }
    #expect(requestID == "srq-first")
    timeout.cancel()
    finish.continuation.finish()
}

@Test func legacyRequestScanKeepsApprovalsWhenOtherSessionsCannotBeRead() async throws {
    let source = LedgerSource.ID(gatewayID: "box", profileID: "writer")
    let scan = try await RequestLedgerClient.scanLegacyRequests(source: source) { method, params in
        #expect(params["profile"] == .string("writer"))
        if method == "session.list" {
            return .object(["sessions": .array([
                .object(["id": .string("broken")]),
                .object(["id": .string("stale"), "resolved_id": .string("owner")]),
            ])])
        }
        if params["session_id"] == .string("broken") { throw URLError(.timedOut) }
        #expect(method == "session.resume")
        #expect(params["session_id"] == .string("owner"))
        return .object(["open_requests": .array([
            .object(["id": .string("srq-exact"), "method": .string("approval"), "params": .object([:])]),
        ])])
    }
    #expect(scan.failure == .offline)
    #expect(scan.rows.map(\.requestID) == ["srq-exact"])
    #expect(scan.rows.first?.sessionID == "owner")
}

@Test func watchRequestCheckWireRoundTrips() throws {
    let request = WatchCompanion.Request.openRequests(UUID())
    let pending = WatchCompanion.Response.checkingRequests
    #expect(try JSONDecoder().decode(WatchCompanion.Request.self, from: JSONEncoder().encode(request)) == request)
    #expect(try JSONDecoder().decode(WatchCompanion.Response.self, from: JSONEncoder().encode(pending)) == pending)
}

@Test func watchRoutesDropRemovedGatewayBeforeAndAfterAnInFlightRefresh() throws {
    let removed = UUID()
    let kept = UUID()
    let removedID = try watchRow(kind: "approval", requestID: "srq-removed", ledger: "removed").id
    let keptID = try watchRow(kind: "approval", requestID: "srq-kept", ledger: "kept").id
    var routes = LedgerRouteCache<String>()
    routes.set("removed route", for: removedID, gateway: removed)
    routes.set("kept route", for: keptID, gateway: kept)
    let inFlight = routes

    #expect(routes[removedID] == "removed route")
    routes.remove(gateway: removed)
    #expect(routes[removedID] == nil)
    #expect(routes.gateway(for: removedID) == nil)
    #expect(routes[keptID] == "kept route")

    routes.replace(with: inFlight)
    #expect(routes[removedID] == nil)
    #expect(routes[keptID] == "kept route")
}

@Test func watchRequestUsesTheFullServerIDAndDoesNotAnswerASimilarRequest() throws {
    let row = try watchRow(kind: "approval", requestID: "srq-backup-24")
    let decoy = """
        {"method":"approval","id":"srq-backup-2","params":{"command":"tar -tf backup.tar","choices":["once","deny"]}}
        """
    let otherMethod = """
        {"method":"clarify","id":"srq-backup-24","params":{"questions":[{"question":"Continue?"}]}}
        """
    let missing = try #require(JSONValue.parse("""
        {"open_requests":[\(decoy),\(otherMethod)]}
        """))
    #expect(WatchCompanion.RequestCard(row: row, snapshot: missing, source: "Ops") == nil)

    let exact = """
        {"method":"approval","id":"srq-backup-24","params":{"request_id":"not-the-rpc-id","command":"tar -tf backup.tar","choices":["once","always","deny"]}}
        """
    let live = try #require(JSONValue.parse("""
        {"open_requests":[\(decoy),\(exact)]}
        """))
    let gateway = UUID()
    let card = try #require(WatchCompanion.RequestCard(row: row, snapshot: live, gateway: gateway, source: "Ops"))
    #expect(card.id.requestID == "srq-backup-24")
    #expect(card.content == .approval(command: "tar -tf backup.tar", decisions: [.once, .deny]))
    #expect(card.result(for: .approval(.once)) == .object(["choice": .string("once")]))
    let answer = WatchCompanion.Request.answer(card, .approval(.deny))
    #expect(try JSONDecoder().decode(WatchCompanion.Request.self, from: JSONEncoder().encode(answer)) == answer)
    let sameIDElsewhere = try watchRow(kind: "approval", requestID: "srq-backup-24", session: "another-chat")
    #expect(card.id != WatchCompanion.RequestCard.identity(of: sameIDElsewhere, gateway: gateway))
    #expect(card.id != WatchCompanion.RequestCard.identity(of: row, gateway: UUID()))
}

@Test func watchRequestsKeepFlaggedApprovalsOnThePhoneAndRejectExpiredCards() throws {
    let row = try watchRow(kind: "approval", requestID: "srq-flagged")
    let snapshot = try #require(JSONValue.parse("""
        {"open_requests":[{"method":"approval","id":"srq-flagged","params":{
          "command":"inspect report","smart_denied":true,"expires_at":100
        }}]}
        """))
    let open = try #require(WatchCompanion.RequestCard(row: row, snapshot: snapshot, source: "Ops",
                                                      now: Date(timeIntervalSince1970: 90)))
    #expect(open.content == .openOnPhone(isApproval: true))
    #expect(open.result(for: .approval(.deny)) == nil)
    #expect(open.isExpired(at: Date(timeIntervalSince1970: 100)))
    #expect(WatchCompanion.RequestCard(row: row, snapshot: snapshot, source: "Ops",
                                       now: Date(timeIntervalSince1970: 100)) == nil)
}

@Test func watchClarifyUsesQuestionIDsAndDoesNotOverwriteLockedAnswers() throws {
    let row = try watchRow(kind: "clarify", requestID: "srq-clarify")
    let snapshot = try #require(JSONValue.parse("""
        {"open_requests":[{"method":"clarify","id":"srq-clarify","params":{
          "questions":[{"qid":"locked","question":"Choose location","choices":["Home","Work"]},
                       {"qid":"words","question":"What's the title?","choices":["Draft"]},
                       {"qid":"format","question":"Pick formats","choices":["PDF","Markdown"],"multi_select":true}],
          "answers":{"locked":"Work"}
        }}]}
        """))
    let card = try #require(WatchCompanion.RequestCard(row: row, snapshot: snapshot, source: "Research Buddy"))
    let selected: [String: WatchCompanion.ClarifyAnswer] = ["words": .text("  Weekly notes\n"), "format": .choices(["Markdown", "PDF"])]
    #expect(card.result(for: .clarify(selected)) == .object(["answers": .object([
        "words": .string("Weekly notes"), "format": .array([.string("PDF"), .string("Markdown")])
    ])]))
    #expect(card.result(for: .clarify(selected.merging(["locked": .text("Home")]) { first, _ in first })) == nil)
    #expect(card.result(for: .clarify(["words": .text("Draft"), "format": .text("PDF")])) == nil)
    #expect(card.result(for: .clarify(["words": .text("Draft"), "format": .choices(["Other"])])) == nil)
}

private func watchRow(kind: String, requestID: String, session: String = "backups", ledger: String = "box-ledger-id") throws -> LedgerRow {
    try JSONDecoder().decode(LedgerRow.self, from: Data("""
        {"ledger_id":"\(ledger)","request_id":"\(requestID)","gateway_id":"home","profile":"ops",
         "session_id":"\(session)","kind":"\(kind)","state":"open","created_at":1}
        """.utf8))
}

@Test func watchCompanionKeepsIdenticalProfilesOnDifferentGatewaysSeparate() throws {
    let first = WatchCompanion.BotID(gateway: UUID(), profile: "ops")
    let second = WatchCompanion.BotID(gateway: UUID(), profile: "ops")
    #expect(first != second)
    let request = WatchCompanion.Request.latestReply(second)
    let encoded = try JSONEncoder().encode(request)
    #expect(try JSONDecoder().decode(WatchCompanion.Request.self, from: encoded) == request)

    let response = WatchCompanion.Response.roster([
        .init(id: first, title: "Ops", gatewayName: "Home", state: .offline),
        .init(id: second, title: "Ops", gatewayName: "Studio", state: .working)
    ], hasUnavailableGateway: true)
    let payload = try JSONEncoder().encode(response)
    #expect(try JSONDecoder().decode(WatchCompanion.Response.self, from: payload) == response)
}

@Test func watchCompanionShowsOnlyTheNewestVisibleAnswer() {
    let messages: [SessionMessage] = [
        .init(role: "assistant", content: .text("First answer")),
        .init(role: "user", content: .text("And next?")),
        .init(role: "assistant", content: .text("Latest answer")),
        .init(role: "user", content: .text("Run in the background")),
        .init(role: "assistant", content: .text("[SILENT]")),
        .init(role: "assistant", content: .text("Internal note"), displayKind: "hidden"),
        .init(role: "user", content: .text("[CONTEXT SUMMARY]: summary")),
        .init(role: "user", content: .text("Still waiting")),
        .init(role: "tool", content: .text("Tool result"))
    ]
    #expect(WatchCompanion.latestReply(in: messages) == "Latest answer")
    #expect(WatchCompanion.latestReply(in: Array(messages.suffix(2))) == nil)
}

@Test func watchCompanionBoundsTheReplyBeforeTransferringIt() {
    let text = String(repeating: "💬", count: 3_000)
    let message = SessionMessage(role: "assistant", content: .text(text))
    #expect(WatchCompanion.latestReply(in: [message]) == String(text.prefix(2_000)) + "…")
}

@Test func watchGatewayLabelsOnlyDisambiguateMatchingBotTitles() {
    let home = UUID()
    let studio = UUID()
    let first = WatchCompanion.Bot(id: .init(gateway: home, profile: "default"), title: "Hermes", gatewayName: "hermes", state: .idle)
    let second = WatchCompanion.Bot(id: .init(gateway: studio, profile: "default"), title: "Hermes", gatewayName: "Studio", state: .idle)
    let ada = WatchCompanion.Bot(id: .init(gateway: studio, profile: "writer"), title: "Ada", gatewayName: "Studio", state: .working)
    #expect(WatchCompanion.gatewayLabels(for: [first, ada]).isEmpty)
    #expect(WatchCompanion.gatewayLabels(for: [first, second, ada]) == [second.id: "Studio"])
}

@Test func watchReplyKeepsMarkdownFormattingWithoutLiveLinksOrFences() {
    let reply = WatchCompanion.formattedReply("""
        Two **new papers**, plus a [link](hermesapp://connect).

        ```swift
        let example = "**literal**"
        ```
        """)
    #expect(String(reply.characters) == "Two new papers, plus a link.\n\nlet example = \"**literal**\"")
    #expect(reply.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
    #expect(reply.runs.contains { $0.inlinePresentationIntent == .code })
    #expect(reply.runs.allSatisfy { $0.link == nil })
}

@Test func watchReplyWaitsForARoutineDeliveryOnThePreviousPage() {
    let brief = """
        The nightly backup completed successfully and no files were skipped. The archive contains
        all shared documents, photos and settings. Verification compared checksums against the
        source, and the previous weekly snapshot is still available in cold storage.
        """
    let delivery = SessionMessage(role: "user", content: .text(
        "[Cronjob \"Backup\" output — scheduled job, not the user. Review it, act on anything that needs action, and summarize for the chat.]\n\n" + brief
    ), displayKind: "internal_notification")
    let echo = SessionMessage(role: "assistant", content: .text(brief))
    let earlier = SessionMessage(role: "assistant", content: .text("Earlier answer"))
    #expect(WatchCompanion.latestReply(in: [echo], hasEarlier: true) == nil)
    #expect(WatchCompanion.latestReply(in: [earlier, delivery, echo]) == "Earlier answer")
    #expect(WatchCompanion.latestReply(in: [earlier, delivery, echo], hasEarlier: true) == nil)
    let question = SessionMessage(role: "user", content: .text("Anything else?"))
    let answer = SessionMessage(role: "assistant", content: .text("Nothing else."))
    #expect(WatchCompanion.latestReply(in: [echo, question, answer], hasEarlier: true) == "Nothing else.")
}

@Test func watchReplyReplacesWidgetDirectivesBeforeSendingPreview() {
    let text = """
        Here is the result.

        ::widget{id="w_backup1" alt="Backup completed"}

        ::widget{id="w_backup2"}

        ```
        ::widget{id="w_example"}
        ```
        """
    let message = SessionMessage(role: "assistant", content: .text(text))
    #expect(WatchCompanion.latestReply(in: [message]) == """
        Here is the result.

        Backup completed

        View this card in Hermes on your iPhone.

        ```
        ::widget{id="w_example"}
        ```
        """)
}

@Test func watchReplyKeepsFencedWidgetExamplesAsCode() throws {
    let text = """
        For example:

        ```widget
        {"fallback_text": "The example JSON"}
        ```
        """
    let message = SessionMessage(role: "assistant", content: .text(text))
    let preview = try #require(WatchCompanion.latestReply(in: [message]))
    #expect(preview == text)
    let display = WatchCompanion.formattedReply(preview)
    #expect(display.runs.contains { $0.inlinePresentationIntent == .code })
}
