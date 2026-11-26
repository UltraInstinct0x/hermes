import Foundation

/// The always-on bubble's life, as pure rules (S22). iOS ends a Live Activity after about 8 hours and lets the owner
/// swipe it away; the two look the same from `activityStateUpdates`, so the age tells them apart.
public enum BaseLifetime {
    /// The system limit for a Live Activity (about).
    public static let systemLimit: TimeInterval = 8 * 3600
    /// The box renews the bubble by push-to-start at 7.5 hours (`box/bff/push-planner.mjs`, `BASE_RENEW_AFTER_MS`).
    public static let serverRenewsAfter: TimeInterval = 7.5 * 3600
    /// An end the app did not cause that happens before this age is the owner's dismissal; later it is the system
    /// limit or the server's renewal, which the owner did not ask for. Below the renewal time on purpose.
    public static let userDismissalCutoff: TimeInterval = 7.4 * 3600
}

public enum BaseEndCause: Equatable, Sendable {
    /// The owner swiped it away: do not bring it back until the next launch or an explicit action.
    case user
    /// The 8 hour limit, or the box renewed it: the bubble may be started again.
    case systemOrRenewal
}

public enum BaseEndClassifier {
    /// `endedByApp` is true when the app itself ended it (the owner turned it off, a leftover): never a dismissal.
    public static func classify(startedAt: Date, now: Date, endedByApp: Bool) -> BaseEndCause {
        if endedByApp { return .systemOrRenewal }
        return now.timeIntervalSince(startedAt) < BaseLifetime.userDismissalCutoff ? .user : .systemOrRenewal
    }
}

/// Whether the app may start the always-on bubble. The owner dismissing it is respected: it does not come back
/// until the next app launch or an explicit action (switching it on again, tapping "Show on lock screen").
public struct BaseRestartPolicy: Equatable, Sendable {
    public private(set) var dismissedByUser = false

    public init(dismissedByUser: Bool = false) { self.dismissedByUser = dismissedByUser }

    public mutating func userDismissed() { dismissedByUser = true }
    /// The next app launch.
    public mutating func appLaunched() { dismissedByUser = false }
    /// The owner switched it on again, or asked for it by hand.
    public mutating func explicitlyRequested() { dismissedByUser = false }

    public func mayStart(preferences: LockScreenPreferences) -> Bool { preferences.alwaysOn && !dismissedByUser }
}
