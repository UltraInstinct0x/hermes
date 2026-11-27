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

/// 1 s of speech at 24 kHz, its first byte marking which chunk it is.
private func speech(_ mark: UInt8) -> Data {
    var pcm = Data(count: 48_000)
    pcm[0] = mark
    return pcm
}

/// A call the bot started, answered through CallKit: the owner role arrives BEFORE `didActivate`, as on the 2026-10-20 morning call.
@MainActor
private final class AnsweredRingRig {
    let link = FakeCallLink()
    let audio = FakeCallAudio()
    let mic = FakeMicrophone()
    let driver = FakeAudioDriver()
    let time = ManualTimeSource()
    let controller: CallController
    let bot = CallBot(botKey: testBotKey, name: "hermesbot", gatewayId: "oracle")
    private var answer: Task<RingAnswerOutcome, Never>?

    init() {
        let session = VoiceAudioSession(driver: driver)
        let link = self.link
        controller = CallController(
            makeLink: { _ in link }, audio: audio, audioSession: session, microphone: mic, time: time, endGrace: .seconds(3))
    }

    /// The hub's side of the ring answered here: join, then take. The phone is owner, the engine waits for CallKit.
    func answerAndTake() async {
        answer = Task { await controller.answerRing(bot: bot, callId: testCallId, timeout: .seconds(20)) }
        await settle()
        link.pushHello(Hub.helloOk(calls: [Hub.summary(owner: nil, epoch: 0)]))
        _ = await until { self.link.messages.contains(.join(id: "c1", callId: testCallId, since: nil)) }
        link.pushInbound(Hub.state(role: "listener", epoch: 0, call: Hub.summary(owner: nil, epoch: 0)))
        link.pushInbound(Hub.joined(id: "c1", role: "listener", epoch: 0))
        _ = await until { self.link.messages.contains(.take(id: "c2", callId: testCallId)) }
        link.pushInbound(Hub.taken(epoch: 1))
        _ = await until { self.controller.session?.role == .owner }
    }

    /// The bot's greeting as the hub sends it: tts.start, then `count` one-second chunks marked 1...count.
    func botSpeaks(reply: Int = 1, marks: ClosedRange<UInt8>) async {
        link.pushInbound(Hub.ttsStart(reply: reply))
        for mark in marks { link.push(.audio(replyId: UInt32(reply), pcm: speech(mark))) }
        // The events run through a stream: give the controller time to take them all (nothing shows yet while the engine waits).
        for _ in 0..<8 { await settle() }
    }

    func playedMarks() -> [UInt8] { audio.played.map { $0.pcm[0] } }
}

@MainActor
@Suite("S28 speech that arrives before the call audio engine runs is kept and played in order")
struct CallControllerReadinessTests {
    @Test func theGreetingBeforeDidActivatePlaysAfterTheEngineStartsInOrder() async {
        let rig = AnsweredRingRig()
        await rig.answerAndTake()
        await rig.botSpeaks(marks: 1...3)
        #expect(rig.audio.starts == 0 && rig.audio.played.isEmpty, "nothing can play before CallKit activated the session")
        rig.controller.systemAudioActivated()
        #expect(rig.audio.starts == 1)
        #expect(rig.playedMarks() == [1, 2, 3], "the queued greeting plays, first words first")
        #expect(rig.controller.isPlaying)
    }

    @Test func nothingIsQueuedOnceTheEngineRuns() async {
        let rig = AnsweredRingRig()
        await rig.answerAndTake()
        rig.controller.systemAudioActivated()
        #expect(rig.audio.starts == 1)
        await rig.botSpeaks(marks: 1...2)
        _ = await until { rig.audio.played.count == 2 }
        #expect(rig.playedMarks() == [1, 2], "played at once, straight through")
        rig.controller.systemAudioDeactivated()
        rig.controller.systemAudioActivated()
        #expect(rig.playedMarks() == [1, 2], "an earlier reply is not played a second time")
    }

    @Test func aQueueLongerThanFifteenSecondsKeepsTheNewestAndPlaysItInOrder() async {
        let rig = AnsweredRingRig()
        await rig.answerAndTake()
        await rig.botSpeaks(marks: 1...20)
        rig.controller.systemAudioActivated()
        #expect(rig.playedMarks() == Array(6...20))
    }

    @Test func aStopOfSpeechBeforeTheEngineStartsDropsWhatWaited() async {
        let rig = AnsweredRingRig()
        await rig.answerAndTake()
        await rig.botSpeaks(marks: 1...2)
        rig.link.pushInbound(Hub.ttsStop())
        await settle()
        rig.controller.systemAudioActivated()
        #expect(rig.audio.starts == 1 && rig.audio.played.isEmpty, "stale speech never plays")
    }

    @Test func aLinkThatDropsBeforeTheEngineStartsDropsWhatWaited() async {
        let rig = AnsweredRingRig()
        await rig.answerAndTake()
        await rig.botSpeaks(marks: 1...2)
        rig.link.push(.down)
        await settle()
        rig.controller.systemAudioActivated()
        #expect(rig.audio.played.isEmpty)
    }

    @Test func losingTheOwnerRoleDropsWhatWaited() async {
        let rig = AnsweredRingRig()
        await rig.answerAndTake()
        await rig.botSpeaks(marks: 1...2)
        let desktop = Hub.summary(owner: "desk", epoch: 2)
        rig.link.pushInbound(Hub.state(role: "listener", epoch: 2, call: desktop))
        _ = await until { rig.controller.session?.role != .owner }
        rig.controller.systemAudioActivated()
        #expect(rig.audio.played.isEmpty)
        #expect(rig.audio.starts == 0, "a listener does not start the engine")
    }

    @Test func aCallThatEndsBeforeTheEngineStartedLeavesNothingForTheNextCall() async {
        let rig = AnsweredRingRig()
        await rig.answerAndTake()
        await rig.botSpeaks(marks: 1...2)
        rig.controller.end()
        _ = await until { rig.time.sleeperCount >= 1 }
        await rig.time.advance(by: .seconds(3))  // the end grace
        _ = await until { !rig.controller.isInCall }
        #expect(!rig.controller.isInCall)
        #expect(rig.audio.played.isEmpty)
    }
}
