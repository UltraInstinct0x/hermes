#if os(iOS)
import AppIntents
import Foundation

/// WidgetKit draws the buttons in the extension, but runs the intents in the app process.
@MainActor
protocol NeoActivityButtonHandling: AnyObject {
    func answerApproval(botKey: String, requestId: String, shown: String, allow: Bool) async -> Bool
    func answerChoice(botKey: String, requestId: String, questionId: String, choice: String, shown: String) async -> Bool
}

@MainActor
enum NeoActivityButtonRouter {
    static weak var handler: (any NeoActivityButtonHandling)?
}

// MARK: approvals

struct NeoApproveRequestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Approve once"
    static let description = IntentDescription("Lets the bot run the waiting command one time.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Bot") var botKey: String
    @Parameter(title: "Request") var requestId: String
    @Parameter(title: "Shown") var shown: String

    init() {}
    init(botKey: String, requestId: String, shown: String) {
        self.botKey = botKey
        self.requestId = requestId
        self.shown = shown
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = await NeoActivityButtonRouter.handler?.answerApproval(botKey: botKey, requestId: requestId, shown: shown, allow: true)
        return .result()
    }
}

struct NeoDenyRequestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Deny"
    static let description = IntentDescription("Tells the bot not to run the waiting command.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Bot") var botKey: String
    @Parameter(title: "Request") var requestId: String
    @Parameter(title: "Shown") var shown: String

    init() {}
    init(botKey: String, requestId: String, shown: String) {
        self.botKey = botKey
        self.requestId = requestId
        self.shown = shown
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = await NeoActivityButtonRouter.handler?.answerApproval(botKey: botKey, requestId: requestId, shown: shown, allow: false)
        return .result()
    }
}

// MARK: questions

/// Answer a question with one of its choices. Free text cannot be typed on the lock screen: that case is a
/// link into the app, not an intent.
struct NeoAnswerChoiceIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Answer a question"
    static let description = IntentDescription("Answers the waiting question with one of its choices.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Bot") var botKey: String
    @Parameter(title: "Request") var requestId: String
    @Parameter(title: "Shown") var shown: String
    @Parameter(title: "Question") var questionId: String
    @Parameter(title: "Choice") var choice: String

    init() {}
    init(botKey: String, requestId: String, questionId: String, choice: String, shown: String) {
        self.botKey = botKey
        self.requestId = requestId
        self.shown = shown
        self.questionId = questionId
        self.choice = choice
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = await NeoActivityButtonRouter.handler?.answerChoice(botKey: botKey, requestId: requestId, questionId: questionId, choice: choice, shown: shown)
        return .result()
    }
}
#endif
