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
        default: return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
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
                                                        action: response.actionIdentifier) else { return false }
        Task { @MainActor in
            NeoBox.shared.push.notePushReceived()
            if case .open(let botKey) = reply { NeoBox.shared.openRequestLink(.bot(key: botKey)) }
            completion()
        }
        return true
    }
}

extension NeoBox: NeoActivityButtonHandling {
    func answerApproval(botKey: String, requestId: String, shown: String, allow: Bool) async -> Bool {
        await answerRequest(botKey: botKey, requestId: requestId, shown: shown, answer: .approval(allow ? .once : .deny))
    }

    func answerChoice(botKey: String, requestId: String, questionId: String, choice: String, shown: String) async -> Bool {
        await answerRequest(botKey: botKey, requestId: requestId, shown: shown, answer: .clarify([questionId: .text(choice)]))
    }
}

#if DEBUG
enum NeoRequestActivityDemo {
    static func startIfAsked() async {
        guard LaunchFlags.take("NEO_REQUEST_ACTIVITY_DEMO") != nil else { return }
        for activity in Activity<RequestActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        let now = Date()
        let state = RequestActivityAttributes.ContentState(
            botKey: "demo::hermes", requestId: "demo-approval", botName: "Hermes",
            style: .approval, detail: "swift test --filter RequestTests", since: now,
            moreWaiting: 1)
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
