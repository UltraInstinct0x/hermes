#if os(iOS)
import HermesBox
import PushKit

/// PushKit VoIP pushes. Registered at every launch, also a cold launch by a VoIP push, so iOS can
/// hand the push over; the token goes to the box through `VoIPRegistrar` (only while "Calls from
/// your bots" is on), and every push goes to `RingCoordinator.receive`, which reports it to CallKit
/// before this callback returns: iOS ends an app that leaves a VoIP push unreported, and stops
/// sending it VoIP pushes. No decisions live here. Ported from Hermes Bot
/// (`ios/HermesBot/PushKitHost.swift`).
///
/// The token and invalidation handling is adapted from kaishi00/hermes-conduit (MIT, Copyright (c)
/// 2026 kaishi00), `Conduit/Voice/HermesNativeCalls.swift`. See Packages/HermesBox/NOTICE.md. No
/// relay: the token goes to the owner's own box only.
@MainActor
final class NeoPushKitHost: NSObject, PKPushRegistryDelegate {
    private let registry: PKPushRegistry
    private let coordinator: RingCoordinator
    private let voip: VoIPRegistrar

    init(coordinator: RingCoordinator, voip: VoIPRegistrar) {
        self.coordinator = coordinator
        self.voip = voip
        // The main queue: the coordinator and the CallKit provider live there too.
        registry = PKPushRegistry(queue: .main)
        super.init()
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let hex = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        MainActor.assumeIsolated {
            let voip = self.voip
            Task { await voip.tokenReceived(hex) }
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        MainActor.assumeIsolated {
            let voip = self.voip
            Task { await voip.tokenInvalidated() }
        }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        // Delivered on the main queue (see init), where the payload is read and PushKit's completion
        // is called once CallKit answered the report. EVERY push is reported before this returns.
        nonisolated(unsafe) let info = payload.dictionaryPayload
        nonisolated(unsafe) let done = completion
        MainActor.assumeIsolated {
            coordinator.receive(info, completion: { done() })
        }
    }
}
#endif
