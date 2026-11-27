#if os(iOS)
import HermesAvatarUI
import HermesBox
import SwiftUI

/// The bot's indicator on the call screen, in Hermes Bot's orb's place and size (`CallOrbHost`, 88 pt): the bot's
/// own animated avatar (the bloub) playing the call's state, and nothing around it. The avatar takes no sound level,
/// so its states are its own looks: listening is its attentive look, thinking its working one, speaking its talking
/// one (`CallAvatarLook`). It is ONE accessibility element whose label is the state sentence, as the orb was.
struct NeoCallAvatar: View {
    let botKey: String?
    let state: CallOrbState
    var size: CGFloat = 88

    var body: some View {
        BloubView(
            profile: bloubProfile(fromKey: botKey ?? RosterMapping.canonicalProfileKey),
            status: BloubStatus(rawValue: CallAvatarLook(state).rawValue) ?? .idle, size: size)
            .frame(width: size, height: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.sentence)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The avatar with the call's real state, in a view of its own (Hermes Bot's `CallOrbHost`).
struct NeoCallOrbHost: View {
    let calls: CallController

    var body: some View {
        NeoCallAvatar(botKey: calls.bot?.botKey, state: Self.state(calls))
    }

    static func state(_ calls: CallController) -> CallOrbState {
        CallOrbState(
            phase: calls.phase, session: calls.session, muted: calls.isMuted, hold: calls.hold, userSpeaking: calls.userSpeaking,
            playing: calls.isPlaying, thinkingGaveUp: calls.thinkingGaveUp)
    }
}
#endif
