import Foundation

/// Where the call's sound comes out of the phone itself: the loudspeaker, or the receiver at the top (held to the ear).
public enum CallOutputChoice: Equatable, Sendable {
    case speaker
    case receiver
}

/// Where the sound really goes right now, as the audio session reports it.
public enum CallOutputKind: Equatable, Sendable {
    case speaker
    case receiver
    /// A device other than the phone itself: Bluetooth, AirPlay, headphones, a car.
    case external
}

/// The sound output of a call, decided from three facts and nothing else:
///
/// - what the owner chose (`preference`, the speaker unless they tapped the circle),
/// - whether something other than the phone is connected (`externalDevice`: Bluetooth, AirPlay, headphones, a car), and
/// - whether the phone is at the ear (`nearEar`, the proximity sensor).
///
/// A connected device always wins: the call then asks the system for nothing and the circle is not offered. At the ear the
/// receiver is used and the screen goes dark (the system does that while proximity is watched); away from it the owner's
/// choice returns. Pure, so each rule is tested without a phone.
public struct CallOutputState: Equatable, Sendable {
    public var preference: CallOutputChoice
    public var externalDevice: Bool
    public var nearEar: Bool
    /// What the session says the sound really does (read after each request and each route change).
    public var routeKind: CallOutputKind

    public init(
        preference: CallOutputChoice = .speaker, externalDevice: Bool = false, nearEar: Bool = false, routeKind: CallOutputKind = .speaker
    ) {
        self.preference = preference
        self.externalDevice = externalDevice
        self.nearEar = nearEar
        self.routeKind = routeKind
    }

    /// The route button is filled while the sound is NOT at the ear: the loudspeaker or a connected device is in use.
    public var routeIsFilled: Bool { routeKind != .receiver }

    /// What the call asks of the audio session now. Nil: leave the route to the system (a connected device is in use).
    public var requested: CallOutputChoice? {
        if externalDevice { return nil }
        return nearEar ? .receiver : preference
    }

    /// The proximity sensor is watched while the phone's own speaker or receiver is the output: it darkens the screen at the ear
    /// and moves the sound to the receiver. With a device connected the screen stays on.
    public var watchesProximity: Bool { !externalDevice }

    /// The circle offers the speaker or the receiver only while the phone itself makes the sound.
    public var offersChoice: Bool { !externalDevice }

    /// True while the sound comes out of the loudspeaker.
    public var speakerIsOn: Bool { requested == .speaker }

    /// The owner tapped the circle: speaker and receiver swap. Nothing happens while a device is connected.
    public mutating func toggle() {
        guard offersChoice else { return }
        preference = preference == .speaker ? .receiver : .speaker
    }
}

/// Words for the output control (one place; the views and the lock screen read them).
public enum CallOutputPresentation {
    public static let title = "Sound"

    /// VoiceOver value of the route button.
    public static func routeValue(_ state: CallOutputState) -> String {
        switch state.routeKind {
        case .speaker: "The speaker is on"
        case .receiver: "The phone receiver is on"
        case .external: "A connected device has the sound"
        }
    }
}

/// The proximity sensor, as the call needs it: on while the phone's own output is in use. Near means at the ear.
@MainActor
public protocol CallProximitySensing: AnyObject {
    /// Called with true when the phone is brought to the face and false when it is taken away.
    var onChange: (@MainActor (Bool) -> Void)? { get set }
    /// Watch the sensor. The system darkens the screen while the phone is near.
    func start()
    func stop()
}
