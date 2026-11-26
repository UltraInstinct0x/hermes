import Foundation

/// The words, the countdown and the buttons of the Live Activities, as pure functions of a content state.
/// The widget views draw what this says and decide nothing. No em-dashes anywhere (product rule).
public struct RequestActivityPresentation: Equatable, Sendable {
    public typealias State = RequestActivityAttributes.ContentState

    /// A button on the lock screen or in the expanded island.
    public enum Action: Equatable, Sendable {
        case approve
        case deny
        /// Answer a question with one of its choices (`index` into `state.choices`).
        case choice(index: Int, label: String)
        /// Free text, many choices or a multi-select: only the app can answer. A link, not a button.
        case openToAnswer
    }

    /// The most the phone shows of a command or a question (the accepted notification wording, S18 D16).
    public static let detailLimit = 120
    public static let maxChoiceButtons = 3

    public let state: State

    public init(_ state: State) { self.state = state }

    // MARK: words

    public var title: String {
        if let outcome = state.outcome { return Self.finalLine(outcome, answeredBy: state.answeredBy) }
        switch state.style {
        case .approval: return "\(state.botName) needs your approval"
        case .question: return "\(state.botName) has a question"
        case .computerOnly: return "\(state.botName) needs you at the computer"
        case .secret: return "\(state.botName) needs a secret"
        case .connection: return "\(state.botName) wants to connect"
        }
    }

    /// The command or question, or the fixed sentence for a prompt that is never shown. Empty once finished.
    public var body: String {
        guard state.outcome == nil else { return "" }
        switch state.style {
        case .computerOnly: return "Answer on the computer."
        case .secret, .connection: return Self.secureBody
        case .approval:
            let text = Self.clip(state.detail, Self.detailLimit)
            guard let tool = state.toolName, !tool.isEmpty else { return text }
            return "\(tool): \(text)"
        case .question: return Self.clip(state.detail, Self.detailLimit)
        }
    }

    /// "N waiting" when more than one request waits, else nil.
    public var waitingTitle: String? {
        state.moreWaiting > 0 && state.outcome == nil ? "\(state.moreWaiting + 1) waiting" : nil
    }

    /// "2 more waiting" under the head request.
    public var moreLine: String? {
        state.moreWaiting > 0 && state.outcome == nil ? "\(state.moreWaiting) more waiting" : nil
    }

    public static func finalLine(_ outcome: State.Outcome, answeredBy: String?) -> String {
        switch outcome {
        case .allowedOnce: "Allowed once"
        case .allowedForSession: "Allowed for the session"
        case .allowedAlways: "Always allowed"
        case .denied: "Denied"
        case .answered: "Answered"
        case .answeredElsewhere: "Answered on \(answeredBy.flatMap { $0.isEmpty ? nil : $0 } ?? "another device")"
        case .expired: "Expired"
        case .noLongerWaiting: "No longer waiting"
        }
    }

    /// The SF Symbol of a finished request (allowed, denied, expired), where the symbol carries the result. Nil
    /// while the request waits: the bubble then shows the app's mark, and the title says what kind of request it is.
    public var outcomeSymbol: String? {
        guard let outcome = state.outcome else { return nil }
        switch outcome {
        case .allowedOnce, .allowedForSession, .allowedAlways, .answered, .answeredElsewhere: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .expired, .noLongerWaiting: return "clock.badge.xmark"
        }
    }

    // MARK: countdown

    /// What the countdown area shows. `timer` is drawn with `Text(timerInterval:countsDown: true)`.
    public enum Countdown: Equatable, Sendable {
        case timer(ClosedRange<Date>)
        /// No deadline is known: the word "Waiting", no number.
        case waiting
        /// The request is finished: nothing to count.
        case none
    }

    public var countdown: Countdown {
        if state.outcome != nil { return .none }
        guard let deadline = state.deadline else { return .waiting }
        // A ClosedRange needs lower <= upper; a request first seen after its own deadline gets a zero range.
        return .timer(min(state.since, deadline)...deadline)
    }

    public static let waitingWord = "Waiting"

    /// Whole seconds left at `now`, never negative. Nil when no deadline is known.
    public func remainingSeconds(now: Date) -> Int? {
        guard let deadline = state.deadline else { return nil }
        return max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
    }

    /// "1:30", "0:07": minutes and two-digit seconds, the format of `Text(timerInterval:)`.
    public static func clock(seconds: Int) -> String {
        let clamped = max(0, seconds)
        return "\(clamped / 60):" + String(format: "%02d", clamped % 60)
    }

    public static func spoken(seconds: Int) -> String {
        let clamped = max(0, seconds)
        let minutes = clamped / 60
        let rest = clamped % 60
        var parts: [String] = []
        if minutes > 0 { parts.append("\(minutes) \(minutes == 1 ? "minute" : "minutes")") }
        if rest > 0 || minutes == 0 { parts.append("\(rest) \(rest == 1 ? "second" : "seconds")") }
        return parts.joined(separator: " ")
    }

    // MARK: buttons

    public var actions: [Action] {
        guard state.outcome == nil else { return [] }
        switch state.style {
        case .computerOnly:
            return []
        case .secret, .connection:
            // Never an inline answer: typing a secret needs the app. The link only opens it.
            return [.openToAnswer]
        case .approval:
            return [.approve, .deny]
        case .question:
            guard state.questionId != nil, !state.choices.isEmpty else { return [.openToAnswer] }
            var out: [Action] = state.choices.prefix(Self.maxChoiceButtons).enumerated().map { .choice(index: $0.offset, label: $0.element) }
            if state.needsApp || state.choices.count > Self.maxChoiceButtons { out.append(.openToAnswer) }
            return out
        }
    }

    public static let secureBody = "Open Hermes Bot to answer. It is typed in the app."
    public static let approveTitle = "Approve once"
    public static let denyTitle = "Deny"
    public static let openToAnswerTitle = "Open to answer"

    public func title(for action: Action) -> String {
        switch action {
        case .approve: Self.approveTitle
        case .deny: Self.denyTitle
        case .choice(_, let label): label
        case .openToAnswer: Self.openToAnswerTitle
        }
    }

    public func accessibilityLabel(for action: Action) -> String {
        switch action {
        case .approve: "Approve once. Lets \(state.botName) run this command one time."
        case .deny: "Deny. \(state.botName) will not run this command."
        case .choice(_, let label): "Answer \(label)"
        case .openToAnswer: "Open Hermes Bot to answer"
        }
    }

    // MARK: accessibility

    /// One sentence for VoiceOver on the whole activity: who, what, how long is left.
    public func accessibilityLabel(now: Date) -> String {
        if state.outcome != nil { return "\(state.botName). \(title)" }
        var parts = [title]
        let text = body
        if !text.isEmpty { parts.append(text) }
        if let seconds = remainingSeconds(now: now) {
            parts.append("\(Self.spoken(seconds: seconds)) left")
        } else {
            parts.append(Self.waitingWord)
        }
        if let more = moreLine { parts.append(more) }
        return parts.joined(separator: ". ")
    }

    // MARK: text

    /// Collapse whitespace and cut on a word boundary with ONE ASCII ellipsis.
    public static func clip(_ text: String, _ limit: Int) -> String {
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard clean.count > limit else { return clean }
        let cut = String(clean.prefix(limit))
        let head = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? cut
        return head.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.")) + "..."
    }
}

/// The words of the call activity.
public struct CallActivityPresentation: Equatable, Sendable {
    public typealias State = CallActivityAttributes.ContentState

    public let attributes: CallActivityAttributes
    public let state: State

    public init(attributes: CallActivityAttributes, state: State) {
        self.attributes = attributes
        self.state = state
    }

    public var title: String { attributes.botName }

    /// "Listening", "Muted"... or "Call ended". A call that runs on another device says where.
    public var subtitle: String {
        if state.ended { return "Call ended" }
        if let owner = state.ownerName, !owner.isEmpty { return "\(state.stateLine) (on \(owner))" }
        return state.stateLine
    }

    public var waitingLine: String? {
        guard !state.ended, state.waitingRequests > 0 else { return nil }
        return state.waitingRequests == 1 ? "1 request waiting" : "\(state.waitingRequests) requests waiting"
    }

    public var muteTitle: String { state.isMuted ? "Unmute" : "Mute" }
    public var muteAccessibilityLabel: String { state.isMuted ? "Unmute the microphone" : "Mute the microphone" }
    public static let endTitle = "End"
    public static let endedWord = "Ended"
    public static let endAccessibilityLabel = "End the call"

    /// Buttons: none after the call, End always, Mute only on the phone that is talking.
    public var showsControls: Bool { !state.ended }
    public var showsMute: Bool { showsControls && state.canMute }
    /// The one circle for the sound, drawn as the AirPlay symbol and filled while the speaker or a device has the sound. A lock
    /// screen cannot show the system route list: with the phone alone the circle swaps speaker and receiver, with a device
    /// connected it opens the call screen, where the list is.
    public var showsOutput: Bool { showsControls && state.canMute }
    public static let outputSymbol = "airplayaudio"
    public var outputAccessibilityLabel: String {
        state.canChooseOutput
            ? (state.outputOn ? "Sound on the speaker. Switch to the receiver" : "Sound on the receiver. Switch to the speaker")
            : "Sound on a connected device. Open the call to choose another"
    }

    public func accessibilityLabel(now: Date) -> String {
        if state.ended { return "Call with \(attributes.botName) ended" }
        let elapsed = max(0, Int(now.timeIntervalSince(state.startedAt)))
        return "Call with \(attributes.botName). \(subtitle). \(RequestActivityPresentation.spoken(seconds: elapsed)) so far"
    }

    /// The compact island shows a short word, not a sentence.
    public var shortState: String {
        if state.ended { return Self.endedWord }
        return state.isMuted ? "Muted" : state.stateLine
    }
}
