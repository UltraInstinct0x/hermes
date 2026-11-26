#if os(iOS)
import HermesAvatarUI
import HermesBox
import SwiftUI

extension View {
    /// A call from a Bot, over the whole app (Hermes Neo, `App/Calls`):
    /// - the call screen (`NeoCallScreen`, Hermes Bot's) as a full-screen cover while it is open;
    /// - minimised (the chevron, the Chats button, or a swipe down), the app's own navigation comes back with the
    ///   call bar (`NeoCallBar`) pinned at the top, and the call and its audio keep running. Tapping the bar opens
    ///   the call again. This is upstream Talk's pattern (`TalkPresentation` presents `TalkScreen` while
    ///   `TalkCenter.isExpanded`; minimised, `CallPill` sits in the chat's top safe-area inset), made app-wide so
    ///   the bar shows over chats, Bots and Settings alike.
    /// It also hands `NeoBox` the app's gateways, whose login pairs this phone with the box.
    func neoCallCover(model: AppModel) -> some View {
        modifier(NeoCallCover(model: model))
    }
}

private struct NeoCallCover: ViewModifier {
    let model: AppModel
    @State private var box = NeoBox.shared
    #if DEBUG
    /// `-NEO_CALL_DEMO …`: a scripted call in place of the box's (`NeoCallDemo`).
    @State private var demo: CallController?
    #endif

    private var calls: CallController {
        #if DEBUG
        if let demo { return demo }
        #endif
        return box.calls
    }

    func body(content: Content) -> some View {
        let calls = self.calls
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if calls.isInCall, !calls.isScreenShown {
                    NeoCallBar(calls: calls) { calls.isScreenShown = true }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.25), value: calls.isInCall && !calls.isScreenShown)
            .fullScreenCover(isPresented: Binding(get: { calls.isScreenShown }, set: { shown in if !shown { calls.closeScreen() } })) {
                NeoCallScreen(calls: calls, waiting: box.waitingConversation(botKey: calls.bot?.botKey))
            }
            .task {
                box.attach(model)
                #if DEBUG
                if NeoCallDemo.mode != nil, demo == nil { demo = await NeoCallDemo.make() }
                #endif
            }
    }
}

/// The call minimised: who, how long, mute and end, and a tap to go back to the call. Upstream's `CallPill`
/// (`App/Views/Talk/CallViews.swift`) with the bot's avatar.
struct NeoCallBar: View {
    let calls: CallController
    let open: () -> Void

    var body: some View {
        let name = calls.bot?.name ?? "your bot"
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(spacing: 10) {
                    NeoCallAvatar(botKey: calls.bot?.botKey, state: NeoCallOrbHost.state(calls), size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Call with \(name)")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.primaryText)
                            .lineLimit(1)
                        HStack(spacing: 0) {
                            if let started = calls.callStartedAt {
                                Text(timerInterval: started...Date.distantFuture, countsDown: false).monospacedDigit()
                                Text(" · ")
                            }
                            Text(calls.stateLine).lineLimit(1)
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
            .accessibilityLabel("Call with \(name), \(calls.stateLine)")
            .accessibilityHint("Opens the call")
            Button { calls.toggleMute() } label: {
                Image(systemName: calls.isMuted ? "mic.slash.fill" : "mic")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(calls.isMuted ? Theme.inkForeground : Theme.primaryText)
                    .frame(width: 36, height: 36)
                    .background(calls.isMuted ? Theme.ink : Theme.controlFill, in: Circle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(calls.isMuted ? "Unmute" : "Mute")
            Button { calls.end() } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Theme.danger, in: Circle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("End call")
        }
        .padding(.leading, 10)
        .padding(.trailing, 11)
        .frame(height: 56)
        .glassEffect(.regular, in: .capsule)
    }
}
#endif
