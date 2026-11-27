#if os(iOS)
import AVFoundation
import CallKit
import HermesBox
import UIKit
import UserNotifications

/// CallKit for a ring the box started: one `CXProvider`, its delegate on the main queue, every
/// action and audio-session callback handed to `RingCoordinator`, which decides. No decisions live
/// here. Ported from Hermes Bot (`ios/HermesBot/CallKitHost.swift`).
///
/// The provider set-up, the error mapping and the `providerDidReset` / `timedOutPerforming` handling
/// are adapted from kaishi00/hermes-conduit (MIT, Copyright (c) 2026 kaishi00),
/// `Conduit/Voice/HermesNativeCalls.swift`. See Packages/HermesBox/NOTICE.md.
@MainActor
final class NeoCallKitHost: NSObject, RingCallProvider {
    private let provider: CXProvider
    /// Set right after the coordinator is built (it needs this host first).
    weak var coordinator: RingCoordinator?

    override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        // A Bot's call shows in the Phone app's Recents, like any missed or answered call.
        configuration.includesCallsInRecents = true
        // The Hermes ringtone, at the root of the app bundle (App/Calls/hermes-ring.caf).
        configuration.ringtoneSound = "hermes-ring.caf"
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    func reportIncoming(uuid: UUID, callerName: String, completion: @escaping @MainActor (RingReportError?) -> Void) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.localizedCallerName = callerName
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        provider.reportNewIncomingCall(with: uuid, update: update, completion: Self.reportCompletion(completion))
    }

    /// CallKit calls the report completion on a queue of its own: the closure is built here,
    /// nonisolated, and hops to the main actor explicitly.
    nonisolated private static func reportCompletion(
        _ completion: @escaping @MainActor (RingReportError?) -> Void
    ) -> @Sendable ((any Error)?) -> Void {
        { error in
            let mapped = reportError(error)
            Task { @MainActor in completion(mapped) }
        }
    }

    func reportEnded(uuid: UUID, reason: RingEndedReason) {
        provider.reportCall(with: uuid, endedAt: Date(), reason: Self.endedReason(reason))
    }

    nonisolated static func reportError(_ error: (any Error)?) -> RingReportError? {
        guard let error else { return nil }
        switch (error as? CXErrorCodeIncomingCallError)?.code {
        case .callUUIDAlreadyExists?: return .callUUIDAlreadyExists
        case .filteredByDoNotDisturb?: return .filteredByDoNotDisturb
        case .filteredByBlockList?: return .filteredByBlockList
        case .unentitled?: return .unentitled
        default: return .unknown
        }
    }

    static func endedReason(_ reason: RingEndedReason) -> CXCallEndedReason {
        switch reason {
        case .failed: .failed
        case .remoteEnded: .remoteEnded
        case .unanswered: .unanswered
        case .answeredElsewhere: .answeredElsewhere
        case .declinedElsewhere: .declinedElsewhere
        }
    }
}

extension NeoCallKitHost: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated { coordinator?.reset() }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // Delivered on the main queue (`setDelegate(self, queue: .main)`), where the action is used and finished.
        nonisolated(unsafe) let action = action
        MainActor.assumeIsolated {
            guard let coordinator else { return action.fail() }
            coordinator.answer(action.callUUID, fulfill: { action.fulfill() }, fail: { action.fail() })
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        nonisolated(unsafe) let action = action
        MainActor.assumeIsolated {
            guard let coordinator else { return action.fulfill() }
            coordinator.end(action.callUUID, fulfill: { action.fulfill() })
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        nonisolated(unsafe) let action = action
        MainActor.assumeIsolated {
            guard let coordinator else { return action.fail() }
            coordinator.setMuted(action.callUUID, muted: action.isMuted, fulfill: { action.fulfill() }, fail: { action.fail() })
        }
    }

    /// The session is CallKit's and live: the call's audio may start (`NeoCallAudio` marks the
    /// `.call` role active, and voice processing goes on, when the controller starts it).
    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            // The call's audio first: it waits for this before it starts anything on the engine.
            NeoBox.shared.callAudio.systemSessionActivated()
            coordinator?.audioActivated()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            NeoBox.shared.callAudio.systemSessionDeactivated()
            coordinator?.audioDeactivated()
        }
    }

    nonisolated func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        action.fail()
    }
}

/// "Hermes Neo tried to reach you": a ring CallKit could not show, or an answer that could not
/// reach the box.
nonisolated struct NeoRingNotifier: RingNotifying {
    func triedToReach(botName: String) async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(botName) tried to reach you"
        content.body = RingCopy.triedToReachBody(botName: botName)
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: "neo.ring.tried.\(UUID().uuidString)", content: content, trigger: nil))
    }
}

/// A little background time while a decline or an answer is on its way to the box (a ring can
/// launch the app in the background). Returns the release.
enum NeoRingBackgroundTime {
    private final class Grant {
        var id = UIBackgroundTaskIdentifier.invalid
        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }

    static func begin(_ name: String) -> @MainActor () -> Void {
        let task = Grant()
        task.id = UIApplication.shared.beginBackgroundTask(withName: "neo.ring.\(name)") { task.end() }
        return { task.end() }
    }
}
#endif
