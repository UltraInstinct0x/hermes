import Foundation
import Testing

@testable import HermesBox

@MainActor
private func until(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<300 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

/// The answer's outcome, waited for at most 3 s of real time: a broken answer fails the test instead of hanging the run.
@MainActor
private func outcome(of answer: Task<RingAnswerOutcome, Never>) async -> RingAnswerOutcome? {
    let result = Locked<RingAnswerOutcome?>(nil)
    Task { @MainActor in
        let value = await answer.value
        result.withLock { $0 = value }
    }
    _ = await until { result.withLock { $0 } != nil }
    return result.withLock { $0 }
}

/// A real `CallController` on fakes, answering a ring the way CallKit makes it (S27 R11).
@MainActor
private final class RingRig {
    let link = FakeCallLink()
    let audio = FakeCallAudio()
    let mic = FakeMicrophone()
    let driver = FakeAudioDriver()
    let time = ManualTimeSource()
    let audioSession: VoiceAudioSession
    let controller: CallController
    let bot = CallBot(botKey: testBotKey, name: "hermesbot", gatewayId: "oracle")
    var ended: [String?] = []

    init() {
        audioSession = VoiceAudioSession(driver: driver)
        let link = self.link
        controller = CallController(
            makeLink: { _ in link }, audio: audio, audioSession: audioSession, microphone: mic, time: time, endGrace: .seconds(3))
        controller.onCallEnded = { [weak self] id in self?.ended.append(id) }
    }

    /// The hub's side of a ring answered here: hello lists the ownerless ring, the join is answered, then the take.
    func hubAnswers() async {
        link.pushHello(Hub.helloOk(calls: [Hub.summary(owner: nil, epoch: 0)]))
        _ = await until { self.link.messages.contains(.join(id: "c1", callId: testCallId, since: nil)) }
        link.pushInbound(Hub.state(role: "listener", epoch: 0, call: Hub.summary(owner: nil, epoch: 0)))
        link.pushInbound(Hub.joined(id: "c1", role: "listener", epoch: 0))
        _ = await until { self.link.messages.contains(.take(id: "c2", callId: testCallId)) }
        link.pushInbound(Hub.taken(epoch: 1))
    }
}

@MainActor
@Suite("S27 call controller answering a ring: CallKit's audio session, join then take, failure")
struct CallControllerRingTests {
    @Test func answerJoinsTakesAndNeverActivatesTheAudioSessionItself() async {
        let rig = RingRig()
        let answer = Task { await rig.controller.answerRing(bot: rig.bot, callId: testCallId, timeout: .seconds(20)) }
        await settle()
        #expect(rig.driver.activations.isEmpty, "CallKit activates the session, never the app")
        #expect(rig.driver.configurations == [.call], "the category is set for the call")
        #expect(rig.audioSession.holder == .call && rig.audioSession.isSystemActivated)
        await rig.hubAnswers()
        #expect(await outcome(of: answer) == .answered)
        #expect(rig.controller.session?.role == .owner && rig.controller.session?.epoch == 1)
        #expect(rig.audio.starts == 0, "no audio before didActivate")
        rig.controller.systemAudioActivated()
        #expect(rig.audio.starts == 1)
        #expect(rig.driver.activations.isEmpty)
    }

    @Test func didActivateBeforeTheTakeStartsAudioOnceTheTakeLands() async {
        let rig = RingRig()
        let answer = Task { await rig.controller.answerRing(bot: rig.bot, callId: testCallId, timeout: .seconds(20)) }
        await settle()
        rig.controller.systemAudioActivated()
        #expect(rig.audio.starts == 0, "a listener does not talk yet")
        await rig.hubAnswers()
        #expect(await outcome(of: answer) == .answered)
        #expect(await until { rig.audio.starts == 1 })
    }

    @Test func aRingTheBotStartedIsAnsweredAtTheEarAndTheCircleStillSwapsToTheSpeaker() async {
        let rig = RingRig()
        let answer = Task { await rig.controller.answerRing(bot: rig.bot, callId: testCallId, timeout: .seconds(20)) }
        await settle()
        rig.controller.systemAudioActivated()
        await rig.hubAnswers()
        #expect(await outcome(of: answer) == .answered)
        #expect(await until { rig.audio.outputs.last == .receiver }, "the ring opens on the receiver, not the loudspeaker")
        #expect(rig.controller.outputState.speakerIsOn == false)
        rig.controller.toggleOutput()
        #expect(rig.audio.outputs.last == .speaker, "the owner can still move the sound to the speaker")
        #expect(rig.controller.outputState.speakerIsOn)
    }

    @Test func aRingThatIsGoneFailsTheAnswer() async {
        let rig = RingRig()
        let answer = Task { await rig.controller.answerRing(bot: rig.bot, callId: testCallId, timeout: .seconds(20)) }
        await settle()
        rig.link.pushHello(Hub.helloOk())
        _ = await until { !rig.link.messages.isEmpty }
        rig.link.pushInbound(Hub.error("not_found", id: "c1", callId: testCallId))
        guard case .failed = await outcome(of: answer) else { Issue.record("expected a failure"); return }
        #expect(!rig.controller.isInCall)
        #expect(rig.ended == [testCallId])
        #expect(rig.driver.deactivations == 0, "CallKit deactivates its own session")
    }

    @Test func noTakeWithinTheTimeoutFailsTheAnswer() async {
        let rig = RingRig()
        let answer = Task { await rig.controller.answerRing(bot: rig.bot, callId: testCallId, timeout: .seconds(20)) }
        // The answer timeout is armed (advancing before it would skip it and leave the answer waiting).
        #expect(await until { rig.time.sleeperCount >= 1 })
        await rig.time.advance(by: .seconds(20))
        guard case .failed = await outcome(of: answer) else { Issue.record("expected a failure"); return }
        #expect(!rig.controller.isInCall)
    }

    @Test func noMicrophonePermissionFailsWithoutAPrompt() async {
        let rig = RingRig()
        rig.mic.status = .undetermined
        guard case .failed = await rig.controller.answerRing(bot: rig.bot, callId: testCallId, timeout: .seconds(20)) else {
            Issue.record("expected a failure"); return
        }
        #expect(rig.mic.requests == 0, "no system prompt from a locked phone")
    }

    @Test func aRingWhileACallRunsIsBusy() async {
        let rig = RingRig()
        let answer = Task { await rig.controller.answerRing(bot: rig.bot, callId: testCallId, timeout: .seconds(20)) }
        await settle()
        await rig.hubAnswers()
        _ = await outcome(of: answer)
        #expect(await rig.controller.answerRing(bot: rig.bot, callId: "other", timeout: .seconds(20)) == .busy)
    }

    @Test func callKitMuteAndHangUpDriveTheCall() async {
        let rig = RingRig()
        let answer = Task { await rig.controller.answerRing(bot: rig.bot, callId: testCallId, timeout: .seconds(20)) }
        await settle()
        await rig.hubAnswers()
        _ = await outcome(of: answer)
        rig.controller.setMuted(true)
        #expect(rig.controller.isMuted)
        rig.controller.end()
        #expect(await until { rig.link.messages.contains(.end(id: "c3", callId: testCallId)) })
    }

    @Test func callKitTakingTheAudioAwayHoldsTheCallUntilItComesBack() async {
        let rig = RingRig()
        let answer = Task { await rig.controller.answerRing(bot: rig.bot, callId: testCallId, timeout: .seconds(20)) }
        await settle()
        await rig.hubAnswers()
        _ = await outcome(of: answer)
        rig.controller.systemAudioActivated()
        #expect(rig.audio.starts == 1)
        rig.controller.systemAudioDeactivated()
        #expect(rig.controller.hold == .interrupted && rig.audio.stops >= 1)
        rig.controller.systemAudioActivated()
        #expect(rig.controller.hold == nil && rig.audio.starts == 2)
        #expect(rig.driver.activations.isEmpty, "never activated by the app, also not on resume")
    }

    @Test func endToEndCallKitAnswerIsFulfilledBeforeTheHubIsAsked() async {
        let rig = RingRig()
        let log = Locked<[String]>([])
        final class Provider: RingCallProvider {
            var ended: [RingEndedReason] = []
            func reportIncoming(uuid: UUID, callerName: String, completion: @escaping @MainActor (RingReportError?) -> Void) { completion(nil) }
            func reportEnded(uuid: UUID, reason: RingEndedReason) { ended.append(reason) }
        }
        final class Quiet: RingNotifying { func triedToReach(botName: String) async {} }
        let provider = Provider()
        let watch = FakeCallLink()
        var links: [any CallLink] = [watch]
        let coordinator = RingCoordinator(
            provider: provider, calls: rig.controller, makeLink: { _ in links.isEmpty ? nil : links.removeFirst() }, notifier: Quiet(),
            callsEnabled: { true }, time: rig.time, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        coordinator.receive(ringPayload()) {}
        let uuid = RingCallID.uuid(for: testCallId)
        coordinator.answer(uuid, fulfill: { log.withLock { $0.append("fulfill:\(rig.link.messages.count)") } }, fail: {})
        #expect(log.withLock { $0 } == ["fulfill:0"], "fulfilled before anything went to the hub")
        await rig.hubAnswers()
        #expect(await until { rig.controller.session?.role == .owner })
        coordinator.audioActivated()
        #expect(await until { rig.audio.starts == 1 })
        #expect(provider.ended.isEmpty)
        // The box ends the call: CallKit hears it.
        rig.link.pushInbound(Hub.ended("ended_by_client"))
        #expect(await until { provider.ended == [.remoteEnded] })
    }
}
