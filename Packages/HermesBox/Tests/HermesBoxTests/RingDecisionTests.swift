import Foundation
import Testing

@testable import HermesBox

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// The push exactly as `box/bff/call-owner.mjs` `ringPayload` builds it (expires_at in seconds).
func ringPayload(callId: String = testCallId, botKey: String = testBotKey, expiresAt: Double = 1_800_000_045, extra: [String: Any] = [:])
    -> [AnyHashable: Any]
{
    var hermes: [String: Any] = [
        "v": 1, "kind": "ring", "call_id": callId, "bot_key": botKey, "bot_name": "hermesbot", "urgency": "urgent", "expires_at": expiresAt,
    ]
    for (key, value) in extra { hermes[key] = value }
    return ["hermes": hermes]
}

private func push(callId: String = testCallId, expiresIn: TimeInterval = 45) -> RingPush {
    RingPush(callId: callId, botKey: testBotKey, botName: "hermesbot", expiresAt: t0.addingTimeInterval(expiresIn))
}

@Suite("S27 ring push: parse, stable UUID, decision table, report table")
struct RingDecisionTests {
    @Test func theBoxPayloadParses() {
        let parsed = RingPush.parse(ringPayload(extra: ["series_id": "s1", "attempt": 2]))
        #expect(parsed?.callId == testCallId)
        #expect(parsed?.botKey == testBotKey && parsed?.gatewayId == "oracle")
        #expect(parsed?.botName == "Hermes Bot" && parsed?.urgency == .urgent, "the name a person knows, never the bare profile")
        #expect(parsed?.expiresAt == Date(timeIntervalSince1970: 1_800_000_045))
        #expect(parsed?.seriesId == "s1" && parsed?.attempt == 2)
    }

    private static func badPayload(_ name: String) -> [AnyHashable: Any] {
        switch name {
        case "no hermes object": ["aps": [String: Any]()]
        case "wrong version": ringPayload(extra: ["v": 2])
        case "not a ring": ringPayload(extra: ["kind": "alarm"])
        case "empty call id": ringPayload(callId: "")
        case "bare profile, no gateway": ringPayload(botKey: "hermesbot")
        case "expiry is not a number": ringPayload(extra: ["expires_at": "soon"])
        default: ringPayload(extra: ["expires_at": true])
        }
    }

    @Test(arguments: [
        "no hermes object", "wrong version", "not a ring", "empty call id", "bare profile, no gateway", "expiry is not a number",
        "expiry is a boolean",
    ])
    func anythingElseIsUnreadable(_ name: String) {
        #expect(RingPush.parse(Self.badPayload(name)) == nil, "\(name)")
    }

    @Test func aMissingBotNameFallsBackToTheProfile() {
        var payload = ringPayload()
        var hermes = payload["hermes"] as! [String: Any]
        hermes["bot_name"] = nil
        payload["hermes"] = hermes
        #expect(RingPush.parse(payload)?.botName == "Hermes Bot", "a missing name is the canonical bot's name, not its profile id")
        #expect(RingPush.parse(payload)?.urgency == .urgent)
    }

    @Test func theCallKitUUIDIsTheHubCallIdAndStable() {
        #expect(RingCallID.uuid(for: testCallId) == UUID(uuidString: testCallId))
        let a = RingCallID.uuid(for: "not-a-uuid-1")
        #expect(a == RingCallID.uuid(for: "not-a-uuid-1"), "the same id is the same CallKit call")
        #expect(a != RingCallID.uuid(for: "not-a-uuid-2"))
    }

    /// The decision table (S27 R11): every push is reported; this decides ring or end at once, and why.
    @Test(arguments: [
        ("a fresh ring rings", RingContext(now: t0, callsEnabled: true), RingDecision.ring),
        ("unreadable push", RingContext(now: t0, callsEnabled: true), .endAtOnce(.unreadable)),
        ("late: after expires_at", RingContext(now: t0.addingTimeInterval(46), callsEnabled: true), .endAtOnce(.late)),
        ("late: exactly at expires_at", RingContext(now: t0.addingTimeInterval(45), callsEnabled: true), .endAtOnce(.late)),
        ("busy in a call here", RingContext(now: t0, callsEnabled: true, inCall: true), .endAtOnce(.busy)),
        ("calls switched off", RingContext(now: t0, callsEnabled: false), .endAtOnce(.callsOff)),
        ("duplicate of a ringing call", RingContext(now: t0, callsEnabled: true, liveCallIds: [testCallId]), .alreadyRinging),
        ("duplicate of an ended call", RingContext(now: t0, callsEnabled: true, finishedCallIds: [testCallId]), .endAtOnce(.duplicate)),
        (
            "an ended duplicate wins over calls off", RingContext(now: t0, callsEnabled: false, finishedCallIds: [testCallId]),
            .endAtOnce(.duplicate)
        ),
        ("calls off wins over late", RingContext(now: t0.addingTimeInterval(60), callsEnabled: false), .endAtOnce(.callsOff)),
        ("late wins over busy", RingContext(now: t0.addingTimeInterval(60), callsEnabled: true, inCall: true), .endAtOnce(.late)),
    ])
    func decision(_ name: String, _ context: RingContext, _ expected: RingDecision) {
        let input: RingPush? = name == "unreadable push" ? nil : push()
        #expect(RingDecision.decide(input, context: context) == expected, "\(name)")
    }

    @Test(arguments: [
        (RingEndCause.unreadable, RingEndedReason.failed), (.late, .unanswered), (.busy, .unanswered), (.duplicate, .remoteEnded),
        (.callsOff, .failed),
    ])
    func endCausesMapToCallKitReasons(_ cause: RingEndCause, _ reason: RingEndedReason) {
        #expect(cause.endedReason == reason)
    }

    @Test func reportUUIDsNeverTouchARealCallByAccident() {
        let fresh = UUID()
        let ring = push()
        let stable = RingCallID.uuid(for: testCallId)
        #expect(RingDecision.ring.reportUUID(for: ring, fresh: { fresh }) == stable)
        #expect(RingDecision.alreadyRinging.reportUUID(for: ring, fresh: { fresh }) == stable)
        #expect(RingDecision.endAtOnce(.late).reportUUID(for: ring, fresh: { fresh }) == stable)
        #expect(RingDecision.endAtOnce(.busy).reportUUID(for: ring, fresh: { fresh }) == stable)
        #expect(RingDecision.endAtOnce(.duplicate).reportUUID(for: ring, fresh: { fresh }) == fresh, "an ended call is never rung again")
        #expect(RingDecision.endAtOnce(.unreadable).reportUUID(for: nil, fresh: { fresh }) == fresh)
    }

    /// What the report callback's error means (the error table).
    @Test(arguments: [
        (RingReportError?.none, RingDecision.ring, RingAfterReport.ringing),
        (nil, .alreadyRinging, .nothing),
        (nil, .endAtOnce(.late), .endNow(.unanswered)),
        (nil, .endAtOnce(.unreadable), .endNow(.failed)),
        (.callUUIDAlreadyExists, .ring, .ringing),
        (.callUUIDAlreadyExists, .alreadyRinging, .nothing),
        (.filteredByDoNotDisturb, .ring, .nothing),
        (.filteredByBlockList, .ring, .nothing),
        (.unknown, .ring, .notShownTellOwner),
        (.unentitled, .ring, .notShownTellOwner),
        (.unknown, .endAtOnce(.late), .nothing),
    ])
    func afterTheReport(_ error: RingReportError?, _ decision: RingDecision, _ expected: RingAfterReport) {
        #expect(RingAfterReport.after(error, decision: decision) == expected)
    }

    @Test func whatTheHubSaysAboutAWatchedRing() {
        func summary(state: HubCallState = .active, owner: String? = nil, ended: String? = nil) -> CallSummary {
            CallSummary(
                callId: testCallId, botKey: testBotKey, engine: .free, state: state, ownerClientId: owner, ownerEpoch: 0, participants: [],
                startedAt: 0, endedReason: ended, seq: 0)
        }
        #expect(RingWatchVerdict.verdict(for: nil) == .remoteEnded, "gone from hello.ok.calls")
        #expect(RingWatchVerdict.verdict(for: summary()) == nil, "still ringing")
        #expect(RingWatchVerdict.verdict(for: summary(owner: "desktop")) == .answeredElsewhere)
        #expect(RingWatchVerdict.verdict(for: summary(state: .ended, ended: "no_answer")) == .unanswered)
        #expect(RingWatchVerdict.verdict(for: summary(state: .ended, ended: "declined")) == .declinedElsewhere)
        #expect(RingWatchVerdict.verdict(for: summary(state: .ended, ended: "ended_by_client")) == .remoteEnded)
    }

    @Test func theDeclineVerbIsTheHubs() {
        #expect(CallOutbound.ringDecline(id: "d", callId: testCallId).json == #"{"call_id":"\#(testCallId)","id":"d","type":"ring.decline"}"#)
    }

    @Test func answeringARingJoinsThenTakesTheOwnerlessCall() {
        var session = CallSession(intent: .answer(callId: testCallId, botKey: testBotKey))
        #expect(session.callId == testCallId && session.botKey == testBotKey && session.answersRing)
        guard case .helloOk(let hello)? = CallInbound.parse(Hub.helloOk(calls: [Hub.summary(owner: nil)])) else {
            Issue.record("hello")
            return
        }
        #expect(session.linkUp(hello) == [.send(.join(id: "c1", callId: testCallId, since: nil))])
        let joined = CallInbound.parse(Hub.joined(id: "c1", role: "listener", epoch: 0))!
        #expect(session.handle(joined) == [.send(.take(id: "c2", callId: testCallId))])
        _ = session.handle(CallInbound.parse(Hub.taken(epoch: 1))!)
        #expect(session.role == .owner && session.epoch == 1)
    }

    @Test func aRingAnotherDeviceAlreadyDrivesEndsHere() {
        var session = CallSession(intent: .answer(callId: testCallId, botKey: testBotKey))
        guard case .helloOk(let hello)? = CallInbound.parse(Hub.helloOk(calls: [Hub.summary(owner: "desktop")])) else { return }
        _ = session.linkUp(hello)
        let effects = session.handle(CallInbound.parse(Hub.joined(id: "c1", role: "listener", epoch: 1))!)
        #expect(effects.contains(.finished))
        #expect(session.ending == .other("answered_elsewhere"))
    }

    @Test func aRingThatIsGoneEndsWithNotFound() {
        var session = CallSession(intent: .answer(callId: testCallId, botKey: testBotKey))
        guard case .helloOk(let hello)? = CallInbound.parse(Hub.helloOk()) else { return }
        _ = session.linkUp(hello)
        let effects = session.handle(CallInbound.parse(Hub.error("not_found", id: "c1", callId: testCallId))!)
        #expect(effects.contains(.finished))
    }
}
