import Foundation

/// The request Live Activity kind on the box's APNs registration wire.
public enum ActivityKind: String, Codable, Sendable, CaseIterable {
    case requests
}

public enum ActivityPushTokens {
    public static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
