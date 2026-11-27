import Foundation

/// Hermes Neo: the box's request alerts (`box/bff/push-planner.mjs`: `aps.category` `hermes.request.approval` or
/// `hermes.request.question`, `botKey` and `requestId` at the top level) and what a tap or an action on one means.
/// The identifiers are Hermes Bot's (`NotificationRouting`), since the box names them. Pure, tested.
public enum BoxRequestNotifications {
    public static let approvalCategory = "hermes.request.approval"
    public static let questionCategory = "hermes.request.question"
    public static let approveAction = "hermes.request.approve"
    public static let denyAction = "hermes.request.deny"
    static let defaultAction = "com.apple.UNNotificationDefaultActionIdentifier"
    static let dismissAction = "com.apple.UNNotificationDismissActionIdentifier"

    public enum Reply: Sendable, Equatable {
        /// A plain tap: open the app (the bot's chat shows the request).
        case open(botKey: String)
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
    public static func reply(userInfo: [AnyHashable: Any], action: String) -> Reply? {
        guard isBoxNotification(userInfo), let botKey = userInfo["botKey"] as? String else { return nil }
        switch action {
        case dismissAction:
            return .dismissed
        default:
            return .open(botKey: botKey)
        }
    }

}
