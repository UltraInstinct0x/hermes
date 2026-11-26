import Foundation

// Ported from Hermes Bot (`HermesKit/Roster/Roster.swift`), only what a ring needs: the box's bot key and the name
// rule for a bot the push names.

/// A bot on the box: `gatewayId::profileId`.
public struct BotKey: Hashable, Sendable, CustomStringConvertible, Comparable, Codable {
    public static let separator = "::"

    public let gatewayId: String
    public let profileId: String

    public init(gatewayId: String, profileId: String) {
        self.gatewayId = gatewayId
        self.profileId = profileId
    }

    public init(rawValue: String) {
        if let range = rawValue.range(of: Self.separator) {
            gatewayId = String(rawValue[..<range.lowerBound])
            profileId = String(rawValue[range.upperBound...])
        } else {
            gatewayId = ""
            profileId = rawValue
        }
    }

    /// `gatewayId::profileId`; a bare profile name when the gateway is empty (legacy rows).
    public var rawValue: String { gatewayId.isEmpty ? profileId : "\(gatewayId)\(Self.separator)\(profileId)" }
    public var description: String { rawValue }

    public static func < (lhs: BotKey, rhs: BotKey) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The box's naming rule for bots (`electron/runtime-core.mjs` `displayNameFor`).
public enum RosterMapping {
    public static let canonicalProfileKey = "hermesbot"
    /// Stale keys and titles the primary bot was listed under, plus the legacy name.
    public static let canonicalAliases = ["alan", "hermes"]
    public static let canonicalDisplayName = "Hermes Bot"

    static func isAliasedTitle(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return v == canonicalProfileKey || canonicalAliases.contains(v)
    }

    static func isCanonical(_ name: String) -> Bool { isAliasedTitle(name) }

    /// Name precedence (S03 R7): canonical alias, then a non-empty gateway title, then the local
    /// rename, then `display_name`, then the profile id.
    static func displayName(profile: String, title: String?, fallback: String?) -> String {
        if isCanonical(profile) { return canonicalDisplayName }
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !t.isEmpty { return isAliasedTitle(t) ? canonicalDisplayName : t }
        let d = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !d.isEmpty { return isAliasedTitle(d) ? canonicalDisplayName : d }
        return isAliasedTitle(profile) ? canonicalDisplayName : profile
    }
}
