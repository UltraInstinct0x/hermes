import Foundation

extension BFFClient {
    /// `ws(s)://host/gw/<id>/api/call/ws`: the call hub through the BFF (S19 section 11). Off on the box until the hub
    /// is deployed: the BFF answers 404 and the app says calls are not enabled on that machine.
    public func callWebSocketURL(gatewayId: String) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = baseURL.scheme == "http" ? "ws" : "wss"
        components.percentEncodedPath = Self.gatewayPath(gatewayId, "/api/call/ws")
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// `/voice-new`: the box sets this bot's voice chat aside, so the next call (from the phone or the Mac) starts fresh.
    public func resetVoiceChat(botKey: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["bot_key": botKey])
        _ = try await send(path: "/bff/voice/reset", method: "POST", body: body)
    }
}
