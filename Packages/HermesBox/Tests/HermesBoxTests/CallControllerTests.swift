import Foundation
import Testing

@testable import HermesBox

/// Poll a main-actor condition (up to 3 s of real time).
@MainActor
private func until(_ message: String, _ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<300 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

@MainActor
private final class Rig {
    let link = FakeCallLink()
    let audio = FakeCallAudio()
    let mic = FakeMicrophone()
    let driver = FakeAudioDriver()
    let activity = RecordingActivity()
    let time = ManualTimeSource()
    let waiting = Locked(0)
    let audioSession: VoiceAudioSession
    let controller: CallController
    let bot = CallBot(botKey: testBotKey, name: "Hermes", gatewayId: "oracle")
    var linksMade: [String] = []

    init(preferences: any CallPreferences = InMemoryCallPreferences(), makeLink: Bool = true) {
        audioSession = VoiceAudioSession(driver: driver)
        let link = self.link
        let waiting = self.waiting
        let made = Locked<[String]>([])
        controller = CallController(
            makeLink: { gateway in
                made.withLock { $0.append(gateway) }
                return makeLink ? link : nil
            },
            audio: audio, audioSession: audioSession, microphone: mic, preferences: preferences, activity: activity,
            waitingCount: { _ in waiting.withLock { $0 } }, time: time, endGrace: .seconds(3))
        madeLinks = made
    }

    let madeLinks: Locked<[String]>

    /// Place the call and let the hub answer: this phone owns epoch 1.
    func startOwned() async {
        await controller.start(bot: bot)
        link.pushHello(Hub.helloOk())
        _ = await until("start sent") { self.link.messages.contains(.start(id: "c1", botKey: testBotKey, engine: .free)) }
        link.pushInbound(Hub.started(id: "c1"))
        _ = await until("owner") { self.controller.session?.role == .owner }
    }

    /// 16 kHz samples arrive from the microphone.
    func hear(_ samples: [Int16]) async {
        audio.hear(samples)
        await settle()
    }
}

@MainActor
@Suite("Call controller: start, speak, barge in, lock, take over, end (all fakes)")
struct CallControllerTests {
    @Test func startingAsksForTheMicrophoneOnFirstUseThenPlacesTheCall() async {
        let rig = Rig()
        rig.mic.status = .undetermined
        await rig.startOwned()
        #expect(rig.mic.requests == 1)
        #expect(rig.driver.activations == [.call], "the call holds the audio session from the first moment")
        #expect(rig.link.opened == 1 && rig.madeLinks.withLock { $0 } == ["oracle"])
        #expect(rig.controller.isInCall && rig.audio.starts == 1)
        #expect(rig.controller.stateLine == "Listening")
    }

    @Test func aQuietVoiceFromTheVoiceProcessingMicOpensAnUtteranceAndTheDiagnosticsCountEveryFrame() async {
        let rig = Rig()
        await rig.startOwned()
        // Voice processing delivers low, gain-controlled speech: about -48 dBFS here (the old gate floor was -45).
        await rig.hear(silence(ms: 200))
        await rig.hear(sine(ms: 600, amplitude: 160))
        await rig.hear(silence(ms: 1200))
        _ = await until("frames reach the link") { rig.link.order.contains("audio") && rig.link.order.last == "audio.eos" }
        let diag = rig.controller.diagnostics
        #expect(diag.utterancesStarted == 1 && diag.eosSent == 1)
        #expect(diag.framesQueued > 0 && diag.framesSent == diag.framesQueued && diag.framesFailed == 0)
        #expect(diag.bytesSent == rig.link.audio.reduce(0) { $0 + $1.pcm.count })
        #expect(diag.peakMicDb > -52 && diag.peakMicDb < -40, "the mic level is in dBFS: \(diag.peakMicDb)")
        #expect(diag.link == "up" && diag.role == "owner" && diag.hubState == "active" && diag.epoch == 1)
        #expect(diag.text.contains("end-of-speech sent: 1") && diag.text.contains("mic level:"))
    }

    @Test func samplesThePhoneMayNotSendAreCountedAsIgnoredAndHubErrorsAreRemembered() async {
        let rig = Rig()
        await rig.startOwned()
        rig.controller.setMuted(true)
        await rig.hear(sine(ms: 300, amplitude: 8000))
        #expect(rig.controller.diagnostics.micSamplesIgnored == 300 * 16)
        rig.link.pushInbound(Hub.error("rate_limited", callId: testCallId))
        _ = await until("error seen") { rig.controller.diagnostics.lastHubError == "rate_limited" }
        #expect(rig.controller.diagnostics.hubErrors == 1)
        #expect(rig.controller.diagnostics.text.contains("last: rate_limited"))
    }

    @Test func aFailureCarriesTheDiagnosticsInItsCopyDetails() async {
        let rig = Rig()
        await rig.startOwned()
        rig.link.push(.failed(.gaveUp(detail: "x")))
        _ = await until("failed") { if case .failed = rig.controller.phase { true } else { false } }
        guard case .failed(let failure) = rig.controller.phase else { Issue.record("not failed"); return }
        #expect(failure.details.contains("frames queued:") && failure.details.contains("link:"))
    }

    @Test func theAudioSessionIsActiveBeforeTheEngineStartsAndEchoCancellationIsAskedFirst() async {
        let rig = Rig()
        let seen = Locked<[[AudioPurpose]]>([])
        rig.audio.beforeStart = { [driver = rig.driver] in seen.withLock { $0.append(driver.activations) } }
        await rig.startOwned()
        #expect(seen.withLock { $0 } == [[.call]], "the .call session was activated before the first engine start")
        #expect(rig.audio.startModes == [true])
    }

    @Test func aMicThatDeliversNothingIsRestartedOnceWithoutEchoCancellationThenTheCallFailsVisibly() async {
        let rig = Rig()
        await rig.startOwned()
        rig.audio.report = ["session: category=playAndRecord mode=voiceChat"]
        await rig.time.advance(by: .milliseconds(1400))
        #expect(rig.audio.startModes == [true], "not before the watchdog time")
        await rig.time.advance(by: .milliseconds(200))
        #expect(rig.audio.startModes == [true, false], "restarted once, without voice processing")
        #expect(rig.audio.stops >= 1 && rig.controller.isInCall)
        #expect(rig.controller.diagnostics.echoCancellation == "off (fallback)")
        await rig.time.advance(by: .milliseconds(1600))
        guard case .failed(let failure) = rig.controller.phase else { Issue.record("not failed: \(rig.controller.phase)"); return }
        #expect(failure.sentence == "The microphone is not delivering audio. Check Settings, Hermes Bot, Microphone, then retry.")
        #expect(failure.details.contains("echo cancellation: off (fallback)") && failure.details.contains("session: category=playAndRecord"))
        #expect(failure.details.contains("watchdog: no audio even without echo cancellation"))
        #expect(rig.audio.startModes == [true, false], "no third start")
    }

    @Test func aMicThatDeliversAudioInTimeIsNeverRestarted() async {
        let rig = Rig()
        await rig.startOwned()
        await rig.hear(sine(ms: 100, amplitude: 4000))
        await rig.time.advance(by: .seconds(5))
        #expect(rig.audio.startModes == [true] && rig.controller.isInCall)
        #expect(rig.controller.diagnostics.watchdog == "ok, audio arrived")
    }

    @Test func theFallbackMicWorksAndTheCallKeepsGoing() async {
        let rig = Rig()
        await rig.startOwned()
        await rig.time.advance(by: .milliseconds(1600))
        #expect(rig.audio.startModes == [true, false])
        await rig.hear(sine(ms: 100, amplitude: 4000))
        await rig.time.advance(by: .seconds(5))
        #expect(rig.controller.isInCall && rig.audio.startModes == [true, false])
        #expect(rig.controller.diagnostics.micBatches == 1)
    }

    @Test func anEngineThatWillNotStayUpFailsTheCallWithItsReason() async {
        let rig = Rig()
        await rig.startOwned()
        rig.audio.onFailure?("the audio engine stopped 3 times in 5 seconds and would not stay up")
        guard case .failed(let failure) = rig.controller.phase else { Issue.record("not failed"); return }
        #expect(failure.details.contains("stopped 3 times in 5 seconds"))
    }

    @Test func restartsAreCappedAtThreeInFiveSeconds() {
        var limiter = RestartLimiter()
        let first = limiter.allow(at: .seconds(0))
        let second = limiter.allow(at: .seconds(1))
        let third = limiter.allow(at: .seconds(2))
        #expect(first && second && third)
        let fourth = limiter.allow(at: .seconds(4))
        #expect(!fourth, "a fourth within five seconds is refused")
        let later = limiter.allow(at: .seconds(5.1))
        #expect(later, "the window slides")
    }

    @Test func aDeniedMicrophoneIsACalmFailureAndNoCallIsPlaced() async {
        let rig = Rig()
        rig.mic.status = .denied
        await rig.controller.start(bot: rig.bot)
        guard case .failed(let failure) = rig.controller.phase else { Issue.record("not failed"); return }
        #expect(failure.sentence.contains("microphone") && failure.canRetry)
        #expect(rig.link.opened == 0 && rig.driver.activations.isEmpty)
    }

    @Test func aPromptThatIsRefusedIsTheSameCalmFailure() async {
        let rig = Rig()
        rig.mic.status = .undetermined
        rig.mic.grantsOnRequest = false
        await rig.controller.start(bot: rig.bot)
        #expect(rig.controller.phase == .failed(.microphoneDenied))
    }

    @Test func autoRunsFreeWithAnHonestNoteAndLiveCannotBePicked() async {
        let rig = Rig()
        rig.controller.setEngineChoice(.live)
        #expect(rig.controller.engineChoice == .auto, "live is disabled in this slice")
        await rig.startOwned()
        #expect(rig.controller.note == CallPresentation.autoNote)
        #expect(rig.link.messages.contains(.start(id: "c1", botKey: testBotKey, engine: .free)))
    }

    @Test func theEngineChoiceIsRemembered() {
        let preferences = InMemoryCallPreferences()
        let rig = Rig(preferences: preferences)
        rig.controller.setEngineChoice(.free)
        #expect(preferences.engineChoice() == .free)
    }

    // MARK: speaking

    @Test func anUtteranceIsSentAsAudioWithTheEpochThenEndOfSpeech() async {
        let rig = Rig()
        await rig.startOwned()
        await rig.hear(silence(ms: 200))
        await rig.hear(sine(ms: 500, amplitude: 8000))
        await rig.hear(silence(ms: 1000))
        #expect(await until("eos") { rig.link.messages.contains(.eos(callId: testCallId, epoch: 1)) })
        let order = rig.link.order
        #expect(order.last == "audio.eos" && order.dropLast().allSatisfy { $0 == "audio" || $0 == "call.start" })
        #expect(rig.link.audio.allSatisfy { $0.epoch == 1 && $0.pcm.count % 2 == 0 && $0.pcm.count <= 64 * 1024 })
        #expect(rig.link.audio.count > 20)
        #expect(rig.controller.stateLine == "Thinking")
    }

    @Test func thinkingEndsWhenTheBotNeverAnswersSoTheCallSaysListening() async {
        let rig = Rig()
        await rig.startOwned()
        await rig.hear(silence(ms: 200))
        await rig.hear(sine(ms: 500, amplitude: 8000))
        await rig.hear(silence(ms: 1000))
        #expect(await until("eos") { rig.link.messages.contains(.eos(callId: testCallId, epoch: 1)) })
        #expect(rig.controller.stateLine == "Thinking")

        await rig.time.advance(by: CallPresentation.thinkingLimit - .seconds(1))
        #expect(rig.controller.stateLine == "Thinking", "a slow answer still says so")
        await rig.time.advance(by: .seconds(2))
        #expect(await until("gave up") { rig.controller.stateLine == "Listening" })
        #expect(rig.controller.thinkingGaveUp)
    }

    @Test func bargeInStopsPlaybackAndTellsTheHubBeforeTheAudio() async {
        let rig = Rig()
        await rig.startOwned()
        rig.link.pushInbound(Hub.ttsStart(reply: 1, rate: 24000))
        _ = await until("tts.start") { rig.controller.session?.openReplies == [1] }
        rig.link.push(.audio(replyId: 1, pcm: Data(count: 24_000 * 2 / 2)))  // 500 ms: past the prebuffer
        _ = await until("played") { !rig.audio.played.isEmpty }
        #expect(rig.controller.stateLine == "Speaking")
        let stopsBefore = rig.audio.playbackStops
        await rig.hear(sine(ms: 1400, amplitude: 9000))  // the stop gate is 1 s of sustained voice
        #expect(await until("barge") { rig.link.messages.contains(.bargeIn(callId: testCallId, epoch: 1)) })
        #expect(rig.audio.playbackStops > stopsBefore && !rig.audio.isPlaying)
        #expect(await until("audio after barge-in") { !rig.link.audio.isEmpty })
        let order = rig.link.order
        let barge = order.firstIndex(of: "audio.barge_in")
        let firstAudio = order.firstIndex(of: "audio")
        #expect(barge != nil && firstAudio != nil && barge! < firstAudio!)
    }

    @Test func lateSpeechAfterTtsStopNeverPlays() async {
        let rig = Rig()
        await rig.startOwned()
        rig.link.pushInbound(Hub.ttsStart(reply: 1))
        rig.link.pushInbound(Hub.ttsStop())
        _ = await until("stopped") { rig.controller.session?.openReplies.isEmpty == true }
        rig.link.push(.audio(replyId: 1, pcm: Data(count: 48_000)))
        await settle()
        #expect(rig.audio.played.isEmpty)
    }

    @Test func muteEndsAnUtteranceInFlightAndSendsNoMoreAudio() async {
        let rig = Rig()
        await rig.startOwned()
        await rig.hear(sine(ms: 400, amplitude: 8000))
        rig.controller.setMuted(true)
        #expect(await until("eos on mute") { rig.link.messages.contains(.eos(callId: testCallId, epoch: 1)) })
        let sent = rig.link.audio.count
        await rig.hear(sine(ms: 600, amplitude: 8000))
        #expect(rig.link.audio.count == sent)
        #expect(rig.controller.stateLine == "Muted")
        rig.controller.setMuted(false)
        #expect(rig.controller.stateLine == "Thinking")
    }

    // MARK: ownership

    @Test func joiningTheDesktopsCallNeedsNoNewCallAndShowsWhereItIs() async {
        let rig = Rig()
        await rig.controller.start(bot: rig.bot)
        let desktop = Hub.summary(owner: "desk", participants: [Hub.participant("desk", kind: "desktop", label: "Mac", role: "owner")])
        rig.link.pushHello(Hub.helloOk(calls: [desktop]))
        _ = await until("join sent") { rig.link.messages.contains(.join(id: "c1", callId: testCallId, since: nil)) }
        #expect(!rig.link.messages.contains { if case .start = $0 { true } else { false } })
        rig.link.pushInbound(Hub.state(role: "listener", epoch: 1, call: desktop))
        rig.link.pushInbound(Hub.joined(id: "c1", role: "listener", epoch: 1))
        _ = await until("elsewhere") { rig.controller.session?.isElsewhere == true }
        #expect(rig.controller.stateLine == "On hold here")
        await rig.hear(sine(ms: 600, amplitude: 9000))
        #expect(rig.link.audio.isEmpty, "a listener sends no audio")
        #expect(rig.audio.starts == 0 || rig.audio.stops >= rig.audio.starts, "a listener keeps the microphone closed")
    }

    @Test func takingItOverStartsTheMicrophoneUnderTheNewEpoch() async {
        let rig = Rig()
        await rig.controller.start(bot: rig.bot)
        let desktop = Hub.summary(owner: "desk", epoch: 1)
        rig.link.pushHello(Hub.helloOk(calls: [desktop]))
        rig.link.pushInbound(Hub.state(role: "listener", epoch: 1, call: desktop))
        rig.link.pushInbound(Hub.joined(id: "c1", role: "listener", epoch: 1))
        _ = await until("elsewhere") { rig.controller.session?.canTakeOver == true }
        rig.controller.takeOver()
        _ = await until("take sent") { rig.link.messages.contains(.take(id: "c2", callId: testCallId)) }
        rig.link.pushInbound(Hub.taken(epoch: 2))
        _ = await until("owner") { rig.controller.session?.uplinkEpoch == 2 }
        #expect(await until("mic on") { rig.audio.starts >= 1 })
        await rig.hear(sine(ms: 600, amplitude: 9000))
        #expect(await until("audio at 2") { rig.link.audio.first?.epoch == 2 })
    }

    @Test func beingTakenOverMovesToListenAndSilencesThePhone() async {
        let rig = Rig()
        await rig.startOwned()
        rig.link.pushInbound(Hub.state(role: "listener", epoch: 2, call: Hub.summary(owner: "desk", epoch: 2)))
        _ = await until("demoted") { rig.controller.session?.isElsewhere == true }
        #expect(rig.audio.playbackStops > 0)
        let sent = rig.link.audio.count
        await rig.hear(sine(ms: 600, amplitude: 9000))
        #expect(rig.link.audio.count == sent)
    }

    // MARK: lock, drop, interruption

    @Test func aDroppedLinkShowsReconnectingKeepsTheAudioAndResumesWithJoin() async {
        let rig = Rig()
        await rig.startOwned()
        let startsBefore = rig.audio.starts
        rig.link.push(.down)
        _ = await until("reconnecting") { rig.controller.stateLine == "Reconnecting" }
        #expect(rig.driver.deactivations == 0, "the audio session stays up, so the app keeps running locked")
        #expect(rig.audio.starts == startsBefore)
        let mine: [[String: Any]] = [["call_id": testCallId, "role": "owner", "owner_epoch": 1]]
        rig.link.pushHello(Hub.helloOk(calls: [Hub.summary()], yours: mine))
        _ = await until("join") { rig.link.messages.contains { if case .join(_, let id, _) = $0 { id == testCallId } else { false } } }
        rig.link.pushInbound(Hub.joined(id: "c2", role: "owner", epoch: 1))
        _ = await until("listening again") { rig.controller.stateLine == "Listening" }
        #expect(rig.link.messages.filter { if case .start = $0 { true } else { false } }.count == 1, "never a second call")
    }

    @Test func aPhoneCallPutsTheCallOnHoldAndResumesWhenTheSystemAllows() async {
        let rig = Rig()
        await rig.startOwned()
        rig.driver.emit(.interruptionBegan)
        _ = await until("hold") { rig.controller.hold == .interrupted }
        #expect(rig.controller.stateLine == "On hold" && rig.audio.stops >= 1)
        rig.driver.emit(.interruptionEnded(shouldResume: true))
        _ = await until("resumed") { rig.controller.hold == nil }
        #expect(rig.driver.activations == [.call, .call])
        #expect(rig.audio.starts == 2)
    }

    @Test func anInterruptionWithoutAResumeHintWaitsForThePersonToResume() async {
        let rig = Rig()
        await rig.startOwned()
        rig.driver.emit(.interruptionBegan)
        _ = await until("hold") { rig.controller.hold == .interrupted }
        rig.driver.emit(.interruptionEnded(shouldResume: false))
        await settle()
        #expect(rig.controller.hold == .interrupted)
        rig.controller.resume()
        #expect(rig.controller.hold == nil && rig.audio.starts == 2)
    }

    @Test func aLostRouteRebuildsTheAudio() async {
        let rig = Rig()
        await rig.startOwned()
        rig.driver.emit(.routeLost)
        #expect(await until("route") { rig.audio.routeChanges == 1 })
    }

    @Test func aRouteThatIsNotSettledYetIsRetriedAndTheCallNeverGoesOnHold() async {
        let rig = Rig()
        await rig.startOwned()
        rig.audio.routeChangeFailures = 2
        rig.driver.emit(.routeLost)
        #expect(await until("first try") { rig.audio.routeChanges == 1 })
        await rig.time.advance(by: .milliseconds(450))
        #expect(await until("second try") { rig.audio.routeChanges == 2 })
        await rig.time.advance(by: .milliseconds(1250))
        #expect(await until("third try works") { rig.audio.routeChanges == 3 })
        #expect(rig.controller.hold == nil, "the earbuds into their case never end the call")
    }

    @Test func aRouteThatNeverOpensPutsTheCallOnHoldWithTheTrueReasonNotAnotherApp() async {
        let rig = Rig()
        await rig.startOwned()
        await rig.hear(sine(ms: 100, amplitude: 8000))  // the microphone works: the silence watchdog never ends the call
        rig.audio.routeChangeFailures = 99
        rig.driver.emit(.routeLost)
        _ = await until("first try") { rig.audio.routeChanges == 1 }
        // Each pause is a timer the call registered after the try before it: let it register, then move the clock.
        await settle()
        await rig.time.advance(by: .milliseconds(450))
        #expect(await until("second try") { rig.audio.routeChanges == 2 })
        await settle()
        await rig.time.advance(by: .milliseconds(1250))
        #expect(await until("third try") { rig.audio.routeChanges == 3 })
        await settle()
        for _ in 0..<4 where rig.audio.routeChanges < 4 {
            await settle()
            await rig.time.advance(by: .seconds(1))
        }
        _ = await until("fourth try") { rig.audio.routeChanges == 4 }
        #expect(rig.audio.routeChanges == 4, "four tries: now, 0.4 s, 1.2 s and 3 s later")
        #expect(await until("on hold") { rig.controller.hold == .routeChanged })
        #expect(CallPresentation.holdSentence(.routeChanged).contains("sound device changed"))
        #expect(!CallPresentation.holdSentence(.routeChanged).contains("Another app"))
    }

    @Test func anAudioSessionTakenByAnotherPurposePutsTheCallOnHold() async {
        let rig = Rig()
        await rig.startOwned()
        try? rig.audioSession.begin(.spokenReply)
        #expect(rig.controller.hold == .audioTaken)
    }

    // MARK: ending

    @Test func endSendsCallEndAndTheHubsEndedReleasesEverything() async {
        let rig = Rig()
        await rig.startOwned()
        rig.controller.end()
        _ = await until("end sent") { rig.link.messages.contains(.end(id: "c2", callId: testCallId)) }
        rig.link.pushInbound(Hub.ended("ended_by_client"))
        _ = await until("over") { rig.controller.phase == .over(.byClient) }
        #expect(rig.driver.deactivations >= 1 && rig.audioSession.holder == nil)
        #expect(await until("closed") { rig.link.closed == 1 })
        #expect(rig.activity.endings.count == 1)
    }

    @Test func ifTheHubNeverAnswersEndStillEndsLocally() async {
        let rig = Rig()
        await rig.startOwned()
        rig.controller.end()
        await settle()
        await rig.time.advance(by: .seconds(4))
        #expect(rig.controller.phase == .over(.byClient))
    }

    @Test func leavingAListenedCallSaysLeaveNotEnd() async {
        let rig = Rig()
        await rig.controller.start(bot: rig.bot)
        rig.link.pushHello(Hub.helloOk(calls: [Hub.summary(owner: "desk")]))
        rig.link.pushInbound(Hub.state(role: "listener", epoch: 1, call: Hub.summary(owner: "desk")))
        rig.link.pushInbound(Hub.joined(id: "c1", role: "listener", epoch: 1))
        _ = await until("listener") { rig.controller.session?.isElsewhere == true }
        rig.controller.leave()
        _ = await until("left") { rig.controller.phase == .over(.byClient) }
        #expect(rig.link.messages.contains { if case .leave = $0 { true } else { false } })
        #expect(!rig.link.messages.contains { if case .end = $0 { true } else { false } })
    }

    @Test func aGatewayLostEndingIsACalmSentenceWithRetry() async {
        let rig = Rig()
        await rig.startOwned()
        rig.link.pushInbound(Hub.ended("gateway_lost"))
        _ = await until("over") { rig.controller.phase == .over(.gatewayLost) }
        await rig.controller.retry()
        #expect(rig.controller.isInCall, "Retry places a new call")
    }

    // MARK: failures

    @Test func aRefusedStartIsACalmFailureWithRetry() async {
        let rig = Rig()
        await rig.controller.start(bot: rig.bot)
        rig.link.pushHello(Hub.helloOk())
        _ = await until("start") { rig.link.messages.contains(.start(id: "c1", botKey: testBotKey, engine: .free)) }
        rig.link.pushInbound(Hub.error("unavailable", id: "c1"))
        _ = await until("failed") { if case .failed = rig.controller.phase { true } else { false } }
        guard case .failed(let failure) = rig.controller.phase else { return }
        #expect(failure.sentence == HubErrorCode.unavailable.sentence && failure.canRetry && !failure.details.isEmpty)
        #expect(failure.calm.details == failure.details)
        #expect(rig.audioSession.holder == nil, "a failed call gives the audio session back")
    }

    @Test func aDisabledRouteSaysCallsAreNotEnabledOnThisMachine() async {
        let rig = Rig()
        await rig.controller.start(bot: rig.bot)
        rig.link.push(.failed(.disabled))
        _ = await until("failed") { if case .failed = rig.controller.phase { true } else { false } }
        guard case .failed(let failure) = rig.controller.phase else { return }
        #expect(failure.sentence == CallPresentation.disabledSentence && !failure.canRetry)
        #expect(rig.controller.availability(for: "oracle") == .disabled)
        #expect(!rig.controller.isCallShown(for: "oracle"))
    }

    @Test func aMissingPairingIsACalmFailure() async {
        let rig = Rig(makeLink: false)
        await rig.controller.start(bot: rig.bot)
        guard case .failed(let failure) = rig.controller.phase else { Issue.record("not failed"); return }
        #expect(failure.canRetry && !failure.sentence.isEmpty)
    }

    @Test func anAudioEngineThatWillNotStartIsACalmFailure() async {
        let rig = Rig()
        struct Boom: Error {}
        rig.audio.startError = Boom()
        await rig.controller.start(bot: rig.bot)
        rig.link.pushHello(Hub.helloOk())
        _ = await until("failed") { if case .failed = rig.controller.phase { true } else { false } }
        guard case .failed(let failure) = rig.controller.phase else { return }
        #expect(failure.sentence.contains("audio"))
    }

    // MARK: availability (the Call button)

    @Test func theProbeShowsTheButtonWhenTheHubSaysHelloAndHidesItOn404() async {
        let available = Rig()
        available.link.pushHello(Hub.helloOk())
        await available.controller.probe(gatewayId: "oracle")
        #expect(available.controller.availability(for: "oracle") == .available && available.controller.isCallShown(for: "oracle"))

        let disabled = Rig()
        disabled.link.push(.failed(.disabled))
        await disabled.controller.probe(gatewayId: "other")
        #expect(disabled.controller.availability(for: "other") == .disabled && !disabled.controller.isCallShown(for: "other"))

        let offline = Rig()
        offline.link.push(.failed(.unreachable(detail: "offline")))
        await offline.controller.probe(gatewayId: "oracle")
        #expect(offline.controller.availability(for: "oracle") == .unreachable && offline.controller.isCallShown(for: "oracle"), "offline keeps the button")
    }

    @Test func theButtonIsHiddenUntilTheMachineHasAnswered() {
        let rig = Rig()
        #expect(!rig.controller.isCallShown(for: "oracle"))
    }

    // MARK: approvals and the Live Activity seam

    @Test func waitingApprovalsAreCountedForTheBannerAndNeverAnsweredByTheCall() async {
        let rig = Rig()
        await rig.startOwned()
        rig.waiting.withLock { $0 = 2 }
        #expect(rig.controller.waitingRequests == 2)
        #expect(CallPresentation.waitingBanner(count: 2) == "2 requests are waiting for you.")
        #expect(rig.link.messages.allSatisfy { if case .say = $0 { false } else { true } })
    }

    @Test func theActivityPresenterSeesEveryChangeAndTheEnd() async {
        let rig = Rig()
        await rig.startOwned()
        rig.link.pushInbound(Hub.text(Hub.transcript(row: "r1", speaker: "voice", text: "Hello there")).self)
        _ = await until("caption") { rig.activity.changes.last?.caption == "Hello there" }
        let snapshot = rig.activity.changes.last
        #expect(snapshot?.botName == "Hermes" && snapshot?.role == .owner && snapshot?.callId == testCallId && snapshot?.engine == .free)
        rig.link.pushInbound(Hub.ended("ended_by_client"))
        _ = await until("ended") { rig.activity.endings.count == 1 }
    }
}

@MainActor
struct CallOutputControllerTests {
    private func rig() async -> (Rig, FakeProximity) {
        let rig = Rig()
        let proximity = FakeProximity()
        rig.controller.proximity = proximity
        await rig.startOwned()
        return (rig, proximity)
    }

    @Test func aCallStartsOnTheSpeakerAndWatchesTheSensor() async {
        let (rig, proximity) = await rig()
        #expect(await until("output asked") { rig.audio.outputs.last == .speaker })
        #expect(proximity.running)
    }

    @Test func bringingThePhoneToTheEarMovesTheSoundToTheReceiverAndTakingItAwayBringsTheSpeakerBack() async {
        let (rig, proximity) = await rig()
        _ = await until("speaker") { rig.audio.outputs.last == .speaker }
        proximity.move(near: true)
        #expect(rig.audio.outputs.last == .receiver)
        proximity.move(near: false)
        #expect(rig.audio.outputs.last == .speaker)
    }

    @Test func theSensorIsOnlyOnDuringTheCallAndIsOffOnceItEnded() async {
        let (rig, proximity) = await rig()
        #expect(proximity.running)
        rig.controller.end()
        rig.link.pushInbound(Hub.ended("ended_by_client"))
        _ = await until("ended") { !rig.controller.isInCall }
        #expect(!proximity.running, "covering the camera must not darken the home or the chat after the call")
    }

    @Test func theCircleSwapsAndAChoiceOfTheReceiverSurvivesTakingThePhoneFromTheEar() async {
        let (rig, proximity) = await rig()
        _ = await until("speaker") { rig.audio.outputs.last == .speaker }
        rig.controller.toggleOutput()
        #expect(rig.audio.outputs.last == .receiver)
        proximity.move(near: true)
        proximity.move(near: false)
        #expect(rig.audio.outputs.last == .receiver, "the owner chose the receiver")
    }

    @Test func aConnectedDeviceIsLeftToTheSystemAndTheSensorIsOff() async {
        let (rig, proximity) = await rig()
        _ = await until("speaker") { rig.audio.outputs.last == .speaker }
        rig.audio.external = true
        rig.driver.emit(.routeChanged)
        #expect(await until("left to the system") { rig.audio.outputs.last.map { $0 == nil } ?? false })
        #expect(!proximity.running)
        #expect(!rig.controller.outputState.offersChoice)
        rig.controller.toggleOutput()
        #expect(rig.audio.outputs.last.map { $0 == nil } ?? false, "a tap changes nothing while a device has the sound")
    }

    @Test func theSessionIsAskedOnlyWhenTheAnswerChanges() async {
        let (rig, proximity) = await rig()
        _ = await until("speaker") { rig.audio.outputs.last == .speaker }
        let asked = rig.audio.outputs.count
        proximity.move(near: false)
        proximity.move(near: false)
        #expect(rig.audio.outputs.count == asked, "our own request coming back as a route change never loops")
    }
}
