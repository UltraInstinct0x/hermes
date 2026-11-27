import Foundation

/// Where a tap on a Live Activity goes. The widget builds the URL, the app parses it. The scheme is
/// registered in the app's Info.plist through ios/project.yml (CFBundleURLTypes).
public enum ActivityLink: Equatable, Sendable {
    /// The Waiting list: every approval and question, with the answer buttons.
    case waiting
    /// A bot's chat.
    case bot(key: String)
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
        }
        // Components with a scheme and a host always form a URL.
        return parts.url ?? URL(fileURLWithPath: "/")
    }

    /// Nil for any other URL: the app ignores what it did not make.
    public init?(url: URL) {
        guard url.scheme == Self.scheme, let host = url.host else { return nil }
        let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "key" }?.value
        switch host {
        case "requests": self = .waiting
        case "request-bot": guard let key, !key.isEmpty else { return nil }; self = .bot(key: key)
        default: return nil
        }
    }
}
