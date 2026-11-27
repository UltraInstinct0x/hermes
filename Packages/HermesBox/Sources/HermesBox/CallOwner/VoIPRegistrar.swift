import Foundation
import Observation

/// "Calls from your bots" (S27 R2, R11): the PushKit VoIP token of this phone on the box, and the Test ring button.
///
/// PushKit registers for VoIP pushes at every launch (also a cold launch from a push). The token goes to the box only
/// while the owner has the switch on and the phone is paired; switching it off, unpairing or iOS invalidating the token
/// deletes it on the box, so the box has nothing to ring. The environment (sandbox or production) is the build's own
/// `aps-environment`, the same rule as S22.
@MainActor
@Observable
public final class VoIPRegistrar {
    /// The owner's switch.
    public private(set) var isEnabled: Bool
    /// iOS has given this phone a VoIP token (never shown).
    public private(set) var hasToken = false
    /// The box holds this phone's token. Nil until it answered.
    public private(set) var registeredOnBox: Bool?
    /// False when the box answered that calls from bots are off there (404, or no `voip` in its status).
    public private(set) var boxSupportsCalls: Bool?
    /// The last registration problem, with Retry and Copy details.
    public private(set) var failure: CalmFailure?
    public private(set) var isTesting = false
    public private(set) var testSentence: String?
    public private(set) var testFailure: CalmFailure?

    @ObservationIgnored private var store: any CallsFromBotsStoring
    @ObservationIgnored private let environment: String
    /// The app's bundle id, sent as `topic` so the box pushes to the right app.
    @ObservationIgnored private let topic: String?
    @ObservationIgnored private var api: (any CallOwnerServing)?
    @ObservationIgnored private var token: String?
    /// Hermes Neo: the box refused this phone's device credential (401 or 403). The app drops it, so the next
    /// attempt pairs again on the gateway login.
    @ObservationIgnored public var onUnauthorized: (@MainActor () -> Void)?

    public init(
        environment: String, topic: String? = Bundle.main.bundleIdentifier, store: any CallsFromBotsStoring = InMemoryCallsFromBots()
    ) {
        self.environment = environment
        self.topic = topic
        self.store = store
        isEnabled = store.enabled
    }

    /// Paired (the BFF client) or unpaired (nil).
    public func attach(_ api: (any CallOwnerServing)?) {
        self.api = api
        if api == nil {
            registeredOnBox = nil
            boxSupportsCalls = nil
        }
    }

    /// Paired, at launch or after pairing: register the token when the owner wants calls.
    public func start() async {
        guard isEnabled else { return }
        await register()
    }

    /// The owner flipped the switch.
    public func setEnabled(_ on: Bool) async {
        isEnabled = on
        store.enabled = on
        testSentence = nil
        testFailure = nil
        if on {
            await register()
        } else {
            await unregister()
        }
    }

    /// PushKit handed over the token (at every launch, and when it changes). Hex, never logged.
    public func tokenReceived(_ hex: String) async {
        let changed = hex != token
        token = hex
        hasToken = true
        if changed || registeredOnBox != true, isEnabled { await register() }
    }

    /// PushKit invalidated the token: the box forgets it.
    public func tokenInvalidated() async {
        token = nil
        hasToken = false
        await unregister()
    }

    /// Unpairing: the box forgets this phone's token, then the client is dropped.
    public func forget() async {
        await unregister()
        attach(nil)
    }

    /// Settings opened: read whether the box holds the token.
    public func refreshStatus() async {
        guard let api else { return }
        do {
            let voip = try await api.voipStatus()
            boxSupportsCalls = voip != nil
            registeredOnBox = voip
        } catch {
            // The status is a nicety: a box out of reach keeps the last answer.
            noteRefusal(error)
        }
    }

    /// Retry after a failed registration.
    public func retry() async { await register() }

    // MARK: Test ring

    public func sendTestRing() async {
        guard let api else { return }
        isTesting = true
        testSentence = nil
        testFailure = nil
        defer { isTesting = false }
        do {
            testSentence = CallOwnerCopy.testSentence(try await api.testRing())
        } catch {
            testFailure = CallOwnerCopy.testFailure(error)
            noteRefusal(error)
        }
    }

    // MARK: words

    /// One line under the switch.
    public var statusLine: String {
        CallOwnerCopy.statusLine(
            enabled: isEnabled, paired: api != nil, hasToken: hasToken, boxSupportsCalls: boxSupportsCalls, registeredOnBox: registeredOnBox)
    }

    // MARK: plumbing

    private func register() async {
        guard isEnabled, let api, let token else { return }
        do {
            try await api.voipRegister(token: token, environment: environment, topic: topic)
            registeredOnBox = true
            boxSupportsCalls = true
            failure = nil
        } catch BFFError.envelope(_, _, 404) {
            boxSupportsCalls = false
            registeredOnBox = false
            failure = nil
        } catch BFFError.unexpectedStatus(404) {
            boxSupportsCalls = false
            registeredOnBox = false
            failure = nil
        } catch {
            failure = CalmFailure(sentence: CallOwnerCopy.registerFailed, details: "voip register: \(error)", retry: .reconnect)
            noteRefusal(error)
        }
    }

    private func unregister() async {
        guard let api else {
            registeredOnBox = nil
            return
        }
        do {
            try await api.voipUnregister()
            registeredOnBox = false
            failure = nil
        } catch BFFError.envelope(_, _, 404) {
            registeredOnBox = false
        } catch BFFError.unexpectedStatus(404) {
            registeredOnBox = false
        } catch {
            // The token stays on the box for now; it is dropped there when Apple says it is dead, or on the next change.
            failure = CalmFailure(sentence: CallOwnerCopy.unregisterFailed, details: "voip unregister: \(error)", retry: .reconnect)
            noteRefusal(error)
        }
    }

    /// 401 or 403 from the box: its device credential for this phone is no good any more.
    private func noteRefusal(_ error: any Error) {
        switch error {
        case BFFError.envelope(_, _, 401), BFFError.envelope(_, _, 403), BFFError.unexpectedStatus(401), BFFError.unexpectedStatus(403):
            onUnauthorized?()
        default:
            break
        }
    }
}

/// The words of "Calls from your bots". Calm sentences, no em-dashes.
public enum CallOwnerCopy {
    public static let sectionTitle = "Calls"
    public static let toggleTitle = "Calls from your bots"
    public static let toggleHint = "Lets your bots ring this phone like a phone call, also when it is locked"
    public static let testButton = "Test ring"
    public static let registerFailed = "Could not tell your box that this phone takes calls. Retry."
    public static let unregisterFailed = "Could not tell your box to stop ringing this phone. Retry."
    public static let footnote =
        "A ring follows the ring and silent switch: in silent mode it only vibrates. Answering needs Tailscale to be connected."

    public static func statusLine(enabled: Bool, paired: Bool, hasToken: Bool, boxSupportsCalls: Bool?, registeredOnBox: Bool?) -> String {
        guard enabled else { return "Off. Your bots cannot ring this phone." }
        guard paired else { return "On, once this phone is paired with your box." }
        if boxSupportsCalls == false { return "On here, but your box does not have calls from bots turned on yet." }
        guard hasToken else { return "Waiting for iOS to give this phone a call token." }
        if registeredOnBox == true { return "On. Your bots can ring this phone." }
        return "On. Telling your box about this phone."
    }

    public static func testSentence(_ result: TestRingResult) -> String {
        switch result.outcome {
        case "ringing":
            if let sent = result.sent, sent == 0 { return "Your box made the call, but Apple did not take the push. Check Diagnostics." }
            return "Your box is ringing this phone now."
        case "busy": return "You are already in a call with that bot."
        default: return "Your box could not start the ring. Check that its call service runs."
        }
    }

    public static func testFailure(_ error: any Error) -> CalmFailure {
        let sentence: String
        switch error {
        case BFFError.envelope("rate_limited", _, _), BFFError.unexpectedStatus(429):
            sentence = "Too many test rings. Wait a while and try again."
        case BFFError.envelope(_, _, 404), BFFError.unexpectedStatus(404):
            sentence = "Calls from bots are not turned on on your box."
        case BFFError.envelope(_, _, 400):
            sentence = "Your box has no call token for this phone yet. Turn on Calls from your bots, then try again."
        default:
            sentence = "Could not reach your box to ring this phone. Check that Tailscale is on, then retry."
        }
        return CalmFailure(sentence: sentence, details: "test ring: \(error)", retry: .reconnect)
    }
}
