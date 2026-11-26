import Foundation
import Observation

/// Why the app holds the audio session. Exactly one purpose at a time.
public enum AudioPurpose: Equatable, Sendable {
    /// The microphone is open for dictation: `playAndRecord`, only for this.
    case dictation
    /// A reply is being read aloud: `playback` with the spoken-audio mode, ducking other audio.
    case spokenReply
    /// A voice call: `playAndRecord` in the voice-chat mode (echo cancellation), held from the start of the call to its
    /// end so the app keeps running with the screen locked (UIBackgroundModes `audio`).
    case call
}

/// What the system tells the app about its audio session, reduced to what voice reacts to.
public enum AudioSessionEvent: Equatable, Sendable {
    /// A call, an alarm or another app took the audio. Recording and speech must stop.
    case interruptionBegan
    /// The interruption is over. `shouldResume` is the system's hint; the mic is never resumed on its own.
    case interruptionEnded(shouldResume: Bool)
    /// The route lost its device (headphones pulled, Bluetooth gone): the microphone changed under us.
    case routeLost
    /// A device joined or the route was reconfigured: nothing was lost, but where the sound goes may have changed.
    case routeChanged
    /// The audio daemon restarted: everything must be set up again.
    case servicesReset
}

/// The thin edge over `AVAudioSession`. The real one lives in `AppleVoice.swift` (iOS only); tests use a fake.
@MainActor
public protocol AudioSessionDriver: AnyObject {
    func activate(_ purpose: AudioPurpose) throws
    /// Gives the session back so other apps' audio resumes.
    func deactivate() throws
    /// A fresh stream of system events for the lifetime of the driver.
    func events() -> AsyncStream<AudioSessionEvent>
    /// S27: set the category and mode for `purpose` WITHOUT activating the session. CallKit activates it (and tells the
    /// app in `provider(_:didActivate:)`); an app that activates it itself before that gets a silent call.
    func configure(_ purpose: AudioPurpose) throws
    /// Hermes Neo: a CallKit call is over here. The session stays CallKit's to deactivate, but whatever the app holds
    /// for it (the coordinator's `.call` role) is given back.
    func systemSessionEnded()
}

extension AudioSessionDriver {
    public func configure(_ purpose: AudioPurpose) throws {}
    public func systemSessionEnded() {}
}

/// Owns the one audio session of the app: who holds it, hand-over between dictation and speech, and the
/// system events fanned out to every listener. Nothing leaks between modes: a purpose that does not hold the
/// session cannot release it, and starting dictation ends speech first.
@MainActor
@Observable
public final class VoiceAudioSession {
    public private(set) var holder: AudioPurpose?
    /// S27: the system (CallKit) activates and deactivates the session for the current holder, not this app.
    public private(set) var isSystemActivated = false

    @ObservationIgnored private let driver: any AudioSessionDriver
    @ObservationIgnored private var listeners: [UUID: AsyncStream<AudioSessionEvent>.Continuation] = [:]
    @ObservationIgnored private var pump: Task<Void, Never>?
    /// Called, synchronously, when a purpose is displaced by another one (speech yields to dictation).
    @ObservationIgnored private var displacedHandlers: [UUID: @MainActor (AudioPurpose) -> Void] = [:]

    public init(driver: any AudioSessionDriver) {
        self.driver = driver
        let source = driver.events()
        pump = Task { [weak self] in
            for await event in source { self?.fanOut(event) }
        }
    }

    isolated deinit { pump?.cancel() }

    /// Registers what to do when a purpose loses the session to another one. Returns the token to remove it.
    public func addDisplacedHandler(_ handler: @escaping @MainActor (AudioPurpose) -> Void) -> UUID {
        let id = UUID()
        displacedHandlers[id] = handler
        return id
    }

    public func removeDisplacedHandler(_ id: UUID) { displacedHandlers[id] = nil }

    /// Takes the session for `purpose`. Throws when the system refuses (the caller shows a calm sentence).
    public func begin(_ purpose: AudioPurpose) throws {
        if let current = holder, current != purpose {
            for handler in Array(displacedHandlers.values) { handler(current) }
        }
        // The displaced owner calls `end` itself; whatever is left is released by the new activation.
        try driver.activate(purpose)
        holder = purpose
        isSystemActivated = false
    }

    /// S27, a CallKit call: takes the session for `purpose` and sets its category, but leaves activation (and the
    /// deactivation at the end) to the system. `provider(_:didActivate:)` is the moment audio may start.
    public func adoptSystemActivated(_ purpose: AudioPurpose) throws {
        if let current = holder, current != purpose {
            for handler in Array(displacedHandlers.values) { handler(current) }
        }
        try driver.configure(purpose)
        holder = purpose
        isSystemActivated = true
    }

    /// Gives the session back, but only if `purpose` still holds it. A session CallKit activated is left to CallKit.
    public func end(_ purpose: AudioPurpose) {
        guard holder == purpose else { return }
        holder = nil
        if isSystemActivated {
            isSystemActivated = false
            driver.systemSessionEnded()
            return
        }
        try? driver.deactivate()
    }

    /// A new stream of system events; it ends when the caller stops iterating.
    public func events() -> AsyncStream<AudioSessionEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            listeners[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.listeners[id] = nil }
            }
        }
    }

    private func fanOut(_ event: AudioSessionEvent) {
        if event == .servicesReset {
            holder = nil
            isSystemActivated = false
        }
        for continuation in listeners.values { continuation.yield(event) }
    }
}
