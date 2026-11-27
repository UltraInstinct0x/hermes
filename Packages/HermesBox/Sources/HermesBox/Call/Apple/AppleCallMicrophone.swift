#if os(iOS)
import AVFoundation
import Foundation

/// The system's microphone permission, with the app's usage string in the prompt.
@MainActor
public final class AppleCallMicrophone: CallMicrophone {
    public init() {}

    public func access() -> MicrophoneAccess {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .undetermined
        }
    }

    public func request() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}
#endif
