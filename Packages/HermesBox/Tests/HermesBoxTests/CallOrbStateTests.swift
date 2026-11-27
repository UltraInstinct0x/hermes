import Foundation
import Testing

@testable import HermesBox

private func liveSession() -> CallSession {
    var session = CallSession(intent: .start(botKey: testBotKey, engine: .free))
    if case .helloOk(let hello)? = CallInbound.parse(Hub.helloOk()) { _ = session.linkUp(hello) }
    if let started = CallInbound.parse(Hub.started(id: "c1")) { _ = session.handle(started) }
    return session
}

private func orb(
    _ session: CallSession?, phase: CallController.Phase = .running, muted: Bool = false, hold: CallHold? = nil, user: Bool = false,
    playing: Bool = false, gaveUp: Bool = false
) -> CallOrbState {
    CallOrbState(phase: phase, session: session, muted: muted, hold: hold, userSpeaking: user, playing: playing, thinkingGaveUp: gaveUp)
}

@Suite("Call orb state and content pane")
struct CallOrbStateTests {
    @Test func idleIsNeutralAndEndedIsPaused() {
        #expect(orb(nil, phase: .idle) == .neutral)
        #expect(orb(nil, phase: .over(.byClient)) == .paused)
    }

    @Test func noSessionOrNoCallYetIsConnecting() {
        #expect(orb(nil) == .connecting)
        #expect(orb(CallSession(intent: .start(botKey: testBotKey, engine: .free))) == .connecting)
    }

    @Test func aLiveOwnedCallListensAndFollowsTheFlags() {
        let session = liveSession()
        #expect(orb(session) == .listening)
        #expect(orb(session, user: true) == .listening)
        #expect(orb(session, playing: true) == .speaking)
        #expect(orb(session, muted: true) == .muted)
        #expect(orb(session, hold: .interrupted) == .paused)
        #expect(orb(session, muted: true, playing: true) == .speaking)
        #expect(orb(session, hold: .interrupted, playing: true) == .paused)
    }

    @Test func orbSentencesAreCalmAndHaveNoEmDash() {
        let session = liveSession()
        #expect(orb(session).sentence == "Listening")
        #expect(orb(session, playing: true).sentence == "The bot is speaking")
        #expect(orb(session, hold: .audioTaken).sentence == "On hold")
        #expect(orb(nil).sentence == "Connecting")
        #expect(orb(session, muted: true).sentence == "Muted")
        #expect(CallOrbState.allCases.allSatisfy { !$0.sentence.contains("\u{2014}") })
    }

    @Test func aNewScreenItemSwitchesToTheScreenAndClearingGoesBack() {
        #expect(CallContentPane.following(current: .transcript, oldCount: 0, newCount: 1) == .screen)
        #expect(CallContentPane.following(current: .transcript, oldCount: 1, newCount: 2) == .screen)
        #expect(CallContentPane.following(current: .screen, oldCount: 2, newCount: 0) == .transcript)
        #expect(CallContentPane.following(current: .transcript, oldCount: 2, newCount: 2) == .transcript)
        #expect(CallContentPane.following(current: .screen, oldCount: 3, newCount: 2) == .screen)
    }

    @Test func followStopsWhenScrolledUp() {
        #expect(CallTranscriptFollow.isAtBottom(distanceFromBottom: 0))
        #expect(CallTranscriptFollow.isAtBottom(distanceFromBottom: 20))
        #expect(!CallTranscriptFollow.isAtBottom(distanceFromBottom: 200))
    }
}
