import Foundation

/// One HTTP exchange. Production: `URLSessionHTTPTransport`; tests: a `URLProtocol` stub behind the
/// same type, so no test ever touches a real BFF.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession

    /// An ephemeral session that never stores or sends cookies: the BFF sets a `bff_device` cookie on
    /// redeem, and that cookie value is a credential this app must not keep (S18 P0: no device secret
    /// unless the BFF returns a separate device token).
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}
