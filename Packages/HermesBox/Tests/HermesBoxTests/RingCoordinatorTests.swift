import Foundation
import Testing

@testable import HermesBox

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let ringUUID = UUID(uuidString: testCallId)!

/// Poll a main-actor condition (up to 3 s of real time).
@MainActor
private func until(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<300 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

/// CallKit's provider, faked: records reports and ends; the report callback runs at once or when the test says.
@MainActor
private final class FakeRingProvider: RingCallProvider {
    private(set) var reports: [(uuid: UUID, name: String)] = []
    private(set) var ended: [(uuid: UUID, reason: RingEndedReason)] = []
    var error: RingReportError?
    var deferCallback = false
    private var pending: [@MainActor () -> Void] = []
    let log: EventLog

    init(log: EventLog) { self.log = log }

    func reportIncoming(uuid: UUID, callerName: String, completion: @escaping @MainActor (RingReportError?) -> Void) {
        reports.append((uuid, callerName))
        log.add("report")
        let error = self.error
        if deferCallback { pending.append { completion(error) } } else { completion(error) }
    }

    func reportEnded(uuid: UUID, reason: RingEndedReason) {
        ended.append((uuid, reason))
        log.add("ended \(reason.rawValue)")
    }

    func runCallbacks() {
        let callbacks = pending
        pending = []
        for callback in callbacks { callback() }
    }
}

@MainActor
private final class EventLog {
    private(set) var events: [String] = []
    func add(_ event: String) { events.append(event) }
}

/// The phone's call, faked at the ring seam.
@MainActor
private final class FakeRingCalls: RingCallHandling {
    var isInCall = false
    var onCallEnded: (@MainActor (String?) -> Void)?
    var outcome = RingAnswerOutcome.answered
    private(set) var answered: [(bot: CallBot, callId: String)] = []
    private(set) var ends = 0
    private(set) var mutes: [Bool] = []
    private(set) var audioActivations = 0
    private(set) var audioDeactivations = 0
    let log: EventLog

    init(log: EventLog) { self.log = log }

    func answerRing(bot: CallBot, callId: String, timeout: Duration) async -> RingAnswerOutcome {
        log.add("answerRing")
        answered.append((bot, callId))
        if outcome == .answered { isInCall = true }
        return outcome
    }

    func end() {
        ends += 1
        log.add("end")
    }

    func setMuted(_ muted: Bool) { mutes.append(muted) }
    func systemAudioActivated() { audioActivations += 1 }
    func systemAudioDeactivated() { audioDeactivations += 1 }
}

private final class FakeRingNotifier: RingNotifying, @unchecked Sendable {
    private let names = Locked<[String]>([])
    var told: [String] { names.withLock { $0 } }
    func triedToReach(botName: String) async { names.withLock { $0.append(botName) } }
}

/// Hands out fake links in order (the first one a ring asks for is its watch).
@MainActor
private final class LinkQueue {
    private(set) var made: [FakeCallLink] = []
    private(set) var gateways: [String] = []
    func make(_ gatewayId: String) -> (any CallLink)? {
        gateways.append(gatewayId)
        let link = FakeCallLink()
        made.append(link)
        return link
    }
}

@MainActor
private final class Rig {
    let log = EventLog()
    let provider: FakeRingProvider
    let calls: FakeRingCalls
    let notifier = FakeRingNotifier()
    let links = LinkQueue()
    let time = ManualTimeSource()
    var enabled = true
    var keptAlive: [String] = []
    var released = 0
    var coordinator: RingCoordinator!

    init() {
        provider = FakeRingProvider(log: log)
        calls = FakeRingCalls(log: log)
        coordinator = RingCoordinator(
            provider: provider, calls: calls, makeLink: { [links] in links.make($0) }, notifier: notifier,
            callsEnabled: { [weak self] in self?.enabled ?? false }, callerName: { "Hermes \($0.botName)" },
            keepAlive: { [weak self] why in
                self?.keptAlive.append(why)
                return { [weak self] in self?.released += 1 }
            }, time: time, now: { t0 })
    }

    func ring(_ payload: [AnyHashable: Any] = ringPayload()) -> Locked<Int> {
        let completions = Locked(0)
        coordinator.receive(payload) {
            self.log.add("completion")
            completions.withLock { $0 += 1 }
        }
        return completions
    }

    var watch: FakeCallLink? { links.made.first }
}

@MainActor
@Suite("S27 ring coordinator: report every push, answer early, decline, watch, expire (fake CallKit, fake hub)")
struct RingCoordinatorTests {
    @Test func everyPushIsReportedAndCompletionWaitsForCallKitsAnswer() async {
        let rig = Rig()
        rig.provider.deferCallback = true
        let completions = rig.ring()
        #expect(rig.provider.reports.count == 1, "reported inside the PushKit callback")
        #expect(rig.provider.reports.first?.uuid == ringUUID, "the hub call id is the CallKit UUID")
        #expect(rig.provider.reports.first?.name == "Hermes Hermes Bot")
        #expect(completions.withLock { $0 } == 0, "PushKit's completion waits for the report callback")
        rig.provider.runCallbacks()
        #expect(completions.withLock { $0 } == 1)
        #expect(rig.log.events == ["report", "completion"])
        #expect(rig.coordinator.activeCallIds == [testCallId])
        #expect(rig.links.gateways == ["oracle"], "the ring is watched on its machine's hub")
    }

    @Test func anUnreadablePushIsStillReportedThenEndedAtOnce() {
        let rig = Rig()
        let completions = rig.ring(["hermes": ["v": 1, "kind": "ring"]])
        #expect(rig.provider.reports.count == 1 && rig.provider.reports[0].name == "Hermes Bot")
        #expect(rig.provider.reports[0].uuid != ringUUID)
        #expect(rig.provider.ended.map(\.reason) == [.failed])
        #expect(rig.provider.ended[0].uuid == rig.provider.reports[0].uuid)
        #expect(completions.withLock { $0 } == 1 && rig.log.events == ["report", "ended failed", "completion"])
        #expect(rig.coordinator.activeCallIds.isEmpty)
    }

    @Test func aLatePushIsReportedThenEndedUnanswered() {
        let rig = Rig()
        _ = rig.ring(ringPayload(expiresAt: 1_799_999_990))
        #expect(rig.provider.reports.count == 1)
        #expect(rig.provider.ended.map(\.reason) == [.unanswered])
        #expect(rig.links.made.isEmpty, "nothing to watch")
    }

    @Test func aPushWhileBusyInACallIsReportedThenEndedWithoutDeclining() {
        let rig = Rig()
        rig.calls.isInCall = true
        _ = rig.ring()
        #expect(rig.provider.ended.map(\.reason) == [.unanswered])
        #expect(rig.links.made.isEmpty, "busy is not a decline: the box's ring times out on its own")
    }

    @Test func callsSwitchedOffStillReportsThenEnds() {
        let rig = Rig()
        rig.enabled = false
        _ = rig.ring()
        #expect(rig.provider.reports.count == 1 && rig.provider.ended.map(\.reason) == [.failed])
    }

    @Test func aDuplicatePushForARingingCallIsReportedUnderTheSameUUIDAndNothingEnds() {
        let rig = Rig()
        _ = rig.ring()
        rig.provider.error = .callUUIDAlreadyExists
        let second = rig.ring()
        #expect(rig.provider.reports.map(\.uuid) == [ringUUID, ringUUID])
        #expect(rig.provider.ended.isEmpty, "the ringing call is untouched")
        #expect(second.withLock { $0 } == 1)
        #expect(rig.coordinator.activeCallIds == [testCallId])
    }

    @Test func aLateCopyOfADeclinedRingIsEndedUnderAFreshUUID() async {
        let rig = Rig()
        _ = rig.ring()
        var fulfilled = 0
        rig.coordinator.end(ringUUID) { fulfilled += 1 }
        #expect(fulfilled == 1)
        _ = rig.ring()
        #expect(rig.provider.reports.count == 2)
        #expect(rig.provider.reports[1].uuid != ringUUID, "never rings the declined call again")
        #expect(rig.provider.ended.map(\.reason) == [.remoteEnded])
    }

    @Test func callKitNotShowingARingTellsTheOwnerCalmly() async {
        let rig = Rig()
        rig.provider.error = .unknown
        _ = rig.ring()
        #expect(await until { rig.notifier.told == ["Hermes Hermes Bot"] })
        #expect(rig.coordinator.activeCallIds.isEmpty)
    }

    @Test func doNotDisturbFilteringStaysQuiet() async {
        let rig = Rig()
        rig.provider.error = .filteredByDoNotDisturb
        _ = rig.ring()
        await settle()
        #expect(rig.notifier.told.isEmpty && rig.provider.ended.isEmpty && rig.coordinator.activeCallIds.isEmpty)
    }

    // MARK: answer

    @Test func answerFulfilsFirstThenJoinsAndTakes() async {
        let rig = Rig()
        _ = rig.ring()
        var order: [String] = []
        rig.coordinator.answer(ringUUID, fulfill: { order.append("fulfill"); rig.log.add("fulfill") }, fail: { order.append("fail") })
        #expect(order == ["fulfill"])
        #expect(rig.calls.answered.isEmpty, "the take comes after the fulfilment")
        #expect(await until { rig.calls.answered.count == 1 })
        #expect(rig.log.events.suffix(2) == ["fulfill", "answerRing"])
        #expect(rig.calls.answered[0].callId == testCallId && rig.calls.answered[0].bot.gatewayId == "oracle")
        #expect(rig.calls.answered[0].bot.name == "Hermes Hermes Bot")
        #expect(rig.coordinator.isAnswered(ringUUID))
        #expect(rig.provider.ended.isEmpty)
        #expect(rig.watch?.closed == 1, "the watch socket closes at the answer")
        #expect(rig.keptAlive == ["answer"] && rig.released == 1)
    }

    @Test func aFailedTakeEndsTheCallFailedWithACalmNotification() async {
        let rig = Rig()
        rig.calls.outcome = .failed(detail: "not_found")
        _ = rig.ring()
        rig.coordinator.answer(ringUUID, fulfill: {}, fail: {})
        #expect(await until { rig.provider.ended.count == 1 })
        #expect(rig.provider.ended[0].uuid == ringUUID && rig.provider.ended[0].reason == .failed)
        #expect(await until { rig.notifier.told == ["Hermes Hermes Bot"] })
        #expect(rig.coordinator.activeCallIds.isEmpty)
    }

    @Test func answeringAnUnknownCallFailsTheAction() {
        let rig = Rig()
        var failed = 0
        rig.coordinator.answer(UUID(), fulfill: {}, fail: { failed += 1 })
        #expect(failed == 1)
    }

    @Test func audioWaitsForDidActivate() async {
        let rig = Rig()
        _ = rig.ring()
        rig.coordinator.answer(ringUUID, fulfill: {}, fail: {})
        await settle()
        #expect(rig.calls.audioActivations == 0, "nothing starts before CallKit activated the session")
        rig.coordinator.audioActivated()
        #expect(await until { rig.calls.audioActivations >= 1 })
    }

    @Test func audioStartsAfterTheBoundedWaitWhenDidActivateNeverComes() async {
        let rig = Rig()
        _ = rig.ring()
        rig.coordinator.answer(ringUUID, fulfill: {}, fail: {})
        // The bounded wait is armed (under load the task may run late: advancing before it would skip it).
        #expect(await until { rig.time.sleeperCount >= 1 })
        #expect(rig.calls.audioActivations == 0)
        await rig.time.advance(by: .seconds(2))
        #expect(rig.calls.audioActivations == 0)
        await rig.time.advance(by: .seconds(1))
        #expect(await until { rig.calls.audioActivations == 1 })
    }

    @Test func theHubEndingTheAnsweredCallEndsTheCallKitCall() async {
        let rig = Rig()
        _ = rig.ring()
        rig.coordinator.answer(ringUUID, fulfill: {}, fail: {})
        #expect(await until { rig.calls.answered.count == 1 })
        await settle()
        rig.calls.isInCall = false
        rig.calls.onCallEnded?(testCallId)
        #expect(rig.provider.ended.map(\.reason) == [.remoteEnded])
    }

    // MARK: end, decline, mute

    @Test func declineSendsRingDeclineToTheHubAndKeepsCallKitsOwnEnd() async {
        let rig = Rig()
        _ = rig.ring()
        guard let watch = rig.watch else { Issue.record("no watch"); return }
        watch.pushHello(Hub.helloOk(calls: [Hub.summary(owner: nil)]))
        await settle()
        var fulfilled = 0
        rig.coordinator.end(ringUUID) { fulfilled += 1 }
        #expect(fulfilled == 1)
        #expect(await until { watch.messages.contains(.ringDecline(id: "decline", callId: testCallId)) })
        #expect(rig.provider.ended.isEmpty, "CallKit ends it through its own action")
        #expect(rig.keptAlive == ["decline"])
        watch.pushInbound(Hub.text(["type": "ring.declined", "id": "decline", "call_id": testCallId]))
        #expect(await until { watch.closed == 1 })
        #expect(await until { rig.time.sleeperCount >= 1 }, "the decline's close timer is armed")
        await rig.time.advance(by: .seconds(5))
        #expect(await until { rig.released == 1 })
    }

    @Test func aDeclineBeforeTheWatchIsUpGoesOutOnceItIs() async {
        let rig = Rig()
        _ = rig.ring()
        rig.coordinator.end(ringUUID) {}
        await settle()
        guard let watch = rig.watch else { Issue.record("no watch"); return }
        #expect(watch.messages.isEmpty)
        watch.pushHello(Hub.helloOk(calls: [Hub.summary(owner: nil)]))
        #expect(await until { watch.messages == [.ringDecline(id: "decline", callId: testCallId)] })
    }

    @Test func hangingUpAnAnsweredCallEndsTheHubCall() async {
        let rig = Rig()
        _ = rig.ring()
        rig.coordinator.answer(ringUUID, fulfill: {}, fail: {})
        #expect(await until { rig.calls.answered.count == 1 })
        rig.coordinator.end(ringUUID) {}
        #expect(rig.calls.ends == 1)
        #expect(rig.watch?.messages.isEmpty == true, "a hang-up is no decline")
    }

    @Test func muteWorksOnlyOnAnAnsweredCall() async {
        let rig = Rig()
        _ = rig.ring()
        var failed = 0
        var fulfilled = 0
        rig.coordinator.setMuted(ringUUID, muted: true, fulfill: { fulfilled += 1 }, fail: { failed += 1 })
        #expect(failed == 1 && rig.calls.mutes.isEmpty)
        rig.coordinator.answer(ringUUID, fulfill: {}, fail: {})
        rig.coordinator.setMuted(ringUUID, muted: true, fulfill: { fulfilled += 1 }, fail: { failed += 1 })
        #expect(fulfilled == 1 && rig.calls.mutes == [true])
    }

    // MARK: the watch and the expiry

    @Test func aRingThatIsGoneOnTheBoxStopsRingingAtOnce() async {
        let rig = Rig()
        _ = rig.ring()
        rig.watch?.pushHello(Hub.helloOk(calls: []))
        #expect(await until { rig.provider.ended.map(\.reason) == [.remoteEnded] })
        #expect(rig.coordinator.activeCallIds.isEmpty)
    }

    @Test func aRingAnsweredOnTheDesktopEndsAnsweredElsewhere() async {
        let rig = Rig()
        _ = rig.ring()
        rig.watch?.pushHello(Hub.helloOk(calls: [Hub.summary(owner: nil)]))
        await settle()
        #expect(rig.provider.ended.isEmpty)
        rig.watch?.pushInbound(Hub.state(role: nil, epoch: 1, call: Hub.summary(owner: "desktop")))
        #expect(await until { rig.provider.ended.map(\.reason) == [.answeredElsewhere] })
    }

    @Test func theBoxEndingTheRingUnansweredEndsItHere() async {
        let rig = Rig()
        _ = rig.ring()
        rig.watch?.pushHello(Hub.helloOk(calls: [Hub.summary(owner: nil)]))
        rig.watch?.pushInbound(Hub.state(role: nil, epoch: 0, call: Hub.summary(state: "ended", owner: nil, ended: "no_answer")))
        #expect(await until { rig.provider.ended.map(\.reason) == [.unanswered] })
    }

    @Test func withoutTheBoxTheRingStopsAtItsExpiry() async {
        let rig = Rig()
        _ = rig.ring()
        rig.watch?.push(.failed(.unreachable(detail: "no tailscale")))
        #expect(await until { rig.time.sleeperCount >= 1 }, "the expiry timer is armed")
        await rig.time.advance(by: .seconds(45))
        #expect(rig.provider.ended.isEmpty)
        await rig.time.advance(by: .seconds(1))
        #expect(await until { rig.provider.ended.map(\.reason) == [.unanswered] })
        #expect(rig.coordinator.activeCallIds.isEmpty)
    }

    @Test func providerResetClearsEverything() async {
        let rig = Rig()
        _ = rig.ring()
        rig.coordinator.answer(ringUUID, fulfill: {}, fail: {})
        #expect(await until { rig.calls.isInCall })
        rig.coordinator.reset()
        #expect(rig.coordinator.activeCallIds.isEmpty)
        #expect(rig.calls.ends == 1)
        await rig.time.advance(by: .seconds(60))
        #expect(rig.provider.ended.isEmpty, "a reset call is not reported again")
    }
}
