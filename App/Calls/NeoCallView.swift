#if os(iOS)
import HermesAvatarUI
import HermesBox
import SwiftUI

extension View {
    /// A call from a Bot, over the whole app (Hermes Neo, `App/Calls`):
    /// - the call screen (`NeoCallScreen`) as a full-screen cover while it is open;
    /// - minimised (the chevron, or a swipe down), the app's own navigation comes back with the call
    ///   bar (`NeoCallBar`) pinned at the top, and the call and its audio keep running. Tapping the
    ///   bar opens the call again. This is upstream Talk's pattern (`TalkPresenter` presents
    ///   `TalkScreen` while `TalkCenter.isExpanded`; minimised, `CallPill` sits in the chat's top
    ///   safe-area inset), made app-wide so the bar shows over chats, Bots and Settings alike.
    /// It also hands `NeoBox` the app's gateways, whose login pairs this phone with the box.
    func neoCallCover(model: AppModel) -> some View {
        modifier(NeoCallCover(model: model))
    }
}

private struct NeoCallCover: ViewModifier {
    let model: AppModel
    @State private var box = NeoBox.shared
    #if DEBUG
    /// `-NEO_CALL_DEMO running|ended|bar` (screenshots): one presentation, so it goes through this one cover.
    @State private var demo = UserDefaults.standard.string(forKey: "NEO_CALL_DEMO")
    private var demoScreen: Bool { demo == "running" || demo == "ended" }
    #else
    private let demoScreen = false
    #endif

    func body(content: Content) -> some View {
        let calls = box.calls
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if calls.isInCall, !calls.isScreenShown {
                    NeoCallBar(state: NeoCallScreenState(calls: calls), levels: calls, actions: NeoCallScreenActions(calls: calls)) {
                        calls.isScreenShown = true
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                } else {
                    #if DEBUG
                    if demo == "bar" { NeoCallDemo.bar.padding(.horizontal, 10).padding(.bottom, 6) }
                    #endif
                }
            }
            .animation(.snappy(duration: 0.25), value: calls.isInCall && !calls.isScreenShown)
            .fullScreenCover(isPresented: Binding(get: { calls.isScreenShown || demoScreen }, set: { shown in
                if !shown {
                    calls.closeScreen()
                    #if DEBUG
                    demo = nil
                    #endif
                }
            })) {
                #if DEBUG
                if demoScreen {
                    NeoCallDemo.screen(ended: demo == "ended")
                } else {
                    NeoCallScreen(state: NeoCallScreenState(calls: calls), actions: NeoCallScreenActions(calls: calls), levels: calls)
                }
                #else
                NeoCallScreen(state: NeoCallScreenState(calls: calls), actions: NeoCallScreenActions(calls: calls), levels: calls)
                #endif
            }
            .task { box.attach(model) }
    }
}

/// The call minimised: who, how long, mute and end, and a tap to go back to the call. Upstream's
/// `CallPill` (`App/Views/Talk/CallViews.swift`) with the bot's avatar.
struct NeoCallBar: View {
    let state: NeoCallScreenState
    let levels: any NeoCallLevels
    let actions: NeoCallScreenActions
    let open: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(spacing: 10) {
                    NeoCallAvatar(botKey: state.botKey, state: state.orb, levels: levels, size: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Call with \(state.botName)")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.primaryText)
                            .lineLimit(1)
                        HStack(spacing: 0) {
                            if let started = state.startedAt {
                                Text(timerInterval: started...Date.distantFuture, countsDown: false).monospacedDigit()
                                Text(" · ")
                            }
                            Text(state.stateLine).lineLimit(1)
                        }
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Call with \(state.botName), \(state.stateLine)")
            .accessibilityHint("Opens the call")
            Button(action: actions.toggleMute) {
                Image(systemName: state.isMuted ? "mic.slash.fill" : "mic")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(state.isMuted ? Theme.inkForeground : Theme.primaryText)
                    .frame(width: 36, height: 36)
                    .background(state.isMuted ? Theme.ink : Theme.controlFill, in: Circle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(state.isMuted ? "Unmute" : "Mute")
            Button(action: actions.end) {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Theme.danger, in: Circle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("End call")
        }
        .padding(.leading, 8)
        .padding(.trailing, 11)
        .frame(minHeight: 56)
        .glassEffect(.regular, in: .capsule)
    }
}

#if DEBUG
/// `-NEO_CALL_DEMO running|ended|bar`: the call screen (or the bar) on made-up content, for
/// screenshots in the simulator. No call, no audio.
private enum NeoCallDemo {
    static let levels = NeoDemoLevels()

    static var bar: some View {
        NeoCallBar(state: state(.running), levels: levels, actions: NeoCallScreenActions()) {}
    }

    static func screen(ended: Bool) -> some View {
        NeoCallScreen(state: state(ended ? .ended(summary) : .running), actions: NeoCallScreenActions(), levels: levels)
    }

    private static let summary = CallEndedSummary(
        kind: .ownerEnded, botName: "Hermes Bot", durationText: "4 minutes",
        displayTitles: ["Flight SXS 123", "Today's weather in Antalya", "Your calendar this afternoon"])

    static func state(_ stage: NeoCallScreenState.Stage) -> NeoCallScreenState {
        let turns: [(Bool, String)] = [
            (true, "Good morning. What's on today?"),
            (false, "Morning! You have two meetings: a stand-up at ten and the Salesforce review at two."),
            (true, "Move the review to four if Ayşe is free."),
            (false, "Ayşe is free at four. I moved the review and told the attendees."),
            (true, "And what's the weather like in Antalya?"),
            (false, "Sunny, 24 degrees, a light breeze from the sea. I put the forecast on your screen."),
            (true, "Is my flight still on time?"),
            (false, "SXS 123 is on time, boarding at 18:40 from gate 207. The details are on your screen too."),
        ]
        let lines = turns.enumerated().map { index, turn in
            CallTranscriptLine(id: "r\(index)", isPerson: turn.0, speaker: turn.0 ? "You" : "Hermes Bot", text: turn.1)
        } + [CallTranscriptLine(id: "partial", isPerson: true, speaker: "You", text: "Great, and remind me to", isLive: true)]
        let display = [
            CallDisplayItem(
                id: "d3", kind: .markdown, title: "Flight SXS 123",
                body: "**On time.** Boarding 18:40, gate 207.\nAntalya (AYT) → Frankfurt (FRA), 19:20 → 21:35."),
            CallDisplayItem(
                id: "d2", kind: .markdown, title: "Today's weather in Antalya",
                body: "Sunny, **24 °C**. Wind 12 km/h from the south-west. Sea 22 °C."),
            CallDisplayItem(
                id: "d1", kind: .markdown, title: "Your calendar this afternoon",
                body: "- 10:00 Stand-up\n- ~~14:00~~ **16:00** Salesforce review (moved)\n- 18:40 Boarding SXS 123"),
        ]
        return NeoCallScreenState(
            stage: stage, botName: "Hermes Bot", botKey: "oracle::hermesbot", startedAt: Date().addingTimeInterval(-252), orb: .speaking,
            stateLine: "Hermes Bot is speaking", lines: lines, display: display)
    }
}

/// A bot talking loudly, for the demo.
@MainActor
private final class NeoDemoLevels: NeoCallLevels {
    var micLevel: Double { 0 }
    var playbackLevel: Double { 0.7 }
}
#endif
#endif
