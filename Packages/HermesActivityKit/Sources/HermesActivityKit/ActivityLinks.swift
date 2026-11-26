import Foundation

/// Where a tap on a Live Activity goes. The widget builds the URL, the app parses it. The scheme is
/// registered in the app's Info.plist through ios/project.yml (CFBundleURLTypes).
public enum ActivityLink: Equatable, Sendable {
    /// The Waiting list: every approval and question, with the answer buttons.
    case waiting
    /// A bot's chat.
    case bot(key: String)
    /// A bot's chat with the call screen up.
    case call(botKey: String)

    public static let scheme = "hermesbot"

    public var url: URL {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        switch self {
        case .waiting:
            parts.host = "waiting"
        case .bot(let key):
            parts.host = "bot"
            parts.queryItems = [URLQueryItem(name: "key", value: key)]
        case .call(let botKey):
            parts.host = "call"
            parts.queryItems = [URLQueryItem(name: "key", value: botKey)]
        }
        // Components with a scheme and a host always form a URL.
        return parts.url ?? URL(fileURLWithPath: "/")
    }

    /// Nil for any other URL: the app ignores what it did not make.
    public init?(url: URL) {
        guard url.scheme == Self.scheme, let host = url.host else { return nil }
        let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "key" }?.value
        switch host {
        case "waiting": self = .waiting
        case "bot": guard let key, !key.isEmpty else { return nil }; self = .bot(key: key)
        case "call": guard let key, !key.isEmpty else { return nil }; self = .call(botKey: key)
        default: return nil
        }
    }
}
