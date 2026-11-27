import Foundation

@testable import HermesBox

/// One request the stub saw, with its body already read from the stream.
struct RecordedRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data?

    var bodyJSON: [String: Any]? {
        body.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

struct StubResponse: Sendable {
    var status = 200
    var body = Data("{}".utf8)
    var headers: [String: String] = ["Content-Type": "application/json"]
    var error: URLError?

    static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> StubResponse {
        StubResponse(status: status, body: Data(text.utf8), headers: ["Content-Type": "application/json"].merging(headers) { $1 })
    }

    static func failure(_ code: URLError.Code) -> StubResponse { StubResponse(error: URLError(code)) }
}

/// A fake BFF at the `URLProtocol` layer. Every test registers its own unique host, so tests running
/// in parallel never share state and nothing ever leaves the process.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (RecordedRequest) -> StubResponse

    private static let routes = Locked<[String: Handler]>([:])
    private static let seen = Locked<[String: [RecordedRequest]]>([:])

    /// Register a fake box. Returns its base URL and a transport that talks only to the stub.
    static func box(_ handler: @escaping Handler) -> (baseURL: URL, host: String, transport: URLSessionHTTPTransport) {
        let host = "box-\(UUID().uuidString.lowercased().prefix(8)).test"
        routes.withLock { $0[host] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return (URL(string: "https://\(host)")!, host, URLSessionHTTPTransport(configuration: configuration))
    }

    static func requests(host: String) -> [RecordedRequest] { seen.withLock { $0[host] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            body = data
        }
        let recorded = RecordedRequest(
            method: request.httpMethod ?? "GET",
            path: (request.url?.path ?? "") + (request.url?.query.map { "?\($0)" } ?? ""),
            headers: request.allHTTPHeaderFields ?? [:],
            body: body)
        Self.seen.withLock { $0[host, default: []].append(recorded) }

        guard let handler = Self.routes.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let response = handler(recorded)
        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
