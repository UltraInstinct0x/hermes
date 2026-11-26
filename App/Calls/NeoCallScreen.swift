#if os(iOS)
import AVKit
import HermesBox
import SwiftUI

/// What the call screen draws, read from `CallController` (or a fake, in Debug, for screenshots).
/// The views hold no logic: every word comes from `CallPresentation` and the HermesBox models.
struct NeoCallScreenState {
    enum Stage {
        /// Before the call is up, or asking for the microphone.
        case starting(String?)
        case running
        case ended(CallEndedSummary)
        case failed(CallFailure)
    }

    var stage: Stage
    var botName: String
    var botKey: String?
    var startedAt: Date?
    var orb: CallOrbState
    var stateLine: String
    var lines: [CallTranscriptLine]
    var display: [CallDisplayItem]
    var isMuted: Bool
    var isInCall: Bool
    var routeFilled: Bool
    var routeValue: String
    var holdSentence: String?
    var notice: String?
    /// Another device has the call: the sentence, and whether it can be taken over here.
    var elsewhere: (sentence: String, canTakeOver: Bool, liveNote: String?)?

    init(calls: CallController) {
        let name = calls.bot?.name ?? ""
        botName = name.isEmpty ? "Your bot" : name
        botKey = calls.bot?.botKey
        startedAt = calls.callStartedAt
        orb = CallOrbState(
            phase: calls.phase, session: calls.session, muted: calls.isMuted, hold: calls.hold, userSpeaking: calls.userSpeaking,
            playing: calls.isPlaying, thinkingGaveUp: calls.thinkingGaveUp)
        stateLine = calls.stateLine
        lines = calls.session.map { CallTranscriptLine.lines($0.captions, botName: name) } ?? []
        display = calls.displayItems
        isMuted = calls.isMuted
        isInCall = calls.isInCall
        routeFilled = calls.outputState.routeIsFilled
        routeValue = CallOutputPresentation.routeValue(calls.outputState)
        holdSentence = calls.hold.map(CallPresentation.holdSentence)
        notice = calls.session?.notice
        if let session = calls.session, session.isListenerOnly {
            elsewhere = (
                session.isElsewhere ? CallPresentation.elsewhereSentence(ownerName: session.ownerName) : CallPresentation.ownerlessSentence,
                session.canTakeOver, session.engine == .live ? CallPresentation.liveTakeoverSentence : nil)
        }
        switch calls.phase {
        case .idle: stage = .starting(calls.isAskingMicrophone ? CallPresentation.microphoneExplanation : nil)
        case .running: stage = calls.session == nil ? .starting(nil) : .running
        case .over(let ending):
            stage = .ended(calls.endedSummary ?? CallEndedSummary(kind: .other, botName: name, detail: ending.sentence))
        case .failed(let failure): stage = calls.endedSummary.map(Stage.ended) ?? .failed(failure)
        }
    }

    #if DEBUG
    init(
        stage: Stage, botName: String, botKey: String?, startedAt: Date?, orb: CallOrbState, stateLine: String,
        lines: [CallTranscriptLine], display: [CallDisplayItem], isMuted: Bool = false
    ) {
        self.stage = stage
        self.botName = botName
        self.botKey = botKey
        self.startedAt = startedAt
        self.orb = orb
        self.stateLine = stateLine
        self.lines = lines
        self.display = display
        self.isMuted = isMuted
        if case .running = stage { isInCall = true } else { isInCall = false }
        routeFilled = false
        routeValue = "iPhone"
    }
    #endif
}

/// Everything the person can do on the call screen, each one call into `CallController`.
struct NeoCallScreenActions {
    var minimize: () -> Void = {}
    var toggleMute: () -> Void = {}
    var end: () -> Void = {}
    var resume: () -> Void = {}
    var takeOver: () -> Void = {}
    var leave: () -> Void = {}
    var clearDisplay: () -> Void = {}
    var callAgain: () -> Void = {}
    var retry: () -> Void = {}
    var done: () -> Void = {}

    init() {}

    init(calls: CallController) {
        minimize = { calls.closeScreen() }
        toggleMute = { calls.toggleMute() }
        end = { calls.end() }
        resume = { calls.resume() }
        takeOver = { calls.takeOver() }
        leave = { calls.leave() }
        clearDisplay = { calls.clearDisplay() }
        callAgain = { Task { await calls.callAgain() } }
        retry = { Task { await calls.retry() } }
        done = { calls.clear() }
    }
}

/// The live levels the avatar follows (30 times a second), read in the avatar's own view so only it
/// redraws. `CallController` is the real one.
@MainActor
protocol NeoCallLevels: AnyObject {
    var micLevel: Double { get }
    var playbackLevel: Double { get }
}

extension CallController: NeoCallLevels {}

/// The call screen, built on Hermes Bot's (`CallViews.swift`): the bot's indicator at the top in the
/// old orb's place and size (now its animated avatar), the conversation in large captions (Talk's
/// style, `TalkTexts`), what the bot shows in its own scrollable pane, and Mute, the route picker and
/// End. The chevron minimises the call to the call bar (`NeoCallBar`) while it keeps running.
struct NeoCallScreen: View {
    let state: NeoCallScreenState
    let actions: NeoCallScreenActions
    let levels: any NeoCallLevels

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            topBar
            switch state.stage {
            case .ended(let summary):
                NeoCallEndedView(summary: summary, botKey: state.botKey, onCallAgain: actions.callAgain, onDone: actions.done)
                    .transition(.opacity)
            case .failed(let failure):
                indicator
                failed(failure)
            case .starting(let explanation):
                indicator
                starting(explanation)
            case .running:
                indicator
                running
            }
            controls
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: isEnded)
        .background(Theme.canvas)
        .interactiveDismissDisabled(!state.isInCall)
    }

    private var isEnded: Bool {
        if case .ended = state.stage { true } else { false }
    }

    // MARK: pieces

    private var topBar: some View {
        HStack {
            Button(action: state.isInCall ? actions.minimize : actions.done) {
                Image(systemName: "chevron.down")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(state.isInCall ? "Minimize the call" : "Close")
            .accessibilityHint(state.isInCall ? "The call keeps going. Return to it from the call bar" : "Closes the call screen")
            Spacer()
            if let started = state.startedAt, state.isInCall {
                Text(timerInterval: started...Date.distantFuture, countsDown: false)
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 12)
                    .accessibilityLabel("Call length")
            }
        }
        .padding(.horizontal, 8)
        .foregroundStyle(Theme.primaryText)
    }

    /// The old orb's place and size (88 pt, under the top bar), then who and what, small.
    private var indicator: some View {
        VStack(spacing: 6) {
            NeoCallAvatar(botKey: state.botKey, state: state.orb, levels: levels)
            Text(state.botName)
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
            Text(state.stateLine)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .accessibilityAddTraits(.updatesFrequently)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }

    private var running: some View {
        VStack(spacing: 10) {
            if let elsewhere = state.elsewhere { elsewhereCard(elsewhere) }
            if let hold = state.holdSentence { holdCard(hold) }
            if let notice = state.notice {
                Text(notice).font(.footnote).foregroundStyle(Theme.secondaryText)
            }
            // The transcript's own region, below the status line: older lines fade out at its top edge,
            // inside the region, and nothing is drawn outside it.
            NeoCallTranscript(lines: state.lines)
                .frame(maxHeight: .infinity)
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 28)
                        Color.black
                    }
                }
                .clipShape(Rectangle())
                .padding(.top, 8)
            if !state.display.isEmpty {
                NeoBotPane(items: state.display, onClear: actions.clearDisplay)
                    .containerRelativeFrame(.vertical) { height, _ in height * 0.34 }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: state.display.isEmpty)
    }

    private func starting(_ explanation: String?) -> some View {
        VStack {
            if let explanation {
                Text(explanation).font(.subheadline).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failed(_ failure: CallFailure) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                Text(failure.sentence).font(.body).foregroundStyle(Theme.primaryText).multilineTextAlignment(.center)
                HStack {
                    if failure.canRetry { Button("Retry", action: actions.retry).buttonStyle(.borderedProminent) }
                    Button("Done", action: actions.done).buttonStyle(.bordered)
                }
                if !failure.details.isEmpty {
                    Button("Copy details") { UIPasteboard.general.string = failure.details }.font(.footnote)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
    }

    private func elsewhereCard(_ elsewhere: (sentence: String, canTakeOver: Bool, liveNote: String?)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(elsewhere.sentence).font(.headline).foregroundStyle(Theme.primaryText)
            if elsewhere.canTakeOver {
                Button(CallPresentation.takeOverTitle, action: actions.takeOver)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: 56)
            } else if let note = elsewhere.liveNote {
                Text(note).font(.footnote).foregroundStyle(Theme.secondaryText)
            }
            Button("Leave the call", action: actions.leave)
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .accessibilityHint("You leave, the call goes on where it is")
        }
        .neoCard()
    }

    private func holdCard(_ sentence: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(sentence).font(.subheadline).foregroundStyle(Theme.primaryText)
            Button("Resume", action: actions.resume)
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
        }
        .neoCard()
    }

    // MARK: controls

    @ViewBuilder
    private var controls: some View {
        if state.isInCall {
            HStack(spacing: 24) {
                roundButton(
                    title: CallPresentation.muteTitle(muted: state.isMuted), image: state.isMuted ? "mic.slash.fill" : "mic.fill",
                    filled: state.isMuted, action: actions.toggleMute)
                routeButton
                roundButton(title: "End call", image: "phone.down.fill", filled: true, tint: Theme.danger, action: actions.end)
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(Theme.canvas)
        }
    }

    /// The system's list of sound devices: filled while the speaker or a connected device has the sound.
    private var routeButton: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(state.routeFilled ? Theme.ink : Theme.controlFill)
                NeoRoutePicker(active: state.routeFilled)
            }
            .frame(width: 56, height: 56)
            Text("Audio").font(.caption).foregroundStyle(Theme.secondaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio route")
        .accessibilityValue(state.routeValue)
        .accessibilityHint("Chooses the iPhone, the speaker, AirPlay, Bluetooth or headphones")
    }

    private func roundButton(
        title: String, image: String, filled: Bool, tint: Color = Theme.ink, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: image)
                    .font(.title3)
                    .frame(width: 56, height: 56)
                    .background(filled ? tint : Theme.controlFill, in: Circle())
                    .foregroundStyle(filled ? (tint == Theme.danger ? .white : Theme.inkForeground) : Theme.primaryText)
                Text(title).font(.caption).foregroundStyle(Theme.secondaryText)
            }
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

extension View {
    func neoCard() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// The system's route picker (AirPlay, Bluetooth, headphones, speaker, phone). Its circle is drawn
/// behind it, filled while a device other than the phone has the sound.
struct NeoRoutePicker: UIViewRepresentable {
    var active = false

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.tintColor = active ? .systemBackground : .label
        view.activeTintColor = active ? .systemBackground : .label
    }
}
#endif
