#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// One VoIP push of the box (S27 R4, `box/bff/call-owner.mjs` `ringPayload`):
/// `{"hermes":{"v":1,"kind":"ring","call_id","bot_key","bot_name","urgency","expires_at"}}`, `expires_at` in seconds.
/// It names the call and the bot only; why the bot calls is never in the push.
public struct RingPush: Sendable, Equatable {
    public enum Urgency: String, Sendable, Equatable {
        case checkin
        case urgent
    }

    public var callId: String
    public var botKey: String
    public var botName: String
    public var urgency: Urgency
    public var expiresAt: Date
    public var seriesId: String?
    public var attempt: Int?

    public init(
        callId: String, botKey: String, botName: String, urgency: Urgency = .checkin, expiresAt: Date, seriesId: String? = nil,
        attempt: Int? = nil
    ) {
        self.callId = callId
        self.botKey = botKey
        self.botName = botName
        self.urgency = urgency
        self.expiresAt = expiresAt
        self.seriesId = seriesId
        self.attempt = attempt
    }

    /// The machine that holds the call: the gateway half of `gatewayId::profileId`.
    public var gatewayId: String { BotKey(rawValue: botKey).gatewayId }

    /// Read the push. Nil for anything that is not a version 1 ring with a call id, a bot key and an expiry: such a push
    /// is still reported to CallKit and ended at once (`RingDecision`), never dropped.
    public static func parse(_ payload: [AnyHashable: Any]) -> RingPush? {
        guard let hermes = payload["hermes"] as? [String: Any], WireValue.int(hermes["v"]) == 1,
            hermes["kind"] as? String == "ring",
            let callId = WireValue.string(hermes["call_id"]), !callId.isEmpty, callId.count <= 128,
            let botKey = WireValue.string(hermes["bot_key"]), botKey.contains(BotKey.separator), botKey.count <= 200,
            let expires = hermes["expires_at"] as? NSNumber, CFGetTypeID(expires) != CFBooleanGetTypeID()
        else { return nil }
        let key = BotKey(rawValue: botKey)
        guard !key.gatewayId.isEmpty, !key.profileId.isEmpty else { return nil }
        let name = WireValue.string(hermes["bot_name"]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return RingPush(
            callId: callId, botKey: botKey,
            // The name a person knows ('Hermes Bot'), never the bare profile ('hermesbot') when the push carried none.
            botName: RosterMapping.displayName(profile: key.profileId, title: String(name.prefix(60)), fallback: nil),
            urgency: (hermes["urgency"] as? String).flatMap(Urgency.init(rawValue:)) ?? .checkin,
            expiresAt: Date(timeIntervalSince1970: expires.doubleValue), seriesId: WireValue.string(hermes["series_id"]),
            attempt: WireValue.int(hermes["attempt"]))
    }
}

/// The CallKit UUID of a hub call. Stable: the same call id always gives the same UUID, so a second push for one ring
/// is the same CallKit call, never a second one. The hub's ids are UUIDs already (`crypto.randomUUID`); any other id is
/// hashed into a name-based UUID.
public enum RingCallID {
    public static func uuid(for callId: String) -> UUID {
        if let uuid = UUID(uuidString: callId) { return uuid }
        var bytes = Array(SHA256.hash(data: Data("hermes-bot.ring:\(callId)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50  // version 5 style (name based)
        bytes[8] = (bytes[8] & 0x3f) | 0x80  // RFC 4122 variant
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10],
                bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }
}
