#if os(iOS)
import AVKit
import HermesBox
import SwiftUI

/// The call: the bot's indicator, transcript or screen, mute, route, End. Hermes Bot's `CallScreen`
/// (`ios/HermesBot/CallViews.swift`), ported as it was: the same layout, sizes, fonts and colours (`NeoCallTheme`).
/// Neo's changes: the indicator is the bot's own avatar (`NeoCallOrbHost`), the transcript page uses upstream Talk's
/// transcript flow in a larger size (`NeoCallTranscript`), a Chats button in the bottom row minimises the call to the
/// app (the call bar), and a request the calling bot waits on is answered here with upstream's own card.
/// Views hold no logic: every action is one call into `CallController`, every sentence comes from `CallPresentation`.
struct NeoCallScreen: View {
    let calls: CallController
    /// The calling bot's chat, when the app has it: its waiting approval or question shows on the call screen.
    var waiting: ConversationModel?

    @State private var pane: CallContentPane = .transcript
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The shared ending, once the call is over (any cause) and its summary is built.
    private var endedSummary: CallEndedSummary? {
        switch calls.phase {
        case .over, .failed: calls.endedSummary
        case .idle, .running: nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if let summary = endedSummary {
                NeoCallEndedView(
                    summary: summary,
                    botKey: calls.bot?.botKey,
                    onCallAgain: { Task { await calls.callAgain() } },
                    onDone: { calls.clear() })
                    .transition(.opacity)
            } else {
                NeoCallOrbHost(calls: calls).padding(.vertical, 4)
                if calls.phase == .running, calls.session != nil {
                    running
                } else {
                    ScrollView {
                        content.padding(.horizontal, 16).padding(.vertical, 12)
                    }
                }
            }
            controls
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: endedSummary != nil)
        .background(NeoCallTheme.background)
        .interactiveDismissDisabled(!calls.isInCall)
    }

    // MARK: pieces

    private var topBar: some View {
        HStack {
            Button {
                calls.closeScreen()
            } label: {
                Image(systemName: "chevron.down").frame(width: NeoCallTheme.tapTarget, height: NeoCallTheme.tapTarget)
            }
            .accessibilityLabel("Hide the call")
            .accessibilityHint(calls.isInCall ? "The call keeps going" : "Closes the call screen")
            Spacer()
            if endedSummary == nil {
                enginePill
            }
        }
        .padding(.horizontal, 8)
        .foregroundStyle(NeoCallTheme.primaryText)
    }

    private var engineLabel: String {
        calls.session.map { CallPresentation.engineName($0.engine) } ?? CallPresentation.engineName(.free)
    }

    private var enginePill: some View {
        Text(engineLabel)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(minHeight: NeoCallTheme.tapTarget)
            .accessibilityLabel("Engine \(engineLabel)")
    }

    @ViewBuilder
    private var content: some View {
        switch calls.phase {
        case .idle:
            if calls.isAskingMicrophone {
                Text(CallPresentation.microphoneExplanation).font(.subheadline).foregroundStyle(NeoCallTheme.secondaryText)
            }
        case .failed(let failure):
            NeoFailureRow(failure: failure.calm) { Task { await calls.retry() } }
            if !failure.canRetry { doneButton }
        case .over(let ending):
            VStack(spacing: 12) {
                Text(ending.sentence).font(.subheadline).foregroundStyle(NeoCallTheme.primaryText)
                if !ending.isCalm {
                    Button("Retry") { Task { await calls.retry() } }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: NeoCallTheme.tapTarget)
                }
                doneButton
            }
            .frame(maxWidth: .infinity)
        case .running:
            EmptyView()
        }
    }

    private var doneButton: some View {
        Button("Done") { calls.clear() }
            .buttonStyle(.bordered)
            .frame(minHeight: NeoCallTheme.tapTarget)
    }

    @ViewBuilder
    private var running: some View {
        if let session = calls.session {
            VStack(spacing: 10) {
                // A listener is never silently mute: the takeover is the first thing on the screen, large.
                if session.isListenerOnly { elsewhere(session) }
                if let hold = calls.hold { holdCard(hold) }
                waitingCard
                if let notice = session.notice { Text(notice).font(.footnote).foregroundStyle(NeoCallTheme.secondaryText) }
                paneContent(session)
                paneDots
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .onChange(of: calls.displayItems.count) { old, new in
                withAnimation(.smooth(duration: 0.35)) {
                    pane = CallContentPane.following(current: pane, oldCount: old, newCount: new)
                }
            }
        }
    }

    /// Two panes side by side, swiped like pages. The slide is the pager's own.
    private func paneContent(_ session: CallSession) -> some View {
        TabView(selection: $pane) {
            NeoCallTranscript(lines: CallTranscriptLine.lines(session.captions, botName: calls.bot?.name ?? "Bot"))
                .tag(CallContentPane.transcript)
            NeoCallDisplayArea(items: calls.displayItems, onClear: { calls.clearDisplay() })
                .tag(CallContentPane.screen)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A tiny two-dot page indicator, not a control for touch. VoiceOver adjusts it (swipe up or down) to change the pane.
    private var paneDots: some View {
        HStack(spacing: 8) {
            ForEach(CallContentPane.allCases) { option in
                Circle()
                    .fill(pane == option ? NeoCallTheme.primaryText : NeoCallTheme.secondaryText.opacity(0.4))
                    .frame(width: 6, height: 6)
            }
        }
        .frame(height: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(pane == .transcript ? 1 : 2) of 2, \(pane.rawValue)")
        .accessibilityAdjustableAction { direction in
            withAnimation(.smooth(duration: 0.35)) { pane = direction == .increment ? .screen : .transcript }
        }
    }

    private func elsewhere(_ session: CallSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(session.isElsewhere ? CallPresentation.elsewhereSentence(ownerName: session.ownerName) : CallPresentation.ownerlessSentence)
                .font(.headline)
                .foregroundStyle(NeoCallTheme.primaryText)
            if session.canTakeOver {
                Button(CallPresentation.takeOverTitle) { calls.takeOver() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: 56)
            } else if session.engine == .live {
                Text(CallPresentation.liveTakeoverSentence).font(.footnote).foregroundStyle(NeoCallTheme.secondaryText)
            }
            Button("Leave the call") { calls.leave() }
                .buttonStyle(.bordered)
                .frame(minHeight: NeoCallTheme.tapTarget)
                .accessibilityHint("You leave, the call goes on where it is")
        }
        .oldCard()
    }

    private func holdCard(_ hold: CallHold) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(CallPresentation.holdSentence(hold)).font(.subheadline).foregroundStyle(NeoCallTheme.primaryText)
            Button("Resume") { calls.resume() }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: NeoCallTheme.tapTarget)
        }
        .oldCard()
    }

    /// What the calling bot waits on, where Hermes Bot had its waiting banner: upstream's own approval card, answered
    /// in place; for a question, upstream's waiting dock (its chips answer it, a tap on it minimises to the app).
    @ViewBuilder
    private var waitingCard: some View {
        #if DEBUG
        if NeoCallDemo.mode == "waiting" {
            ApprovalCard(approval: NeoCallDemo.approval, asker: calls.bot?.name ?? "Your bot", onChoice: { _ in })
        }
        #endif
        if let conversation = waiting {
            if let approval = conversation.pendingApproval {
                ApprovalCard(
                    approval: approval, asker: calls.bot?.name ?? "Your bot", waiting: conversation.waitingApprovals,
                    onChoice: { conversation.respond(to: approval, with: $0) }, onChoiceForAll: conversation.respondToAll)
                    .id(approval.id)
            } else if !conversation.waitingItems.isEmpty {
                NeedsYouDock(conversation: conversation) { calls.closeScreen() }
            }
        }
    }

    // MARK: controls

    @ViewBuilder
    private var controls: some View {
        if calls.isInCall {
            HStack(spacing: 24) {
                roundButton(
                    title: CallPresentation.muteTitle(muted: calls.isMuted), image: calls.isMuted ? "mic.slash.fill" : "mic.fill",
                    filled: calls.isMuted
                ) { calls.toggleMute() }
                routeButton
                // Neo: back to the app while the call goes on (the call bar brings it back).
                roundButton(title: "Chats", image: "bubble.left.and.bubble.right.fill", filled: false) { calls.closeScreen() }
                    .accessibilityLabel("Hide the call")
                    .accessibilityHint("Goes back to your chats and bots. The call keeps going")
                roundButton(title: "End call", image: "phone.down.fill", filled: true, tint: NeoCallTheme.problem) { calls.end() }
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(NeoCallTheme.background)
        }
    }

    /// The system's list of sound devices: filled while the speaker or a connected device has the sound, read from the
    /// route the session really has.
    private var routeButton: some View {
        let filled = calls.outputState.routeIsFilled
        return ZStack {
            Circle().fill(filled ? NeoCallTheme.primaryText : NeoCallTheme.botBubble)
            NeoRoutePicker(active: filled)
        }
        .frame(width: 56, height: 56)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio route")
        .accessibilityValue(CallOutputPresentation.routeValue(calls.outputState))
        .accessibilityHint("Chooses the iPhone, the speaker, AirPlay, Bluetooth or headphones")
    }

    private func roundButton(
        title: String, image: String, filled: Bool, tint: Color = NeoCallTheme.userBubble, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: image)
                    .font(.title3)
                    .frame(width: 56, height: 56)
                    .background(filled ? tint : NeoCallTheme.botBubble, in: Circle())
                    .foregroundStyle(filled ? NeoCallTheme.onUserBubble : NeoCallTheme.primaryText)
                Text(title).font(.caption).foregroundStyle(NeoCallTheme.secondaryText)
            }
            .frame(minWidth: NeoCallTheme.tapTarget, minHeight: NeoCallTheme.tapTarget)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private extension View {
    func oldCard() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NeoCallTheme.botBubble, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// The system's route picker (AirPlay, Bluetooth, headphones, speaker, phone). Its circle is drawn behind it, filled
/// while a device other than the phone has the sound, so the glyph is dark on a light disc then.
struct NeoRoutePicker: UIViewRepresentable {
    var active = false

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        // The disc is `label` coloured (white on dark, black on light), so the glyph takes the background colour on it.
        view.tintColor = active ? .systemBackground : .label
        view.activeTintColor = active ? .systemBackground : .label
    }
}
#endif
