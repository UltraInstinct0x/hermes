import AppIntents
import Foundation

// The buttons on the lock screen. This folder is compiled into BOTH the app and the HermesBotActivities
// widget extension: the extension needs the types to draw `Button(intent:)`, and iOS RUNS a
// `LiveActivityIntent` in the app's process (it launches the app in the background if it is not running).
// So `perform()` only forwards to the app through `NeoActivityButtonRouter`; the answer itself is made by
// HermesKit's `LiveActivityActions` (tested with a fake ledger). In the extension the router stays empty.

/// What the app does for a lock-screen button. The app implements it (HermesBot/ActivityButtonBridge.swift).
@MainActor
protocol NeoActivityButtonHandling: AnyObject {
    func answerApproval(botKey: String, requestId: String, allow: Bool) async -> Bool
    func answerChoice(botKey: String, requestId: String, questionId: String, choice: String) async -> Bool
    func toggleMute() -> Bool
    func toggleSpeaker() -> Bool
    func endCall() -> Bool
}

@MainActor
enum NeoActivityButtonRouter {
    static weak var handler: (any NeoActivityButtonHandling)?
}

// MARK: approvals

/// Approve once. NO unlock: `.alwaysAllowed` lets the system run it on a locked phone (owner decision D2, the
/// same as the notification action). `openAppWhenRun` is false so the lock screen stays where it is.
struct NeoApproveRequestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Approve once"
    static let description = IntentDescription("Lets the bot run the waiting command one time.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Bot") var botKey: String
    @Parameter(title: "Request") var requestId: String

    init() {}
    init(botKey: String, requestId: String) {
        self.botKey = botKey
        self.requestId = requestId
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = await NeoActivityButtonRouter.handler?.answerApproval(botKey: botKey, requestId: requestId, allow: true)
        return .result()
    }
}

struct NeoDenyRequestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Deny"
    static let description = IntentDescription("Tells the bot not to run the waiting command.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Bot") var botKey: String
    @Parameter(title: "Request") var requestId: String

    init() {}
    init(botKey: String, requestId: String) {
        self.botKey = botKey
        self.requestId = requestId
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = await NeoActivityButtonRouter.handler?.answerApproval(botKey: botKey, requestId: requestId, allow: false)
        return .result()
    }
}

// MARK: questions

/// Answer a question with one of its choices. Free text cannot be typed on the lock screen: that case is a
/// link into the app, not an intent.
struct NeoAnswerChoiceIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Answer a question"
    static let description = IntentDescription("Answers the waiting question with one of its choices.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Bot") var botKey: String
    @Parameter(title: "Request") var requestId: String
    @Parameter(title: "Question") var questionId: String
    @Parameter(title: "Choice") var choice: String

    init() {}
    init(botKey: String, requestId: String, questionId: String, choice: String) {
        self.botKey = botKey
        self.requestId = requestId
        self.questionId = questionId
        self.choice = choice
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = await NeoActivityButtonRouter.handler?.answerChoice(botKey: botKey, requestId: requestId, questionId: questionId, choice: choice)
        return .result()
    }
}

// MARK: the call

/// Mute or unmute the microphone of the running call.
struct NeoToggleCallMuteIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mute or unmute the call"
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    static var openAppWhenRun: Bool { false }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = NeoActivityButtonRouter.handler?.toggleMute()
        return .result()
    }
}

/// Speaker on or off for the running call. The list of devices (AirPlay, Bluetooth) cannot be raised from a lock screen: that
/// stays on the call screen.
struct NeoToggleCallSpeakerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Speaker on or off"
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    static var openAppWhenRun: Bool { false }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = NeoActivityButtonRouter.handler?.toggleSpeaker()
        return .result()
    }
}

/// End the call (an owner ends it for everyone; a listener only leaves).
struct NeoEndCallIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "End the call"
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    static var openAppWhenRun: Bool { false }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = NeoActivityButtonRouter.handler?.endCall()
        return .result()
    }
}
