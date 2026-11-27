import Foundation
import os

/// Unified logging for the box half of the app: subsystem is the running app's bundle id.
/// `log show --last 1h --predicate 'subsystem == "dev.supersaiyan.hermesneo" && category == "call"'`
enum HermesLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "HermesBox"
    /// The voice call: audio engine start, speech queue.
    static let call = Logger(subsystem: subsystem, category: "call")
    /// Rings: PushKit, CallKit, the ring coordinator.
    static let ring = Logger(subsystem: subsystem, category: "ring")
}
