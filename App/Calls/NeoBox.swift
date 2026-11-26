#if os(iOS)
import Foundation
import HermesBox
import HermesKit
import Observation

/// Hermes Neo: the owner's box (its BFF, `box/bff`) and the calls its Bots make to this phone.
///
/// - Pairing: the box's pairing link or QR code (`/bff/pair/redeem`, `client: "ios"`); the device
///   token goes to the Keychain and every request carries it as a Bearer (`DeviceBearer`).
/// - "Calls from your bots" (off by default): the PushKit VoIP token on the box
///   (`POST /bff/push/voip/register {token, environment, topic}`), Test ring.
/// - A ring: PushKit hands the push to `RingCoordinator`, which reports it to CallKit at once; an
///   answer joins and takes the box's call through `/gw/<id>/api/call/ws` (the call hub).
///
/// Made once, when the app starts (`HermesApp`), so a cold launch by a VoIP push has PushKit and
/// CallKit ready before the push is delivered. Upstream Hermes chose not to use CallKit for Talk
/// (`docs/voice.md` §4.4); these calls are real calls placed by the box, see `docs/neo-calls.md`.
@MainActor
@Observable
final class NeoBox {
    static let shared = NeoBox()

    /// The paired box, or nil.
    private(set) var box: PairedBox?
    var linkText = ""
    var boxAddress = ""
    private(set) var isPairing = false
    private(set) var pairingFailure: CalmFailure?

    let voip: VoIPRegistrar
    let calls: CallController

    @ObservationIgnored private let pairing: PairingService
    @ObservationIgnored private let links: NeoCallLinks
    @ObservationIgnored private let microphone = AppleCallMicrophone()
    @ObservationIgnored private let callKit: NeoCallKitHost
    @ObservationIgnored private let rings: RingCoordinator
    @ObservationIgnored private var pushKit: NeoPushKitHost?

    private init() {
        let http = URLSessionHTTPTransport()
        let service = (Bundle.main.bundleIdentifier ?? "hermes-neo") + ".box"
        pairing = PairingService(transport: http, secrets: KeychainSecretStore(service: service), deviceLabel: "iPhone (Hermes Neo)")
        let links = NeoCallLinks(http: http, authorizer: pairing.authorizer())
        self.links = links
        #if DEBUG
        let debugFallback = true
        #else
        let debugFallback = false
        #endif
        let environment = ApsEnvironment.current(
            profileURL: Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"), isSimulatorOrDebugFallback: debugFallback)
        voip = VoIPRegistrar(environment: environment, topic: Bundle.main.bundleIdentifier, store: UserDefaultsCallsFromBots())
        let audio = NeoCallAudio()
        let calls = CallController(
            makeLink: { links.makeCallLink(gatewayId: $0) }, audio: audio, audioSession: VoiceAudioSession(driver: audio),
            microphone: AppleCallMicrophone())
        // At the ear the call uses the receiver and the screen goes dark; away from it the speaker choice returns.
        calls.proximity = AppleProximity()
        self.calls = calls
        let callKit = NeoCallKitHost()
        self.callKit = callKit
        let voip = self.voip
        rings = RingCoordinator(
            provider: callKit, calls: NeoRingCalls(calls), makeLink: { links.makeCallLink(gatewayId: $0) }, notifier: NeoRingNotifier(),
            callsEnabled: { voip.isEnabled && links.bff != nil },
            prepare: { NeoBox.shared.restoreIfNeeded() },
            keepAlive: { NeoRingBackgroundTime.begin($0) })
        callKit.coordinator = rings
        restoreIfNeeded()
        pushKit = NeoPushKitHost(coordinator: rings, voip: voip)
    }

    var isPaired: Bool { box != nil }

    // MARK: pairing

    /// The pairing this phone saved, read again (at launch, or a ring that woke the app before the
    /// Keychain could be read).
    func restoreIfNeeded() {
        guard box == nil, let stored = try? pairing.load() else { return }
        pairing.relaxKeychainAccess()
        adopt(stored)
    }

    /// Redeem the pasted or scanned link. The link is a one-time credential: it is cleared after.
    func pair() async {
        isPairing = true
        pairingFailure = nil
        defer { isPairing = false }
        do {
            let link = try BoxPairingLink.parse(linkText).get()
            let address = boxAddress.isEmpty ? nil : BoxPairingLink.baseURL(fromAddress: boxAddress)
            let paired = try await pairing.pair(link, baseURL: address)
            linkText = ""
            adopt(paired)
        } catch {
            pairingFailure = CalmFailure.from(error, retry: .pair)
        }
    }

    /// The box forgets this phone's call token, then the pairing goes.
    func unpair() async {
        await voip.forget()
        try? pairing.forget()
        links.bff = nil
        box = nil
    }

    private func adopt(_ paired: PairedBox) {
        let client = links.adopt(paired)
        box = paired
        voip.attach(client)
        Task { [voip] in await voip.start() }
    }

    // MARK: calls from your bots

    /// The switch. Turning it on asks for the microphone now: a ring can't ask from a locked phone.
    func setCallsEnabled(_ on: Bool) async {
        if on, microphone.access() == .undetermined { _ = await microphone.request() }
        await voip.setEnabled(on)
    }

    var microphoneDenied: Bool { microphone.access() == .denied }
}

/// The box's client and the call sockets made from it; shared by the controller, the ring
/// coordinator and the ring watch.
@MainActor
final class NeoCallLinks {
    private let http: any HTTPTransport
    private let authorizer: any BFFAuthorizer
    private let connector = URLSessionWebSocketConnector()
    var bff: BFFClient?

    init(http: any HTTPTransport, authorizer: any BFFAuthorizer) {
        self.http = http
        self.authorizer = authorizer
    }

    func adopt(_ box: PairedBox) -> BFFClient {
        let client = BFFClient(baseURL: box.baseURL, transport: http, authorizer: authorizer)
        bff = client
        return client
    }

    /// `wss://<box>/gw/<id>/api/call/ws` with the device Bearer: the call hub, as Hermes Bot joins it.
    func makeCallLink(gatewayId: String) -> (any CallLink)? {
        guard let bff else { return nil }
        let authorizer = authorizer
        return CallClient(
            url: {
                guard let url = bff.callWebSocketURL(gatewayId: gatewayId) else { throw BFFError.undecodable(detail: "no call URL") }
                return url
            },
            headers: { await authorizer.authorize(URLRequest(url: bff.baseURL)).allHTTPHeaderFields ?? [:] },
            connector: connector, time: SystemTimeSource())
    }
}

/// The ring's view of the phone's calls: busy while a box call runs, and also while upstream's
/// Talk runs (its engine doesn't stop for another role, so a ring then is reported and ended).
@MainActor
final class NeoRingCalls: RingCallHandling {
    private let controller: CallController

    init(_ controller: CallController) {
        self.controller = controller
    }

    var isInCall: Bool { controller.isInCall || TalkCenter.shared.isActive }

    var onCallEnded: (@MainActor (String?) -> Void)? {
        get { controller.onCallEnded }
        set { controller.onCallEnded = newValue }
    }

    func answerRing(bot: CallBot, callId: String, timeout: Duration) async -> RingAnswerOutcome {
        await controller.answerRing(bot: bot, callId: callId, timeout: timeout)
    }

    func end() { controller.end() }
    func setMuted(_ muted: Bool) { controller.setMuted(muted) }
    func systemAudioActivated() { controller.systemAudioActivated() }
    func systemAudioDeactivated() { controller.systemAudioDeactivated() }
}
#endif
