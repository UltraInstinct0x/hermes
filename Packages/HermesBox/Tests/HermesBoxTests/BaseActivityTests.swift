import Foundation
import HermesActivityKit
import Testing

@testable import HermesBox

// S22: the always-on bubble's pure parts. The JSON samples below were produced by the box's own builders
// (`box/bff/push-planner.mjs`, `baseContentState` and `requestContentState`), so a change of keys on either side
// fails a test on the other.

private let serverBase = """
    {"mode":"call","machinesOnline":1,"machinesTotal":2,"waiting":3,"lastEvent":"Allowed once (hermesbot)","lastEventAt":1791000000,
     "updatedAt":1791000100,"call":{"botKey":"oracle::hermesbot","botName":"hermesbot","stateLine":"On a call","startedAt":1791000050,
     "ownerHere":false,"ownerName":"Gokhan Mac"}}
    """

private let serverIdle = #"{"mode":"idle","machinesOnline":2,"machinesTotal":2,"waiting":0,"updatedAt":1791000100}"#

private let serverRequest = """
    {"botKey":"oracle::hermesbot","requestId":"L1","botName":"hermesbot","style":"question","detail":"Which branch?","deadline":812692890,
     "since":812692800,"choices":["main","dev"],"needsApp":false,"questionId":"q1","moreWaiting":1}
    """

private func date(_ epoch: Int) -> Date { Date(timeIntervalSince1970: Double(epoch)) }

@Suite("S22 content states: what the box writes is what the app reads")
struct BoxContentStateTests {
    @Test func theBaseStateTheBoxBuildsDecodesInTheApp() throws {
        let state = try JSONDecoder().decode(BaseActivityAttributes.ContentState.self, from: Data(serverBase.utf8))
        #expect(state.mode == .call && state.machinesOnline == 1 && state.machinesTotal == 2 && state.waiting == 3)
        #expect(state.lastEvent == "Allowed once (hermesbot)" && state.lastEventAt == 1_791_000_000 && state.updatedAt == 1_791_000_100)
        #expect(state.call?.botName == "hermesbot" && state.call?.ownerHere == false && state.call?.ownerName == "Gokhan Mac")
        #expect(state.call?.isMuted == nil, "the box does not know mute")
    }

    @Test func theIdleStateWithNoEventDecodesAndInventsNoLine() throws {
        let state = try JSONDecoder().decode(BaseActivityAttributes.ContentState.self, from: Data(serverIdle.utf8))
        #expect(state.mode == .idle && state.lastEvent == nil && state.call == nil)
        #expect(BaseActivityPresentation(state).lastEventLine(now: date(1_791_000_200)) == nil)
    }

    @Test func theRequestStateTheBoxBuildsDecodesWithReferenceDateSeconds() throws {
        let state = try JSONDecoder().decode(RequestActivityAttributes.ContentState.self, from: Data(serverRequest.utf8))
        #expect(state.style == .question && state.choices == ["main", "dev"] && state.questionId == "q1" && state.moreWaiting == 1)
        // Dates are seconds since 2001-01-01 (the default Codable form ActivityKit uses for a pushed state).
        #expect(state.deadline == Date(timeIntervalSinceReferenceDate: 812_692_890))
        #expect(state.since == Date(timeIntervalSinceReferenceDate: 812_692_800))
        #expect(state.toolName == nil && state.outcome == nil)
    }

    @Test func theAppEncodesTheSameKeysTheBoxWrites() throws {
        let state = BaseActivityAttributes.ContentState(
            mode: .call, machinesOnline: 1, machinesTotal: 2, waiting: 3, lastEvent: "x", lastEventAt: 5, updatedAt: 6,
            call: .init(botKey: "g::p", botName: "p", stateLine: "On a call", startedAt: 7, ownerHere: true, ownerName: "n", isMuted: false))
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        #expect(Set(json.keys) == ["mode", "machinesOnline", "machinesTotal", "waiting", "lastEvent", "lastEventAt", "updatedAt", "call"])
        let call = try #require(json["call"] as? [String: Any])
        #expect(Set(call.keys) == ["botKey", "botName", "stateLine", "startedAt", "ownerHere", "ownerName", "isMuted"])
    }

    @Test func theStartAttributesAcceptWhatTheBoxSendsAndAnOlderServerWithoutStartedAt() throws {
        let withStart = try JSONDecoder().decode(BaseActivityAttributes.self, from: Data(#"{"title":"Hermes","startedAt":1791000000}"#.utf8))
        #expect(withStart.startedAt == 1_791_000_000)
        let without = try JSONDecoder().decode(BaseActivityAttributes.self, from: Data(#"{"title":"Hermes"}"#.utf8))
        #expect(without.startedAt == nil)
    }
}

@Suite("S22 base bubble words: honest about age, no em-dashes")
struct BasePresentationTests {
    private func state(online: Int = 2, total: Int = 2, waiting: Int = 0, event: String? = nil, at: Int? = nil, updated: Int = 1_000) -> BaseActivityAttributes.ContentState {
        .init(machinesOnline: online, machinesTotal: total, waiting: waiting, lastEvent: event, lastEventAt: at, updatedAt: updated)
    }

    @Test func theIdleLineSaysMachinesWaitingAndTheLastEventWithItsAge() {
        let line = BaseActivityPresentation(state(online: 1, total: 2, waiting: 1, event: "Allowed once (hermesbot)", at: 1_000)).idleLine(now: date(1_000 + 180))
        #expect(line == "1 of 2 machines online. 1 request waiting. Allowed once (hermesbot), 3 min ago")
    }

    @Test func machineAndWaitingWordsCoverTheEdges() {
        #expect(BaseActivityPresentation(state(online: 0, total: 2)).machinesLine == "No machine online")
        #expect(BaseActivityPresentation(state(online: 1, total: 1)).machinesLine == "1 machine online")
        #expect(BaseActivityPresentation(state(online: 0, total: 0)).machinesLine == nil, "no machine known yet: nothing is claimed")
        #expect(BaseActivityPresentation(state(waiting: 0)).waitingLine == "Nothing waiting")
        #expect(BaseActivityPresentation(state(waiting: 4)).waitingLine == "4 requests waiting")
    }

    @Test func ageWordsAndStaleness() {
        #expect(BaseActivityPresentation.age(seconds: 10) == "just now")
        #expect(BaseActivityPresentation.age(seconds: 125) == "2 min ago")
        #expect(BaseActivityPresentation.age(seconds: 7_300) == "2 h ago")
        #expect(BaseActivityPresentation.age(seconds: 90_000) == "1 d ago")
        let presentation = BaseActivityPresentation(state(updated: 1_000))
        #expect(!presentation.isStale(now: date(1_000 + 19 * 60)))
        #expect(presentation.isStale(now: date(1_000 + 21 * 60)))
        #expect(presentation.updatedLine(now: date(1_000 + 4 * 60)) == "Updated 4 min ago")
        #expect(presentation.staleLine(now: date(1_000 + 25 * 60)) == "Not updating. Updated 25 min ago")
    }

    @Test func theCallMorphShowsMuteOnlyOnThePhoneThatTalks() {
        var call = BaseActivityAttributes.ContentState.Call(botKey: "g::p", botName: "p", stateLine: "Listening", startedAt: 1, ownerHere: true)
        var s = state()
        s.mode = .call
        s.call = call
        var presentation = BaseActivityPresentation(s)
        #expect(presentation.isCall && presentation.showsMute && presentation.muteTitle == "Mute" && presentation.callSubtitle == "Listening")
        call.isMuted = true
        s.call = call
        presentation = BaseActivityPresentation(s)
        #expect(presentation.muteTitle == "Unmute" && presentation.callSubtitle == "Muted")
        call.ownerHere = false
        call.ownerName = "Gokhan's Mac"
        s.call = call
        presentation = BaseActivityPresentation(s)
        #expect(!presentation.showsMute && presentation.callSubtitle == "Listening (on Gokhan's Mac)")
    }

    @Test func theBubbleIsNamedAfterTheAppAndACallAfterItsBot() {
        // Owner 2026-10-12: the app's name reads "Hermes Bot", the app display name; a bot's own name is never replaced.
        #expect(ActivityBrand.name == "Hermes Bot" && ActivityBrand.markImageName == "HermesMark")
        let idle = BaseActivityPresentation(state(online: 1, total: 1, waiting: 0))
        #expect(idle.title == "Hermes Bot")
        #expect(idle.accessibilityLabel(now: date(1_000)).hasPrefix("Hermes Bot. "))
        #expect(BaseActivityAttributes().title == "Hermes Bot")
        var s = state()
        s.mode = .call
        s.call = .init(botKey: "g::p", botName: "alan", stateLine: "Listening", startedAt: 1, ownerHere: true)
        #expect(BaseActivityPresentation(s).title == "alan")
    }

    @Test func noWordIsAnEmDash() {
        var s = state(online: 1, total: 2, waiting: 2, event: "Denied (p)", at: 5)
        s.mode = .call
        s.call = .init(botKey: "g::p", botName: "p", stateLine: "Listening", startedAt: 1, ownerHere: false, ownerName: "n")
        let p = BaseActivityPresentation(s)
        let words = [p.idleLine(now: date(500)), p.staleLine(now: date(9_000)), p.callSubtitle, p.accessibilityLabel(now: date(500))]
        for text in words { #expect(!text.contains("\u{2014}") && !text.contains("\u{2013}")) }
    }
}

@Suite("S22 lock screen choices: asked once, changed in Settings")
struct LockScreenChoiceTests {
    @Test func theSuggestedDefaultsHaveTheAlwaysOnBubbleOff() {
        let p = LockScreenPreferences.suggested
        #expect(!p.alwaysOn && p.approvals && p.call && p.notifications)
        #expect(p.wantsPush && !LockScreenPreferences.allOff.wantsPush)
        #expect(!p.morphsCall)
        #expect(LockScreenPreferences(alwaysOn: true, approvals: false, call: true, notifications: false).morphsCall)
        // an older store that says call: false must not bring back a second call bubble beside the always-on one
        #expect(LockScreenPreferences(alwaysOn: true, approvals: false, call: false, notifications: false).morphsCall)
        #expect(!LockScreenPreferences(alwaysOn: false, approvals: true, call: true, notifications: true).morphsCall)
    }

    @Test func theSheetIsDueUntilAnsweredAndNeverAgain() {
        let store = InMemoryLockScreenPreferences()
        var choice = LockScreenChoice(stored: store.load())
        #expect(choice.needsFirstLaunchSheet && choice.preferences == .allOff)
        choice.answer(.suggested)
        store.save(choice.preferences)
        #expect(!choice.needsFirstLaunchSheet)
        #expect(!LockScreenChoice(stored: store.load()).needsFirstLaunchSheet, "a later launch does not ask again")
        // "Not now" is an answer too.
        var declined = LockScreenChoice(stored: nil)
        declined.answer(.allOff)
        #expect(!declined.needsFirstLaunchSheet && !declined.preferences.wantsPush)
    }

    @Test func aToggleKeepsTheOthersAndCountsAsAnAnswer() {
        var choice = LockScreenChoice(stored: .suggested)
        choice.set { $0.alwaysOn = true }
        #expect(choice.preferences == LockScreenPreferences(alwaysOn: true, approvals: true, call: true, notifications: true))
        var fresh = LockScreenChoice(stored: nil)
        fresh.set { $0.approvals = true }
        #expect(!fresh.needsFirstLaunchSheet)
    }

    @Test func userDefaultsRoundTrip() throws {
        let suite = try #require(UserDefaults(suiteName: "hermes.test.lockscreen.\(UUID().uuidString)"))
        let store = UserDefaultsLockScreenPreferences(defaults: suite)
        #expect(store.load() == nil)
        store.save(LockScreenPreferences(alwaysOn: true, approvals: false, call: true, notifications: false))
        #expect(store.load() == LockScreenPreferences(alwaysOn: true, approvals: false, call: true, notifications: false))
    }
}

@Suite("S22 the bubble's life: a dismissal is the owner's, the 8 hour limit is not")
struct BaseLifetimeTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func anEndTheAppDidNotCauseBeforeTheRenewalAgeIsAUserDismissal() {
        #expect(BaseEndClassifier.classify(startedAt: start, now: start.addingTimeInterval(3 * 3600), endedByApp: false) == .user)
        #expect(BaseEndClassifier.classify(startedAt: start, now: start.addingTimeInterval(60), endedByApp: false) == .user)
    }

    @Test func theSystemLimitAndTheBoxRenewalAreNotDismissals() {
        #expect(BaseEndClassifier.classify(startedAt: start, now: start.addingTimeInterval(7.5 * 3600), endedByApp: false) == .systemOrRenewal, "the box renews at 7.5 h")
        #expect(BaseEndClassifier.classify(startedAt: start, now: start.addingTimeInterval(8 * 3600), endedByApp: false) == .systemOrRenewal)
        #expect(BaseLifetime.userDismissalCutoff < BaseLifetime.serverRenewsAfter)
    }

    @Test func anEndTheAppCausedIsNeverADismissal() {
        #expect(BaseEndClassifier.classify(startedAt: start, now: start.addingTimeInterval(60), endedByApp: true) == .systemOrRenewal)
    }

    @Test func aDismissalBlocksARestartUntilALaunchOrAnExplicitAction() {
        var policy = BaseRestartPolicy()
        let on = LockScreenPreferences(alwaysOn: true)
        #expect(policy.mayStart(preferences: on))
        policy.userDismissed()
        #expect(!policy.mayStart(preferences: on))
        policy.appLaunched()
        #expect(policy.mayStart(preferences: on))
        policy.userDismissed()
        policy.explicitlyRequested()
        #expect(policy.mayStart(preferences: on))
        #expect(!policy.mayStart(preferences: .suggested), "off means off")
    }
}

@Suite struct BaseCallOutputCircleTests {
    private func state(ownerHere: Bool, outputOn: Bool?, canChoose: Bool?) -> BaseActivityAttributes.ContentState {
        BaseActivityAttributes.ContentState(
            mode: .call, machinesOnline: 1, machinesTotal: 1, waiting: 0, updatedAt: 1_000,
            call: .init(botKey: "oracle::hermesbot", botName: "Hermes Bot", stateLine: "Listening", startedAt: 900, ownerHere: ownerHere,
                        isMuted: false, outputOn: outputOn, canChooseOutput: canChoose))
    }

    @Test func theCallBubbleOfThePhoneThatTalksShowsTheOutputCircleNextToMute() {
        let p = BaseActivityPresentation(state(ownerHere: true, outputOn: true, canChoose: true))
        #expect(p.showsMute && p.showsOutput && p.outputOn && p.canChooseOutput)
    }

    @Test func aListenerGetsNeitherMuteNorTheOutputCircle() {
        #expect(!BaseActivityPresentation(state(ownerHere: false, outputOn: nil, canChoose: nil)).showsOutput)
    }

    @Test func aStateFromAnOlderWriterDecodesWithTheCircleOff() throws {
        let json = #"{"botKey":"a::b","botName":"B","stateLine":"x","startedAt":1,"ownerHere":true}"#
        let call = try JSONDecoder().decode(BaseActivityAttributes.ContentState.Call.self, from: Data(json.utf8))
        #expect(call.outputOn == nil && call.canChooseOutput == nil)
    }
}
