import Foundation

/// Why the phone's side of a call is paused.
public enum CallHold: Sendable, Equatable {
    /// A phone call, Siri or an alarm took the audio. Resumes by itself only when the system says it may.
    case interrupted
    /// Another app or the system took the audio session.
    case audioTaken
    /// The sound device changed (earbuds put away, a speaker gone) and the call could not use the new route yet.
    case routeChanged
}

/// Words and small decisions of the call screen. Pure: the views draw what this says.
public enum CallPresentation {
    public static let disabledSentence = "Calls are not enabled on this machine."
    public static let liveUnavailableSentence = "GPT-Live needs a WebRTC stack on this phone, planned later."
    public static let autoNote = "Auto uses the free engine on this phone for now."
    public static let microphoneExplanation = "Hermes Bot needs your microphone to talk with your bot. Your speech goes to your own box and nowhere else."

    /// A device as a person names it. The pairing label when there is one, else its kind.
    public static func deviceName(kind: String, label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        switch kind {
        case "desktop": return "the desktop"
        case "ios": return "another iPhone"
        case "pwa": return "the phone web app"
        default: return "another device"
        }
    }

    // MARK: engines

    public struct EngineOption: Equatable, Identifiable, Sendable {
        public let choice: CallEngineChoice
        public let title: String
        public let detail: String
        public let isEnabled: Bool
        public var id: String { choice.id }
    }

    /// The picker rows. GPT-Live is shown, disabled, with the reason.
    public static func engineOptions() -> [EngineOption] {
        [
            EngineOption(choice: .auto, title: "Auto", detail: "GPT-Live, or Free when it is not available. Free for now.", isEnabled: true),
            EngineOption(choice: .free, title: "Free", detail: "This bot's own speech engines. No per-minute cost.", isEnabled: true),
            EngineOption(choice: .live, title: "Live", detail: liveUnavailableSentence, isEnabled: false),
        ]
    }

    public struct Resolution: Equatable, Sendable {
        public var engine: CallEngine?
        public var note: String?
        /// The calm sentence when no engine can be used.
        public var refusal: String?
    }

    /// The `auto` rule (S19 R36) on a phone whose GPT-Live path does not exist yet: `auto` and `free` run free, `live` refuses.
    public static func resolve(_ choice: CallEngineChoice, liveUsable: Bool = false) -> Resolution {
        switch choice {
        case .free: return Resolution(engine: .free)
        case .live:
            return liveUsable ? Resolution(engine: .live) : Resolution(refusal: liveUnavailableSentence)
        case .auto:
            return liveUsable ? Resolution(engine: .live) : Resolution(engine: .free, note: autoNote)
        }
    }

    public static func engineName(_ engine: CallEngine) -> String { engine == .free ? "Free" : "Live" }

    // MARK: lines

    /// The one-line state under the bot's name.
    /// The pauses before each try to rebuild the call audio after the route lost its device: at once, then 0.4 s, 1.2 s and 3 s.
    public static let routeRebuildPauses: [Duration] = [.zero, .milliseconds(400), .milliseconds(1200), .seconds(3)]

    /// How long "Thinking" may stay when the voice has not started to speak. A bot that chooses not to answer (a stray remark, a turn that
    /// ended in a tool) must not leave the call saying "Thinking" while it is in fact listening.
    public static let thinkingLimit: Duration = .seconds(25)

    public static func stateLine(
        session: CallSession?, muted: Bool, hold: CallHold?, userSpeaking: Bool, playing: Bool, thinkingGaveUp: Bool = false
    ) -> String {
        guard let session else { return "Connecting" }
        if session.ending != nil { return "Call ended" }
        switch session.link {
        case .connecting: return "Connecting"
        case .reconnecting: return "Reconnecting"
        case .up: break
        }
        if session.callId == nil || session.hubState == .starting { return "Starting the call" }
        if session.hubState == .handover { return "On hold" }
        if session.role == .listener { return session.isElsewhere ? "On hold here" : "Listening in" }
        if hold != nil { return "On hold" }
        if muted { return "Muted" }
        if playing || !session.openReplies.isEmpty { return "Speaking" }
        if session.standingBy { return standbySentence }
        if userSpeaking { return "Listening" }
        if session.awaitingReply, !thinkingGaveUp { return "Thinking" }
        return session.role == .owner ? "Listening" : "Connecting"
    }

    public static func elsewhereSentence(ownerName: String?) -> String {
        "This call is on \(ownerName ?? "another device")."
    }

    /// What a call in standby says (the orb's accessibility label and the state line).
    public static let standbySentence = "Standing by. Say \"Hermes\" to continue."

    public static let ownerlessSentence = "Nobody is driving this call."

    public static let takeOverTitle = "Take it over here"

    /// Why the takeover button is off for a Live call.
    public static let liveTakeoverSentence = "This call uses GPT-Live. It can only be taken over on a device that runs GPT-Live."

    public static func waitingBanner(count: Int) -> String? {
        switch count {
        case ..<1: nil
        case 1: "1 request is waiting for you."
        default: "\(count) requests are waiting for you."
        }
    }

    public static func holdSentence(_ hold: CallHold) -> String {
        switch hold {
        case .interrupted: "The call is on hold while another call or app uses the audio."
        case .audioTaken: "Another app took the audio. The call is on hold."
        case .routeChanged: "The sound device changed and the call could not use the new one yet. Tap Resume to try again."
        }
    }

    public static func muteTitle(muted: Bool) -> String { muted ? "Unmute" : "Mute" }
}
