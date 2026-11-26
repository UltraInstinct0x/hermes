import Foundation
import Testing

@testable import HermesBox

private func liveSession() -> CallSession {
    var session = CallSession(intent: .start(botKey: testBotKey, engine: .free))
    if case .helloOk(let hello)? = CallInbound.parse(Hub.helloOk()) { _ = session.linkUp(hello) }
    if let started = CallInbound.parse(Hub.started(id: "c1")) { _ = session.handle(started) }
    return session
}

private func standbyFrame(on: Bool, callId: String = testCallId) -> CallInbound? {
    CallInbound.parse(Hub.text(["type": "call.standby", "call_id": callId, "on": on, "at": 1]))
}

private func orb(_ session: CallSession?, muted: Bool = false, playing: Bool = false) -> CallOrbState {
    CallOrbState(phase: .running, session: session, muted: muted, hold: nil, userSpeaking: false, playing: playing)
}

@Suite("Call standby: decode, session, orb and sentence")
struct CallStandbyTests {
    @Test func theSharedFixtureDecodesAsTheHubSendsIt() throws {
        let url = try #require(Bundle.module.url(forResource: "call-standby-frames", withExtension: "json", subdirectory: "Fixtures"))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let list = try #require(root["frames"] as? [[String: Any]])
        #expect(list.count >= 4)
        for entry in list {
            let name = entry["name"] as? String ?? "?"
            let swift = try #require(entry["swift"] as? [String: Any])
            let frame = try #require(entry["frame"] as? [String: Any])
            let parsed = CallInbound.parse(Hub.text(frame))
            if swift["decodes"] as? String == "standby" {
                let on = try #require(swift["on"] as? Bool)
                #expect(parsed == .standby(callId: "11111111-2222-4333-8444-555555555555", on: on), "\(name)")
            } else {
                #expect(parsed == nil, "\(name)")
            }
        }
    }

    @Test func theSessionFollowsTheFrameAndIgnoresOtherCalls() throws {
        var session = liveSession()
        #expect(!session.standingBy)
        _ = session.handle(try #require(standbyFrame(on: true, callId: "someone-else")))
        #expect(!session.standingBy)
        _ = session.handle(try #require(standbyFrame(on: true)))
        #expect(session.standingBy)
        _ = session.handle(try #require(standbyFrame(on: false)))
        #expect(!session.standingBy)
    }

    @Test func theCallStaysOpenInStandbyAndTheFlagGoesWhenTheCallEnds() throws {
        var session = liveSession()
        _ = session.handle(try #require(standbyFrame(on: true)))
        #expect(session.ending == nil)
        let ended = try #require(CallInbound.parse(Hub.text(["type": "call.ended", "call_id": testCallId, "reason": "ended_by_client", "at": 3])))
        _ = session.handle(ended)
        #expect(session.ending != nil && !session.standingBy)
    }

    @Test func theOrbIsStandbyAfterSpeechAndTheSentenceIsCalm() throws {
        var session = liveSession()
        _ = session.handle(try #require(standbyFrame(on: true)))
        #expect(orb(session) == .standby)
        #expect(orb(session, playing: true) == .speaking, "the line that goes to standby is still heard first")
        #expect(orb(session, muted: true) == .muted)
        #expect(orb(session).sentence == "Standing by. Say \"Hermes\" to continue.")
        #expect(CallPresentation.stateLine(session: session, muted: false, hold: nil, userSpeaking: false, playing: false) == CallPresentation.standbySentence)
        _ = session.handle(try #require(standbyFrame(on: false)))
        #expect(orb(session) == .listening)
        #expect(CallOrbState.allCases.allSatisfy { !$0.sentence.contains("\u{2014}") })
    }
}
