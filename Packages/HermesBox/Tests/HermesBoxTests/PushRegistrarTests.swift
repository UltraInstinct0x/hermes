import Foundation
import HermesActivityKit
import Testing

@testable import HermesBox

/// A fake box: records what the phone registers and answers status and test as scripted.
private final class FakeBox: PushServing, @unchecked Sendable {
    private let lock = NSLock()
    private var _registrations: [APNsRegistration] = []
    private var _unregistrations: [APNsUnregistration] = []
    var status: APNsStatus?
    var failRegister = false
    var test = APNsTestResult(alert: .init(sent: true, status: 200, via: nil), activity: .init(sent: true, status: 200, via: "update"))

    var registrations: [APNsRegistration] { lock.withLock { _registrations } }
    var unregistrations: [APNsUnregistration] { lock.withLock { _unregistrations } }

    func apnsStatus() async throws -> APNsStatus? { status }

    func apnsRegister(_ registration: APNsRegistration) async throws {
        if failRegister { throw BFFError.unreachable(detail: "down") }
        lock.withLock { _registrations.append(registration) }
    }

    func apnsUnregister(_ unregistration: APNsUnregistration) async throws { lock.withLock { _unregistrations.append(unregistration) } }
    func apnsTest() async throws -> APNsTestResult { test }
}

@MainActor
private final class FakePlatform: RemoteNotificationPlatform {
    var environment = "sandbox"
    var allow = true
    private(set) var asked = 0
    private(set) var registered = 0
    func requestAuthorization() async -> Bool {
        asked += 1
        return allow
    }

    func registerForRemoteNotifications() { registered += 1 }
}

private func enabledStatus(lastPush: Int? = nil) -> APNsStatus {
    APNsStatus(
        enabled: true, environment: "sandbox", registered: .init(deviceToken: false, pushToStart: false, requests: false),
        prefs: .init(alwaysOn: false, approvals: false, call: false, notifications: false), lastPushAt: lastPush,
        lastPushKind: lastPush == nil ? nil : "requests.update", lastPushStatus: lastPush == nil ? nil : 200, keyLoaded: true)
}

@MainActor
private struct Rig {
    let box = FakeBox()
    let platform = FakePlatform()
    let state = InMemoryPushState()
    let registrar: PushRegistrar

    init(status: APNsStatus? = enabledStatus()) {
        box.status = status
        registrar = PushRegistrar(platform: platform, topic: "dev.supersaiyan.hermesneo", state: state)
        registrar.attach(box)
    }
}

@MainActor
@Suite("S22 push registration: only with the owner's yes AND the box's yes")
struct PushRegistrarTests {
    @Test func checkingAgainAfterTheBoxEnablesPushRegistersTheRequestsPreference() async {
        let rig = Rig(status: nil)
        await rig.registrar.start(preferences: .suggested)
        #expect(rig.box.registrations.isEmpty)

        rig.box.status = enabledStatus()
        await rig.registrar.start(preferences: .suggested)

        #expect(rig.platform.registered == 1)
        #expect(rig.box.registrations.contains { $0.prefs?.approvals == true })
    }

    @Test func nothingIsRegisteredBeforeTheOwnerOptedIn() async {
        let rig = Rig()
        await rig.registrar.start(preferences: .allOff)
        #expect(rig.box.registrations.isEmpty && rig.platform.asked == 0)
        #expect(!rig.registrar.pushTokensEnabled, "no push tokens are requested from ActivityKit")
        await rig.registrar.handle(.pushToStart(kind: .requests, token: "aa"))
        #expect(rig.box.registrations.isEmpty)
    }

    @Test func aBoxWithPushOffKeepsEverythingLocal() async {
        let rig = Rig(status: nil)
        await rig.registrar.start(preferences: .suggested)
        #expect(rig.registrar.serverEnabled == false && !rig.registrar.pushTokensEnabled)
        #expect(rig.box.registrations.isEmpty && rig.platform.asked == 0, "the permission is not asked when nothing can be pushed")
    }

    @Test func optedInWithAPushEnabledBoxRegistersRequestPreferencesAndEnvironment() async {
        let rig = Rig()
        var gate: [Bool] = []
        rig.registrar.onGateChange = { gate.append($0) }
        rig.registrar.configure(preferences: .suggested)
        await rig.registrar.start(preferences: .suggested)
        #expect(rig.registrar.pushTokensEnabled)
        let first = rig.box.registrations.first
        #expect(first?.environment == "sandbox")
        #expect(first?.prefs == .init(alwaysOn: false, approvals: true, call: false, notifications: false))
        #expect(rig.platform.asked == 1 && rig.platform.registered == 1)
        #expect(rig.state.serverEnabled == true, "remembered, so the next launch starts with push tokens from the first frame")
    }

    @Test func aBubbleTokenThatArrivedBeforeTheBoxAnsweredIsRegisteredWhenTheRegistrationStarts() async {
        let rig = Rig()
        rig.registrar.configure(preferences: .suggested)
        // ActivityKit hands out the token of the adopted bubble before the box's status has been read
        await rig.registrar.handle(.activityToken(kind: .requests, id: "request-1", token: "abcd", startedAt: nil))
        #expect(rig.box.registrations.isEmpty, "nothing is sent while the box has not said yes")

        await rig.registrar.start(preferences: LockScreenPreferences(approvals: true))

        let activities = rig.box.registrations.compactMap(\.activity)
        #expect(activities.contains { $0.id == "request-1" && $0.kind == "requests" && $0.token == "abcd" }, "the box learns the bubble's token")
    }

    /// Hermes Neo: the permission (and the device token) are asked for as soon as the owner wants any push, since a
    /// request's Live Activity and the Test notification need them; never while nothing is wanted.
    @Test func theNotificationPermissionIsAskedOnlyWhenSomePushIsWanted() async {
        let rig = Rig()
        await rig.registrar.start(preferences: .allOff)
        #expect(rig.platform.asked == 0 && rig.platform.registered == 0)
        await rig.registrar.preferencesChanged(LockScreenPreferences(approvals: true))
        #expect(rig.platform.asked == 1)
    }

    @Test func aDeniedPermissionDoesNotRegisterForRemoteNotifications() async {
        let rig = Rig()
        rig.platform.allow = false
        await rig.registrar.start(preferences: .suggested)
        #expect(rig.platform.asked == 1 && rig.platform.registered == 0)
    }

    @Test func tokensAreSentWithTheirKindAndTheDeviceTokenOnlyWhenAlertsAreOn() async {
        let rig = Rig()
        await rig.registrar.start(preferences: .suggested)
        await rig.registrar.deviceTokenReceived("dd")
        await rig.registrar.handle(.pushToStart(kind: .requests, token: "r1"))
        await rig.registrar.handle(.pushToStart(kind: .requests, token: "b1"))
        await rig.registrar.handle(.activityToken(kind: .requests, id: "act-1", token: "ba", startedAt: Date(timeIntervalSince1970: 100)))
        let sent = rig.box.registrations
        #expect(sent.contains { $0.deviceToken == "dd" })
        #expect(sent.contains { $0.pushToStartTokens == ["requests": "r1"] })
        #expect(sent.contains { $0.pushToStartTokens == ["requests": "b1"] })
        #expect(sent.contains { $0.activity == .init(id: "act-1", kind: "requests", token: "ba", startedAt: 100) })
        let diag = rig.registrar.diagnostics
        #expect(diag.deviceTokenRegistered && diag.requestsPushToStart && diag.requestsActivityRegistered)

        let quiet = Rig()
        await quiet.registrar.start(preferences: .allOff)
        await quiet.registrar.deviceTokenReceived("dd")
        #expect(!quiet.box.registrations.contains { $0.deviceToken != nil }, "nothing wanted: the device token stays on the phone")
    }

    /// Hermes Neo: every registration names this app as its topic, so the box pushes to Neo and not to Hermes Bot.
    @Test func everyRegistrationCarriesTheAppsTopic() async {
        let rig = Rig()
        await rig.registrar.start(preferences: LockScreenPreferences(approvals: true))
        await rig.registrar.deviceTokenReceived("dd")
        await rig.registrar.handle(.pushToStart(kind: .requests, token: "r1"))
        let sent = rig.box.registrations
        #expect(!sent.isEmpty && sent.allSatisfy { $0.topic == "dev.supersaiyan.hermesneo" })
        #expect(sent.contains { $0.deviceToken == "dd" }, "requests alone are enough to send the device token")
    }

    @Test func endingRequestActivitiesUnregistersTheirIDsWithoutRecordingABaseDismissal() async {
        let rig = Rig()
        await rig.registrar.start(preferences: .suggested)
        await rig.registrar.handle(.activityEnded(kind: .requests, id: "a", byUser: false))
        await rig.registrar.handle(.activityEnded(kind: .requests, id: "b", byUser: false))
        #expect(rig.box.unregistrations == [APNsUnregistration(activityId: "a"), APNsUnregistration(activityId: "b")])
    }

    @Test func turningEverythingOffUnregistersThePhoneAndClosesTheGate() async {
        let rig = Rig()
        var gate: [Bool] = []
        rig.registrar.onGateChange = { gate.append($0) }
        await rig.registrar.start(preferences: .suggested)
        await rig.registrar.preferencesChanged(.allOff)
        #expect(rig.box.unregistrations.contains(APNsUnregistration(all: true)))
        #expect(!rig.registrar.pushTokensEnabled && gate.last == false)
    }

    @Test func theLastLaunchsAnswerOfTheBoxIsRemembered() async {
        let state = InMemoryPushState(serverEnabled: true)
        let registrar = PushRegistrar(platform: FakePlatform(), state: state)
        registrar.configure(preferences: .suggested)
        #expect(registrar.pushTokensEnabled, "before the box has answered this run")
        registrar.configure(preferences: .allOff)
        #expect(!registrar.pushTokensEnabled)
    }

    @Test func aFailedRegistrationIsAFactInDiagnosticsNotAnAlert() async {
        let rig = Rig()
        rig.box.failRegister = true
        await rig.registrar.start(preferences: .suggested)
        #expect(rig.registrar.diagnostics.lastError?.contains("Reopen the app") == true)
        rig.box.failRegister = false
        await rig.registrar.deviceTokenReceived("dd")
        #expect(rig.registrar.diagnostics.lastError == nil)
    }

    @Test func diagnosticsShowTheBoxsLastPushAndWhenOneArrivedHere() async {
        let rig = Rig(status: enabledStatus(lastPush: Int(Date().timeIntervalSince1970) - 120))
        await rig.registrar.start(preferences: .suggested)
        #expect(rig.registrar.diagnostics.serverLastPush?.contains("requests.update") == true)
        #expect(rig.registrar.diagnostics.serverLastPush?.contains("Apple answered 200") == true)
        #expect(rig.registrar.diagnostics.lastPushReceived == nil)
        rig.registrar.notePushReceived()
        #expect(rig.registrar.diagnostics.lastPushReceived != nil && rig.state.lastPushReceivedAt != nil)
    }

    @Test func theTestPushSaysWhatWasSentInCalmWords() async {
        let rig = Rig()
        await rig.registrar.start(preferences: .suggested)
        await rig.registrar.sendTest()
        #expect(rig.registrar.testSentence == "The alert was handed to Apple. The bubble was handed to Apple.")
        rig.box.test = APNsTestResult(alert: .init(sent: false, status: 400, via: nil), activity: .init(sent: false, status: nil, via: nil))
        await rig.registrar.sendTest()
        #expect(rig.registrar.testSentence == "Apple refused the alert (status 400). No bubble was sent: the box has no token for it yet.")
        for text in [rig.registrar.testSentence ?? ""] { #expect(!text.contains("\u{2014}")) }
    }

    @Test func unpairingForgetsThePhoneAtTheBox() async {
        let rig = Rig()
        await rig.registrar.start(preferences: .suggested)
        await rig.registrar.forget()
        #expect(rig.box.unregistrations.contains(APNsUnregistration(all: true)))
        #expect(rig.registrar.serverEnabled == nil)
    }
}
