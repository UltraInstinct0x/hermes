import Foundation

/// What the bot-state orb at the top of the call screen shows. Pure: derived from the same flags as
/// `CallPresentation.stateLine`, so the orb and the spoken sentence never disagree.
public enum CallOrbState: Sendable, Equatable, CaseIterable {
    /// Nothing is happening yet (the screen is open, no call).
    case neutral
    /// The call is set up and the bot waits for the person.
    case listening
    /// The bot is talking.
    case speaking
    /// The bot is thinking or a delegated task runs.
    case processing
    /// The line is being set up or re-set up.
    case connecting
    /// Standby: the bot listens for a wake word only. A calm flat ring that breathes very slowly; it carries no level data.
    case standby
    /// The microphone is muted: the person is not heard.
    case muted
    /// On hold, ended or failed: the call is not live from the phone's side.
    case paused

    public init(
        phase: CallController.Phase, session: CallSession?, muted: Bool, hold: CallHold?, userSpeaking: Bool, playing: Bool,
        thinkingGaveUp: Bool = false
    ) {
        switch phase {
        case .idle: self = .neutral
        case .over, .failed: self = .paused
        case .running:
            self = Self.running(
                session: session, muted: muted, hold: hold, userSpeaking: userSpeaking, playing: playing, thinkingGaveUp: thinkingGaveUp)
        }
    }

    private static func running(
        session: CallSession?, muted: Bool, hold: CallHold?, userSpeaking: Bool, playing: Bool, thinkingGaveUp: Bool
    ) -> CallOrbState {
        guard let session else { return .connecting }
        if session.ending != nil { return .paused }
        if session.link != .up { return .connecting }
        if session.callId == nil || session.hubState == .starting { return .connecting }
        if session.hubState == .handover || session.role == .listener || hold != nil { return .paused }
        // The bot is heard whatever the microphone does, so speech shows even while muted.
        if playing || !session.openReplies.isEmpty { return .speaking }
        if muted { return .muted }
        if session.standingBy { return .standby }
        if userSpeaking { return .listening }
        if session.awaitingReply, !thinkingGaveUp { return .processing }
        return session.role == .owner ? .listening : .connecting
    }

    /// The plain sentence read aloud for the orb (the text line is gone from the screen).
    public var sentence: String {
        switch self {
        case .neutral: "Ready"
        case .listening: "Listening"
        case .speaking: "The bot is speaking"
        case .processing: "Thinking"
        case .connecting: "Connecting"
        case .standby: CallPresentation.standbySentence
        case .muted: "Muted"
        case .paused: "On hold"
        }
    }

    /// Orb states change their look with a cross-fade this long (seconds).
    public static let crossFade: Double = 0.5
    /// One slow breath of the standby ring (seconds).
    public static let standbyBreath: Double = 6
    /// One turn of the dots of `processing` (seconds). The reference's 10 s is too slow for the eye.
    public static let processingTurn: Double = 3
    /// Speaking bars: bar `i` shows the playback level `i * barDelay` seconds ago.
    public static let barDelay: Double = 0.06
}

/// The two views of the call's content area and when the screen switches between them on its own.
public enum CallContentPane: String, Sendable, Equatable, CaseIterable, Identifiable {
    case transcript = "Transcript"
    case screen = "Screen"

    public var id: String { rawValue }

    public static let emptyScreenSentence = "The bot has not put anything on the screen."

    /// A new display item shows the screen; an emptied screen goes back to the transcript; otherwise the person's choice stays.
    public static func following(current: CallContentPane, oldCount: Int, newCount: Int) -> CallContentPane {
        if newCount > oldCount { return .screen }
        if newCount == 0, oldCount > 0 { return .transcript }
        return current
    }
}

/// Auto-follow of the transcript: stay at the bottom unless the person scrolled up.
public enum CallTranscriptFollow {
    /// `distanceFromBottom` in points; a little slack so a finger rest does not unpin it.
    public static func isAtBottom(distanceFromBottom: Double, slack: Double = 24) -> Bool { distanceFromBottom <= slack }
}
