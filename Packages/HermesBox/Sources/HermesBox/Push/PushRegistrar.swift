import Foundation
import HermesActivityKit
import Observation

// Ported from Hermes Bot (`HermesKit/Push/PushRegistrar.swift`, S22). Hermes Neo changes:
// - every registration carries `topic` (the app's bundle id), so the box pushes to this app;
// - the device token is asked for and sent whenever the owner wants any push, not only alerts: a request's
//   Live Activity is the way Neo answers, and the Test notification needs the token.

/// Facts about the lock-screen activities the box needs, reported by `ActivityController`.
public enum PushActivityEvent: Equatable, Sendable {
    case pushToStart(kind: ActivityKind, token: String)
    case activityToken(kind: ActivityKind, id: String, token: String, startedAt: Date?)
    /// An activity ended. `byUser` is true only for the owner swiping the always-on bubble away.
    case activityEnded(kind: ActivityKind, id: String, byUser: Bool)
}

/// The iPhone side of remote notifications, so the registrar is tested without UIKit. The app target implements it.
@MainActor
public protocol RemoteNotificationPlatform: AnyObject, Sendable {
    /// `sandbox` for a build installed from Xcode, `production` for TestFlight and the App Store. It is the build's own
    /// `aps-environment`, never a switch.
    var environment: String { get }
    /// Ask for permission to show alerts (the system prompt appears once; later calls just report). True when allowed.
    func requestAuthorization() async -> Bool
    /// `UIApplication.registerForRemoteNotifications()`: the device token then arrives at the app delegate.
    func registerForRemoteNotifications()
}

/// What survives a restart of the app: whether the box had push on the last time (so the host starts with push tokens
/// from the first frame), and when a push last arrived.
public protocol PushStateStoring: Sendable {
    var serverEnabled: Bool? { get set }
    var lastPushReceivedAt: Date? { get set }
    var pendingOptOut: Bool { get set }
}

public final class InMemoryPushState: PushStateStoring, @unchecked Sendable {
    public var serverEnabled: Bool?
    public var lastPushReceivedAt: Date?
    public var pendingOptOut = false
    public init(serverEnabled: Bool? = nil, lastPushReceivedAt: Date? = nil) {
        self.serverEnabled = serverEnabled
        self.lastPushReceivedAt = lastPushReceivedAt
    }
}

public final class UserDefaultsPushState: PushStateStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var serverEnabled: Bool? {
        get { defaults.object(forKey: "hermes.push.serverEnabled") as? Bool }
        set { defaults.set(newValue, forKey: "hermes.push.serverEnabled") }
    }

    public var lastPushReceivedAt: Date? {
        get { defaults.object(forKey: "hermes.push.lastReceivedAt") as? Date }
        set { defaults.set(newValue, forKey: "hermes.push.lastReceivedAt") }
    }

    public var pendingOptOut: Bool {
        get { defaults.bool(forKey: "hermes.push.pendingOptOut") }
        set { defaults.set(newValue, forKey: "hermes.push.pendingOptOut") }
    }
}

/// What Settings shows under Diagnostics. Plain facts, no tokens.
public struct PushDiagnostics: Equatable, Sendable {
    /// Nil until the box answered once.
    public var serverEnabled: Bool?
    public var environment: String
    public var deviceTokenRegistered: Bool
    public var requestsPushToStart: Bool
    public var requestsActivityRegistered: Bool
    public var lastPushReceived: Date?
    /// The box's own record of its last push to this phone (time, kind, HTTP status from Apple).
    public var serverLastPush: String?
    public var notificationsAllowed: Bool?
    public var lastError: String?

    public init(
        serverEnabled: Bool? = nil, environment: String, deviceTokenRegistered: Bool = false,
        requestsPushToStart: Bool = false, requestsActivityRegistered: Bool = false,
        lastPushReceived: Date? = nil, serverLastPush: String? = nil, notificationsAllowed: Bool? = nil, lastError: String? = nil
    ) {
        self.serverEnabled = serverEnabled
        self.environment = environment
        self.deviceTokenRegistered = deviceTokenRegistered
        self.requestsPushToStart = requestsPushToStart
        self.requestsActivityRegistered = requestsActivityRegistered
        self.lastPushReceived = lastPushReceived
        self.serverLastPush = serverLastPush
        self.notificationsAllowed = notificationsAllowed
        self.lastError = lastError
    }
}

/// The words of the Test push button. Calm sentences, no em-dashes.
public enum PushTestPresentation {
    public static func sentence(_ result: APNsTestResult) -> String {
        let alert = part(result.alert, noun: "alert")
        let bubble = part(result.activity, noun: "bubble")
        return "\(alert) \(bubble)"
    }

    private static func part(_ p: APNsTestResult.Part, noun: String) -> String {
        if p.sent { return "The \(noun) was handed to Apple." }
        if let status = p.status, status != 0 { return "Apple refused the \(noun) (status \(status))." }
        return "No \(noun) was sent: the box has no token for it yet."
    }
}

/// Registers this phone's push tokens and choices with the box, and holds what Settings shows (S22).
///
/// The rules: nothing is registered, and no push token is requested from ActivityKit, until the owner opted into at
/// least one bubble AND the box answered that push is on (`pushTokensEnabled`). The notification permission is asked
/// only when Notifications is on. The box's answer is remembered between runs so the lock-screen host starts with the
/// right setting. Failures never reach the screen on their own; Settings shows the last one in Diagnostics.
@MainActor
@Observable
public final class PushRegistrar {
    /// Nil until the box answered. `false` means the box has push off (404 or `enabled:false`).
    public private(set) var serverEnabled: Bool?
    public private(set) var diagnostics: PushDiagnostics
    public private(set) var testSentence: String?
    public private(set) var isTesting = false

    /// Tells the lock-screen host whether to request push tokens (set by the app session).
    @ObservationIgnored public var onGateChange: (@MainActor (Bool) -> Void)?

    @ObservationIgnored private var api: (any PushServing)?
    @ObservationIgnored private let platform: any RemoteNotificationPlatform
    @ObservationIgnored private var state: any PushStateStoring
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var preferences = LockScreenPreferences.allOff
    @ObservationIgnored private var deviceToken: String?
    @ObservationIgnored private var pushToStart: [ActivityKind: String] = [:]
    @ObservationIgnored private var activities: [ActivityKind: (id: String, token: String, startedAt: Date?)] = [:]
    @ObservationIgnored private let topic: String?

    public init(
        platform: any RemoteNotificationPlatform, topic: String? = Bundle.main.bundleIdentifier, state: any PushStateStoring = InMemoryPushState(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.platform = platform
        self.topic = topic
        self.state = state
        self.now = now
        serverEnabled = state.serverEnabled
        diagnostics = PushDiagnostics(serverEnabled: state.serverEnabled, environment: platform.environment, lastPushReceived: state.lastPushReceivedAt)
    }

    /// Request push tokens from ActivityKit: the owner wants some push AND the box has it on.
    public var pushTokensEnabled: Bool { preferences.wantsPush && serverEnabled == true }

    // MARK: lifecycle

    /// The owner's choices at launch, before the box has answered, so `pushTokensEnabled` is right from the first frame.
    public func configure(preferences: LockScreenPreferences) { self.preferences = preferences }

    /// Unpairing: tell the box this phone wants nothing more, then forget it.
    public func forget() async {
        let before = pushTokensEnabled
        let shouldUnregister = preferences.wantsPush || state.pendingOptOut
        preferences = .allOff
        notifyGate(before)
        if shouldUnregister { await unregisterAll() }
        attach(nil)
    }

    /// The BFF client exists (the phone is paired) or is gone (unpaired).
    public func attach(_ api: (any PushServing)?) {
        self.api = api
        if api == nil {
            state.pendingOptOut = false
            setServerEnabled(nil)
        }
    }

    /// The first call after pairing or launch: read the box's answer, then (when it is on and the owner wants push)
    /// register everything known.
    public func start(preferences: LockScreenPreferences) async {
        self.preferences = preferences
        await refreshStatus()
        guard self.preferences.wantsPush else {
            await retryOptOut()
            return
        }
        state.pendingOptOut = false
        guard serverEnabled == true else { return }
        await beginPlatform()
        guard pushTokensEnabled else { return }
        await send(fullRegistration())
        await sendKnownActivities()
    }

    /// Every activity token this run already knows. They arrive from ActivityKit as soon as a bubble starts or is
    /// adopted, which is usually BEFORE the box's answer is read, and the box has just been given a new record (a first
    /// launch or a re-pair): without this the box never learns the bubble's token, can push nothing to it, and the
    /// bubble only ever shows what the app itself draws in the foreground.
    private func sendKnownActivities() async {
        for (kind, activity) in activities {
            await send(
                APNsRegistration(
                    activity: .init(id: activity.id, kind: kind.rawValue, token: activity.token, startedAt: activity.startedAt.map { Int($0.timeIntervalSince1970) }),
                    environment: platform.environment))
        }
    }

    /// The owner changed a choice (the sheet or Settings).
    public func preferencesChanged(_ new: LockScreenPreferences) async {
        let before = pushTokensEnabled
        preferences = new
        if !new.wantsPush {
            state.pendingOptOut = true
            notifyGate(before)
            await retryOptOut()
            return
        }
        state.pendingOptOut = false
        if serverEnabled == nil { await refreshStatus() }
        guard serverEnabled == true else { notifyGate(before); return }
        await beginPlatform()
        await send(APNsRegistration(environment: platform.environment, prefs: APNsRegistration.prefs(new)))
        await sendKnownActivities()
        notifyGate(before)
    }

    /// The system handed the device token to the app delegate.
    public func deviceTokenReceived(_ hex: String) async {
        deviceToken = hex
        diagnostics.deviceTokenRegistered = true
        guard serverEnabled == true, preferences.wantsPush else { return }
        await send(APNsRegistration(deviceToken: hex, environment: platform.environment))
    }

    public func deviceTokenFailed(_ detail: String) {
        diagnostics.lastError = "The system did not give this app a push token. Check Notifications for the app in Settings."
        diagnostics.deviceTokenRegistered = false
    }

    /// ActivityKit tokens and lifetime facts from `ActivityController`.
    public func handle(_ event: PushActivityEvent) async {
        switch event {
        case .pushToStart(let kind, let token):
            pushToStart[kind] = token
            update { $0.requestsPushToStart = pushToStart[.requests] != nil }
            guard serverEnabled == true, preferences.wantsPush else { return }
            await send(APNsRegistration(pushToStartTokens: [kind.rawValue: token], environment: platform.environment))
        case .activityToken(let kind, let id, let token, let startedAt):
            activities[kind] = (id, token, startedAt)
            update { $0.requestsActivityRegistered = activities[.requests] != nil }
            guard serverEnabled == true, preferences.wantsPush else { return }
            await send(
                APNsRegistration(
                    activity: .init(id: id, kind: kind.rawValue, token: token, startedAt: startedAt.map { Int($0.timeIntervalSince1970) }),
                    environment: platform.environment))
        case .activityEnded(let kind, let id, let byUser):
            if activities[kind]?.id == id { activities[kind] = nil }
            update { $0.requestsActivityRegistered = activities[.requests] != nil }
            guard serverEnabled == true else { return }
            try? await api?.apnsUnregister(APNsUnregistration(activityId: id, byUser: byUser ? true : nil))
        }
    }

    /// A push arrived (alert, silent, or an activity update the app learned about).
    public func notePushReceived() {
        let at = now()
        state.lastPushReceivedAt = at
        diagnostics.lastPushReceived = at
    }

    // MARK: Settings

    /// Re-read the box's view of this device (Settings does it when it opens).
    public func refreshStatus() async {
        guard let api else { return }
        do {
            if let status = try await api.apnsStatus(), status.enabled {
                let before = pushTokensEnabled
                setServerEnabled(true)
                let lastPush = status.lastPushAt.map { Date(timeIntervalSince1970: Double($0)) }
                update {
                    $0.deviceTokenRegistered = $0.deviceTokenRegistered || status.registered.deviceToken
                    $0.serverLastPush = Self.describe(lastPush, kind: status.lastPushKind, status: status.lastPushStatus)
                    $0.lastError = status.keyLoaded == false ? "The box has no usable APNs key. Check its journal." : nil
                }
                notifyGate(before)
            } else {
                let before = pushTokensEnabled
                setServerEnabled(false)
                update { $0.serverLastPush = nil }
                notifyGate(before)
            }
        } catch {
            update { $0.lastError = "Could not reach your box to read the push status." }
        }
        let allowed = await currentNotificationsAllowed()
        update { $0.notificationsAllowed = allowed }
    }

    /// The Test push button: the box sends an alert and a bubble update to THIS phone.
    public func sendTest() async {
        guard let api else { return }
        isTesting = true
        defer { isTesting = false }
        do {
            testSentence = PushTestPresentation.sentence(try await api.apnsTest())
        } catch BFFError.envelope(let code, _, _) where code == "rate_limited" {
            testSentence = "Too many test pushes. Wait a minute and try again."
        } catch BFFError.envelope(_, _, 404) {
            testSentence = "Push is not set up on your box yet."
        } catch {
            testSentence = "Could not reach your box to send the test."
        }
    }

    // MARK: plumbing

    @ObservationIgnored private var notificationsAllowedProbe: (@MainActor () async -> Bool?)?

    /// Overridden by the app target to read the real permission; the default says "unknown".
    public func setNotificationsProbe(_ probe: @escaping @MainActor () async -> Bool?) { notificationsAllowedProbe = probe }

    private func currentNotificationsAllowed() async -> Bool? { await notificationsAllowedProbe?() }

    private func beginPlatform() async {
        if preferences.wantsPush {
            let allowed = await platform.requestAuthorization()
            guard preferences.wantsPush else { return }
            if allowed { platform.registerForRemoteNotifications() }
            update { $0.notificationsAllowed = allowed }
        }
    }

    private func fullRegistration() -> APNsRegistration {
        APNsRegistration(
            deviceToken: preferences.wantsPush ? deviceToken : nil,
            pushToStartTokens: pushToStart.isEmpty ? nil : Dictionary(uniqueKeysWithValues: pushToStart.map { ($0.key.rawValue, $0.value) }),
            activity: nil, environment: platform.environment, prefs: APNsRegistration.prefs(preferences))
    }

    private func unregisterAll() async {
        guard let api else { return }
        do {
            try await api.apnsUnregister(APNsUnregistration(all: true))
            state.pendingOptOut = false
        } catch {
            update { $0.lastError = "Could not tell your box this phone turned off Requests." }
        }
        deviceToken = nil
        activities = [:]
        update { $0.deviceTokenRegistered = false; $0.requestsActivityRegistered = false }
    }

    private func retryOptOut() async {
        guard state.pendingOptOut, !preferences.wantsPush else { return }
        await unregisterAll()
    }

    private func send(_ registration: APNsRegistration) async {
        guard let api else { return }
        var registration = registration
        registration.topic = topic
        do {
            try await api.apnsRegister(registration)
            update { $0.lastError = nil }
        } catch {
            update { $0.lastError = "Could not tell your box about this phone's push tokens. Reopen the app to retry." }
        }
    }

    private func setServerEnabled(_ value: Bool?) {
        serverEnabled = value
        state.serverEnabled = value
        update { $0.serverEnabled = value }
    }

    private func notifyGate(_ before: Bool) {
        let after = pushTokensEnabled
        if after != before { onGateChange?(after) }
    }

    private func update(_ change: (inout PushDiagnostics) -> Void) { change(&diagnostics) }

    static func describe(_ at: Date?, kind: String?, status: Int?) -> String? {
        guard let at, let kind else { return nil }
        let when = at.formatted(.relative(presentation: .named))
        return "\(kind), \(status.map { "Apple answered \($0)" } ?? "no answer"), \(when)"
    }
}
