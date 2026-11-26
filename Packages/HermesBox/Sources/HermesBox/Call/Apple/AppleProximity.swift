#if os(iOS)
import Foundation
import UIKit

/// The iPhone's proximity sensor. Watching it makes the system darken the screen when the phone is at the ear, which is what
/// lets a call be held like a phone.
@MainActor
public final class AppleProximity: CallProximitySensing {
    public var onChange: (@MainActor (Bool) -> Void)?
    private var observer: (any NSObjectProtocol)?

    public init() {}

    public func start() {
        guard observer == nil else { return }
        let device = UIDevice.current
        device.isProximityMonitoringEnabled = true
        // A phone without the sensor reports `false` for the setting: nothing then changes.
        guard device.isProximityMonitoringEnabled else { return }
        observer = NotificationCenter.default.addObserver(forName: UIDevice.proximityStateDidChangeNotification, object: device, queue: .main) {
            [weak self] _ in
            let near = UIDevice.current.proximityState
            Task { @MainActor in self?.onChange?(near) }
        }
    }

    public func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        UIDevice.current.isProximityMonitoringEnabled = false
    }
}
#endif
