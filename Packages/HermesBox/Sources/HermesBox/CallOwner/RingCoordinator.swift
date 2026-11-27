import Foundation

// S27 slice 2: the bot rings the owner. PushKit hands a VoIP push to `receive`, CallKit's provider actions come in as
// `answer`, `end`, `setMuted`, and its audio session news as `audioActivated` and `audioDeactivated`. The app target only
// adapts CallKit and PushKit to these calls (`CallKitHost.swift`, `PushKitHost.swift`); every decision is here and in
// `RingDecision`, tested with fakes.
//
// The answer action is fulfilled EARLY, before the hub call is joined and taken: CallKit times out actions it is kept
// waiting on, and a fulfilled answer is what makes CallKit activate the audio session. A take that then fails ends the
// call `failed` and leaves a calm local notification. Audio starts only after `didActivate` (bounded wait, about 3 s).
// The didActivate waiter and the reset handling are adapted from kaishi00/hermes-conduit (MIT, Copyright (c) 2026
// kaishi00), `Conduit/Voice/HermesNativeCalls.swift`. See NOTICE.md.

/// The CallKit provider as the coordinator uses it. The app's `CallKitHost` wraps `CXProvider`; tests use a fake.
@MainActor
public protocol RingCallProvider: AnyObject {
    /// `reportNewIncomingCall`: must be called inside the PushKit callback, for every push. `completion` runs once CallKit
    /// answered, with the error it gave (nil: the call is on screen).
    func reportIncoming(uuid: UUID, callerName: String, completion: @escaping @MainActor (RingReportError?) -> Void)
    /// `reportCall(with:endedAt:reason:)`: the call ended without a CallKit action.
    func reportEnded(uuid: UUID, reason: RingEndedReason)
}

/// The phone's one voice call, as a ring needs it. `CallController` is the real one.
@MainActor
public protocol RingCallHandling: AnyObject {
    var isInCall: Bool { get }
    var onCallEnded: (@MainActor (String?) -> Void)? { get set }
    func answerRing(bot: CallBot, callId: String, timeout: Duration) async -> RingAnswerOutcome
    func end()
    func setMuted(_ muted: Bool)
    func systemAudioActivated()
    func systemAudioDeactivated()
}

extension CallController: RingCallHandling {}

/// The calm local notification after a ring that could not be shown or connected.
public protocol RingNotifying: Sendable {
    func triedToReach(botName: String) async
}

/// The words of a ring. Calm, no em-dashes.
public enum RingCopy {
    /// The caller name of a push that could not be read.
    public static let unknownCaller = "Hermes Bot"
    public static let triedToReachTitle = "Hermes Bot tried to reach you"
    public static func triedToReachBody(botName: String) -> String {
        "\(botName) called, but the call could not connect. Check that Tailscale is on, then call back from the app."
    }
}

@MainActor
public final class RingCoordinator {
    private struct Ring {
        var push: RingPush
        var callerName: String
        var answered = false
        /// The answer reached the hub and this phone owns the call.
        var connected = false
        var watch: RingWatch?
        var expiry: Task<Void, Never>?
    }

    private let provider: any RingCallProvider
    private let calls: any RingCallHandling
    private let makeLink: @MainActor (String) -> (any CallLink)?
    private let notifier: any RingNotifying
    private let callsEnabled: @MainActor () -> Bool
    private let prepare: @MainActor () -> Void
    private let callerName: @MainActor (RingPush) -> String
    private let keepAlive: @MainActor (String) -> (@MainActor () -> Void)
    private let time: any TimeSource
    private let now: @Sendable () -> Date
    private let audioWait: Duration
    private let answerTimeout: Duration

    private var rings: [UUID: Ring] = [:]
    /// Call ids that ended here, newest last (a late copy of their push is ended at once).
    private var finished: [String] = []
    private var declines: [ObjectIdentifier: RingWatch] = [:]
    private var audioActive = false
    private var audioWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - prepare: make sure the paired box is loaded (a cold launch from a push has not restored it yet).
    ///   - callsEnabled: "Calls from your bots" is on AND the phone is paired.
    ///   - keepAlive: ask iOS for background time while a decline or an answer is on its way; returns the release.
    public init(
        provider: any RingCallProvider, calls: any RingCallHandling, makeLink: @escaping @MainActor (String) -> (any CallLink)?,
        notifier: any RingNotifying, callsEnabled: @escaping @MainActor () -> Bool, prepare: @escaping @MainActor () -> Void = {},
        callerName: @escaping @MainActor (RingPush) -> String = { $0.botName },
        keepAlive: @escaping @MainActor (String) -> (@MainActor () -> Void) = { _ in {} }, time: any TimeSource = SystemTimeSource(),
        now: @escaping @Sendable () -> Date = { Date() }, audioWait: Duration = .seconds(3), answerTimeout: Duration = .seconds(20)
    ) {
        self.provider = provider
        self.calls = calls
        self.makeLink = makeLink
        self.notifier = notifier
        self.callsEnabled = callsEnabled
        self.prepare = prepare
        self.callerName = callerName
        self.keepAlive = keepAlive
        self.time = time
        self.now = now
        self.audioWait = audioWait
        self.answerTimeout = answerTimeout
        calls.onCallEnded = { [weak self] callId in self?.callEnded(callId) }
    }

    /// Rings that are ringing or running here (for Settings and tests).
    public var activeCallIds: [String] { rings.values.map(\.push.callId).sorted() }

    public func isAnswered(_ uuid: UUID) -> Bool { rings[uuid]?.answered == true }

    // MARK: PushKit

    /// A VoIP push. Reports it to CallKit before returning, whatever it holds, and calls `completion` once CallKit has
    /// answered the report (iOS kills an app that does not report every VoIP push).
    public func receive(_ payload: [AnyHashable: Any], completion: @escaping @MainActor () -> Void) {
        prepare()
        let push = RingPush.parse(payload)
        let context = RingContext(
            now: now(), callsEnabled: callsEnabled(), inCall: calls.isInCall || rings.values.contains(where: \.answered),
            liveCallIds: Set(rings.values.map(\.push.callId)), finishedCallIds: Set(finished))
        let decision = RingDecision.decide(push, context: context)
        let uuid = decision.reportUUID(for: push)
        let name = push.map(callerName) ?? RingCopy.unknownCaller
        if decision == .ring, let push { rings[uuid] = Ring(push: push, callerName: name) }
        provider.reportIncoming(uuid: uuid, callerName: name) { [weak self] error in
            self?.reported(uuid, push: push, name: name, decision: decision, error: error)
            completion()
        }
    }

    private func reported(_ uuid: UUID, push: RingPush?, name: String, decision: RingDecision, error: RingReportError?) {
        switch RingAfterReport.after(error, decision: decision) {
        case .ringing:
            guard let push else { return }
            if rings[uuid] == nil { rings[uuid] = Ring(push: push, callerName: name) }
            watch(uuid)
            armExpiry(uuid)
        case .endNow(let reason):
            provider.reportEnded(uuid: uuid, reason: reason)
            if let push, decision != .alreadyRinging, rings[uuid] == nil { remember(push.callId) }
        case .notShownTellOwner:
            forget(uuid)
            let notifier = self.notifier
            Task { await notifier.triedToReach(botName: name) }
        case .nothing:
            if decision == .ring { forget(uuid) }
        }
    }

    // MARK: CallKit actions

    /// `CXAnswerCallAction`. Fulfilled at once (CallKit then activates the audio session), then the hub call is joined
    /// and taken. A failed take ends the call `failed` with a calm local notification.
    public func answer(_ uuid: UUID, fulfill: () -> Void, fail: () -> Void) {
        guard var ring = rings[uuid], !ring.answered else { return fail() }
        fulfill()
        ring.answered = true
        ring.expiry?.cancel()
        ring.expiry = nil
        ring.watch?.stop()
        ring.watch = nil
        rings[uuid] = ring
        let bot = CallBot(botKey: ring.push.botKey, name: ring.callerName, gatewayId: ring.push.gatewayId)
        let callId = ring.push.callId
        let release = keepAlive("answer")
        Task { [weak self] in
            await self?.waitForAudio()
            self?.calls.systemAudioActivated()
        }
        Task { [weak self, calls, answerTimeout] in
            let outcome = await calls.answerRing(bot: bot, callId: callId, timeout: answerTimeout)
            self?.answered(uuid, outcome: outcome)
            release()
        }
    }

    private func answered(_ uuid: UUID, outcome: RingAnswerOutcome) {
        guard let ring = rings[uuid] else { return }
        switch outcome {
        case .answered:
            rings[uuid]?.connected = true
            // The call may have ended between the take and this line.
            if !calls.isInCall { finish(uuid, reason: .remoteEnded) }
        case .failed, .busy:
            finish(uuid, reason: .failed)
            let notifier = self.notifier
            Task { await notifier.triedToReach(botName: ring.callerName) }
        }
    }

    /// `CXEndCallAction`: a decline while it rings (the hub ends the ring `declined`), a hang-up once answered.
    public func end(_ uuid: UUID, fulfill: () -> Void) {
        defer { fulfill() }
        guard var ring = rings[uuid] else { return }
        if ring.answered {
            forget(uuid)
            calls.end()
            return
        }
        let watch = ring.watch
        ring.watch = nil
        rings[uuid] = ring
        forget(uuid)
        decline(ring.push, through: watch)
    }

    /// `CXSetMutedCallAction`: only for an answered call.
    public func setMuted(_ uuid: UUID, muted: Bool, fulfill: () -> Void, fail: () -> Void) {
        guard rings[uuid]?.answered == true else { return fail() }
        calls.setMuted(muted)
        fulfill()
    }

    /// `provider(_:didActivate:)`: the audio session is CallKit's and active; the call's audio may start.
    public func audioActivated() {
        audioActive = true
        resumeAudioWaiters()
        if rings.values.contains(where: \.answered) { calls.systemAudioActivated() }
    }

    /// `provider(_:didDeactivate:)`.
    public func audioDeactivated() {
        audioActive = false
        if rings.values.contains(where: \.answered) { calls.systemAudioDeactivated() }
    }

    /// `providerDidReset`: CallKit dropped every call. Everything here is cleared; a running answered call ends.
    public func reset() {
        let answered = rings.values.contains(where: \.answered)
        for uuid in Array(rings.keys) { forget(uuid) }
        audioActive = false
        resumeAudioWaiters()
        if answered, calls.isInCall { calls.end() }
    }

    // MARK: pieces

    private func watch(_ uuid: UUID) {
        guard let ring = rings[uuid], ring.watch == nil, let link = makeLink(ring.push.gatewayId) else { return }
        let watch = RingWatch(link: link, callId: ring.push.callId, time: time) { [weak self] reason in
            self?.ringEndedOnBox(uuid, reason: reason)
        }
        rings[uuid]?.watch = watch
        watch.start()
    }

    private func ringEndedOnBox(_ uuid: UUID, reason: RingEndedReason) {
        guard let ring = rings[uuid], !ring.answered else { return }
        finish(uuid, reason: reason)
    }

    /// A ring nobody answered stops at its expiry, also when the box cannot be reached to say so.
    private func armExpiry(_ uuid: UUID) {
        guard let ring = rings[uuid] else { return }
        let left = max(0, ring.push.expiresAt.timeIntervalSince(now()))
        rings[uuid]?.expiry = Task { [weak self, time] in
            try? await time.sleep(for: .milliseconds(Int(left * 1000)) + .seconds(1))
            guard !Task.isCancelled, let self, let ring = self.rings[uuid], !ring.answered else { return }
            self.finish(uuid, reason: .unanswered)
        }
    }

    private func decline(_ push: RingPush, through watch: RingWatch?) {
        let declining: RingWatch
        if let watch, !watch.isClosed {
            declining = watch
        } else {
            guard let link = makeLink(push.gatewayId) else { return }
            declining = RingWatch(link: link, callId: push.callId, time: time) { _ in }
            declining.start()
        }
        let key = ObjectIdentifier(declining)
        declines[key] = declining
        let release = keepAlive("decline")
        declining.decline { [weak self] in
            self?.declines[key] = nil
            release()
        }
    }

    /// The hub call ended on the call controller (hung up here or elsewhere, the box ended it).
    private func callEnded(_ callId: String?) {
        guard let callId, let entry = rings.first(where: { $0.value.push.callId == callId && $0.value.connected }) else { return }
        finish(entry.key, reason: .remoteEnded)
    }

    private func finish(_ uuid: UUID, reason: RingEndedReason) {
        guard rings[uuid] != nil else { return }
        forget(uuid)
        provider.reportEnded(uuid: uuid, reason: reason)
    }

    private func forget(_ uuid: UUID) {
        guard let ring = rings.removeValue(forKey: uuid) else { return }
        ring.expiry?.cancel()
        ring.watch?.stop()
        remember(ring.push.callId)
    }

    private func remember(_ callId: String) {
        finished.removeAll { $0 == callId }
        finished.append(callId)
        if finished.count > 32 { finished.removeFirst(finished.count - 32) }
    }

    private func waitForAudio() async {
        guard !audioActive else { return }
        let timeout = Task { [weak self, time, audioWait] in
            try? await time.sleep(for: audioWait)
            guard !Task.isCancelled else { return }
            self?.resumeAudioWaiters()
        }
        await withCheckedContinuation { continuation in
            if audioActive {
                continuation.resume()
            } else {
                audioWaiters.append(continuation)
            }
        }
        timeout.cancel()
    }

    private func resumeAudioWaiters() {
        let waiters = audioWaiters
        audioWaiters = []
        for waiter in waiters { waiter.resume() }
    }
}
