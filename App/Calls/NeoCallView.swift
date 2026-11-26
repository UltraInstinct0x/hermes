#if os(iOS)
import HermesBox
import SwiftUI
import UIKit

/// The in-app screen of a call from a Bot: who, what the call is doing, Mute and End. CallKit's own
/// screen carries the call on the Lock Screen; this one shows when the app is opened during it (the
/// call pill), so the owner can always hang up here too. Deliberately small: Hermes Bot's full call
/// screen (orb, captions, cards) isn't ported.
struct NeoCallView: View {
    let calls: CallController

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "phone.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(calls.bot?.name ?? "Your bot")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text(line)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.updatesFrequently)
            if case .failed(let failure) = calls.phase {
                Button("Copy Details") { UIPasteboard.general.string = failure.details }
                    .font(.footnote)
            }
            Spacer()
            if calls.isInCall {
                HStack(spacing: 48) {
                    roundButton(calls.isMuted ? "Unmute" : "Mute", symbol: calls.isMuted ? "mic.slash.fill" : "mic.fill", tint: .gray) {
                        calls.toggleMute()
                    }
                    roundButton("End", symbol: "phone.down.fill", tint: .red) { calls.end() }
                }
            } else {
                Button("Close") { calls.clear() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }

    private var line: String {
        switch calls.phase {
        case .idle: "Connecting"
        case .running: calls.stateLine
        case .over: "The call ended."
        case .failed(let failure): failure.sentence
        }
    }

    private func roundButton(_ title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.title)
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(tint))
                Text(title).font(.footnote)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

extension View {
    /// Shows a call from a Bot over the app while it runs (Hermes Neo, `App/Calls`).
    func neoCallCover() -> some View {
        modifier(NeoCallCover())
    }
}

private struct NeoCallCover: ViewModifier {
    @State private var box = NeoBox.shared

    func body(content: Content) -> some View {
        let calls = box.calls
        content.fullScreenCover(isPresented: Binding(get: { calls.isScreenShown }, set: { shown in if !shown { calls.closeScreen() } })) {
            NeoCallView(calls: calls)
        }
    }
}
#endif
