import Foundation

/// `POST /bff/call-owner/test-ring` (S27 slice 1): the box rings its default bot, then pushes to THIS phone.
public struct TestRingResult: Decodable, Equatable, Sendable {
    /// `ringing` (the hub holds the call), `busy` (already in a call with that bot) or `failed` (no hub call).
    public var outcome: String
    /// How many devices Apple accepted the VoIP push for.
    public var sent: Int?

    public init(outcome: String, sent: Int? = nil) {
        self.outcome = outcome
        self.sent = sent
    }
}

/// The box side of "Calls from your bots". `BFFClient` implements it; tests use a fake.
public protocol CallOwnerServing: Sendable {
    /// `POST /bff/push/voip/register {token, environment, topic}`. `topic` is the app's bundle id (Hermes Neo and the
    /// Hermes Bot app share a box); a box that predates it ignores the field.
    func voipRegister(token: String, environment: String, topic: String?) async throws
    /// `DELETE /bff/push/voip/register`.
    func voipUnregister() async throws
    /// `GET /bff/push/apns/status`, its `voip` boolean. Nil when the box has push or calls from bots off.
    func voipStatus() async throws -> Bool?
    func testRing() async throws -> TestRingResult
}

private struct VoIPStatusBody: Decodable {
    var voip: Bool?
}

private struct VoIPRegistrationBody: Encodable {
    var token: String
    var environment: String
    /// Left out when nil.
    var topic: String?
}

extension BFFClient: CallOwnerServing {
    public func voipRegister(token: String, environment: String, topic: String?) async throws {
        let body = try JSONEncoder().encode(VoIPRegistrationBody(token: token, environment: environment, topic: topic))
        _ = try await send(path: "/bff/push/voip/register", method: "POST", body: body)
    }

    public func voipUnregister() async throws {
        _ = try await send(path: "/bff/push/voip/register", method: "DELETE", body: Data("{}".utf8))
    }

    public func voipStatus() async throws -> Bool? {
        do {
            let status: VoIPStatusBody = try await get("/bff/push/apns/status")
            return status.voip
        } catch BFFError.envelope(_, _, 404) {
            return nil
        } catch BFFError.unexpectedStatus(404) {
            return nil
        }
    }

    public func testRing() async throws -> TestRingResult {
        let data = try await send(path: "/bff/call-owner/test-ring", method: "POST", body: Data("{}".utf8))
        do {
            return try JSONDecoder().decode(TestRingResult.self, from: data)
        } catch {
            throw BFFError.undecodable(detail: "/bff/call-owner/test-ring: \(error)")
        }
    }
}

/// The owner's "Calls from your bots" switch, kept on the phone. Off until the owner turns it on.
public protocol CallsFromBotsStoring: Sendable {
    var enabled: Bool { get set }
}

public final class InMemoryCallsFromBots: CallsFromBotsStoring, @unchecked Sendable {
    public var enabled: Bool
    public init(enabled: Bool = false) { self.enabled = enabled }
}

public final class UserDefaultsCallsFromBots: CallsFromBotsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "hermes.callsFromBots.enabled"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var enabled: Bool {
        get { defaults.bool(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }
}
