import Foundation

// Hermes Neo: the pure halves of the call screen (App/Calls/NeoCallScreen.swift). The views draw these and hold no logic.

/// One line of the call's transcript as the screen draws it: who said it, and whether it is still being said.
public struct CallTranscriptLine: Sendable, Equatable, Identifiable {
    public var id: String
    public var isPerson: Bool
    /// "You", or the bot's name.
    public var speaker: String
    public var text: String
    /// The person's words while they are still talking (partial speech): drawn lighter, never stored.
    public var isLive: Bool

    public init(id: String, isPerson: Bool, speaker: String, text: String, isLive: Bool = false) {
        self.id = id
        self.isPerson = isPerson
        self.speaker = speaker
        self.text = text
        self.isLive = isLive
    }

    public static let personName = "You"

    /// The call's lines, oldest first, the live line of the person last. Empty rows are left out.
    public static func lines(_ captions: CallCaptions, botName: String) -> [CallTranscriptLine] {
        let bot = botName.isEmpty ? "Bot" : botName
        var result = captions.rows.filter { !$0.text.isEmpty }.map {
            CallTranscriptLine(id: $0.rowId, isPerson: $0.speaker == .person, speaker: $0.speaker == .person ? personName : bot, text: $0.text)
        }
        if let partial = captions.partialPerson {
            result.append(CallTranscriptLine(id: "partial", isPerson: true, speaker: personName, text: partial, isLive: true))
        }
        return result
    }
}

/// What the bot's avatar (the bloub, `HermesAvatarUI.BloubStatus` by raw value) plays for each state of the call indicator.
public enum CallAvatarLook: String, Sendable, Equatable, CaseIterable {
    case idle, working, waiting, error, speaking, sleeping

    public init(_ state: CallOrbState) {
        switch state {
        case .neutral, .muted: self = .idle
        // Eyes open, turned to the person: it hears them.
        case .listening: self = .waiting
        case .speaking: self = .speaking
        case .processing, .connecting: self = .working
        case .standby, .paused: self = .sleeping
        }
    }

    /// The level the ring around the avatar follows: the microphone while it listens, the speaker while it talks.
    public enum Meter: Sendable, Equatable { case none, microphone, speaker }

    public static func meter(_ state: CallOrbState) -> Meter {
        switch state {
        case .listening: .microphone
        case .speaking: .speaker
        case .neutral, .muted, .processing, .connecting, .standby, .paused: .none
        }
    }
}
