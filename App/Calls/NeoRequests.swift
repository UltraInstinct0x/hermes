#if os(iOS)
import ActivityKit
import HermesActivityKit
import HermesBox
import UIKit
import UserNotifications

// Hermes Neo: requests (approvals, questions) and Live Activities from the owner's box (S22 in Hermes Bot).
// The box pushes the requests bubble (`RequestActivityAttributes`) and the always-on bubble (`BaseActivityAttributes`)
// to this app's topic; their buttons answer through `BoxRequestAnswers`. No chat notifications: Neo asks the box for
// requests and bubbles only (`prefs.notifications` stays off, which is also what keeps the box's own chat alerts away).

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
        default: return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
    }

    /// The token arrives at `PushAppDelegate`, which hands it to `NeoBox.deviceTokenReceived` too.
    func registerForRemoteNotifications() { UIApplication.shared.registerForRemoteNotifications() }
}

/// ActivityKit's tokens and the bubbles' lifetimes, reported to the registrar (Hermes Bot's `ActivityController`,
/// only the part the box needs: push-to-start tokens for both kinds, each running bubble's update token, its end).
@MainActor
final class NeoActivityHost {
    private let report: @MainActor (PushActivityEvent) async -> Void
    private var tasks: [Task<Void, Never>] = []
    private var followed: Set<String> = []

    init(report: @escaping @MainActor (PushActivityEvent) async -> Void) {
        self.report = report
    }

    func start() {
        guard tasks.isEmpty else { return }
        tasks.append(Task { [weak self] in
            for await data in Activity<RequestActivityAttributes>.pushToStartTokenUpdates {
                await self?.report(.pushToStart(kind: .requests, token: ActivityPushTokens.hex(data)))
            }
        })
        tasks.append(Task { [weak self] in
            for await data in Activity<BaseActivityAttributes>.pushToStartTokenUpdates {
                await self?.report(.pushToStart(kind: .base, token: ActivityPushTokens.hex(data)))
            }
        })
        for activity in Activity<RequestActivityAttributes>.activities { follow(activity, kind: .requests) }
        for activity in Activity<BaseActivityAttributes>.activities { follow(activity, kind: .base) }
        tasks.append(Task { [weak self] in
            for await activity in Activity<RequestActivityAttributes>.activityUpdates { self?.follow(activity, kind: .requests) }
        })
        tasks.append(Task { [weak self] in
            for await activity in Activity<BaseActivityAttributes>.activityUpdates { self?.follow(activity, kind: .base) }
        })
    }

    /// One bubble: its update token (so the box can update and end it) and its end.
    private func follow<Attributes: ActivityAttributes>(_ activity: Activity<Attributes>, kind: ActivityKind) {
        let id = activity.id
        guard followed.insert(id).inserted else { return }
        tasks.append(Task { [weak self] in
            for await data in activity.pushTokenUpdates {
                await self?.report(.activityToken(kind: kind, id: id, token: ActivityPushTokens.hex(data), startedAt: nil))
            }
        })
        tasks.append(Task { [weak self] in
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                // Only the owner swiping the always-on bubble away is remembered as theirs (the box then leaves it alone).
                await self?.report(.activityEnded(kind: kind, id: id, byUser: state == .dismissed && kind == .base))
                self?.followed.remove(id)
                break
            }
        })
    }
}

/// Where upstream's notification delegate hands a response to one of the box's request alerts.
enum NeoNotificationRouting {
    /// Approve once and Deny on an approval (no authentication, no opening the app: they work from the Lock Screen,
    /// as in Hermes Bot); a question only opens the app.
    static var categories: Set<UNNotificationCategory> {
        let approve = UNNotificationAction(identifier: BoxRequestNotifications.approveAction, title: "Approve once", options: [])
        let deny = UNNotificationAction(identifier: BoxRequestNotifications.denyAction, title: "Deny", options: [.destructive])
        return [
            UNNotificationCategory(identifier: BoxRequestNotifications.approvalCategory, actions: [approve, deny], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: BoxRequestNotifications.questionCategory, actions: [], intentIdentifiers: [], options: []),
        ]
    }

    /// True when the response was one of the box's (then `completion` runs once it is handled).
    nonisolated static func handle(_ response: UNNotificationResponse, completion: @escaping @Sendable () -> Void) -> Bool {
        guard let reply = BoxRequestNotifications.reply(userInfo: response.notification.request.content.userInfo, action: response.actionIdentifier)
        else { return false }
        Task { @MainActor in
            await NeoBox.shared.handle(reply)
            completion()
        }
        return true
    }
}

extension NeoBox: NeoActivityButtonHandling {
    func answerApproval(botKey: String, requestId: String, allow: Bool) async -> Bool {
        await answer(botKey: botKey) { $0.answerApproval(botKey: botKey, requestId: requestId, allow: allow) }
    }

    func answerChoice(botKey: String, requestId: String, questionId: String, choice: String) async -> Bool {
        await answer(botKey: botKey) { $0.answerChoice(botKey: botKey, requestId: requestId, questionId: questionId, choice: choice) }
    }

    func toggleMute() -> Bool {
        guard calls.isInCall else { return false }
        calls.toggleMute()
        return true
    }

    func toggleSpeaker() -> Bool {
        guard calls.isInCall, calls.outputState.offersChoice else { return false }
        calls.toggleOutput()
        return true
    }

    func endCall() -> Bool {
        guard calls.isInCall else { return false }
        calls.end()
        return true
    }

    /// A tap or an action on one of the box's request alerts.
    func handle(_ reply: BoxRequestNotifications.Reply) async {
        switch reply {
        case .answer(let botKey, let requestId, let allow):
            _ = await answerApproval(botKey: botKey, requestId: requestId, allow: allow)
        case .open, .dismissed:
            // The app is open now; the bot's chat (upstream's Bots) shows what waits.
            break
        }
    }

    /// One answer on the box; a note when it did not go through (the bot still waits).
    private func answer(botKey: String, _ call: (BoxRequestAnswers) async -> BoxRequestAnswers.Outcome) async -> Bool {
        restoreIfNeeded()
        let release = NeoRingBackgroundTime.begin("answer")
        defer { release() }
        guard let answers = requestAnswers() else {
            await Self.postStillWaiting(botKey: botKey)
            return false
        }
        switch await call(answers) {
        case .answered:
            return true
        case .notWaiting:
            // Answered elsewhere or expired: the box's bubble update says so; nothing to add.
            return false
        case .failed:
            await Self.postStillWaiting(botKey: botKey)
            return false
        }
    }

    private static func postStillWaiting(botKey: String) async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let profile = BotKey(rawValue: botKey).profileId
        let words = BoxRequestNotifications.stillWaiting(botName: profile.isEmpty ? "Your bot" : profile)
        let content = UNMutableNotificationContent()
        content.title = words.title
        content.body = words.body
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: "neo.request.failed.\(UUID().uuidString)", content: content, trigger: nil))
    }
}
#endif
