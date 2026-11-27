#if os(iOS)
import AppIntents
import HermesActivityKit

@MainActor
protocol NeoActivityButtonHandling: AnyObject {
    func answerActivity(reference: RequestReference, shown: String, action: RequestActivityPresentation.Action) async -> Bool
    func openActivityRequest(_ reference: RequestReference, foregrounded: Bool) async
}

@MainActor
enum NeoActivityButtonRouter {
    static weak var handler: (any NeoActivityButtonHandling)?
}

struct NeoAnswerRequestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Answer a request"
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "Bot") var botKey: String
    @Parameter(title: "Request") var requestId: String
    @Parameter(title: "Session") var sessionId: String
    @Parameter(title: "Generation") var executionGeneration: Int
    @Parameter(title: "Shown") var shown: String
    @Parameter(title: "Index") var index: Int
    @Parameter(title: "Choice") var choice: String

    init() {}

    init(reference: RequestReference, shown: String, action: RequestActivityPresentation.Action) {
        botKey = reference.botKey
        requestId = reference.requestId
        sessionId = reference.sessionId
        executionGeneration = reference.executionGeneration ?? -1
        self.shown = shown
        switch action {
        case .approve: index = -1; choice = ""
        case .deny: index = -2; choice = ""
        case .choice(let index, let label): self.index = index; choice = label
        case .openToAnswer, .typeAnAnswer: index = -3; choice = ""
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let reference = RequestReference(botKey: botKey, requestId: requestId, sessionId: sessionId,
                                            executionGeneration: executionGeneration == -1 ? nil : executionGeneration),
           index >= -2 {
            let action: RequestActivityPresentation.Action = index == -1 ? .approve : index == -2 ? .deny : .choice(index: index, label: choice)
            if let handler = NeoActivityButtonRouter.handler,
               await handler.answerActivity(reference: reference, shown: shown, action: action) {
                let foregrounded: Bool
                do {
                    try await continueInForeground(alwaysConfirm: false)
                    foregrounded = true
                } catch {
                    foregrounded = false
                }
                await handler.openActivityRequest(reference, foregrounded: foregrounded)
            }
        }
        return .result()
    }
}
#endif
