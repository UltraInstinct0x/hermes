import Foundation
import Testing

@testable import HermesBox

/// The box's VoIP routes, faked (`box/bff/call-owner.mjs`).
private final class FakeCallOwnerBox: CallOwnerServing, @unchecked Sendable {
    private let state = Locked<(registered: [(String, String)], unregistered: Int, topics: [String?])>(([], 0, []))
    var registerError: (any Error)?
    var status: Bool? = true
    var test: Result<TestRingResult, BFFError> = .success(TestRingResult(outcome: "ringing", sent: 1))

    var registered: [(token: String, environment: String)] { state.withLock { $0.registered.map { (token: $0.0, environment: $0.1) } } }
    var unregistered: Int { state.withLock { $0.unregistered } }

    var topics: [String?] { state.withLock { $0.topics } }

    func voipRegister(token: String, environment: String, topic: String?) async throws {
        if let registerError { throw registerError }
        state.withLock {
            $0.registered.append((token, environment))
            $0.topics.append(topic)
        }
    }

    func voipUnregister() async throws { state.withLock { $0.unregistered += 1 } }
    func voipStatus() async throws -> Bool? { status }
    func testRing() async throws -> TestRingResult { try test.get() }
}

private let fakeToken = String(repeating: "ab", count: 32)

/// Records each BFF request and answers 200 `{}`.
private final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    private let recorded = Locked<[URLRequest]>([])
    var requests: [URLRequest] { recorded.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recorded.withLock { $0.append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data("{}".utf8), response)
    }
}

@MainActor
@Suite("S27 VoIP registrar: token to the box only while Calls from your bots is on, Test ring words")
struct VoIPRegistrarTests {
    @Test func offByDefaultNothingReachesTheBox() async {
        let box = FakeCallOwnerBox()
        let registrar = VoIPRegistrar(environment: "sandbox")
        registrar.attach(box)
        await registrar.tokenReceived(fakeToken)
        await registrar.start()
        #expect(!registrar.isEnabled && box.registered.isEmpty)
        #expect(registrar.statusLine == "Off. Your bots cannot ring this phone.")
    }

    @Test func switchingOnRegistersTheTokenWithTheBuildsEnvironment() async {
        let box = FakeCallOwnerBox()
        let store = InMemoryCallsFromBots()
        let registrar = VoIPRegistrar(environment: "production", store: store)
        registrar.attach(box)
        await registrar.tokenReceived(fakeToken)
        await registrar.setEnabled(true)
        #expect(store.enabled)
        #expect(box.registered.map(\.token) == [fakeToken] && box.registered.map(\.environment) == ["production"])
        #expect(registrar.registeredOnBox == true)
        #expect(registrar.statusLine == "On. Your bots can ring this phone.")
    }

    @Test func aBoxThatRefusesTheDeviceCredentialIsReportedSoTheAppPairsAgain() async {
        let box = FakeCallOwnerBox()
        box.registerError = BFFError.envelope(code: "unauthorized", message: "", status: 401)
        let registrar = VoIPRegistrar(environment: "sandbox", topic: "t", store: InMemoryCallsFromBots(enabled: true))
        var refusals = 0
        registrar.onUnauthorized = { refusals += 1 }
        registrar.attach(box)
        await registrar.tokenReceived(fakeToken)
        #expect(refusals == 1)
        box.registerError = BFFError.unreachable(detail: "offline")
        await registrar.retry()
        #expect(refusals == 1, "a box out of reach is not a refusal")
    }

    @Test func theTokenCarriesThisAppsBundleIdAsItsTopic() async {
        let box = FakeCallOwnerBox()
        let registrar = VoIPRegistrar(environment: "sandbox", topic: "dev.supersaiyan.hermesneo", store: InMemoryCallsFromBots(enabled: true))
        registrar.attach(box)
        await registrar.tokenReceived(fakeToken)
        #expect(box.topics == ["dev.supersaiyan.hermesneo"])
    }

    @Test func theRegisterBodyIsTokenEnvironmentAndTopicAndLeavesOutAMissingTopic() async throws {
        let transport = RecordingTransport()
        let client = BFFClient(baseURL: URL(string: "https://box.example.ts.net")!, transport: transport)
        try await client.voipRegister(token: "aa", environment: "sandbox", topic: "dev.supersaiyan.hermesneo")
        try await client.voipRegister(token: "bb", environment: "production", topic: nil)
        let requests = transport.requests
        #expect(requests.map(\.url?.path) == ["/bff/push/voip/register", "/bff/push/voip/register"])
        #expect(requests.map(\.httpMethod) == ["POST", "POST"])
        let bodies = requests.compactMap { $0.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } }
        #expect(bodies == [
            ["token": "aa", "environment": "sandbox", "topic": "dev.supersaiyan.hermesneo"],
            ["token": "bb", "environment": "production"],
        ])
    }

    @Test func aTokenArrivingAfterTheSwitchIsSentOnceAndAChangedOneAgain() async {
        let box = FakeCallOwnerBox()
        let registrar = VoIPRegistrar(environment: "sandbox", store: InMemoryCallsFromBots(enabled: true))
        registrar.attach(box)
        await registrar.start()
        #expect(box.registered.isEmpty && registrar.statusLine == "Waiting for iOS to give this phone a call token.")
        await registrar.tokenReceived(fakeToken)
        await registrar.tokenReceived(fakeToken)
        let changed = String(repeating: "cd", count: 32)
        await registrar.tokenReceived(changed)
        #expect(box.registered.map(\.token) == [fakeToken, changed])
    }

    @Test func switchingOffInvalidationAndUnpairingDeleteTheTokenOnTheBox() async {
        let box = FakeCallOwnerBox()
        let registrar = VoIPRegistrar(environment: "sandbox", store: InMemoryCallsFromBots(enabled: true))
        registrar.attach(box)
        await registrar.tokenReceived(fakeToken)
        await registrar.setEnabled(false)
        #expect(box.unregistered == 1 && registrar.registeredOnBox == false)
        await registrar.setEnabled(true)
        await registrar.tokenInvalidated()
        #expect(box.unregistered == 2 && !registrar.hasToken)
        await registrar.forget()
        #expect(box.unregistered == 3)
    }

    @Test func aBoxWithCallsFromBotsOffSaysSoCalmly() async {
        let box = FakeCallOwnerBox()
        box.registerError = BFFError.envelope(code: "not_found", message: "x", status: 404)
        let registrar = VoIPRegistrar(environment: "sandbox", store: InMemoryCallsFromBots(enabled: true))
        registrar.attach(box)
        await registrar.tokenReceived(fakeToken)
        #expect(registrar.boxSupportsCalls == false && registrar.failure == nil)
        #expect(registrar.statusLine == "On here, but your box does not have calls from bots turned on yet.")
    }

    @Test func anUnreachableBoxIsACalmFailureWithDetailsAndRetry() async {
        let box = FakeCallOwnerBox()
        box.registerError = BFFError.unreachable(detail: "offline")
        let registrar = VoIPRegistrar(environment: "sandbox", store: InMemoryCallsFromBots(enabled: true))
        registrar.attach(box)
        await registrar.tokenReceived(fakeToken)
        #expect(registrar.failure?.sentence == CallOwnerCopy.registerFailed)
        #expect(registrar.failure?.details.contains("offline") == true)
        #expect(!(registrar.failure?.details.contains(fakeToken) ?? true), "the token is never in Copy details")
        box.registerError = nil
        await registrar.retry()
        #expect(registrar.failure == nil && registrar.registeredOnBox == true)
    }

    @Test func theStatusReadsTheBoxsVoipBoolean() async {
        let box = FakeCallOwnerBox()
        let registrar = VoIPRegistrar(environment: "sandbox")
        registrar.attach(box)
        box.status = false
        await registrar.refreshStatus()
        #expect(registrar.registeredOnBox == false && registrar.boxSupportsCalls == true)
        box.status = nil
        await registrar.refreshStatus()
        #expect(registrar.boxSupportsCalls == false)
    }

    @Test(arguments: [
        (TestRingResult(outcome: "ringing", sent: 1), "Your box is ringing this phone now."),
        (TestRingResult(outcome: "ringing", sent: 0), "Your box made the call, but Apple did not take the push. Check Diagnostics."),
        (TestRingResult(outcome: "busy"), "You are already in a call with that bot."),
        (TestRingResult(outcome: "failed"), "Your box could not start the ring. Check that its call service runs."),
    ])
    func testRingOutcomes(_ result: TestRingResult, _ sentence: String) async {
        let box = FakeCallOwnerBox()
        box.test = .success(result)
        let registrar = VoIPRegistrar(environment: "sandbox")
        registrar.attach(box)
        await registrar.sendTestRing()
        #expect(registrar.testSentence == sentence && registrar.testFailure == nil && !registrar.isTesting)
    }

    @Test(arguments: [
        (BFFError.envelope(code: "rate_limited", message: "x", status: 429), "Too many test rings. Wait a while and try again."),
        (BFFError.envelope(code: "not_found", message: "x", status: 404), "Calls from bots are not turned on on your box."),
        (
            BFFError.envelope(code: "bad_request", message: "x", status: 400),
            "Your box has no call token for this phone yet. Turn on Calls from your bots, then try again."
        ),
        (BFFError.unreachable(detail: "tls"), "Could not reach your box to ring this phone. Check that Tailscale is on, then retry."),
    ])
    func testRingErrorsAreCalm(_ error: BFFError, _ sentence: String) async {
        let box = FakeCallOwnerBox()
        box.test = .failure(error)
        let registrar = VoIPRegistrar(environment: "sandbox")
        registrar.attach(box)
        await registrar.sendTestRing()
        #expect(registrar.testFailure?.sentence == sentence)
        #expect(registrar.testFailure?.details.isEmpty == false)
        #expect(!sentence.contains("\u{2014}"), "no em-dashes")
    }

    @Test func noCopyHasEmDashes() {
        let lines = [
            CallOwnerCopy.toggleTitle, CallOwnerCopy.toggleHint, CallOwnerCopy.footnote, CallOwnerCopy.registerFailed, CallOwnerCopy.unregisterFailed,
            RingCopy.triedToReachTitle, RingCopy.triedToReachBody(botName: "hermesbot"),
        ]
        for line in lines { #expect(!line.contains("\u{2014}"), "\(line)") }
    }
}
