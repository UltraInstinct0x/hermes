import Foundation

/// An approval or a question waiting for the owner, as a Live Activity. ONE request activity exists at a
/// time: it shows the most urgent request and says how many more wait (iOS allows only a few activities per
/// app, and the call needs one of them).
public struct RequestActivityAttributes: Codable, Hashable, Sendable {
    /// Constant for the activity's life. The head request changes inside `ContentState`.
    public var title: String

    public init(title: String = "Waiting for you") { self.title = title }

    public struct ContentState: Codable, Hashable, Sendable {
        public enum Style: String, Codable, Hashable, Sendable {
            /// A command the bot wants to run: Approve once and Deny.
            case approval
            /// A question: choices answer it, free text needs the app.
            case question
            /// A sudo or secret prompt: no buttons, no text, answered on the computer.
            case computerOnly
            /// A secret prompt: neutral words, one "Open to answer" link. Typing it needs the app, never the lock screen.
            case secret
            /// A connection form: neutral words, one "Open to answer" link.
            case connection
        }

        /// How a finished request is worded in the short final state.
        public enum Outcome: String, Codable, Hashable, Sendable {
            case allowedOnce, allowedForSession, allowedAlways, denied
            /// A question answered from this phone.
            case answered
            /// Answered on another device (`answeredBy` names it when the ledger did).
            case answeredElsewhere
            case expired
            case noLongerWaiting
        }

        public var botKey: String
        public var requestId: String
        public var sessionId: String?
        public var executionGeneration: Int?
        public var command: String?
        public var approvalKind: String?
        public var botName: String
        public var style: Style
        /// The command (approval) or the question, already clipped. Never set for `computerOnly`.
        public var detail: String
        public var toolName: String?
        /// The gateway's own deadline (`expires_at` of the ledger row). Nil means unknown: the activity says
        /// "Waiting" and shows no countdown. Never guessed.
        public var deadline: Date?
        /// When the request began to wait (the ledger's `created_at`), or when the phone first saw it.
        public var since: Date
        /// Up to three choices of a single-select question, shown as buttons.
        public var choices: [String]
        /// The question has more choices than fit, or needs typing: "Open to answer" is offered too.
        public var needsApp: Bool
        public var questionId: String?
        /// Other requests that wait besides this one.
        public var moreWaiting: Int
        public var outcome: Outcome?
        public var answeredBy: String?
        public var answeredChoice: String?

        public init(
            botKey: String, requestId: String, botName: String, style: Style, detail: String = "", toolName: String? = nil,
            deadline: Date? = nil, since: Date, choices: [String] = [], needsApp: Bool = false, questionId: String? = nil,
            moreWaiting: Int = 0, outcome: Outcome? = nil, answeredBy: String? = nil,
            sessionId: String? = nil, executionGeneration: Int? = nil, command: String? = nil, approvalKind: String? = nil,
            answeredChoice: String? = nil
        ) {
            self.botKey = botKey
            self.requestId = requestId
            self.sessionId = sessionId
            self.executionGeneration = executionGeneration
            self.command = command
            self.approvalKind = approvalKind
            self.botName = botName
            self.style = style
            self.detail = detail
            self.toolName = toolName
            self.deadline = deadline
            self.since = since
            self.choices = choices
            self.needsApp = needsApp
            self.questionId = questionId
            self.moreWaiting = moreWaiting
            self.outcome = outcome
            self.answeredBy = answeredBy
            self.answeredChoice = answeredChoice
        }
    }
}
