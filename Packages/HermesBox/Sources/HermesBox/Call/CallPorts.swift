import Foundation

// The thin edges of a call. Each is a protocol so the controller is tested with fakes; the iPhone versions live in
// `Call/Apple` (compile-checked only: no simulator runtime here).

/// Capture, echo cancellation and playback on one audio engine. The audio session must already be the `.call` purpose.
@MainActor
public protocol CallAudioIO: AnyObject {
    /// Starts the microphone and the player. `onSamples` gets 16 kHz mono PCM16 samples, on any thread, in order.
    /// `echoCancellation` false is the fallback capture (no voice processing), used when the first start delivered nothing.
    func start(onSamples: @escaping @Sendable ([Int16]) -> Void, echoCancellation: Bool) throws
    func stop()
    /// Queue speech for playback. Chunks of one reply play back to back.
    func play(_ chunk: PlaybackChunk)
    /// Drop whatever is queued and playing, at once.
    func stopPlayback()
    /// Level of the bot's speech, 0...1 (1 = full), reached with a short ramp (about 30 ms). Not the system volume.
    func setPlaybackLevel(_ level: Float)
    var isPlaying: Bool { get }
    /// Called when the last queued chunk has been played.
    var onDrained: (@MainActor () -> Void)? { get set }
    /// The audio route changed under the engine (headphones, Bluetooth): rebuild what the system tore down.
    func routeChanged() throws
    /// Ask the audio session for the speaker or the receiver. Nil gives the choice back to the system (a device is connected).
    func setOutput(_ choice: CallOutputChoice?)
    /// True when the sound goes to something other than the phone's own speaker and receiver (Bluetooth, AirPlay, headphones, a car).
    var hasExternalOutput: Bool { get }
    /// Where the sound really goes now.
    var currentOutput: CallOutputKind { get }
    /// What the microphone really delivers ("48000 Hz, 1 ch, Float32 planar; 312 buffers, 0 unreadable"), for Details.
    var captureDescription: String { get }
    /// Session, route, permission, engine and restart facts, one per line, for Details and Copy details.
    var captureReport: [String] { get }
    /// What the speaker renders, measured as it plays (not when it was received): the RMS of each rendered buffer in dBFS
    /// (silence is -120). Called on the audio thread.
    var onPlaybackLevel: (@Sendable (Double) -> Void)? { get set }
    /// The engine failed in a way the call cannot survive (it would not stay up); the reason is for Copy details.
    var onFailure: (@MainActor (String) -> Void)? { get set }
}

extension CallAudioIO {
    public func setPlaybackLevel(_ level: Float) {}
    public func setOutput(_ choice: CallOutputChoice?) {}
    public var hasExternalOutput: Bool { false }
    public var currentOutput: CallOutputKind { .speaker }
    public var captureDescription: String { "" }
    public var captureReport: [String] { [] }
}

public enum MicrophoneAccess: Sendable, Equatable {
    case granted, denied, undetermined
}

@MainActor
public protocol CallMicrophone: AnyObject {
    func access() -> MicrophoneAccess
    /// Shows the system prompt (with the app's usage string) when undetermined.
    func request() async -> Bool
}

/// The owner's engine choice, remembered on this phone (it is not call state, S19 R36).
public protocol CallPreferences: Sendable {
    func engineChoice() -> CallEngineChoice
    func setEngineChoice(_ choice: CallEngineChoice)
}

public final class InMemoryCallPreferences: CallPreferences, @unchecked Sendable {
    private let lock = NSLock()
    private var value: CallEngineChoice
    public init(_ value: CallEngineChoice = .auto) { self.value = value }
    public func engineChoice() -> CallEngineChoice { lock.withLock { value } }
    public func setEngineChoice(_ choice: CallEngineChoice) { lock.withLock { value = choice } }
}

public struct UserDefaultsCallPreferences: CallPreferences, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "hermes.call.engineChoice"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func engineChoice() -> CallEngineChoice { defaults.string(forKey: key).flatMap(CallEngineChoice.init(rawValue:)) ?? .auto }
    public func setEngineChoice(_ choice: CallEngineChoice) { defaults.set(choice.rawValue, forKey: key) }
}

/// What a Live Activity (P5) needs to draw a call. The controller publishes it on every change.
public struct CallActivitySnapshot: Sendable, Equatable {
    public var callId: String?
    public var botKey: String
    public var botName: String
    public var engine: CallEngine
    public var stateLine: String
    public var startedAt: Date
    public var isMuted: Bool
    public var role: CallRole?
    public var ownerName: String?
    public var caption: String?
    public var waitingRequests: Int
    /// The loudspeaker or a connected device has the sound (not the receiver), and whether the owner may switch it (not while a device is connected).
    public var outputOn: Bool = false
    public var canChooseOutput: Bool = false
}

/// P5 plugs in here (ActivityKit); until then `NoCallActivity` does nothing. Both calls are idempotent.
@MainActor
public protocol CallActivityPresenting: AnyObject {
    func callChanged(_ snapshot: CallActivitySnapshot)
    func callEnded(_ snapshot: CallActivitySnapshot)
}

@MainActor
public final class NoCallActivity: CallActivityPresenting {
    public init() {}
    public func callChanged(_ snapshot: CallActivitySnapshot) {}
    public func callEnded(_ snapshot: CallActivitySnapshot) {}
}

/// The engines of a phone call, like the desktop's Live, Free and Auto (`voice-mode.ts`).
public enum CallEngineChoice: String, Sendable, Equatable, CaseIterable, Identifiable {
    case free
    case live
    case auto

    public var id: String { rawValue }
}

/// Whether the phone can place a call to a machine. Decided by the one probe: a 404 on the upgrade means the BFF has
/// the route off, or does not front the hub for that gateway (S19 section 11).
public enum CallAvailability: Sendable, Equatable {
    case unknown
    case available
    /// "Calls are not enabled on this machine": the Call button is hidden.
    case disabled
    /// The box could not be reached just now: the button stays, a tap says why.
    case unreachable
}

/// A bot as a call needs to name it.
public struct CallBot: Sendable, Equatable {
    public var botKey: String
    public var name: String
    public var gatewayId: String

    public init(botKey: String, name: String, gatewayId: String) {
        self.botKey = botKey
        self.name = name
        self.gatewayId = gatewayId
    }
}

/// One calm sentence, the raw cause behind Copy details only.
public struct CallFailure: Sendable, Equatable {
    public var sentence: String
    public var details: String
    public var canRetry: Bool

    public var calm: CalmFailure { CalmFailure(sentence: sentence, details: details, retry: .reconnect) }

    static func link(_ failure: CallLinkFailure) -> CallFailure {
        switch failure {
        case .disabled:
            return CallFailure(sentence: CallPresentation.disabledSentence, details: "call route answered 404", canRetry: false)
        case .unauthorized:
            return CallFailure(sentence: "Your box did not accept this phone for calls. Check that it is still paired.", details: "call route answered 401 or 403", canRetry: true)
        case .replaced:
            return CallFailure(sentence: "The call moved to another connection of this phone.", details: "close code 4009", canRetry: true)
        case .unreachable(let detail):
            return CallFailure(sentence: "Could not reach the call service. Check that Tailscale is connected, then retry.", details: detail, canRetry: true)
        case .gaveUp(let detail):
            return CallFailure(sentence: "The connection to the call was lost and did not come back. Retry.", details: detail, canRetry: true)
        }
    }

    static func hub(_ code: HubErrorCode) -> CallFailure {
        CallFailure(sentence: code.sentence, details: "hub error \(code.rawValue)", canRetry: code != .unauthorized)
    }

    static let microphoneDenied = CallFailure(
        sentence: "Hermes Neo cannot use the microphone. Allow it in Settings, then try again.", details: "microphone permission denied",
        canRetry: true)

    static let microphoneSilent = CallFailure(
        sentence: "The microphone is not delivering audio. Check Settings, Hermes Neo, Microphone, then retry.",
        details: "no microphone buffers 1.5 s after the audio engine started, with and without echo cancellation", canRetry: true)

    static func audio(_ detail: String) -> CallFailure {
        CallFailure(sentence: "The phone's audio could not start for the call. Retry.", details: detail, canRetry: true)
    }
}
