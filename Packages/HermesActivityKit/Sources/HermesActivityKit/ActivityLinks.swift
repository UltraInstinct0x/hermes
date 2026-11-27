import Foundation

/// Where a tap on a Live Activity goes. The widget builds the URL, the app parses it. The scheme is
/// registered in the app's Info.plist through ios/project.yml (CFBundleURLTypes).
public enum ActivityLink: Equatable, Sendable {
    /// The Waiting list: every approval and question, with the answer buttons.
    case waiting
    /// A bot's chat.
    case bot(key: String)
    case request(RequestReference)
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
                URLQueryItem(name: "generation", value: String(ref.executionGeneration)),
            ]
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
            guard let key, let request = field("request"),
                  let ref = RequestReference(botKey: key, requestId: request, sessionId: field("session"),
                                             executionGeneration: field("generation").flatMap(Int.init)) else { return nil }
            self = .request(ref)
        default: return nil
        }
    }
}
