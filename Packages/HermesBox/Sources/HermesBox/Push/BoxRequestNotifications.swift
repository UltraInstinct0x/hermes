import Foundation
import HermesActivityKit

/// Hermes Neo: the box's request alerts (`box/bff/push-planner.mjs`: `aps.category` `hermes.request.approval` or
/// `hermes.request.question`, `botKey` and `requestId` at the top level) and what a tap or an action on one means.
/// The identifiers are Hermes Bot's (`NotificationRouting`), since the box names them. Pure, tested.
public enum BoxRequestNotifications {
    public static let approvalCategory = "hermes.request.approval"
    public static let questionCategory = "hermes.request.question"
    public static let approveAction = "hermes.request.approve"
    public static let denyAction = "hermes.request.deny"
    public static let typeAction = "hermes.request.type"
    static let defaultAction = "com.apple.UNNotificationDefaultActionIdentifier"
    static let dismissAction = "com.apple.UNNotificationDismissActionIdentifier"

    public enum Reply: Sendable, Equatable {
        /// A plain tap: open the app (the bot's chat shows the request).
        case open(botKey: String)
        case lookup(botKey: String, requestId: String)
        case type(RequestReference)
        case answer(RequestReference, RequestSelection, shown: String)
        /// Swiped away: nothing to do.
        case dismissed
    }

    /// Whether a notification is one of the box's (it names a box bot and is not a relay notice).
    public static func isBoxNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let key = userInfo["botKey"] as? String, let requestId = userInfo["requestId"] as? String,
              !requestId.isEmpty else { return false }
        let bot = BotKey(rawValue: key)
        guard !bot.gatewayId.isEmpty, !bot.profileId.isEmpty else { return false }
        // Upstream's relay notices carry their sealed envelope under `hermes` (HermesPush `PushUserInfo.envelope`).
        return userInfo["hermes"] == nil
    }

    /// What the owner did with one of the box's notifications. Nil when it isn't one of the box's.
    public static func reply(userInfo: [AnyHashable: Any], action: String, answersEnabled: Bool = false,
                             now: Date = .now) -> Reply? {
        guard isBoxNotification(userInfo), let botKey = userInfo["botKey"] as? String else { return nil }
        if action == dismissAction { return .dismissed }
        if action == defaultAction, userInfo["needsApp"] as? Bool == true || userInfo["sessionId"] != nil {
            if let url = (userInfo["neoRequestLink"] as? String).flatMap(URL.init(string:)),
               case .request(let ref)? = ActivityLink(url: url), ref.botKey == botKey,
               ref.requestId == userInfo["requestId"] as? String {
                return .type(ref)
            }
            if let state = contentState(userInfo), let ref = RequestReference(state) { return .type(ref) }
            if let requestId = userInfo["requestId"] as? String { return .lookup(botKey: botKey, requestId: requestId) }
        }
        guard let state = contentState(userInfo), let ref = RequestReference(state) else { return .open(botKey: botKey) }
        let actions = RequestActivityPresentation(state).actions(lockScreenAnswersEnabled: answersEnabled, isStale: false, now: now)
        guard let selection = actions.first(where: { identifier(for: $0) == action }) else {
            return action == defaultAction ? .open(botKey: botKey) : nil
        }
        switch selection {
        case .approve, .deny:
            guard let command = state.command else { return nil }
            return .answer(ref, .approval(allow: selection == .approve), shown: command)
        case .choice(_, let choice):
            return .answer(ref, .clarification(choice, questionId: ref.isFrame ? state.questionId : nil), shown: state.detail)
        case .typeAnAnswer:
            return .type(ref)
        case .openToAnswer:
            return .open(botKey: botKey)
        }
    }

    public static func openRequestInfo(_ reference: RequestReference) -> [String: Any] {
        ["botKey": reference.botKey, "requestId": reference.requestId, "needsApp": true,
         "neoRequestLink": ActivityLink.request(reference).url.absoluteString]
    }

    public static func identifier(for action: RequestActivityPresentation.Action) -> String {
        switch action {
        case .approve: approveAction
        case .deny: denyAction
        case .choice(let index, _): "hermes.request.choice.\(index)"
        case .typeAnAnswer: typeAction
        case .openToAnswer: defaultAction
        }
    }

    public static func contentState(_ userInfo: [AnyHashable: Any]) -> RequestActivityAttributes.ContentState? {
        guard isBoxNotification(userInfo),
              let aps = userInfo["aps"] as? [String: Any],
              let category = aps["category"] as? String,
              category == approvalCategory || category == questionCategory,
              let botKey = userInfo["botKey"] as? String, let requestId = userInfo["requestId"] as? String,
              let data = try? JSONSerialization.data(withJSONObject: userInfo),
              let fields = try? JSONDecoder().decode(Fields.self, from: data) else { return nil }
        return .init(botKey: botKey, requestId: requestId,
                     botName: (aps["alert"] as? [String: String])?["title"] ?? "Hermes",
                     style: category == approvalCategory ? .approval : .question,
                     detail: fields.prompt ?? (aps["alert"] as? [String: String])?["body"] ?? "",
                     deadline: fields.expiresAt.map(Date.init(timeIntervalSince1970:)),
                     since: Date(timeIntervalSince1970: fields.createdAt ?? 0), choices: fields.choices ?? [],
                     needsApp: fields.needsApp != false, questionId: fields.questionId, sessionId: fields.sessionId,
                     executionGeneration: fields.executionGeneration, command: fields.command, approvalKind: fields.approvalKind)
    }

    private struct Fields: Decodable {
        let sessionId: String?
        let executionGeneration: Int?
        let prompt: String?
        let command: String?
        let choices: [String]?
        let questionId: String?
        let needsApp: Bool?
        let createdAt: Double?
        let expiresAt: Double?
        let approvalKind: String?
    }

}
