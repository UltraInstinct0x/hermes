import Foundation
import HermesActivityKit

// Ported from Hermes Bot (`HermesKit/Push/PushAPI.swift`, S22). Hermes Neo adds `topic` to the registration.

/// What the box reports about this device's push registration (`GET /bff/push/apns/status`). Booleans and counts
/// only: the box never returns a token.
public struct APNsStatus: Decodable, Equatable, Sendable {
    public struct Registered: Decodable, Equatable, Sendable {
        public var deviceToken: Bool
        public var pushToStart: Bool
        public var base: Bool
        public var requests: Bool
    }

    public struct Prefs: Decodable, Equatable, Sendable {
        public var alwaysOn: Bool
        public var approvals: Bool
        public var call: Bool
        public var notifications: Bool
    }

    public var enabled: Bool
    public var environment: String
    public var registered: Registered
    public var prefs: Prefs
    public var baseDismissedByUser: Bool
    public var lastPushAt: Int?
    public var lastPushKind: String?
    public var lastPushStatus: Int?
    public var keyLoaded: Bool?
}

/// `POST /bff/push/apns/register`. Every field is optional: the box merges what it is given.
public struct APNsRegistration: Encodable, Equatable, Sendable {
    public struct Activity: Encodable, Equatable, Sendable {
        public var id: String
        public var kind: String
        public var token: String
        public var startedAt: Int?
    }

    public struct Prefs: Encodable, Equatable, Sendable {
        public var alwaysOn: Bool
        public var approvals: Bool
        public var call: Bool
        public var notifications: Bool
    }

    public var deviceToken: String?
    public var pushToStartTokens: [String: String]?
    public var activity: Activity?
    public var environment: String?
    public var prefs: Prefs?
    /// The app just launched: a dismissal of the always-on bubble from an earlier run no longer counts.
    public var launch: Bool?
    /// Hermes Neo: the registering app's bundle id. The box sends this device's alerts and Live Activities to that
    /// topic (an allowlisted second app); without it they would go to Hermes Bot's and Apple would drop the token.
    public var topic: String?

    public init(
        deviceToken: String? = nil, pushToStartTokens: [String: String]? = nil, activity: Activity? = nil, environment: String? = nil,
        prefs: Prefs? = nil, launch: Bool? = nil, topic: String? = nil
    ) {
        self.deviceToken = deviceToken
        self.pushToStartTokens = pushToStartTokens
        self.activity = activity
        self.environment = environment
        self.prefs = prefs
        self.launch = launch
        self.topic = topic
    }

    public static func prefs(_ p: LockScreenPreferences) -> Prefs {
        Prefs(alwaysOn: p.alwaysOn, approvals: p.approvals, call: p.call, notifications: p.notifications)
    }
}

/// `DELETE /bff/push/apns/register`.
public struct APNsUnregistration: Encodable, Equatable, Sendable {
    public var all: Bool?
    public var activityId: String?
    public var byUser: Bool?
    public var deviceToken: Bool?
    public var pushToStart: Bool?

    public init(all: Bool? = nil, activityId: String? = nil, byUser: Bool? = nil, deviceToken: Bool? = nil, pushToStart: Bool? = nil) {
        self.all = all
        self.activityId = activityId
        self.byUser = byUser
        self.deviceToken = deviceToken
        self.pushToStart = pushToStart
    }
}

/// `POST /bff/push/apns/test`: the box says what it sent.
public struct APNsTestResult: Decodable, Equatable, Sendable {
    public struct Part: Decodable, Equatable, Sendable {
        public var sent: Bool
        public var status: Int?
        public var via: String?
    }

    public var alert: Part
    public var activity: Part
}

/// The box side of push, as the app uses it. `BFFClient` implements it; tests use a fake.
public protocol PushServing: Sendable {
    /// Nil when the box has push off (a 404): "not available", not an error.
    func apnsStatus() async throws -> APNsStatus?
    func apnsRegister(_ registration: APNsRegistration) async throws
    func apnsUnregister(_ unregistration: APNsUnregistration) async throws
    func apnsTest() async throws -> APNsTestResult
}

extension BFFClient: PushServing {
    public func apnsStatus() async throws -> APNsStatus? {
        do {
            return try await get("/bff/push/apns/status")
        } catch BFFError.envelope(_, _, 404) {
            return nil
        } catch BFFError.unexpectedStatus(404) {
            return nil
        }
    }

    public func apnsRegister(_ registration: APNsRegistration) async throws {
        _ = try await send(path: "/bff/push/apns/register", method: "POST", body: try JSONEncoder().encode(registration))
    }

    public func apnsUnregister(_ unregistration: APNsUnregistration) async throws {
        _ = try await send(path: "/bff/push/apns/register", method: "DELETE", body: try JSONEncoder().encode(unregistration))
    }

    public func apnsTest() async throws -> APNsTestResult {
        let data = try await send(path: "/bff/push/apns/test", method: "POST", body: Data("{}".utf8))
        do {
            return try JSONDecoder().decode(APNsTestResult.self, from: data)
        } catch {
            throw BFFError.undecodable(detail: "/bff/push/apns/test: \(error)")
        }
    }
}
