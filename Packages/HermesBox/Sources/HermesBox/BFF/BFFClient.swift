import Foundation

/// One gateway as `GET /bff/gateways` reports it (`box/bff/gateways.mjs`).
public struct BFFGateway: Codable, Sendable, Hashable, Identifiable {
    public enum Mode: Sendable, Hashable, RawRepresentable, Codable {
        case live, offline, error
        case unknown(String)

        public init(rawValue: String) {
            switch rawValue {
            case "live": self = .live
            case "offline": self = .offline
            case "error": self = .error
            default: self = .unknown(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .live: return "live"
            case .offline: return "offline"
            case .error: return "error"
            case .unknown(let value): return value
            }
        }

        public init(from decoder: Decoder) throws {
            self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public var id: String
    public var label: String
    public var mode: Mode
    public var reason: String
    public var botCount: Int

    public init(id: String, label: String, mode: Mode, reason: String = "", botCount: Int = 0) {
        self.id = id
        self.label = label
        self.mode = mode
        self.reason = reason
        self.botCount = botCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = (try? c.decodeIfPresent(String.self, forKey: .label)).flatMap { $0 }.flatMap { $0.isEmpty ? nil : $0 } ?? id
        mode = try c.decode(Mode.self, forKey: .mode)
        reason = (try? c.decodeIfPresent(String.self, forKey: .reason)).flatMap { $0 } ?? ""
        botCount = (try? c.decodeIfPresent(Int.self, forKey: .botCount)).flatMap { $0 } ?? 0
    }

    enum CodingKeys: String, CodingKey { case id, label, mode, reason, botCount }
}

/// Why a BFF call failed. `calmSentence` is the default text; `detail` is for Copy details only and
/// never contains a pairing token, a device token or any header.
public enum BFFError: Error, Sendable, Equatable {
    /// The box could not be reached (offline, Tailscale off, TLS).
    case unreachable(detail: String)
    /// The BFF answered with its closed error envelope (`{ok:false,error:{code,message}}`).
    case envelope(code: String, message: String, status: Int)
    /// A status the BFF's table does not name.
    case unexpectedStatus(Int)
    case undecodable(detail: String)
    case invalidPairingLink(reason: String)

    public var calmSentence: String {
        switch self {
        case .unreachable:
            return "Could not reach your box. Check that Tailscale is connected, then retry."
        case .envelope(let code, _, _):
            switch code {
            case "invalid_pairing_token":
                return "That pairing link did not work. It may have expired or been used already. Create a new one on the desktop and try again."
            case "rate_limited":
                return "Too many attempts. Wait a minute and try again."
            case "unauthorized", "forbidden":
                return "Your box did not accept this device. Check that this phone is on your tailnet."
            case "gateway_unavailable", "gateway_token_missing", "snapshot_unavailable":
                return "Your box could not reach the bot's machine. Retry in a moment."
            default:
                return "Your box could not do that. Retry."
            }
        case .unexpectedStatus:
            return "Your box answered in a way this app did not expect. Retry."
        case .undecodable:
            return "Your box sent something this app did not understand."
        case .invalidPairingLink(let reason):
            return reason
        }
    }

    public var detail: String {
        switch self {
        case .unreachable(let detail): return detail
        case .envelope(let code, let message, let status): return "HTTP \(status) \(code): \(message)"
        case .unexpectedStatus(let status): return "HTTP \(status)"
        case .undecodable(let detail): return detail
        case .invalidPairingLink(let reason): return reason
        }
    }
}

/// Adds the device credential to a BFF request, when there is one.
///
/// Today (P0, BFF as it is) the tailnet is the gate and the app sends nothing: `TailnetIdentity`.
/// When B1 R2 lands the BFF accepts `Authorization: Bearer <deviceToken>`; `DeviceBearer` is the
/// switch for that, and nothing else in the app changes.
public protocol BFFAuthorizer: Sendable {
    func authorize(_ request: URLRequest) async -> URLRequest
}

public struct TailnetIdentity: BFFAuthorizer {
    public init() {}
    public func authorize(_ request: URLRequest) async -> URLRequest { request }
}

public struct DeviceBearer: BFFAuthorizer {
    private let token: @Sendable () async -> String?

    public init(token: @escaping @Sendable () async -> String?) { self.token = token }

    public func authorize(_ request: URLRequest) async -> URLRequest {
        guard let value = await token(), !value.isEmpty else { return request }
        var request = request
        request.setValue("Bearer \(value)", forHTTPHeaderField: "Authorization")
        return request
    }
}

/// The box BFF over the tailnet (`box/bff/`). Routes used by P0: `/bff/pair/redeem`, `/bff/gateways`,
/// `/gw/<id>/api/profiles`, `/bff/presence`, and the WebSocket `/gw/<id>/api/ws`.
public struct BFFClient: Sendable {
    public let baseURL: URL
    private let transport: any HTTPTransport
    private let authorizer: any BFFAuthorizer

    public init(baseURL: URL, transport: any HTTPTransport, authorizer: any BFFAuthorizer = TailnetIdentity()) {
        self.baseURL = baseURL
        self.transport = transport
        self.authorizer = authorizer
    }

    // MARK: routes

    public func gateways() async throws -> [BFFGateway] {
        struct Body: Decodable { let gateways: [BFFGateway] }
        let body: Body = try await get("/bff/gateways")
        return body.gateways
    }

    /// `ws(s)://host/gw/<id>/api/ws`. The BFF injects the gateway token; the app never holds it.
    public func gatewayWebSocketURL(gatewayId: String) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = baseURL.scheme == "http" ? "ws" : "wss"
        components.percentEncodedPath = Self.gatewayPath(gatewayId, "/api/ws")
        components.query = nil
        components.fragment = nil
        return components.url
    }

    public static func gatewayPath(_ gatewayId: String, _ path: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        let id = gatewayId.addingPercentEncoding(withAllowedCharacters: allowed) ?? gatewayId
        return "/gw/\(id)\(path)"
    }

    /// Redeem a pairing token. Sends `client:"ios"`; a BFF with B1 R2 then also returns a `deviceToken`.
    /// The `bff_device` cookie is deliberately not kept (the session never stores cookies).
    public func redeem(token: PairingToken, deviceLabel: String) async throws -> RedeemResult {
        let payload: [String: String] = ["token": token.reveal(), "deviceLabel": deviceLabel, "client": "ios"]
        let body = try JSONEncoder().encode(payload)
        let data = try await send(path: "/bff/pair/redeem", method: "POST", body: body)
        return RedeemResult(responseBody: data)
    }

    // MARK: plumbing

    func get<T: Decodable>(_ path: String) async throws -> T {
        let data = try await send(path: path, method: "GET", body: nil)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw BFFError.undecodable(detail: "\(path): \(error)")
        }
    }

    func send(path: String, method: String, body: Data?) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw BFFError.undecodable(detail: "bad path \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        // A native client sends no Origin header, so the BFF's CSRF check passes (box/bff server.mjs).
        request = await authorizer.authorize(request)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw BFFError.unreachable(detail: "\(method) \(path): \((error as? URLError)?.localizedDescription ?? "\(error)")")
        }
        guard (200..<300).contains(response.statusCode) else { throw Self.error(status: response.statusCode, data: data) }
        return data
    }

    static func error(status: Int, data: Data) -> BFFError {
        struct Envelope: Decodable {
            struct Inner: Decodable { let code: String?; let message: String? }
            let error: Inner?
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data), let inner = envelope.error, let code = inner.code {
            return .envelope(code: code, message: inner.message ?? "", status: status)
        }
        return .unexpectedStatus(status)
    }
}
