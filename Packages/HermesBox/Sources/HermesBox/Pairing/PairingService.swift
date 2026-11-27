import Foundation

/// A paired box as the app remembers it across launches.
public struct PairedBox: Sendable, Equatable {
    public let baseURL: URL
    /// False until the BFF has R2 (B1): then the tailnet alone is the gate and no device secret is stored.
    public let hasDeviceToken: Bool

    public init(baseURL: URL, hasDeviceToken: Bool) {
        self.baseURL = baseURL
        self.hasDeviceToken = hasDeviceToken
    }
}

/// Pair with the BFF and remember the result.
///
/// Per S18 R11: the app takes the fragment token from a pasted link or a scan and calls redeem with
/// `client:"ios"`. If the BFF returns a `deviceToken` (R2) it goes ONLY into the Keychain; otherwise the
/// app relies on the tailnet and stores no credential. The gateway token is never present in the app.
public struct PairingService: Sendable {
    private let transport: any HTTPTransport
    private let secrets: any SecretStore
    private let deviceLabel: String

    public init(transport: any HTTPTransport, secrets: any SecretStore, deviceLabel: String) {
        self.transport = transport
        self.secrets = secrets
        self.deviceLabel = deviceLabel
    }

    /// Redeem the link's token against `baseURL` (the link's own host unless the caller overrides it).
    public func pair(_ link: BoxPairingLink, baseURL override: URL? = nil) async throws -> PairedBox {
        guard let baseURL = override ?? link.baseURL else {
            throw BFFError.invalidPairingLink(reason: "Enter your box address (for example my-box.your-tailnet.ts.net).")
        }
        let client = BFFClient(baseURL: baseURL, transport: transport)
        let result = try await client.redeem(token: link.token, deviceLabel: deviceLabel)
        try secrets.write(baseURL.absoluteString, account: SecretAccount.boxBaseURL)
        if let token = result.deviceToken {
            try secrets.write(token, account: SecretAccount.deviceToken)
        } else {
            try secrets.delete(SecretAccount.deviceToken)
        }
        return PairedBox(baseURL: baseURL, hasDeviceToken: result.deviceToken != nil)
    }

    /// Hermes Neo: pair on the owner's gateway login (`POST /bff/pair/gateway`) instead of a link. The device token is
    /// kept where a redeemed one is (the Keychain, then the Bearer of every request). An answer without one is a
    /// failure: the box must hand this phone its own credential.
    public func pairWithGateway(baseURL: URL, credentialHeaders: [String: String]) async throws -> PairedBox {
        let client = BFFClient(baseURL: baseURL, transport: transport)
        let result = try await client.pairWithGateway(credentialHeaders: credentialHeaders, deviceLabel: deviceLabel)
        guard let token = result.deviceToken else {
            throw BFFError.undecodable(detail: "/bff/pair/gateway answered without a deviceToken")
        }
        try secrets.write(baseURL.absoluteString, account: SecretAccount.boxBaseURL)
        try secrets.write(token, account: SecretAccount.deviceToken)
        return PairedBox(baseURL: baseURL, hasDeviceToken: true)
    }

    /// Hermes Neo: which gateway login the stored pairing was made with (a one-way fingerprint, never the login), so a
    /// changed login pairs again.
    public func gatewayFingerprint() -> String? { try? secrets.read(SecretAccount.gatewayFingerprint) }

    public func rememberGatewayFingerprint(_ fingerprint: String) {
        try? secrets.write(fingerprint, account: SecretAccount.gatewayFingerprint)
    }

    /// The box this phone is paired with, if any.
    public func load() throws -> PairedBox? {
        guard let text = try secrets.read(SecretAccount.boxBaseURL), let url = URL(string: text) else { return nil }
        return PairedBox(baseURL: url, hasDeviceToken: try secrets.read(SecretAccount.deviceToken) != nil)
    }

    /// An authorizer for the paired box: bearer when a device token exists, otherwise tailnet identity.
    public func authorizer() -> any BFFAuthorizer {
        let secrets = self.secrets
        return DeviceBearer { try? secrets.read(SecretAccount.deviceToken) }
    }

    /// A pairing saved by an older build is readable only while the phone is unlocked: make it readable after the first
    /// unlock. Called after a successful read, so the phone is unlocked now. Failing to upgrade is not worth a message.
    public func relaxKeychainAccess() {
        for account in [SecretAccount.boxBaseURL, SecretAccount.deviceToken] {
            do { try secrets.relaxAccess(account) } catch {
                // intentional: the pairing still works; only a start while the phone is locked would still wait.
            }
        }
    }

    public func forget() throws {
        try secrets.delete(SecretAccount.boxBaseURL)
        try secrets.delete(SecretAccount.deviceToken)
        try secrets.delete(SecretAccount.gatewayFingerprint)
    }
}
