import Foundation

/// The kinds of Live Activity the box knows by name (`box/bff/apns-registry.mjs` `ACTIVITY_KINDS`). The call has no
/// kind: it is driven by the phone itself and never by push.
public enum ActivityKind: String, Codable, Sendable, CaseIterable {
    case base
    case requests
}

/// The ActivityKit push tokens, as hex strings (what APNs wants). `requestPushToStart` and `basePushToStart` are
/// separate because a push-to-start token belongs to one activity type.
public struct ActivityPushTokens: Equatable, Sendable {
    /// `Activity<RequestActivityAttributes>.pushToStartTokenUpdates` (iOS 17.2): lets the box START an approvals
    /// activity while the app is not running. Needs the Push Notifications capability (paid team).
    public var requestPushToStart: String?
    /// The same for the always-on bubble.
    public var basePushToStart: String?
    /// `pushTokenUpdates` of each running activity (`pushType: .token`), by activity id.
    public var activityTokens: [String: String] = [:]

    public init(requestPushToStart: String? = nil, basePushToStart: String? = nil, activityTokens: [String: String] = [:]) {
        self.requestPushToStart = requestPushToStart
        self.basePushToStart = basePushToStart
        self.activityTokens = activityTokens
    }

    public static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

/// What a host reports when ActivityKit hands out or drops a token.
public enum ActivityTokenEvent: Equatable, Sendable {
    /// The approvals activity's push-to-start token (kept as is since P5).
    case pushToStart(String)
    case pushToStartBase(String)
    case activity(id: String, token: String)
    /// A token of a running activity whose kind the host knows (S22). The registration to the box needs the kind.
    case kindActivity(kind: ActivityKind, id: String, token: String)
    case activityEnded(id: String)
}
