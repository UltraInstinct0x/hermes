import Foundation

/// Whether this phone receives request Live Activities.
public struct LockScreenPreferences: Codable, Equatable, Sendable {
    public var approvals: Bool

    public init(approvals: Bool = false) {
        self.approvals = approvals
    }

    public static let suggested = LockScreenPreferences(approvals: true)

    public static let allOff = LockScreenPreferences()

    /// The owner wants the box to push anything: the only case in which push tokens are requested and sent.
    public var wantsPush: Bool { approvals }

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
