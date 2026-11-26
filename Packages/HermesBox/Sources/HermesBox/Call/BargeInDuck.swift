import Foundation

/// The first half of a barge-in: when the person starts to talk over the bot, the bot gets quieter at once (the desktop's
/// duck, `DUCK_LEVEL` 0.12, `DUCK_MAX_MS` 4000). Playback only stops if the sustained-voice gate then confirms it is
/// a person; a short noise or an echo gives the full level back and never reaches the hub. Pure: time comes in as a
/// parameter (the controller's `TimeSource`), so tests drive it by hand.
public struct BargeInDuck: Sendable, Equatable {
    public struct Config: Sendable, Equatable {
        /// Playback level while the voice is unconfirmed.
        public var duckLevel: Float = 0.12
        /// A duck never lasts longer than this, whatever the microphone says.
        public var safety: Duration = .milliseconds(4000)
        /// The voice must be gone this long before the level returns (one quiet frame inside a word must not flap it).
        public var release: Duration = .milliseconds(200)
        public init() {}
    }

    public enum Action: Sendable, Equatable {
        /// Lower playback to `Config.duckLevel`.
        case duck
        /// The voice went away (noise) or the safety fired: full level again, no barge-in.
        case restore
    }

    public let config: Config
    public private(set) var isDucked = false
    private var duckedAt = Duration.zero
    private var lastVoice = Duration.zero
    /// After the safety fired, the same voice must not duck again; it has to stop first.
    private var latched = false

    public init(config: Config = Config()) { self.config = config }

    /// `voice`: the gate has seen the first onset (before its stop gate). `confirmed`: the stop gate fired this step.
    public mutating func update(voice: Bool, confirmed: Bool, now: Duration) -> Action? {
        if confirmed {
            // The caller stops playback; the level is restored by `reset`, after the stop, so nothing blips.
            latched = false
            return nil
        }
        if !voice { latched = false }
        guard isDucked else {
            guard voice, !latched else { return nil }
            isDucked = true
            duckedAt = now
            lastVoice = now
            return .duck
        }
        if voice { lastVoice = now }
        if now - duckedAt >= config.safety {
            latched = voice
            isDucked = false
            return .restore
        }
        if !voice, now - lastVoice >= config.release {
            isDucked = false
            return .restore
        }
        return nil
    }

    /// A new reply, a stop or the end of the call: back to idle. True when the level has to be restored.
    @discardableResult
    public mutating func reset() -> Bool {
        let was = isDucked
        isDucked = false
        latched = false
        return was
    }
}
