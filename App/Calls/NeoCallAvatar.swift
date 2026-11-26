#if os(iOS)
import HermesAvatarUI
import HermesBox
import SwiftUI

/// The bot's indicator on the call screen, in Hermes Bot's orb's place and size (88 pt): the bot's
/// own animated avatar (the bloub) playing the call's state, inside a ring that follows the live
/// sound. While the person talks the ring follows the microphone; while the bot talks the avatar
/// and its halo follow what the speaker renders (`CallController.micLevel` / `playbackLevel`, a
/// fast attack and a slower release, `LevelMeter`), so loud and quiet are seen, not a canned loop.
/// Each state has its own look: listening is a green ring, speaking a blue halo that swells,
/// thinking an orange arc that turns, muted a still grey ring with a slashed microphone.
struct NeoCallAvatar: View {
    let botKey: String?
    let state: CallOrbState
    let levels: any NeoCallLevels
    var size: CGFloat = 88

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var profile: String { bloubProfile(fromKey: botKey ?? RosterMapping.canonicalProfileKey) }
    private var look: BloubStatus { BloubStatus(rawValue: CallAvatarLook(state).rawValue) ?? .idle }

    var body: some View {
        let level = currentLevel
        ZStack {
            halo(level)
            ring(level)
            BloubView(profile: profile, status: look, size: size * 0.66)
                .scaleEffect(reduceMotion ? 1 : 1 + bodySwing * level)
            if state == .muted { mutedBadge }
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : .easeInOut(duration: CallOrbState.crossFade), value: state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.sentence)
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// The level the look follows now: the microphone while it listens, the speaker while it talks.
    private var currentLevel: Double {
        switch CallAvatarLook.meter(state) {
        case .microphone: levels.micLevel
        case .speaker: levels.playbackLevel
        case .none: 0
        }
    }

    private var tint: Color {
        switch state {
        case .listening: Theme.success
        case .speaking: Theme.info
        case .processing, .connecting: Theme.warning
        case .muted, .paused, .standby, .neutral: Theme.secondaryText
        }
    }

    /// How much the avatar itself swells with the sound.
    private var bodySwing: Double { state == .speaking ? 0.14 : state == .listening ? 0.06 : 0 }

    @ViewBuilder
    private func halo(_ level: Double) -> some View {
        // A soft disc behind the avatar: grows and brightens with the sound (up to the full 88 pt).
        let base = size * 0.78
        Circle()
            .fill(tint.opacity(state == .speaking || state == .listening ? 0.14 + 0.36 * level : 0.08))
            .frame(width: base, height: base)
            .scaleEffect(reduceMotion ? 1 : 1 + 0.27 * level)
    }

    @ViewBuilder
    private func ring(_ level: Double) -> some View {
        let diameter = size * 0.8
        switch state {
        case .listening, .speaking:
            Circle()
                .stroke(tint.opacity(0.55 + 0.45 * level), lineWidth: 2 + 3 * level)
                .frame(width: diameter, height: diameter)
                .scaleEffect(reduceMotion ? 1 : 1 + 0.2 * level)
        case .processing, .connecting:
            TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { timeline in
                let turn = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: CallOrbState.processingTurn / 2) / (CallOrbState.processingTurn / 2)
                Circle()
                    .trim(from: 0, to: state == .connecting ? 0.2 : 0.32)
                    .stroke(tint, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .frame(width: diameter, height: diameter)
                    .rotationEffect(.degrees(turn * 360))
            }
        case .muted:
            Circle()
                .stroke(Theme.secondaryText.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
                .frame(width: diameter, height: diameter)
        case .paused, .standby, .neutral:
            Circle()
                .stroke(Theme.secondaryText.opacity(0.35), lineWidth: 1.5)
                .frame(width: diameter, height: diameter)
        }
    }

    private var mutedBadge: some View {
        Image(systemName: "mic.slash.fill")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Theme.inkForeground)
            .frame(width: 26, height: 26)
            .background(Theme.ink, in: Circle())
            .offset(x: size * 0.32, y: size * 0.32)
    }
}
#endif
