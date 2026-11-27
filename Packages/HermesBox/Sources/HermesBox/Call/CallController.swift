import Foundation
import Observation

/// One voice call on this phone: the link to the hub, the audio, the audio session and what the screen shows.
/// The views only call these methods; every decision lives here and in the pure types it drives (`CallSession`,
/// `UtteranceGate`, `ReplyJitterBuffer`, `CallPresentation`), all tested with fakes.
///
/// The call is server held: this controller is one client of it. It can start a call, join one that runs elsewhere
/// (the desktop), take it over and end it. Approvals are never handled here: they stay on the ledger cards.
///
/// Locked screen: the audio session (`.call`) is held from the first moment to the last, and the audio engine runs
/// whenever this phone is the one talking, so with `UIBackgroundModes` `audio` the app keeps running and so does the
/// WebSocket. See `ios/README.md`, "Voice calls".
@MainActor
@Observable
public final class CallController {
    public enum Phase: Equatable, Sendable {
        case idle
        case running
        case over(CallEnding)
        case failed(CallFailure)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var session: CallSession?
    /// What the end-of-call screen says. Set when the call is over (whatever the cause), cleared when a new call starts or the screen is done.
    public private(set) var endedSummary: CallEndedSummary?
    public private(set) var bot: CallBot?
    public private(set) var isMuted = false
    public private(set) var hold: CallHold?
    public private(set) var userSpeaking = false
    public private(set) var isPlaying = false
    /// What the microphone really hears and what the speaker really plays, 0...1, smoothed (`LevelMeter`) and published at
    /// about `levelRate` Hz so the screen does not redraw per buffer. The orb reads these directly.
    public private(set) var micLevel = 0.0
    public private(set) var playbackLevel = 0.0
    /// The last few `playbackLevel` values, for the travelling bars.
    public private(set) var playbackTrail = LevelTrail()
    /// Where the sound goes and why (the owner's choice, a connected device, the phone at the ear).
    public private(set) var outputState = CallOutputState()
    /// "Thinking" lasted longer than `CallPresentation.thinkingLimit` with no speech: the line says what the call is doing now.
    public private(set) var thinkingGaveUp = false
    public private(set) var isAskingMicrophone = false
    public private(set) var engineChoice: CallEngineChoice
    /// A calm line about the engine that was picked ("Auto uses the free engine on this phone for now.").
    public private(set) var note: String?
    public private(set) var availability: [String: CallAvailability] = [:]
    /// The call screen is up. The chat presents it from this one flag.
    public var isScreenShown = false

    @ObservationIgnored private let makeLink: @MainActor (String) -> (any CallLink)?
    @ObservationIgnored private let audio: any CallAudioIO
    @ObservationIgnored private let audioSession: VoiceAudioSession
    @ObservationIgnored private let microphone: any CallMicrophone
    @ObservationIgnored private let preferences: any CallPreferences
    @ObservationIgnored private let activity: any CallActivityPresenting
    @ObservationIgnored private let waitingCount: @MainActor (String) -> Int
    @ObservationIgnored private let time: any TimeSource
    @ObservationIgnored private var thinkingExpiry: Task<Void, Never>?
    @ObservationIgnored private var routeRebuild: Task<Void, Never>?
    /// The last output the call asked of the session, so a route change that is our own request never loops.
    @ObservationIgnored private var lastRequestedOutput: CallOutputChoice?
    @ObservationIgnored private var outputAsked = false
    /// The proximity sensor: at the ear the receiver is used and the screen goes dark. Set by the app.
    @ObservationIgnored public var proximity: (any CallProximitySensing)? {
        didSet {
            proximity?.onChange = { [weak self] near in
                self?.outputState.nearEar = near
                self?.refreshOutput()
            }
        }
    }
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let endGrace: Duration
    @ObservationIgnored private let micWatchdog: Duration

    @ObservationIgnored private var link: (any CallLink)?
    @ObservationIgnored private var gate = UtteranceGate()
    @ObservationIgnored private var duck = BargeInDuck()
    @ObservationIgnored private var jitter = ReplyJitterBuffer()
    @ObservationIgnored private var outbox: AsyncStream<Outgoing>.Continuation?
    @ObservationIgnored private var micInput: AsyncStream<[Int16]>.Continuation?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var displacedToken: UUID?
    @ObservationIgnored private var audioRunning = false
    @ObservationIgnored private var micMeter = LevelMeter()
    @ObservationIgnored private var playbackMeter = LevelMeter()
    /// The latest raw readings and when they came; a reading older than `staleReading` counts as silence.
    @ObservationIgnored private var micRaw = (level: 0.0, at: ContinuousClock.now)
    @ObservationIgnored private var playbackRaw = (level: 0.0, at: ContinuousClock.now)
    @ObservationIgnored private var levelTicker: Task<Void, Never>?
    public static let levelRate = 30.0
    static let staleReading = Duration.milliseconds(150)
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var diag = CallDiagnostics()
    @ObservationIgnored private var echoCancellation = true
    @ObservationIgnored private var micBatches = 0
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var uplink = UplinkCounters()
    /// S27, a call answered through CallKit: the audio engine waits for CallKit's `didActivate` (or the bounded wait of
    /// the ring coordinator), never the app's own activation.
    @ObservationIgnored private var requiresSystemAudio = false
    @ObservationIgnored private var systemAudioReady = false
    @ObservationIgnored private var answerResult: RingAnswerOutcome?
    @ObservationIgnored private var answerWaiter: CheckedContinuation<RingAnswerOutcome, Never>?
    @ObservationIgnored private var answerTimeout: Task<Void, Never>?
    /// S28: speech that arrives before the engine runs waits here (about 15 s, oldest dropped) and plays in order once it starts.
    @ObservationIgnored private var pendingSpeech = PendingSpeechQueue()
    /// S28: when CallKit activated the audio session, to log how long the engine took after it.
    @ObservationIgnored private var systemActivatedAt: ContinuousClock.Instant?
    /// S27: told once when a call ends or fails here, with its hub call id (the ring coordinator ends the CallKit call).
    @ObservationIgnored public var onCallEnded: (@MainActor (String?) -> Void)?

    private enum Outgoing: Sendable {
        case message(CallOutbound)
        case audio(epoch: UInt32, pcm: Data)
    }

    public init(
        makeLink: @escaping @MainActor (String) -> (any CallLink)?, audio: any CallAudioIO, audioSession: VoiceAudioSession,
        microphone: any CallMicrophone, preferences: any CallPreferences = InMemoryCallPreferences(),
        activity: any CallActivityPresenting = NoCallActivity(), waitingCount: @escaping @MainActor (String) -> Int = { _ in 0 },
        time: any TimeSource = SystemTimeSource(), now: @escaping @Sendable () -> Date = { Date() }, endGrace: Duration = .seconds(3),
        micWatchdog: Duration = .milliseconds(1500)
    ) {
        self.makeLink = makeLink
        self.audio = audio
        self.audioSession = audioSession
        self.microphone = microphone
        self.preferences = preferences
        self.activity = activity
        self.waitingCount = waitingCount
        self.time = time
        self.now = now
        self.endGrace = endGrace
        self.micWatchdog = micWatchdog
        engineChoice = preferences.engineChoice()
        audio.onDrained = { [weak self] in self?.playbackDrained() }
        self.audio.onFailure = { [weak self] reason in self?.audioEngineFailed(reason) }
        self.audio.onPlaybackLevel = Self.playbackReporter(self)
    }

    // MARK: derived (what the screen reads)

    public var isInCall: Bool { phase == .running }

    /// Hermes Neo: when the running call started here, for the call bar's and the screen's clock (read only).
    public var callStartedAt: Date? { isInCall ? startedAt : nil }

    /// The bot is in standby (it answers only to a wake word); the call itself is unchanged.
    public var standingBy: Bool { session?.standingBy ?? false }

    public var stateLine: String {
        CallPresentation.stateLine(
            session: session, muted: isMuted, hold: hold, userSpeaking: userSpeaking, playing: isPlaying, thinkingGaveUp: thinkingGaveUp)
    }

    /// The phone's side of the call in numbers (frames sent, mic level, end-of-speech, last hub error, link). Not observed:
    /// the Details block re-reads it once a second, so the audio path never invalidates a view 50 times a second.
    public var diagnostics: CallDiagnostics {
        var d = diag
        let sent = uplink.snapshot
        d.framesSent = sent.sent
        d.framesFailed = sent.failed
        d.bytesSent = sent.bytes
        d.captureFormat = audio.captureDescription
        d.audioReport = audio.captureReport
        d.echoCancellation = echoCancellation ? "on" : "off (fallback)"
        d.micBatches = micBatches
        if let session {
            switch session.link {
            case .connecting: d.link = "connecting"
            case .up: d.link = "up"
            case .reconnecting: d.link = "reconnecting"
            }
            d.role = session.role?.rawValue ?? "none"
            d.hubState = session.hubState.rawValue
            d.epoch = session.epoch
            d.lastHubError = session.lastHubError?.rawValue
            d.hubErrors = session.hubErrorCount
            d.partialRows = session.partialRows
            d.finalPersonRows = session.finalPersonRows
        }
        return d
    }

    public var waitingRequests: Int { bot.map { waitingCount($0.botKey) } ?? 0 }

    public func availability(for gatewayId: String) -> CallAvailability { availability[gatewayId] ?? .unknown }

    /// The Call button: shown unless the machine said calls are off, and only once it said yes or could not be reached.
    public func isCallShown(for gatewayId: String) -> Bool {
        switch availability(for: gatewayId) {
        case .available, .unreachable: true
        case .unknown, .disabled: false
        }
    }

    public func setEngineChoice(_ choice: CallEngineChoice) {
        guard CallPresentation.engineOptions().first(where: { $0.choice == choice })?.isEnabled == true else { return }
        engineChoice = choice
        preferences.setEngineChoice(choice)
    }

    // MARK: availability

    /// Ask the machine once whether calls are on: open the call socket, wait for the hub's hello, close. A 404 means no.
    public func probe(gatewayId: String) async {
        if availability(for: gatewayId) == .available || availability(for: gatewayId) == .disabled { return }
        guard let probeLink = makeLink(gatewayId) else { return }
        await probeLink.open()
        var result = CallAvailability.unreachable
        for await event in probeLink.events {
            switch event {
            case .up: result = .available
            case .failed(.disabled): result = .disabled
            case .failed: result = .unreachable
            default: continue
            }
            break
        }
        await probeLink.close()
        availability[gatewayId] = result
    }

    // MARK: the one entry point

    /// Show the call screen for `bot`: the running call when there is one, else start a new one.
    public func open(bot: CallBot) {
        isScreenShown = true
        if isInCall { return }
        Task { await start(bot: bot) }
    }

    public func closeScreen() { isScreenShown = false }

    // MARK: starting

    public func start(bot: CallBot) async {
        guard !isInCall else { return }
        generation += 1
        let mine = generation
        self.bot = bot
        resetRuntimeState()
        requiresSystemAudio = false
        let resolution = CallPresentation.resolve(engineChoice)
        note = resolution.note
        guard let engine = resolution.engine else {
            phase = .failed(CallFailure(sentence: resolution.refusal ?? CallPresentation.liveUnavailableSentence, details: "engine live not available", canRetry: false))
            return
        }
        guard await ensureMicrophone(), mine == generation else { return }
        guard let link = makeLink(bot.gatewayId) else {
            phase = .failed(CallFailure.link(.unreachable(detail: "not paired")))
            return
        }
        startedAt = now()
        session = CallSession(intent: .start(botKey: bot.botKey, engine: engine))
        phase = .running
        do {
            try audioSession.begin(.call)
        } catch {
            fail(.audio("audio session: \(error)"))
            return
        }
        attach(link)
        await link.open()
        publish()
    }

    // MARK: answering a ring (S27)

    /// Answer a ring the box started (CallKit's answer action, already fulfilled by the caller): open the link, join the
    /// ownerless call and take it. The audio session is CallKit's: it is configured here but never activated, and the
    /// engine starts only after `systemAudioActivated()`. Resolves `.answered` once this phone owns the call, `.failed`
    /// when the join or take did not work within `timeout` (the call is then over here), `.busy` when a call already runs.
    public func answerRing(bot: CallBot, callId: String, timeout: Duration = .seconds(20)) async -> RingAnswerOutcome {
        guard !isInCall else { return .busy }
        generation += 1
        let mine = generation
        self.bot = bot
        resetRuntimeState()
        // The bot rang, so the phone is answered like any phone call: at the ear first. A call the owner starts keeps the
        // speaker (he is looking at the app); a ring often arrives with the phone locked or in a pocket, and the loudspeaker
        // there feeds the bot's own greeting back into the microphone. The sound circle still swaps to the speaker.
        outputState.preference = .receiver
        answerResult = nil
        requiresSystemAudio = true
        guard microphone.access() == .granted else {
            // No prompt from a locked phone: the owner allows the microphone in the app once.
            requiresSystemAudio = false
            phase = .failed(.microphoneDenied)
            return .failed(detail: "microphone not granted")
        }
        guard let link = makeLink(bot.gatewayId) else {
            requiresSystemAudio = false
            phase = .failed(CallFailure.link(.unreachable(detail: "not paired")))
            return .failed(detail: "not paired")
        }
        startedAt = now()
        session = CallSession(intent: .answer(callId: callId, botKey: bot.botKey))
        phase = .running
        isScreenShown = true
        do {
            try audioSession.adoptSystemActivated(.call)
        } catch {
            fail(.audio("audio session: \(error)"))
            return .failed(detail: "audio session: \(error)")
        }
        attach(link)
        armAnswerTimeout(timeout, generation: mine)
        await link.open()
        publish()
        if let answerResult { return answerResult }
        return await withCheckedContinuation { continuation in
            if let answerResult {
                continuation.resume(returning: answerResult)
            } else {
                answerWaiter = continuation
            }
        }
    }

    /// CallKit activated the audio session (or the coordinator stopped waiting for it): the engine may start.
    public func systemAudioActivated() {
        systemAudioReady = true
        systemActivatedAt = ContinuousClock.now
        guard isInCall else { return }
        if hold == .interrupted, requiresSystemAudio { hold = nil }
        syncAudio()
        publish()
    }

    /// CallKit took the audio session away (another call): hold until it is activated again.
    public func systemAudioDeactivated() {
        guard requiresSystemAudio else { return }
        systemAudioReady = false
        holdForAudio(.interrupted)
    }

    private func armAnswerTimeout(_ timeout: Duration, generation mine: Int) {
        answerTimeout?.cancel()
        answerTimeout = Task { [weak self, time] in
            try? await time.sleep(for: timeout)
            guard !Task.isCancelled, let self, mine == self.generation, self.isInCall, self.session?.role != .owner else { return }
            self.fail(CallFailure.link(.unreachable(detail: "the ring was not taken within \(timeout)")))
        }
    }

    private func resolveAnswer(_ outcome: RingAnswerOutcome) {
        guard requiresSystemAudio, answerResult == nil else { return }
        answerResult = outcome
        answerTimeout?.cancel()
        answerTimeout = nil
        let waiter = answerWaiter
        answerWaiter = nil
        waiter?.resume(returning: outcome)
    }

    /// Mic access with the system prompt on first use. A denial is a calm failure, never a silent call.
    private func ensureMicrophone() async -> Bool {
        switch microphone.access() {
        case .granted: return true
        case .denied:
            phase = .failed(.microphoneDenied)
            return false
        case .undetermined:
            isAskingMicrophone = true
            let granted = await microphone.request()
            isAskingMicrophone = false
            if !granted { phase = .failed(.microphoneDenied) }
            return granted
        }
    }

    /// "Call again" on the end-of-call screen: a new call with the same bot through the one start path.
    public func callAgain() async { await retry() }

    /// Try again after a failure or an ended call that did not end by choice.
    public func retry() async {
        guard let bot else { return }
        switch phase {
        case .failed, .over: await start(bot: bot)
        case .idle, .running: break
        }
    }

    // MARK: what the person does

    public func toggleMute() { setMuted(!isMuted) }

    /// Hermes Neo: a typed turn of the call (`call.say_text`): the bot answers it aloud, as if it was said.
    public func say(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isInCall, !text.isEmpty else { return }
        apply(session?.say(text) ?? [])
        publish()
    }

    public func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        isMuted = muted
        // A sentence in flight is closed now: the hub must not wait for words that will never come.
        if muted { send(gate.finishUtterance()) }
        publish()
    }

    public func takeOver() {
        guard session?.canTakeOver == true else { return }
        Task { [weak self] in
            guard let self, await self.ensureMicrophone() else { return }
            self.apply(self.session?.take() ?? [])
            self.syncAudio()
            self.publish()
        }
    }

    /// Leave a call that runs elsewhere without ending it for everyone.
    public func leave() {
        guard isInCall else { return }
        guard let id = session?.callId, let link else { return finishLocally(.byClient) }
        // The message goes out before the link closes (the outbox would be cancelled with the rest).
        Task { [weak self] in
            await link.send(.leave(id: "leave", callId: id))
            self?.finishLocally(.byClient)
        }
    }

    public func end() {
        guard isInCall else { return }
        // Hermes Neo: a call whose socket never joined (the phone could not reach the box) has no session to send the end
        // through; End must still close it here, or the screen and CallKit stay stuck until the app is killed.
        guard session != nil else { return finishLocally(.byClient) }
        apply(session?.end() ?? [])
        publish()
        let mine = generation
        Task { [weak self, time, endGrace] in
            try? await time.sleep(for: endGrace)
            guard let self, mine == self.generation, self.isInCall else { return }
            self.finishLocally(.byClient)
        }
    }

    /// Back from an interruption that the system did not resume by itself.
    public func resume() {
        guard hold != nil, isInCall else { return }
        do {
            // A CallKit call's session is activated by CallKit, never here (S27).
            if !audioSession.isSystemActivated { try audioSession.begin(.call) }
            hold = nil
            syncAudio()
            publish()
        } catch {
            fail(.audio("audio session: \(error)"))
        }
    }

    public func dismissNotice() {
        session?.dismissNotice()
    }

    /// What the bot put on the call screen, newest first.
    public var displayItems: [CallDisplayItem] { session?.display.items ?? [] }

    /// Clear the cards from this screen only. The call and the other devices are untouched.
    public func clearDisplay() {
        session?.clearDisplay()
    }

    /// Close the screen of a call that is over and forget it.
    public func clear() {
        guard !isInCall else { return }
        phase = .idle
        session = nil
        endedSummary = nil
        isScreenShown = false
    }

    // MARK: wiring

    private func attach(_ link: any CallLink) {
        self.link = link
        let counters = uplink
        let (outStream, outContinuation) = AsyncStream.makeStream(of: Outgoing.self, bufferingPolicy: .unbounded)
        outbox = outContinuation
        let (micStream, micContinuation) = AsyncStream.makeStream(of: [Int16].self, bufferingPolicy: .unbounded)
        micInput = micContinuation
        tasks.append(
            Task {
                for await item in outStream {
                    switch item {
                    case .message(let message): await link.send(message)
                    case .audio(let epoch, let pcm):
                        let delivered = await link.sendAudio(epoch: epoch, pcm: pcm)
                        counters.record(delivered: delivered, bytesInFrame: pcm.count)
                    }
                }
            })
        tasks.append(
            Task { [weak self] in
                for await event in link.events { self?.handle(event) }
            })
        tasks.append(
            Task { [weak self] in
                for await samples in micStream { self?.micSamples(samples) }
            })
        let events = audioSession.events()
        tasks.append(
            Task { [weak self] in
                for await event in events { self?.audioSessionEvent(event) }
            })
        displacedToken = audioSession.addDisplacedHandler { [weak self] purpose in
            if purpose == .call { self?.holdForAudio(.audioTaken) }
        }
    }

    private func handle(_ event: CallLinkEvent) {
        guard isInCall else { return }
        switch event {
        case .up(let hello):
            apply(session?.linkUp(hello) ?? [])
        case .down:
            session?.linkDown()
            stopSpeech()
        case .inbound(let inbound):
            apply(session?.handle(inbound) ?? [])
        case .audio(let replyId, let pcm):
            guard session?.role == .owner, hold == nil else { return }
            play(jitter.push(replyId: replyId, pcm: pcm))
        case .failed(let failure):
            if failure == .disabled, let gateway = bot?.gatewayId { availability[gateway] = .disabled }
            fail(CallFailure.link(failure))
            return
        }
        if let refusal = session?.refusal, session?.callId == nil {
            fail(CallFailure.hub(refusal))
            return
        }
        if session?.role == .owner { resolveAnswer(.answered) }
        syncAudio()
        publish()
    }

    private func apply(_ effects: [CallEffect]) {
        for effect in effects {
            switch effect {
            case .send(let message): outboxSend(message)
            case .stopPlayback: stopSpeech()
            case .beginReply(let replyId, let rate):
                diag.repliesStarted += 1
                restorePlaybackLevel()
                jitter.begin(replyId: replyId, sampleRate: rate)
            case .endReply(let replyId): play(jitter.end(replyId: replyId))
            case .finished:
                finishLocally(session?.ending ?? .byClient)
            }
        }
    }

    // MARK: audio

    /// The engine runs while this phone talks (or may soon): not while it only listens in, not while on hold.
    private func syncAudio() {
        guard isInCall else { return }
        let listensOnly = session?.link == .up && session?.role == .listener
        // Speech waits only for a phone that is the owner; losing the role means it is stale.
        if session?.role != .owner { clearPendingSpeech() }
        // A CallKit call: nothing starts before CallKit activated the session, and nothing before this phone owns it.
        let waitsForSystem = requiresSystemAudio && (!systemAudioReady || session?.role != .owner)
        let wanted = hold == nil && !listensOnly && !waitsForSystem
        if wanted, !audioRunning {
            let input = micInput
            do {
                micBatches = 0
                try audio.start(onSamples: { input?.yield($0) }, echoCancellation: echoCancellation)
                audioRunning = true
                logEngineStarted()
                startLevelTicker()
                armWatchdog()
                refreshOutput()
                flushPendingSpeech()
            } catch {
                fail(.audio("audio engine: \(error)"))
            }
        } else if !wanted, audioRunning {
            stopAudioEngine()
        }
    }

    /// If the tap delivers nothing within `micWatchdog` of the engine start: restart ONCE without voice processing (the
    /// proven dictation capture), then fail the call visibly. A call that connects and hears nothing is never silent.
    private func armWatchdog() {
        watchdog?.cancel()
        diag.watchdog = "waiting (\(echoCancellation ? "with" : "without") echo cancellation)"
        let wait = micWatchdog
        watchdog = Task { [weak self, time] in
            try? await time.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.watchdogFired()
        }
    }

    private func watchdogFired() {
        guard isInCall, audioRunning, micBatches == 0 else {
            if micBatches > 0 { diag.watchdog = "ok, audio arrived" }
            return
        }
        if echoCancellation {
            echoCancellation = false
            diag.watchdog = "no audio with echo cancellation: restarted without it"
            print("[call-audio] watchdog: no tap buffers after \(micWatchdog); restarting without voice processing")
            audio.stop()
            audioRunning = false
            syncAudio()
            publish()
        } else {
            diag.watchdog = "no audio even without echo cancellation: failed"
            print("[call-audio] watchdog: still no tap buffers; failing the call")
            fail(.microphoneSilent)
        }
    }

    private func audioEngineFailed(_ reason: String) {
        guard isInCall else { return }
        fail(.audio(reason))
    }

    private func stopAudioEngine() {
        watchdog?.cancel()
        audio.stop()
        audioRunning = false
        stopLevelTicker()
        gate.reset()
        stopSpeech()
        userSpeaking = false
    }

    private func micSamples(_ samples: [Int16]) {
        micBatches += 1
        guard isInCall, !isMuted, hold == nil, let id = session?.callId, let epoch = session?.uplinkEpoch else {
            diag.micSamplesIgnored += samples.count
            micRaw = (0, ContinuousClock.now)
            gate.reset()
            restorePlaybackLevel()
            userSpeaking = false
            return
        }
        let outputs = gate.process(samples, assistantSpeaking: audio.isPlaying)
        duckWhileUnconfirmed(confirmed: outputs.contains(.bargeIn))
        diag.noteMic(samples: samples, thresholdDb: gate.thresholdDb)
        micRaw = (LevelMeter.normalised(db: diag.lastMicDb), ContinuousClock.now)
        for output in outputs {
            switch output {
            case .bargeIn:
                // Talking over the bot: its speech stops here at once, and the hub is told before the audio follows.
                stopSpeech()
                diag.bargeInsSent += 1
                outboxSend(.bargeIn(callId: id, epoch: epoch))
            case .speechStarted:
                diag.utterancesStarted += 1
                userSpeaking = true
                session?.localSpeechBegan()
            case .audio(let pcm):
                diag.framesQueued += 1
                outbox?.yield(.audio(epoch: epoch, pcm: pcm))
            case .endOfSpeech:
                userSpeaking = false
                diag.eosSent += 1
                session?.localUtteranceEnded()
                outboxSend(.eos(callId: id, epoch: epoch))
            }
        }
        if !outputs.isEmpty { publish() }
    }

    /// End an utterance that is in flight (mute): the hub is told its end of speech.
    private func send(_ outputs: [UtteranceGate.Output]) {
        guard outputs.contains(.endOfSpeech), let id = session?.callId, let epoch = session?.uplinkEpoch else { return }
        userSpeaking = false
        diag.eosSent += 1
        session?.localUtteranceEnded()
        outboxSend(.eos(callId: id, epoch: epoch))
    }

    // MARK: levels

    /// Built outside the main actor on purpose: the audio edge calls it on its own realtime queue.
    nonisolated private static func playbackReporter(_ controller: CallController) -> @Sendable (Double) -> Void {
        { [weak controller] db in Task { @MainActor in controller?.notePlayback(db: db) } }
    }

    /// A buffer the speaker is rendering right now measured `db` dBFS (called from the audio edge, hopped to the main actor).
    func notePlayback(db: Double) { playbackRaw = (LevelMeter.normalised(db: db), ContinuousClock.now) }

    private func startLevelTicker() {
        levelTicker?.cancel()
        levelTicker = Task { [weak self] in
            let clock = ContinuousClock()
            var last = clock.now
            while !Task.isCancelled {
                try? await clock.sleep(for: .milliseconds(1000 / Int(Self.levelRate)))
                guard let self, !Task.isCancelled else { return }
                let now = clock.now
                let seconds = last.duration(to: now)
                last = now
                self.levelTick(dt: Double(seconds.components.seconds) + Double(seconds.components.attoseconds) / 1e18)
            }
        }
    }

    private func stopLevelTicker() {
        levelTicker?.cancel()
        levelTicker = nil
        micMeter.reset()
        playbackMeter.reset()
        micRaw = (0, ContinuousClock.now)
        playbackRaw = (0, ContinuousClock.now)
        micLevel = 0
        playbackLevel = 0
        playbackTrail.reset()
    }

    /// One publishing step: smooth the latest readings over `dt` seconds. Only changes that matter are published.
    func levelTick(dt: Double) {
        let now = ContinuousClock.now
        let mic = micRaw.at.duration(to: now) > Self.staleReading || isMuted ? 0 : micRaw.level
        let played = playbackRaw.at.duration(to: now) > Self.staleReading ? 0 : playbackRaw.level
        let micNow = micMeter.advance(toward: mic, dt: dt)
        let playNow = playbackMeter.advance(toward: played, dt: dt)
        if abs(micNow - micLevel) > 0.004 || (micNow == 0) != (micLevel == 0) { micLevel = micNow }
        if abs(playNow - playbackLevel) > 0.004 || (playNow == 0) != (playbackLevel == 0) { playbackLevel = playNow }
        if playNow > 0 || !playbackTrail.isSilent {
            playbackTrail.push(playNow)
        }
    }

    private func play(_ chunks: [PlaybackChunk]) {
        guard !chunks.isEmpty else { return }
        // S28: no engine yet (a CallKit call before `didActivate`): keep the speech, it plays when the engine starts.
        guard audioRunning else {
            if isInCall, session?.role == .owner, hold == nil {
                for chunk in chunks { pendingSpeech.enqueue(chunk) }
                logPendingSpeech(because: "waiting for the engine")
            }
            return
        }
        for chunk in chunks { audio.play(chunk) }
        isPlaying = true
    }

    /// The engine just started: what waited plays now, in order, before anything that comes later.
    private func flushPendingSpeech() {
        let waiting = pendingSpeech.drain()
        logPendingSpeech(because: "engine started")
        play(waiting)
    }

    private func clearPendingSpeech() {
        guard !pendingSpeech.isEmpty else { return }
        pendingSpeech.clear()
        logPendingSpeech(because: "cleared")
    }

    /// One log line with counts only (never the audio or any words).
    private func logPendingSpeech(because reason: String) {
        let c = pendingSpeech.takeCounters()
        guard !c.isEmpty else { return }
        HermesLog.call.info(
            "speech queue \(reason, privacy: .public): queued=\(c.queued) flushed=\(c.flushed) dropped_overflow=\(c.droppedOverflow) dropped_cleared=\(c.droppedCleared)")
    }

    private func logEngineStarted() {
        if let activated = systemActivatedAt {
            let ms = Int((activated.duration(to: ContinuousClock.now) / .milliseconds(1)).rounded())
            HermesLog.call.info("engine started after_didActivate_ms=\(ms)")
        } else {
            HermesLog.call.info("engine started (no CallKit activation on this call)")
        }
    }

    private func stopSpeech() {
        jitter.stop()
        clearPendingSpeech()
        audio.stopPlayback()
        isPlaying = false
        // Nothing is playing now, so the level goes back without a blip; the next reply starts at full.
        restorePlaybackLevel()
    }

    /// The first onset of voice over the bot lowers it; noise that fades before the stop gate gives it back.
    private func duckWhileUnconfirmed(confirmed: Bool) {
        let voice = audio.isPlaying && gate.voiceRun >= gate.config.onsetFrames
        switch duck.update(voice: voice, confirmed: confirmed, now: time.now()) {
        case .duck: audio.setPlaybackLevel(duck.config.duckLevel)
        case .restore: audio.setPlaybackLevel(1)
        case nil: break
        }
    }

    private func restorePlaybackLevel() {
        if duck.reset() { audio.setPlaybackLevel(1) }
    }

    private func playbackDrained() {
        isPlaying = audio.isPlaying
        publish()
    }

    private func audioSessionEvent(_ event: AudioSessionEvent) {
        guard isInCall else { return }
        switch event {
        case .interruptionBegan:
            holdForAudio(.interrupted)
        case .interruptionEnded(let shouldResume):
            // Resume by itself only when the system says it may; otherwise the screen offers Resume.
            if shouldResume, hold == .interrupted { resume() }
        case .routeLost:
            rebuildAfterRouteLoss()
        case .routeChanged:
            refreshOutput()
        case .servicesReset:
            hold = .audioTaken
            stopAudioEngine()
            resume()
        }
    }

    /// The route lost its device (earbuds into their case, a speaker switched off). The system needs a moment to settle on the
    /// next route, so the engine is rebuilt at once and, if that fails, a few more times a little later. Only when none works the
    /// call goes on hold, and then with the true reason: nobody took the audio, the new route would not open yet.
    private func rebuildAfterRouteLoss() {
        guard routeRebuild == nil else { return }
        routeRebuild = Task { [weak self, time] in
            for pause in CallPresentation.routeRebuildPauses {
                if pause > .zero { try? await time.sleep(for: pause) }
                guard let self, !Task.isCancelled, self.isInCall, self.hold == nil else {
                    self?.routeRebuild = nil
                    return
                }
                do {
                    try self.audio.routeChanged()
                    self.refreshOutput()
                    self.routeRebuild = nil
                    return
                } catch {
                    continue
                }
            }
            self?.routeRebuild = nil
            self?.holdForAudio(.routeChanged)
        }
    }

    private func holdForAudio(_ reason: CallHold) {
        guard isInCall, hold == nil else { return }
        // The mic is closed, so a sentence in flight is ended first.
        send(gate.finishUtterance())
        hold = reason
        stopAudioEngine()
        publish()
    }

    // MARK: finishing

    private func fail(_ failure: CallFailure) {
        var failure = failure
        // Copy details carries the phone's side of the call too (numbers only).
        failure.details += "\n" + diagnostics.text
        let callId = session?.callId
        endedSummary = CallEndedSummary.make(
            failure: failure, started: callId != nil, botName: bot?.name ?? "", duration: ranFor(),
            display: session?.displayForSummary ?? [])
        tearDown()
        phase = .failed(failure)
        publish(ended: true)
        resolveAnswer(.failed(detail: failure.details))
        endedHere(callId)
    }

    private func finishLocally(_ ending: CallEnding) {
        guard isInCall else { return }
        let callId = session?.callId
        endedSummary = CallEndedSummary.make(
            ending: ending, botName: bot?.name ?? "", duration: ranFor(), display: session?.displayForSummary ?? [])
        // The bot hung up while the screen was hidden: bring the ending back, the owner would otherwise never learn why it went quiet.
        if endedSummary?.kind == .botEnded { isScreenShown = true }
        tearDown()
        phase = .over(ending)
        publish(ended: true)
        resolveAnswer(.failed(detail: "call over before it was taken: \(ending)"))
        endedHere(callId)
    }

    private func ranFor() -> TimeInterval { max(0, now().timeIntervalSince(startedAt)) }

    private func endedHere(_ callId: String?) {
        requiresSystemAudio = false
        systemAudioReady = false
        systemActivatedAt = nil
        onCallEnded?(callId)
    }

    private func tearDown() {
        watchdog?.cancel()
        watchdog = nil
        generation += 1
        for task in tasks { task.cancel() }
        tasks = []
        outbox?.finish()
        micInput?.finish()
        outbox = nil
        micInput = nil
        if audioRunning { audio.stop() }
        audioRunning = false
        stopLevelTicker()
        audio.stopPlayback()
        if let token = displacedToken { audioSession.removeDisplacedHandler(token) }
        displacedToken = nil
        audioSession.end(.call)
        let closing = link
        link = nil
        if let closing { Task { await closing.close() } }
        isPlaying = false
        userSpeaking = false
        hold = nil
        jitter.stop()
        clearPendingSpeech()
        gate.reset()
        restorePlaybackLevel()
        // The proximity sensor belongs to the call: left on after it, covering the camera would darken the home and the chat too.
        releaseOutput()
    }

    /// The owner tapped the sound circle: speaker and receiver swap. Nothing happens while a device is connected.
    public func toggleOutput() {
        guard isInCall else { return }
        outputState.toggle()
        refreshOutput()
    }

    /// Read what is connected and where the phone is, then ask the session for the output that follows. Safe to call at any time:
    /// the session is asked only when the answer changed.
    private func refreshOutput() {
        guard isInCall else { return }
        outputState.externalDevice = audio.hasExternalOutput
        if outputState.watchesProximity {
            proximity?.start()
        } else {
            proximity?.stop()
            outputState.nearEar = false
        }
        let wanted = outputState.requested
        if !outputAsked || wanted != lastRequestedOutput {
            outputAsked = true
            lastRequestedOutput = wanted
            audio.setOutput(wanted)
        }
        // The picture of the route is what the session says, not what was asked: the owner may also pick a device from the system list.
        outputState.routeKind = audio.currentOutput
        publish()
    }

    private func releaseOutput() {
        proximity?.stop()
        outputState = CallOutputState()
        outputAsked = false
        lastRequestedOutput = nil
    }

    private func resetRuntimeState() {
        releaseOutput()
        echoCancellation = true
        micBatches = 0
        diag = CallDiagnostics()
        uplink = UplinkCounters()
        isMuted = false
        hold = nil
        userSpeaking = false
        isPlaying = false
        note = nil
        session = nil
        endedSummary = nil
        jitter = ReplyJitterBuffer()
        gate = UtteranceGate()
    }

    private func outboxSend(_ message: CallOutbound) { outbox?.yield(.message(message)) }

    // MARK: Live Activity

    /// Arm or disarm the limit of "Thinking": armed while the session waits for a reply, disarmed (and forgotten) when it does not.
    private func watchThinking() {
        guard session?.awaitingReply == true else {
            thinkingExpiry?.cancel()
            thinkingExpiry = nil
            thinkingGaveUp = false
            return
        }
        guard thinkingExpiry == nil, !thinkingGaveUp else { return }
        thinkingExpiry = Task { [weak self, time] in
            try? await time.sleep(for: CallPresentation.thinkingLimit)
            guard !Task.isCancelled, let self, self.session?.awaitingReply == true else { return }
            self.thinkingExpiry = nil
            self.thinkingGaveUp = true
            self.publish()
        }
    }

    private func publish(ended: Bool = false) {
        guard let bot else { return }
        watchThinking()
        let snapshot = CallActivitySnapshot(
            callId: session?.callId, botKey: bot.botKey, botName: bot.name, engine: session?.engine ?? .free, stateLine: stateLine,
            startedAt: startedAt, isMuted: isMuted, role: session?.role, ownerName: session?.ownerName,
            caption: session?.captions.botLine ?? session?.captions.userLine, waitingRequests: waitingRequests,
            outputOn: outputState.routeIsFilled, canChooseOutput: outputState.offersChoice)
        if ended { activity.callEnded(snapshot) } else { activity.callChanged(snapshot) }
    }
}
