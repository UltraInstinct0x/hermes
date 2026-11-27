import Foundation
import Testing

@testable import HermesBox

private func hello(_ text: String) -> HelloOk {
    guard case .helloOk(let hello)? = CallInbound.parse(text) else { fatalError("not hello.ok") }
    return hello
}

private func feed(_ session: inout CallSession, _ text: String) -> [CallEffect] {
    guard let inbound = CallInbound.parse(text) else { fatalError("unparseable frame") }
    return session.handle(inbound)
}

private func sentMessages(_ effects: [CallEffect]) -> [CallOutbound] {
    effects.compactMap { if case .send(let message) = $0 { message } else { nil } }
}

/// A session that started a call on this phone and owns it at epoch 1.
private func ownedSession() -> CallSession {
    var session = CallSession(intent: .start(botKey: testBotKey, engine: .free))
    _ = session.linkUp(hello(Hub.helloOk()))
    _ = feed(&session, Hub.started(id: "c1"))
    return session
}

@Suite("Call session: start, join, take over, epoch fencing as the client sees it")
struct CallSessionTests {
    @Test func startingSendsCallStartAndTheStarterOwnsEpochOne() {
        var session = CallSession(intent: .start(botKey: testBotKey, engine: .free))
        let effects = session.linkUp(hello(Hub.helloOk()))
        #expect(sentMessages(effects) == [.start(id: "c1", botKey: testBotKey, engine: .free)])
        _ = feed(&session, Hub.started(id: "c1"))
        #expect(session.role == .owner && session.epoch == 1 && session.callId == testCallId)
        #expect(session.uplinkEpoch == 1)
    }

    @Test func autoIsNeverSentOnTheWire() {
        // The session only knows free and live (S19 R35): `auto` was resolved before this point.
        #expect(CallEngine.allCases.map(\.rawValue) == ["free", "live"])
    }

    @Test func aCallAlreadyRunningForTheBotIsJoinedNotRestarted() {
        var session = CallSession(intent: .start(botKey: testBotKey, engine: .free))
        let desktop = Hub.summary(owner: "desk", participants: [Hub.participant("desk", kind: "desktop", label: "Mac", role: "owner")])
        let effects = session.linkUp(hello(Hub.helloOk(calls: [desktop])))
        #expect(sentMessages(effects) == [.join(id: "c1", callId: testCallId, since: nil)])
        #expect(session.joinedExisting)
        _ = feed(&session, Hub.state(role: "listener", epoch: 1, call: desktop))
        _ = feed(&session, Hub.joined(id: "c1", role: "listener", epoch: 1))
        #expect(session.isElsewhere && session.canTakeOver && session.ownerName == "Mac")
        #expect(session.uplinkEpoch == nil, "a listener never sends audio")
    }

    @Test func callExistsJoinsTheCallTheHubNamed() {
        var session = CallSession(intent: .start(botKey: testBotKey, engine: .free))
        _ = session.linkUp(hello(Hub.helloOk()))
        let effects = feed(&session, Hub.error("call_exists", id: "c1", callId: testCallId))
        #expect(sentMessages(effects) == [.join(id: "c2", callId: testCallId, since: nil)])
        #expect(session.refusal == nil)
    }

    @Test func aStaleCallOfThisPhoneFoundByTheCallButtonIsClaimedAtOnce() {
        // After a crash the hub still lists the call with this phone as its owner (and the restarted app is a listener).
        var session = CallSession(intent: .start(botKey: testBotKey, engine: .free))
        let stale = Hub.summary(owner: "phone", epoch: 2, participants: [Hub.participant("phone", role: "listener")])
        _ = session.linkUp(hello(Hub.helloOk(calls: [stale])))
        let effects = feed(&session, Hub.joined(id: "c1", role: "listener", epoch: 2))
        guard case .take? = sentMessages(effects).first else { Issue.record("not claimed"); return }
        _ = feed(&session, Hub.taken(epoch: 3))
        #expect(session.uplinkEpoch == 3 && session.role == .owner)
    }

    @Test func anOwnerlessCallFoundByTheCallButtonIsClaimedAtOnce() {
        var session = CallSession(intent: .start(botKey: testBotKey, engine: .free))
        let ownerless = Hub.summary(owner: nil, epoch: 2)
        _ = session.linkUp(hello(Hub.helloOk(calls: [ownerless])))
        let effects = feed(&session, Hub.joined(id: "c1", role: "listener", epoch: 2))
        #expect(sentMessages(effects).count == 1)
        guard case .take? = sentMessages(effects).first else { Issue.record("not claimed"); return }
        // a second joined frame never sends a second take while the first is pending
        #expect(sentMessages(feed(&session, Hub.joined(id: nil, role: "listener", epoch: 2))).isEmpty)
    }

    @Test func callExistsOnAnOwnerlessCallIsClaimedAndOnALiveForeignCallIsNot() {
        var ownerless = CallSession(intent: .start(botKey: testBotKey, engine: .free))
        _ = ownerless.linkUp(hello(Hub.helloOk()))
        _ = feed(&ownerless, Hub.error("call_exists", id: "c1", callId: testCallId))
        _ = feed(&ownerless, Hub.state(role: "listener", epoch: 2, call: Hub.summary(owner: nil, epoch: 2)))
        guard case .take? = sentMessages(feed(&ownerless, Hub.joined(id: "c2", role: "listener", epoch: 2))).first else {
            Issue.record("ownerless call not claimed")
            return
        }

        var foreign = CallSession(intent: .start(botKey: testBotKey, engine: .free))
        _ = foreign.linkUp(hello(Hub.helloOk()))
        _ = feed(&foreign, Hub.error("call_exists", id: "c1", callId: testCallId))
        let desktop = Hub.summary(owner: "desk", participants: [Hub.participant("desk", kind: "desktop", label: "Mac", role: "owner")])
        _ = feed(&foreign, Hub.state(role: "listener", epoch: 1, call: desktop))
        #expect(sentMessages(feed(&foreign, Hub.joined(id: "c2", role: "listener", epoch: 1))).isEmpty)
        #expect(foreign.isElsewhere && foreign.uplinkEpoch == nil)
    }

    @Test func aCallJoinedByIdFromTheDesktopIsNeverClaimedEvenWhenOwnerless() {
        var session = CallSession(intent: .join(callId: testCallId))
        _ = session.linkUp(hello(Hub.helloOk()))
        _ = feed(&session, Hub.state(role: "listener", epoch: 2, call: Hub.summary(owner: nil, epoch: 2)))
        #expect(sentMessages(feed(&session, Hub.joined(id: "c1", role: "listener", epoch: 2))).isEmpty)
    }

    @Test func takeOverSendsCallTakeAndAdoptsTheFreshEpoch() {
        var session = CallSession(intent: .join(callId: testCallId))
        _ = session.linkUp(hello(Hub.helloOk()))
        _ = feed(&session, Hub.joined(id: "c1", role: "listener", epoch: 1))
        _ = feed(&session, Hub.state(role: "listener", epoch: 1, call: Hub.summary(owner: "desk")))
        let effects = session.take()
        #expect(sentMessages(effects) == [.take(id: "c2", callId: testCallId)])
        _ = feed(&session, Hub.taken(epoch: 2))
        #expect(session.role == .owner && session.uplinkEpoch == 2)
    }

    @Test func takingALiveCallIsNotOfferedOnThisPhone() {
        var session = CallSession(intent: .join(callId: testCallId))
        _ = session.linkUp(hello(Hub.helloOk()))
        _ = feed(&session, Hub.state(role: "listener", epoch: 1, call: Hub.summary(engine: "live")))
        _ = feed(&session, Hub.joined(id: "c1", role: "listener", epoch: 1))
        #expect(!session.canTakeOver && session.take().isEmpty)
    }

    @Test func whenAnotherDeviceTakesTheCallThisOneIsFencedAndSpeechStops() {
        var session = ownedSession()
        _ = feed(&session, Hub.ttsStart(reply: 5))
        #expect(session.uplinkEpoch == 1 && session.openReplies == [5])
        let effects = feed(&session, Hub.state(role: "listener", epoch: 2, call: Hub.summary(owner: "desk", epoch: 2)))
        #expect(effects.contains(.stopPlayback))
        #expect(session.uplinkEpoch == nil && session.role == .listener && session.openReplies.isEmpty)
        #expect(session.isElsewhere)
    }

    @Test func notOwnerAndStaleEpochDemoteWithoutRetakingOnTheirOwn() {
        for code in ["not_owner", "stale_epoch"] {
            var session = ownedSession()
            let effects = feed(&session, Hub.error(code, callId: testCallId, epoch: 9))
            #expect(effects == [.stopPlayback])
            #expect(session.uplinkEpoch == nil && session.role == .listener && !session.wantsOwner)
        }
    }

    // MARK: reconnect rules (S19 R39, R40)

    @Test func theEpochIsForgottenTheMomentTheLinkDrops() {
        var session = ownedSession()
        session.linkDown()
        #expect(session.epoch == nil && session.uplinkEpoch == nil && session.link == .reconnecting && session.wantsOwner)
    }

    @Test func insideTheGraceThePhoneRejoinsTheSameCallAndKeepsOwnership() {
        var session = ownedSession()
        _ = feed(&session, Hub.transcript(row: "r1", speaker: "voice", text: "hi", seq: 12).jsonText)
        session.linkDown()
        let mine: [[String: Any]] = [["call_id": testCallId, "role": "owner", "owner_epoch": 1]]
        let effects = session.linkUp(hello(Hub.helloOk(calls: [Hub.summary()], yours: mine)))
        #expect(sentMessages(effects).count == 1)
        guard case .join(_, let id, let since)? = sentMessages(effects).first else { Issue.record("no join"); return }
        #expect(id == testCallId && since == 12, "resumes after the last row it saw")
        #expect(session.uplinkEpoch == 1, "hello.ok.yours is one of the three places an epoch may come from")
        _ = feed(&session, Hub.joined(id: "c2", role: "owner", epoch: 1))
        #expect(session.uplinkEpoch == 1 && !session.wantsOwner)
    }

    @Test func afterTheGraceAnOwnerlessCallIsTakenBackWithAFreshEpoch() {
        var session = ownedSession()
        session.linkDown()
        _ = session.linkUp(hello(Hub.helloOk(calls: [Hub.summary(owner: nil, epoch: 2)])))
        _ = feed(&session, Hub.state(role: "listener", epoch: 2, call: Hub.summary(owner: nil, epoch: 2)))
        let effects = feed(&session, Hub.joined(id: "c2", role: "listener", epoch: 2))
        let take = sentMessages(effects)
        #expect(take.count == 1)
        guard case .take = take.first else { Issue.record("no take"); return }
        #expect(session.uplinkEpoch == nil, "epoch 2 is not ours until call.taken says so")
        _ = feed(&session, Hub.taken(epoch: 3))
        #expect(session.uplinkEpoch == 3)
    }

    @Test func ifAnotherDeviceTookItMeanwhileThePhoneDoesNotStealItBack() {
        var session = ownedSession()
        session.linkDown()
        _ = session.linkUp(hello(Hub.helloOk()))
        _ = feed(&session, Hub.state(role: "listener", epoch: 3, call: Hub.summary(owner: "desk", epoch: 3)))
        let effects = feed(&session, Hub.joined(id: "c2", role: "listener", epoch: 3))
        #expect(sentMessages(effects).isEmpty)
        #expect(session.isElsewhere && !session.wantsOwner && session.uplinkEpoch == nil)
    }

    @Test func aCallThatEndedWhileAwayIsNotFoundAndNeverRestarted() {
        var session = ownedSession()
        session.linkDown()
        _ = session.linkUp(hello(Hub.helloOk()))
        let effects = feed(&session, Hub.error("not_found", id: "c2", callId: testCallId))
        #expect(effects.contains(.finished))
        #expect(session.isOver && session.ending == .other("not_found"))
        #expect(session.ending?.sentence == "The call ended.")
    }

    // MARK: speech, transcript, end

    @Test func speechOnlyPlaysForTheOwnerAndStopsWhenTheHubSaysSo() {
        var session = ownedSession()
        #expect(feed(&session, Hub.ttsStart(reply: 1, rate: 24000)) == [.beginReply(replyId: 1, sampleRate: 24000)])
        #expect(feed(&session, Hub.ttsEnd(reply: 1)) == [.endReply(replyId: 1)])
        _ = feed(&session, Hub.ttsStart(reply: 2))
        #expect(feed(&session, Hub.ttsStop()) == [.stopPlayback])
        #expect(session.openReplies.isEmpty)

        var listener = CallSession(intent: .join(callId: testCallId))
        _ = listener.linkUp(hello(Hub.helloOk()))
        _ = feed(&listener, Hub.joined(id: "c1", role: "listener", epoch: 1))
        #expect(feed(&listener, Hub.ttsStart(reply: 3)).isEmpty)
    }

    @Test func captionsShowTheLastLinesAndThePartialIsReplacedByTheFinal() {
        var session = ownedSession()
        _ = feed(&session, Hub.text(Hub.transcript(row: "partial", speaker: "person", text: "merh", final: false, seq: nil)))
        #expect(session.captions.userLine == "merh")
        _ = feed(&session, Hub.text(Hub.transcript(row: "r1", speaker: "person", text: "merhaba", seq: 1)))
        #expect(session.captions.userLine == "merhaba" && session.captions.partialPerson == nil)
        _ = feed(&session, Hub.text(Hub.transcript(row: "r2", speaker: "voice", text: "Selam", seq: 2)))
        _ = feed(&session, Hub.text(Hub.transcript(row: "r2", speaker: "voice", text: "Selam, nasilsin", seq: 3)))
        #expect(session.captions.botLine == "Selam, nasilsin" && session.captions.rows.count == 2)
    }

    @Test func thinkingFromTheEndOfSpeechUntilTheBotAnswers() {
        var session = ownedSession()
        session.localSpeechBegan()
        session.localUtteranceEnded()
        #expect(session.awaitingReply)
        _ = feed(&session, Hub.ttsStart(reply: 1))
        #expect(!session.awaitingReply)
    }

    @Test func callEndedFinishesOnceWithAGentleSentence() {
        var session = ownedSession()
        let effects = feed(&session, Hub.ended("gateway_lost"))
        #expect(effects == [.stopPlayback, .finished])
        #expect(session.ending == .gatewayLost && session.ending?.sentence == "The call ended because the server lost its voice link.")
        #expect(feed(&session, Hub.ended("gateway_lost")).isEmpty)
        #expect(session.uplinkEpoch == nil)
    }

    @Test func aRefusedStartIsARefusalNotACrash() {
        var session = CallSession(intent: .start(botKey: testBotKey, engine: .free))
        _ = session.linkUp(hello(Hub.helloOk()))
        _ = feed(&session, Hub.error("unavailable", id: "c1"))
        #expect(session.refusal == .unavailable && session.callId == nil)
    }

    @Test func aTransientErrorMidCallIsANoticeNotAnEnd() {
        var session = ownedSession()
        _ = feed(&session, Hub.error("rate_limited"))
        #expect(session.notice == HubErrorCode.rateLimited.sentence && !session.isOver)
    }
}

extension Dictionary where Key == String, Value == Any {
    fileprivate var jsonText: String { Hub.text(self) }
}
