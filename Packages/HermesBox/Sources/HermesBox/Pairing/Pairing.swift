import Foundation

/// The one-time pairing token. It is a credential for 300 seconds, so it never prints: `description`,
/// `debugDescription` and reflection all say "redacted", and only `reveal()` (called by the redeem
/// request) returns the value. It is never logged, stored or committed.
public struct PairingToken: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let value: String

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        value = trimmed
    }

    func reveal() -> String { value }

    public var description: String { "PairingToken(redacted)" }
    public var debugDescription: String { "PairingToken(redacted)" }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// A pairing link as the desktop shows it: `https://<box>/pair#<token>` (the token sits in the URL
/// fragment so it never reaches a server log or a Referer header; `box/bff/pair.mjs`).
public struct BoxPairingLink: Sendable, Hashable {
    public let baseURL: URL?
    public let token: PairingToken

    public init(baseURL: URL?, token: PairingToken) {
        self.baseURL = baseURL
        self.token = token
    }

    /// Accepts a pasted or scanned link (`https://host/pair#TOKEN`, `...#token=TOKEN`, `...?pair=TOKEN`)
    /// and, as a last resort, a bare token (then `baseURL` is nil and the caller must supply the box
    /// address). Mirrors `extractTokenFromScannedUrl` and `readPairToken` in `src/web`.
    public static func parse(_ raw: String) -> Result<BoxPairingLink, BFFError> {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .failure(.invalidPairingLink(reason: "Paste the pairing link from your desktop.")) }

        if let components = URLComponents(string: value), let scheme = components.scheme?.lowercased(),
            let host = components.host, !host.isEmpty
        {
            guard let token = token(in: components).flatMap(PairingToken.init) else {
                return .failure(.invalidPairingLink(reason: "That link has no pairing code. Create a new one on the desktop."))
            }
            guard let base = baseURL(scheme: scheme, host: host, port: components.port) else {
                return .failure(.invalidPairingLink(reason: "The pairing link must use https."))
            }
            return .success(BoxPairingLink(baseURL: base, token: token))
        }
        let looksBare = !value.contains("://") && value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil && value.count >= 12
        if looksBare, let token = PairingToken(value) { return .success(BoxPairingLink(baseURL: nil, token: token)) }
        return .failure(.invalidPairingLink(reason: "That does not look like a pairing link. Copy it again from your desktop."))
    }

    /// Normalise a box address typed by hand (`my-box.tailnet.ts.net` or a full URL) to a base URL.
    public static func baseURL(fromAddress raw: String) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let withScheme = value.contains("://") ? value : "https://\(value)"
        guard let components = URLComponents(string: withScheme), let host = components.host, !host.isEmpty else { return nil }
        return baseURL(scheme: components.scheme?.lowercased() ?? "https", host: host, port: components.port)
    }

    /// https only, except for a loopback host (a local fake BFF in a simulator).
    private static func baseURL(scheme: String, host: String, port: Int?) -> URL? {
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard scheme == "https" || (scheme == "http" && loopback) else { return nil }
        var base = URLComponents()
        base.scheme = scheme
        base.host = host
        base.port = port
        return base.url
    }

    private static func token(in components: URLComponents) -> String? {
        if let fragment = components.percentEncodedFragment, !fragment.isEmpty {
            if !fragment.contains("=") { return fragment.removingPercentEncoding }
            if let found = keyed(fragment) { return found }
        }
        if let query = components.percentEncodedQuery, let found = keyed(query) { return found }
        return nil
    }

    private static func keyed(_ encoded: String) -> String? {
        for pair in encoded.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == "token" || parts[0] == "pair", !parts[1].isEmpty else { continue }
            return parts[1].removingPercentEncoding
        }
        return nil
    }
}

/// What redeem returned that the app keeps. The BFF's `device.id` is NOT kept: on a BFF without B1 it is
/// the value of the `bff_device` cookie, i.e. a credential, and the app has no use for it either way.
/// Only a separate `deviceToken` (B1 R2) is stored, and only in the Keychain.
public struct RedeemResult: Sendable, Equatable {
    public let deviceLabel: String?
    /// Present only when the BFF has R2 and the request said `client:"ios"`. The B1 BFF returns it once,
    /// at the top level of the redeem body (`box/bff/server.mjs`); `device.deviceToken` is accepted too.
    public let deviceToken: String?

    public init(deviceLabel: String?, deviceToken: String?) {
        self.deviceLabel = deviceLabel
        self.deviceToken = deviceToken
    }

    init(responseBody data: Data) {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let device = object?["device"] as? [String: Any]
        let token = (object?["deviceToken"] as? String) ?? (device?["deviceToken"] as? String)
        deviceLabel = device?["label"] as? String
        deviceToken = (token?.isEmpty == false) ? token : nil
    }
}
