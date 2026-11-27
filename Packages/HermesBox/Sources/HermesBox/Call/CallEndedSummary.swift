import Foundation

/// What the end-of-call screen says, for EVERY way a call can end (the owner pressed End, the bot ended it, the call was
/// handed to another device, the link was lost, it could not start). Pure: built once when the call is over, from the
/// reason, the time it ran and what the bot put on the screen. No em-dashes in any sentence.
public struct CallEndedSummary: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case ownerEnded
        case botEnded
        case handedOver
        case connectionLost
        case couldNotStart
        case other
    }

    public static let maxTitles = 5

    public let kind: Kind
    public let botName: String
    /// The big line: "You ended the call".
    public let title: String
    /// "4 minutes", or nil when the call never really started or lasted no time at all.
    public let durationText: String?
    /// A calm second sentence from a failure ("Could not reach the call service ..."), or nil.
    public let detail: String?
    /// The raw cause, shown only behind Copy details.
    public let copyableDetails: String?
    /// Titles of what the bot showed during the call, newest first, at most `maxTitles`.
    public let displayTitles: [String]
    /// False when starting again cannot work (calls are off on that machine).
    public let canCallAgain: Bool

    public init(
        kind: Kind, botName: String, durationText: String? = nil, detail: String? = nil, copyableDetails: String? = nil,
        displayTitles: [String] = [], canCallAgain: Bool = true
    ) {
        self.kind = kind
        self.botName = botName
        self.title = Self.title(kind, botName: botName)
        self.durationText = durationText
        self.detail = detail
        self.copyableDetails = copyableDetails
        self.displayTitles = displayTitles
        self.canCallAgain = canCallAgain
    }

    /// The summary of a call that ended with a reason (the hub's, or the phone's own).
    public static func make(
        ending: CallEnding, botName: String, duration: TimeInterval, display: [CallDisplayItem]
    ) -> CallEndedSummary {
        CallEndedSummary(
            kind: kind(for: ending), botName: botName, durationText: durationWords(duration),
            displayTitles: titles(display))
    }

    /// The summary of a call that failed. `started` is true when the hub had already given the call an id.
    public static func make(
        failure: CallFailure, started: Bool, botName: String, duration: TimeInterval, display: [CallDisplayItem]
    ) -> CallEndedSummary {
        CallEndedSummary(
            kind: started ? .connectionLost : .couldNotStart, botName: botName,
            durationText: started ? durationWords(duration) : nil, detail: failure.sentence,
            copyableDetails: failure.details, displayTitles: titles(display), canCallAgain: failure.canRetry)
    }

    /// Any reason maps to a kind; a reason a newer hub invents is `.other`, never a crash.
    public static func kind(for ending: CallEnding) -> Kind {
        switch ending {
        case .byClient: .ownerEnded
        case .gatewayLost, .hubRestart: .connectionLost
        case .idleTimeout, .maxDuration: .other
        case .other(let reason):
            switch reason {
            case "ended_by_bot": .botEnded
            case "answered_elsewhere", "taken_over", "take_over", "handed_over": .handedOver
            case "ended_by_client": .ownerEnded
            default: .other
            }
        }
    }

    static func title(_ kind: Kind, botName: String) -> String {
        let name = botName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .ownerEnded: return "You ended the call"
        case .botEnded: return name.isEmpty ? "Your bot ended the call" : "\(name) ended the call"
        case .handedOver: return "The call was handed to another device"
        case .connectionLost: return "The connection was lost"
        case .couldNotStart: return "The call could not start"
        case .other: return "The call ended"
        }
    }

    /// "4 minutes", "1 minute", "Less than a minute", "1 hour 5 minutes". Nil for nothing at all.
    public static func durationWords(_ seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds >= 1 else { return nil }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "Less than a minute" }
        let hours = minutes / 60
        let rest = minutes % 60
        func unit(_ count: Int, _ word: String) -> String { count == 1 ? "1 \(word)" : "\(count) \(word)s" }
        if hours == 0 { return unit(minutes, "minute") }
        return rest == 0 ? unit(hours, "hour") : "\(unit(hours, "hour")) \(unit(rest, "minute"))"
    }

    /// The titles of the last `maxTitles` items, as the call screen names them (an empty title becomes "Note", "Link" or "Picture").
    public static func titles(_ items: [CallDisplayItem]) -> [String] {
        items.prefix(maxTitles).map(CallDisplayPresentation.title)
    }

    /// The whole thing in one sentence for VoiceOver.
    public var spokenLabel: String {
        [title, durationText].compactMap { $0 }.joined(separator: ". ")
    }
}
