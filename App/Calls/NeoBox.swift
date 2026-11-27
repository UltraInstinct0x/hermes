#if os(iOS)
import CryptoKit
import Foundation
import HermesActivityKit
import HermesBox
import HermesKit
import Observation

/// Hermes Neo: the owner's box (its BFF, `box/bff`) and the calls its Bots make to this phone.
///
/// - No pairing step of its own: the box pairs this phone on the owner's gateway login
///   (`POST /bff/pair/gateway` on `https://<gateway host>:<boxPort>`, with the credential exactly as
///   `BackendClient` sends it to that gateway). The device token it returns goes to the Keychain and
///   every later request carries it as a Bearer (`DeviceBearer`).
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

    /// The box BFF's port on the gateway's host (`tailscale serve`): the gateway is on its own port,
    /// the BFF on this one. `defaults write dev.supersaiyan.hermesneo neo.boxPort -int <port>` overrides it.
    static var boxPort: Int {
        (UserDefaults.standard.object(forKey: "neo.boxPort") as? Int) ?? defaultBoxPort
    }
    static let defaultBoxPort = 9443
    static let deviceLabel = "HermesNeo"

    /// The paired box, or nil.
    private(set) var box: PairedBox?
    private(set) var isPairing = false
    private(set) var pairingFailure: CalmFailure?

    let voip: VoIPRegistrar
    let calls: CallController
    let push: PushRegistrar
    private(set) var lockScreen: LockScreenPreferences
    @ObservationIgnored private let lockScreenStore = UserDefaultsLockScreenPreferences(key: "neo.lockScreenPreferences.v1")
    @ObservationIgnored private let activities: NeoActivityHost
    @ObservationIgnored private var pendingRequestLink: ActivityLink?
    /// The call's audio on the app's audio coordinator; CallKit tells it when the session is live.
    @ObservationIgnored let callAudio: NeoCallAudio

    /// The app's gateways, whose login pairs this phone with the box. Set once the first window is up.
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let pairing: PairingService
    @ObservationIgnored private let links: NeoCallLinks
    @ObservationIgnored private let microphone = AppleCallMicrophone()
    @ObservationIgnored private let callKit: NeoCallKitHost
    @ObservationIgnored private let rings: RingCoordinator
    @ObservationIgnored private var pushKit: NeoPushKitHost?
    /// The box's call as one of the app's Talk calls (the pill, End, its card in the bot's chat).
    @ObservationIgnored private(set) var talk: NeoTalkCall?

    private init() {
        let http = URLSessionHTTPTransport()
        let service = (Bundle.main.bundleIdentifier ?? "hermes-neo") + ".box"
        pairing = PairingService(transport: http, secrets: KeychainSecretStore(service: service), deviceLabel: Self.deviceLabel)
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
        let push = PushRegistrar(platform: NeoRemotePlatform(environment: environment), topic: Bundle.main.bundleIdentifier, state: UserDefaultsPushState())
        self.push = push
        let preferences = lockScreenStore.load() ?? .allOff
        lockScreen = preferences
        push.configure(preferences: preferences)
        activities = NeoActivityHost { event in await push.handle(event) }
        let audio = NeoCallAudio()
        callAudio = audio
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
        NeoActivityButtonRouter.handler = self
        push.onGateChange = { [weak self] enabled in
            if enabled { self?.activities.start() }
            else { self?.activities.stop() }
        }
        push.setNotificationsProbe { await NeoRemotePlatform.notificationsAllowed() }
        if push.pushTokensEnabled { activities.start() }
        restoreIfNeeded()
        pushKit = NeoPushKitHost(coordinator: rings, voip: voip)
        // The box refused the device token: drop it, so the next attempt pairs again on the gateway login.
        voip.onUnauthorized = { [weak self] in self?.forgetPairing() }
        let talk = NeoTalkCall(calls: calls, box: self)
        talk.start()
        self.talk = talk
    }

    var isPaired: Bool { box != nil }

    /// The line under the switch.
    var statusLine: String {
        guard voip.isEnabled, box == nil else { return voip.statusLine }
        return isPairing ? "On. Connecting to your box through your gateway." : "On, once this phone can reach your box."
    }

    // MARK: pairing on the gateway login

    /// The app's gateways, once the first window is up. With the switch on, the box pairing is
    /// checked now (no pairing yet, or a different login).
    func attach(_ app: AppModel) {
        self.app = app
        if let pendingRequestLink {
            self.pendingRequestLink = nil
            openRequestLink(pendingRequestLink)
        }
        guard voip.isEnabled || lockScreen.approvals else { return }
        Task { await ensurePaired(quietly: true) }
    }

    /// The pairing this phone saved, read again (at launch, or a ring that woke the app before the
    /// Keychain could be read).
    func restoreIfNeeded() {
        guard box == nil, let stored = try? pairing.load() else { return }
        pairing.relaxKeychainAccess()
        adopt(stored)
    }

    /// Paired with the box on the current gateway login: kept when it was made with this login and
    /// this box, made again otherwise. `quietly`: at launch, a gateway that isn't loaded yet isn't a failure.
    @discardableResult
    func ensurePaired(quietly: Bool = false) async -> Bool {
        guard !isPairing else { return false }
        guard let login = await gatewayLogin() else {
            if box != nil { return true }
            if !quietly {
                pairingFailure = CalmFailure(
                    sentence: "Add your gateway and sign in to it, then try again.", details: "no gateway with a login", retry: .pair)
            }
            return false
        }
        if let box, box.baseURL == login.bff, pairing.gatewayFingerprint() == login.fingerprint { return true }
        if box != nil { forgetPairing() }
        isPairing = true
        defer { isPairing = false }
        do {
            let paired = try await pairing.pairWithGateway(baseURL: login.bff, credentialHeaders: login.headers)
            pairing.rememberGatewayFingerprint(login.fingerprint)
            pairingFailure = nil
            adopt(paired)
            return true
        } catch {
            pairingFailure = Self.pairingFailure(error)
            return false
        }
    }

    /// The gateway whose login pairs this phone: the one in use, else the first with Bot Mode and a
    /// login. The box is on the same host, on `boxPort`.
    private func gatewayLogin() async -> (bff: URL, headers: [String: String], fingerprint: String)? {
        guard let app else { return nil }
        let workspaces = [app.currentWorkspace].compactMap { $0 } + app.bots.compactMap { app.workspaces[$0.id] }
        for workspace in workspaces {
            guard let client = workspace.roster?.backendClient, let host = client.baseURL.host() else { continue }
            let headers = await client.authorizationHeaders()
            guard !headers.isEmpty else { continue }
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            components.port = Self.boxPort
            guard let bff = components.url else { continue }
            return (bff, headers, Self.fingerprint(host: host, headers: headers))
        }
        return nil
    }

    /// Which login the pairing was made with, one way: the session token itself, or only that it was
    /// a cookie sign-in (the gate refreshes cookies on use, so their values change without a new login;
    /// a refused device token re-pairs those).
    private static func fingerprint(host: String, headers: [String: String]) -> String {
        let login = headers["X-Hermes-Session-Token"].map { "token:\($0)" } ?? "cookies"
        let digest = SHA256.hash(data: Data("\(host)|\(login)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func pairingFailure(_ error: any Error) -> CalmFailure {
        let details = "pair on gateway login: \((error as? BFFError)?.detail ?? String(describing: error))"
        let sentence = switch error {
        case BFFError.envelope(_, _, 401), BFFError.envelope(_, _, 403), BFFError.unexpectedStatus(401), BFFError.unexpectedStatus(403):
            "Sign in to your gateway again, then try again."
        case BFFError.envelope(_, _, 429), BFFError.unexpectedStatus(429):
            "Too many tries. Wait a few minutes, then try again."
        case BFFError.envelope(_, _, 502), BFFError.unexpectedStatus(502), BFFError.unreachable:
            "Could not reach your box through your gateway. Check that Tailscale is on, then try again."
        default:
            "Could not connect this phone to your box. Try again."
        }
        return CalmFailure(sentence: sentence, details: details, retry: .pair)
    }

    /// The box's device token is no good (or the login changed): forget it; the next attempt pairs again.
    private func forgetPairing() {
        try? pairing.forget()
        links.bff = nil
        box = nil
        voip.attach(nil)
        push.attach(nil)
        activities.stop()
    }

    private func adopt(_ paired: PairedBox) {
        let client = links.adopt(paired)
        box = paired
        voip.attach(client)
        push.attach(client)
        Task { [voip] in await voip.start() }
        Task { [weak self] in
            guard let self, self.box == paired, lockScreen.approvals else { return }
            await push.start(preferences: lockScreen)
        }
    }

    func deviceTokenReceived(_ token: Data) {
        let hex = ActivityPushTokens.hex(token)
        Task { [push] in await push.deviceTokenReceived(hex) }
    }

    func setRequestsEnabled(_ on: Bool) async {
        let preferences = LockScreenPreferences(approvals: on)
        lockScreen = preferences
        lockScreenStore.save(preferences)
        if on { await ensurePaired() }
        guard lockScreen == preferences, isPaired else { return }
        await push.preferencesChanged(preferences)
        if !on { await activities.endRequests() }
    }

    func refreshPush() async {
        if lockScreen.approvals { await ensurePaired(quietly: true) }
        await push.start(preferences: lockScreen)
    }

    func openRequestLink(_ link: ActivityLink, window: UUID? = nil) {
        guard let app else { pendingRequestLink = link; return }
        if case .bot(let key) = link {
            let bot = BotKey(rawValue: key)
            let matches = app.workspaces.values.filter {
                box != nil && $0.roster?.backendClient.baseURL.host() == box?.baseURL.host()
                    && $0.roster?.bot(named: bot.profileId) != nil
            }
            if matches.count == 1, let workspace = matches.first {
                app.select(workspace.id, in: window)
                workspace.sidebarMode = .bots
                workspace.selection = .bot(bot.profileId)
                return
            }
        }
        guard let workspace = window.flatMap({ app.workspace(in: $0) }) ?? app.currentWorkspace else { return }
        workspace.sidebarMode = .chats
        workspace.inboxFilter = .needsYou
        workspace.searchText = ""
        workspace.selection = nil
    }

    func answerRequest(botKey: String, requestId: String, shown: String, answer: WatchCompanion.RequestAnswer) async -> Bool {
        guard lockScreen.approvals, let app else { return false }
        return await app.needsYou.answerFromLiveActivity(botKey: BotKey(rawValue: botKey), requestId: requestId,
                                                        shown: shown, answer: answer, workspaces: Array(app.workspaces.values))
    }

    /// The calling bot's chat in the app, when a gateway's Bot Mode lists a bot of that profile: its waiting approval
    /// or question shows on the call screen. Nil when the app has no such bot (then nothing shows there).
    func waitingConversation(botKey: String?) -> ConversationModel? {
        guard let botKey, let roster = roster(for: botKey) else { return nil }
        return roster.conversation(for: BotKey(rawValue: botKey).profileId)
    }

    /// The Bot Mode of the app's gateway that has a bot of this box bot's profile name.
    private func roster(for botKey: String) -> BotRoster? {
        guard let app else { return nil }
        let profile = BotKey(rawValue: botKey).profileId
        for workspace in [app.currentWorkspace].compactMap({ $0 }) + app.bots.compactMap({ app.workspaces[$0.id] }) {
            if let roster = workspace.roster, roster.profiles.contains(where: { $0.name == profile }) { return roster }
        }
        return nil
    }

    /// The face the app draws for that bot (the call pill).
    func appearance(botKey: String?) -> BotAppearance? {
        guard let botKey, let roster = roster(for: botKey), let bot = roster.bot(named: BotKey(rawValue: botKey).profileId) else { return nil }
        return roster.appearance(for: bot)
    }

    /// The bot's Bot Chat, where a call's card goes: the open one's, or the one the gateway names.
    func botChatSessionID(botKey: String) async -> String? {
        guard let roster = roster(for: botKey) else { return nil }
        let profile = BotKey(rawValue: botKey).profileId
        if let id = roster.conversation(for: profile).sessionID { return id }
        return try? await roster.resolveBotChat(profile)
    }

    // MARK: calls from your bots

    /// The switch. Turning it on asks for the microphone now (a ring can't ask from a locked phone),
    /// then pairs with the box on the gateway login if needed, then registers the call token.
    func setCallsEnabled(_ on: Bool) async {
        if on {
            if microphone.access() == .undetermined { _ = await microphone.request() }
            await ensurePaired()
        } else {
            pairingFailure = nil
        }
        await voip.setEnabled(on)
    }

    /// Retry: pair again if needed, then register the call token again.
    func retry() async {
        guard await ensurePaired() else { return }
        await voip.retry()
    }

    /// Settings opened: with the switch on, check the pairing and read the box's status.
    func refresh() async {
        if voip.isEnabled { await ensurePaired(quietly: true) }
        await voip.refreshStatus()
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

    var isInCall: Bool { controller.isInCall || TalkCenter.shared.session != nil }

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
