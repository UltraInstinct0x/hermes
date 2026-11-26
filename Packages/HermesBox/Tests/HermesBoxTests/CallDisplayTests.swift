import Foundation
import Testing

@testable import HermesBox

private struct Expectation {
    var decodes: String
    var kind: String?
    var secure: Bool?
}

private func samples() throws -> [(name: String, expectation: Expectation, text: String)] {
    let url = try #require(Bundle.module.url(forResource: "call-display-frames", withExtension: "json", subdirectory: "Fixtures"))
    let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let list = try #require(root["frames"] as? [[String: Any]])
    return try list.map { entry in
        let swift = try #require(entry["swift"] as? [String: Any])
        let frame = try #require(entry["frame"] as? [String: Any])
        let expectation = Expectation(
            decodes: swift["decodes"] as? String ?? "", kind: swift["kind"] as? String, secure: swift["secure"] as? Bool)
        return (entry["name"] as? String ?? "?", expectation, Hub.text(frame))
    }
}

private let fixtureCallId = "11111111-2222-4333-8444-555555555555"

private func item(_ n: Int, kind: CallDisplayKind = .markdown, title: String? = nil) -> CallDisplayItem {
    let id = "00000000-0000-4000-8000-\(String(format: "%012d", n))"
    return CallDisplayItem(
        id: id, kind: kind, title: title ?? "Item \(n)", body: kind == .markdown ? "text \(n)" : nil,
        url: kind == .markdown ? nil : "https://example.com/\(n)")
}

private func frame(_ item: CallDisplayItem, callId: String = testCallId) -> String {
    var body: [String: Any] = ["id": item.id, "kind": item.kind.rawValue, "title": item.title]
    if let text = item.body { body["body"] = text }
    if let url = item.url { body["url"] = url }
    return Hub.text(["type": "call.display", "call_id": callId, "item": body, "at": 1])
}

private func clearFrame(callId: String = testCallId) -> String {
    Hub.text(["type": "call.display.clear", "call_id": callId, "at": 2])
}

private func ownedSession() -> CallSession {
    var session = CallSession(intent: .start(botKey: testBotKey, engine: .free))
    if case .helloOk(let hello)? = CallInbound.parse(Hub.helloOk()) { _ = session.linkUp(hello) }
    if let started = CallInbound.parse(Hub.started(id: "c1")) { _ = session.handle(started) }
    return session
}

private func feed(_ session: inout CallSession, _ text: String) {
    guard let inbound = CallInbound.parse(text) else { fatalError("unparseable frame") }
    _ = session.handle(inbound)
}

@Suite("Call display: decode, list, session, link safety")
struct CallDisplayTests {
    @Test func theSharedFixtureDecodesAsTheHubSendsIt() throws {
        let all = try samples()
        #expect(all.count >= 8)
        for sample in all {
            let parsed = CallInbound.parse(sample.text)
            switch sample.expectation.decodes {
            case "display":
                guard case .display(let callId, let item)? = parsed else { Issue.record("\(sample.name): not a display frame"); continue }
                #expect(callId == fixtureCallId, "\(sample.name)")
                #expect(item.kind.rawValue == sample.expectation.kind, "\(sample.name)")
                #expect((CallDisplayPresentation.secureURL(item) != nil) == (sample.expectation.secure ?? false), "\(sample.name)")
            case "clear":
                #expect(parsed == .displayClear(callId: fixtureCallId), "\(sample.name)")
            default:
                #expect(parsed == .other(type: "call.display"), "\(sample.name)")
            }
        }
    }

    @Test func theListKeepsFiveNewestFirstAndAReusedIdReplaces() {
        var list = CallDisplayList()
        for n in 1...7 { list.apply(item(n)) }
        #expect(list.items.map(\.title) == ["Item 7", "Item 6", "Item 5", "Item 4", "Item 3"])
        list.apply(item(4, title: "Item 4 again"))
        #expect(list.items.count == 5)
        #expect(list.items.map(\.title) == ["Item 4 again", "Item 7", "Item 6", "Item 5", "Item 3"])
        list.clear()
        #expect(list.isEmpty)
    }

    @Test func aSessionShowsItemsAndAClearFrameEmptiesThem() {
        var session = ownedSession()
        feed(&session, frame(item(1)))
        feed(&session, frame(item(2, kind: .url)))
        #expect(session.display.items.map(\.id) == [item(2).id, item(1).id])
        feed(&session, clearFrame())
        #expect(session.display.isEmpty)
    }

    @Test func aSixthItemDropsTheOldestAndTheSameIdReplaces() {
        var session = ownedSession()
        for n in 1...6 { feed(&session, frame(item(n))) }
        #expect(session.display.items.count == 5 && !session.display.items.contains { $0.id == item(1).id })
        feed(&session, frame(item(3, title: "Renamed")))
        #expect(session.display.items.count == 5 && session.display.items.first?.title == "Renamed")
    }

    @Test func framesOfAnotherCallAreIgnored() {
        var session = ownedSession()
        feed(&session, frame(item(1)))
        feed(&session, frame(item(2), callId: fixtureCallId))
        feed(&session, clearFrame(callId: fixtureCallId))
        #expect(session.display.items.map(\.id) == [item(1).id])
    }

    @Test func theCallEndingClearsTheScreen() {
        var session = ownedSession()
        feed(&session, frame(item(1)))
        feed(&session, Hub.text(["type": "call.ended", "call_id": testCallId, "reason": "ended_by_client"]))
        #expect(session.isOver && session.display.isEmpty)
    }

    @Test func clearingLocallyEmptiesOnlyThisSession() {
        var session = ownedSession()
        feed(&session, frame(item(1)))
        session.clearDisplay()
        #expect(session.display.isEmpty)
        feed(&session, frame(item(2)))
        #expect(session.display.items.count == 1, "later items still arrive")
    }

    @Test func onlyPublicHttpsLinksAreEverOpenedOrLoaded() {
        let secure: (String) -> URL? = { CallDisplayPresentation.secureURL($0) }
        #expect(secure("https://example.com/a?b=1") != nil)
        #expect(secure("HTTPS://Example.com/a") != nil)
        for refused in [
            "http://example.com/", "javascript:alert(1)", "file:///etc/hosts", "data:text/html,hi", "hermes://x", "https://",
            "https://user:pw@example.com/", "https://localhost/", "https://printer.local/", "https://box.tail1.ts.net/", "https://intranet/",
            "https://10.0.0.1/", "https://127.0.0.1/", "https://192.168.1.2/", "https://172.16.0.1/", "https://169.254.1.1/",
            "https://100.64.0.1/", "https://[::1]/", "https://example.com/a b", "", "example.com",
        ] {
            #expect(secure(refused) == nil, "\(refused)")
        }
        #expect(secure("https://8.8.8.8/") != nil)
        #expect(CallDisplayPresentation.secureURL(item(1)) == nil, "a note has no link")
    }

    @Test func markdownKeepsInlineStyleAndDropsLinksThatAreNotHttps() {
        let text = CallDisplayPresentation.attributed(markdown: "**bold** [ok](https://example.com/) [bad](http://example.com/) [js](javascript:x)")
        let links = text.runs.compactMap(\.link).map(\.absoluteString)
        #expect(links == ["https://example.com/"])
        #expect(String(text.characters).contains("bold") && !String(text.characters).contains("**"))
    }

    @Test func titlesSymbolsAndLabelsFollowTheKind() {
        #expect(CallDisplayKind.allCases.map(CallDisplayPresentation.symbol) == ["doc.text", "link", "photo"])
        #expect(CallDisplayPresentation.accessibilityLabel(item(1, kind: .image, title: " Chart ")) == "Picture, Chart")
        #expect(CallDisplayPresentation.title(item(1, title: "  ")) == "Note")
        #expect(CallDisplayPresentation.pageLabel(index: 1, count: 3) == "Item 2 of 3")
        let copy = [CallDisplayPresentation.clearTitle, CallDisplayPresentation.clearHint, CallDisplayPresentation.imageUnavailable, CallDisplayPresentation.linkUnavailable]
        #expect(copy.allSatisfy { !$0.contains("\u{2014}") })
    }
}
