import Foundation

/// Where a tap on a Live Activity goes. The widget builds the URL, the app parses it. The scheme is
/// registered in the app's Info.plist through ios/project.yml (CFBundleURLTypes).
public enum ActivityLink: Equatable, Sendable {
    /// The Waiting list: every approval and question, with the answer buttons.
    case waiting
    /// A bot's chat.
    case bot(key: String)
    case request(RequestReference)
    case lookup(botKey: String, requestId: String)
    public static let scheme = "hermesneo"

    public var url: URL {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        switch self {
        case .waiting:
            parts.host = "requests"
        case .bot(let key):
            parts.host = "request-bot"
            parts.queryItems = [URLQueryItem(name: "key", value: key)]
        case .request(let ref):
            parts.host = "request-card"
            parts.queryItems = [
                URLQueryItem(name: "key", value: ref.botKey),
                URLQueryItem(name: "session", value: ref.sessionId),
                URLQueryItem(name: "request", value: ref.requestId),
            ]
            if let generation = ref.executionGeneration {
                parts.queryItems?.append(URLQueryItem(name: "generation", value: String(generation)))
            }
        case .lookup(let botKey, let requestId):
            parts.host = "request-lookup"
            parts.queryItems = [URLQueryItem(name: "key", value: botKey), URLQueryItem(name: "request", value: requestId)]
        }
        // Components with a scheme and a host always form a URL.
        return parts.url ?? URL(fileURLWithPath: "/")
    }

    /// Nil for any other URL: the app ignores what it did not make.
    public init?(url: URL) {
        guard url.scheme == Self.scheme, let host = url.host else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func field(_ name: String) -> String? {
            let matching = items.filter { $0.name == name }
            return matching.count == 1 ? matching.first?.value : nil
        }
        let key = field("key")
        switch host {
        case "requests": self = .waiting
        case "request-bot": guard let key, !key.isEmpty else { return nil }; self = .bot(key: key)
        case "request-card":
            let generations = items.filter { $0.name == "generation" }
            let generation = field("generation").flatMap(Int.init)
            guard generations.isEmpty || generation != nil else { return nil }
            guard let key, let request = field("request"),
                  let ref = RequestReference(botKey: key, requestId: request, sessionId: field("session"),
                                             executionGeneration: generation) else { return nil }
            self = .request(ref)
        case "request-lookup":
            guard let key, !key.isEmpty, let request = field("request"), !request.isEmpty else { return nil }
            self = .lookup(botKey: key, requestId: request)
        default: return nil
        }
    }
}
