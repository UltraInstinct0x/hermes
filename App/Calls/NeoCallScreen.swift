#if os(iOS)
import AVKit
import HermesBox
import SwiftUI

/// The call: the bot's indicator, transcript or screen, mute, route, End. Hermes Bot's `CallScreen`
/// (`ios/HermesBot/CallViews.swift`), ported as it was: the same layout, sizes, fonts and colours (`NeoCallTheme`).
/// Neo's changes: the indicator is the bot's own avatar (`NeoCallOrbHost`), the transcript page shows the call as
/// the app's chat or as large captions (`NeoCallTranscript`, View), the buttons are upstream Talk's row (Mute, Audio,
/// Type, View, End), minimising leaves upstream's call pill in the chat, and a request the calling bot waits on is
/// answered here with upstream's own card.
/// Views hold no logic: every action is one call into `CallController`, every sentence comes from `CallPresentation`.
struct NeoCallScreen: View {
    let calls: CallController
    /// The call as the app's Talk call: what upstream's own captions (`TalkTexts`) read.
    var talk: NeoTalkCall?
    /// The calling bot's chat, when the app has it: its waiting approval or question shows on the call screen.
    var waiting: ConversationModel?

    @State private var pane: CallContentPane = .transcript
    /// View: the transcript page as the app's chat (`chat`) or as large captions (`captions`). Kept on this phone.
    @AppStorage("neo.call.transcriptStyle") private var transcriptStyle = NeoCallTranscript.Style.chat.rawValue
    /// Type: a field above the buttons whose words are a turn of the call.
    @State private var isTyping = false
    @State private var typed = ""
    @FocusState private var typingFocused: Bool
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
                minimize()
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

    /// Back to the app while the call goes on: its pill at the top of the chat brings it back (`TalkCenter`).
    private func minimize() {
        calls.closeScreen()
        if TalkCenter.shared.external != nil { TalkCenter.shared.isExpanded = false }
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
            Group {
                if isCaptions, let talk {
                    // Upstream Talk's own captions: the sentence spoken now, heard words settled, the rest lighter.
                    TalkTexts(session: talk, large: true, centered: true)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onAppear { talk.showsCaptions = true }
                } else {
                    NeoCallTranscript(lines: CallTranscriptLine.lines(session.captions, botName: calls.bot?.name ?? "Bot"), style: .chat)
                        // The oldest line in view fades out under the indicator instead of being cut there.
                        .mask {
                            VStack(spacing: 0) {
                                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 24)
                                Color.black
                            }
                        }
                }
            }
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

    /// The call's buttons as upstream Talk draws them (`CallControls`: `CallButton`s on one glass bar, every one
    /// labelled): Mute, Audio, Type, View, End. Type writes a turn of the call; View switches the transcript page
    /// between the app's chat and large captions.
    @ViewBuilder
    private var controls: some View {
        if calls.isInCall {
            VStack(spacing: 10) {
                if isTyping { typeField }
                HStack(spacing: 6) {
                    CallButton(
                        symbol: calls.isMuted ? "mic.slash.fill" : "mic.fill", label: calls.isMuted ? "Muted" : "Mute", isOn: calls.isMuted
                    ) { calls.toggleMute() }
                    .accessibilityLabel(calls.isMuted ? "Unmute" : "Mute")
                    routeButton
                    CallButton(symbol: "keyboard", label: "Type", isOn: isTyping) {
                        isTyping.toggle()
                        typingFocused = isTyping
                    }
                    .accessibilityHint("Type a turn of the call. The bot answers it aloud")
                    CallButton(symbol: isCaptions ? "captions.bubble.fill" : "bubble.left.and.text.bubble.right", label: "View") {
                        transcriptStyle = (isCaptions ? NeoCallTranscript.Style.chat : .captions).rawValue
                        pane = .transcript
                    }
                    .accessibilityValue(isCaptions ? Text("Captions") : Text("Chat"))
                    .accessibilityHint("Shows the call as the chat or as large captions")
                    CallButton(symbol: "phone.down.fill", label: "End", tint: Theme.danger) { calls.end() }
                        .accessibilityLabel("End call")
                }
                .padding(.top, 12)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: 36))
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private var isCaptions: Bool { transcriptStyle == NeoCallTranscript.Style.captions.rawValue }

    /// A typed turn of the call (`call.say_text`).
    private var typeField: some View {
        HStack(spacing: 8) {
            TextField("Type into the call", text: $typed, axis: .vertical)
                .lineLimit(1...4)
                .focused($typingFocused)
                .submitLabel(.send)
                .onSubmit(sendTyped)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.composer))
            Button(action: sendTyped) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.inkForeground)
                    .frame(width: 36, height: 36)
                    .background(Theme.ink, in: Circle())
            }
            .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send to the call")
        }
    }

    private func sendTyped() {
        calls.say(typed)
        typed = ""
    }

    /// The system's list of sound devices (iPhone, speaker, AirPlay, Bluetooth, headphones), drawn as a `CallButton`.
    private var routeButton: some View {
        let filled = calls.outputState.routeIsFilled
        return VStack(spacing: 6) {
            ZStack {
                Circle().fill(filled ? Theme.ink : Theme.controlFill)
                NeoRoutePicker(active: filled)
            }
            .frame(width: 56, height: 56)
            Text("Audio")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
        .frame(width: 64)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio route")
        .accessibilityValue(CallOutputPresentation.routeValue(calls.outputState))
        .accessibilityHint("Chooses the iPhone, the speaker, AirPlay, Bluetooth or headphones")
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
