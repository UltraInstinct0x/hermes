import Foundation

/// What the owner chose for the lock screen (S22): three independent bubbles and the notifications. It lives on the
/// phone (`UserDefaults`) and is also sent to the box, which only pushes what the owner asked for.
public struct LockScreenPreferences: Codable, Equatable, Sendable {
    /// The always-on "Hermes" bubble. OFF unless the owner turns it on.
    public var alwaysOn: Bool
    /// The separate approvals and questions bubble (shown only while something waits).
    public var approvals: Bool
    /// Kept for the box and for older stores; it is no longer a choice. A running call is ALWAYS shown: in the always-on
    /// bubble when that is on, by itself when it is off.
    public var call: Bool
    /// Alert notifications (with Approve once and Deny) when the box has something for you.
    public var notifications: Bool

    public init(alwaysOn: Bool = false, approvals: Bool = true, call: Bool = true, notifications: Bool = true) {
        self.alwaysOn = alwaysOn
        self.approvals = approvals
        self.call = call
        self.notifications = notifications
    }

    /// What the first launch sheet suggests: approvals, calls and notifications on, the always-on bubble off.
    public static let suggested = LockScreenPreferences()

    /// Nothing at all (the state before the owner answered, and after "Not now" on the sheet).
    public static let allOff = LockScreenPreferences(alwaysOn: false, approvals: false, call: false, notifications: false)

    /// The owner wants the box to push anything: the only case in which push tokens are requested and sent.
    public var wantsPush: Bool { alwaysOn || approvals || call || notifications }

    /// The always-on bubble morphs into the call bubble whenever it is on (never a second, separate call bubble beside it).
    public var morphsCall: Bool { alwaysOn }
}

/// Where the choices are kept. A seam so the logic is tested without `UserDefaults`.
public protocol LockScreenPreferencesStoring: Sendable {
    /// Nil until the owner has answered the first launch sheet once.
    func load() -> LockScreenPreferences?
    func save(_ preferences: LockScreenPreferences)
}

public final class UserDefaultsLockScreenPreferences: LockScreenPreferencesStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "hermes.lockScreenPreferences.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> LockScreenPreferences? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(LockScreenPreferences.self, from: data)
    }

    public func save(_ preferences: LockScreenPreferences) {
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: key) }
    }
}

public final class InMemoryLockScreenPreferences: LockScreenPreferencesStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: LockScreenPreferences?

    public init(_ value: LockScreenPreferences? = nil) { self.value = value }

    public func load() -> LockScreenPreferences? { lock.withLock { value } }
    public func save(_ preferences: LockScreenPreferences) { lock.withLock { value = preferences } }
}

/// The opt-in state: has the owner answered the first launch sheet, and what is chosen now. Pure, so the
/// "ask once, change later in Settings" rule is tested.
public struct LockScreenChoice: Equatable, Sendable {
    public private(set) var preferences: LockScreenPreferences
    /// The first launch sheet is shown while this is false, and never again after the owner answered it.
    public private(set) var hasAnswered: Bool

    public init(stored: LockScreenPreferences?) {
        preferences = stored ?? .allOff
        hasAnswered = stored != nil
    }

    public var needsFirstLaunchSheet: Bool { !hasAnswered }

    /// "Keep my choices" on the sheet (or "Not now" with `.allOff`).
    public mutating func answer(_ chosen: LockScreenPreferences) {
        preferences = chosen
        hasAnswered = true
    }

    /// A toggle in Settings. Counts as an answer too (it cannot be reached before the sheet, but be safe).
    public mutating func set(_ update: (inout LockScreenPreferences) -> Void) {
        update(&preferences)
        hasAnswered = true
    }
}
