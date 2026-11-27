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

    private var calls: CallController {
        #if DEBUG
        if let demo { return demo }
        #endif
        return box.calls
    }

    func body(content: Content) -> some View {
        let calls = self.calls
        content
            .fullScreenCover(isPresented: Binding(
                // While it is the app's Talk call, Talk's expanded flag decides (the pill opens it, minimise hides it).
                get: { TalkCenter.shared.external != nil ? TalkCenter.shared.isExpanded && calls.hasScreen : calls.isScreenShown },
                set: { shown in
                    guard !shown else { return }
                    calls.closeScreen()
                    if TalkCenter.shared.external != nil { TalkCenter.shared.isExpanded = false }
                }
            )) {
                NeoCallScreen(calls: calls, waiting: box.waitingConversation(botKey: calls.bot?.botKey))
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
