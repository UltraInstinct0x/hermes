#if os(iOS)
import ActivityKit
import HermesActivityKit
import HermesBox
import HermesKit
import HermesPush
import OSLog
import UIKit
import UserNotifications

/// The iPhone side of remote notifications for `PushRegistrar`: the permission and the device token.
@MainActor
final class NeoRemotePlatform: RemoteNotificationPlatform {
    let environment: String

    init(environment: String) { self.environment = environment }

    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        case .notDetermined:
            PushCenter.shared.reserveAuthorizationForRequests()
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        @unknown default: return false
        }
    }

    static func notificationsAllowed() async -> Bool? {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: true
        case .denied: false
        default: nil
        }
    }

    /// The token arrives at `PushAppDelegate`, which hands it to `NeoBox.deviceTokenReceived` too.
    func registerForRemoteNotifications() { UIApplication.shared.registerForRemoteNotifications() }
}

/// ActivityKit's request tokens and lifetimes, reported to the box registrar.
@MainActor
final class NeoActivityHost {
    private let report: @MainActor (PushActivityEvent) async -> Void
    private var tasks: [Task<Void, Never>] = []
    private var followed: [String: (token: Task<Void, Never>, lifecycle: Task<Void, Never>)] = [:]

    init(report: @escaping @MainActor (PushActivityEvent) async -> Void) {
        self.report = report
    }

    func start() {
        guard tasks.isEmpty else { return }
        tasks.append(Task { [weak self] in
            if let data = Activity<RequestActivityAttributes>.pushToStartToken {
                await self?.report(.pushToStart(kind: .requests, token: ActivityPushTokens.hex(data)))
            }
            for await data in Activity<RequestActivityAttributes>.pushToStartTokenUpdates {
                await self?.report(.pushToStart(kind: .requests, token: ActivityPushTokens.hex(data)))
            }
        })
        for activity in Activity<RequestActivityAttributes>.activities { follow(activity, kind: .requests) }
        tasks.append(Task { [weak self] in
            for await activity in Activity<RequestActivityAttributes>.activityUpdates { self?.follow(activity, kind: .requests) }
        })
    }

    func stop() {
        for task in tasks { task.cancel() }
        for record in followed.values {
            record.token.cancel()
            record.lifecycle.cancel()
        }
        tasks.removeAll()
        followed.removeAll()
    }

    func endRequests() async {
        for activity in Activity<RequestActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// One bubble: its update token (so the box can update and end it) and its end.
    private func follow<Attributes: ActivityAttributes>(_ activity: Activity<Attributes>, kind: ActivityKind) {
        let id = activity.id
        guard followed[id] == nil else { return }
        let tokenUpdates = Task { [weak self] in
            if let data = activity.pushToken {
                await self?.report(.activityToken(kind: kind, id: id, token: ActivityPushTokens.hex(data), startedAt: nil))
            }
            for await data in activity.pushTokenUpdates {
                await self?.report(.activityToken(kind: kind, id: id, token: ActivityPushTokens.hex(data), startedAt: nil))
            }
        }
        let lifecycle = Task { [weak self] in
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                tokenUpdates.cancel()
                self?.followed.removeValue(forKey: id)
                await self?.report(.activityEnded(kind: kind, id: id, byUser: false))
                break
            }
        }
        followed[id] = (tokenUpdates, lifecycle)
    }
}

enum NeoNotificationRouting {
    static var categories: Set<UNNotificationCategory> {
        Set([BoxRequestNotifications.approvalCategory, BoxRequestNotifications.questionCategory].map {
            UNNotificationCategory(identifier: $0, actions: [], intentIdentifiers: [], options: [])
        })
    }

    nonisolated static func handle(_ response: UNNotificationResponse, completion: @escaping @Sendable () -> Void) -> Bool {
        guard let reply = BoxRequestNotifications.reply(userInfo: response.notification.request.content.userInfo,
                                                        action: response.actionIdentifier,
                                                        answersEnabled: NotificationCatalog.neoLockScreenAnswersEnabled) else { return false }
        let identifier = response.notification.request.identifier
        Task { @MainActor in
            NeoBox.shared.push.notePushReceived()
            switch reply {
            case .open(let botKey):
                NeoBox.shared.openRequestLink(.bot(key: botKey))
            case .lookup(let botKey, let requestId):
                NeoBox.shared.openRequestLink(.lookup(botKey: botKey, requestId: requestId))
            case .type(let reference):
                NeoBox.shared.openRequestLink(.request(reference))
            case .answer(let reference, let selection, let shown):
                if let outcome = await NeoBox.shared.submitRequest(reference, shown: shown, selection: selection) {
                    let center = UNUserNotificationCenter.current()
                    center.removeDeliveredNotifications(withIdentifiers: [identifier])
                    let receipt = UNMutableNotificationContent()
                    receipt.title = RequestActivityPresentation.finalLine(outcome, answeredBy: nil, answeredChoice: selection.receiptChoice)
                    try? await center.add(UNNotificationRequest(identifier: identifier, content: receipt, trigger: nil))
                }
            case .dismissed:
                break
            }
            completion()
        }
        return true
    }
}

extension NeoBox: NeoActivityButtonHandling {
    func answerActivity(reference: RequestReference, shown: String, action: RequestActivityPresentation.Action) async {
        let matching = Activity<RequestActivityAttributes>.activities.filter { RequestReference($0.content.state) == reference }
        guard matching.count == 1, let activity = matching.first else { return }
        let presentation = RequestActivityPresentation(activity.content.state)
        guard presentation.actions(lockScreenAnswersEnabled: NotificationCatalog.neoLockScreenAnswersEnabled,
                                   isStale: activity.activityState == .stale).contains(action),
              presentation.textToVerify(for: action) == shown else { return }
        let selection: RequestSelection
        switch action {
        case .approve, .deny:
            selection = .approval(allow: action == .approve)
        case .choice(_, let label):
            selection = .clarification(label, questionId: reference.isFrame ? activity.content.state.questionId : nil)
        case .openToAnswer, .typeAnAnswer:
            return
        }
        _ = await submitRequest(reference, shown: shown, selection: selection)
    }

    func submitRequest(_ reference: RequestReference, shown: String, selection: RequestSelection) async -> RequestActivityAttributes.ContentState.Outcome? {
        guard NotificationCatalog.neoLockScreenAnswersEnabled,
              let outcome = await answerRequest(reference, shown: shown, selection: selection) else { return nil }
        for activity in Activity<RequestActivityAttributes>.activities {
            var state = activity.content.state
            guard RequestReference(state) == reference, state.outcome == nil else { continue }
            state.outcome = outcome
            if outcome == .answered { state.answeredChoice = selection.receiptChoice }
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
        if outcome == .noLongerWaiting {
            await UIApplication.shared.open(ActivityLink.request(reference).url)
        }
        return outcome
    }
}

private extension RequestSelection {
    var receiptChoice: String? {
        if case .clarification(let answer, _) = self { return VisibleText.of(answer) }
        return nil
    }
}

#if DEBUG
enum NeoRequestActivityDemo {
    static func startIfAsked() async {
        guard let mode = LaunchFlags.take("NEO_REQUEST_ACTIVITY_DEMO") else { return }
        #if targetEnvironment(simulator)
        PushShared.current.defaults.set(mode != "1", forKey: "NEO_LOCK_SCREEN_ANSWER_DEMO")
        #endif
        for activity in Activity<RequestActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        let now = Date()
        let question = mode == "clarify"
        let state = RequestActivityAttributes.ContentState(
            botKey: "demo::hermes", requestId: mode == "1" ? "demo-request" : "demo-answer-request", botName: "Hermes",
            style: question ? .question : .approval, detail: question ? "Which report should I open?" : "git status",
            since: now, choices: question ? ["Weekly", "Monthly"] : [], moreWaiting: 1,
            sessionId: "demo-session", executionGeneration: 1, command: question ? nil : "git status",
            approvalKind: question ? nil : "command")
        do {
            _ = try Activity.request(attributes: RequestActivityAttributes(),
                                     content: ActivityContent(state: state, staleDate: nil), pushType: nil)
        } catch {
            let fault = error as NSError
            Logger(subsystem: "dev.supersaiyan.hermesneo", category: "Requests").error(
                "Could not start request activity: \(fault.domain, privacy: .public) \(fault.code)")
        }
    }
}
#endif
#endif
