#if os(iOS)
import HermesBox
import SwiftUI

extension View {
    /// A call from a Bot, over the whole app (Hermes Neo, `App/Calls`): the call screen (`NeoCallScreen`, Hermes
    /// Bot's) as a full-screen cover while it is expanded. The call is one of the app's Talk calls
    /// (`NeoTalkCall` in `TalkCenter`), so minimised it is upstream's own call pill at the top of the chat
    /// (`ChatScreen`), and `TalkCenter.isExpanded` is what shows the screen again.
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
    @State private var demoTalk: NeoTalkCall?
    #endif

    private var talk: NeoTalkCall? {
        #if DEBUG
        if let demoTalk { return demoTalk }
        #endif
        return box.talk
    }

    private var calls: CallController {
        #if DEBUG
        if let demo { return demo }
        #endif
        return box.calls
    }

    func body(content: Content) -> some View {
        let calls = self.calls
        let center = TalkCenter.shared
        content
            // The box call minimised shows on every screen (home, chats, other sections): upstream's own pill, at the
            // top with the padding a chat gives it, from here only (a chat draws its own pill for Talk calls alone).
            .safeAreaInset(edge: .top, spacing: 0) {
                if let call = center.external, !center.isExpanded {
                    CallPill(session: call)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.25), value: center.external == nil || center.isExpanded)
            .fullScreenCover(isPresented: Binding(
                // While it is the app's Talk call, Talk's expanded flag decides (the pill opens it, minimise hides it).
                get: { TalkCenter.shared.external != nil ? TalkCenter.shared.isExpanded && calls.hasScreen : calls.isScreenShown },
                set: { shown in
                    guard !shown else { return }
                    calls.closeScreen()
                    if TalkCenter.shared.external != nil { TalkCenter.shared.isExpanded = false }
                }
            )) {
                NeoCallScreen(calls: calls, talk: talk, waiting: box.waitingConversation(botKey: calls.bot?.botKey))
            }
            .task {
                box.attach(model)
                #if DEBUG
                if NeoCallDemo.mode != nil, demo == nil {
                    let demo = await NeoCallDemo.make()
                    let talk = NeoTalkCall(calls: demo, box: box)
                    talk.start()
                    self.demo = demo
                    demoTalk = talk
                }
                #endif
            }
    }
}

extension CallController {
    /// The call has a screen: running, or over with its ending to show.
    var hasScreen: Bool {
        switch phase {
        case .idle: false
        case .running, .over, .failed: true
        }
    }
}
#endif
