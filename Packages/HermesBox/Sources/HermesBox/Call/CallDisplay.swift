import Foundation

// What a bot puts on the call screen (hub frames `call.display` and `call.display.clear`, `box/call-hub/protocol.mjs`).
// Pure: no socket, no UI. The hub validates strictly; the phone re-checks every link before it draws or opens one.

public enum CallDisplayKind: String, Sendable, Equatable, CaseIterable {
    case markdown
    case url
    case image
}

public struct CallDisplayItem: Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: CallDisplayKind
    public var title: String
    /// Markdown text (kind `markdown` only).
    public var body: String?
    /// The link as the hub sent it (kinds `url` and `image`). Never opened without `CallDisplayPresentation.secureURL`.
    public var url: String?

    public init(id: String, kind: CallDisplayKind, title: String, body: String? = nil, url: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.url = url
    }
}

/// The items on the screen, newest first. At most `limit` (the hub's own cap); the same `id` replaces the old item.
public struct CallDisplayList: Sendable, Equatable {
    public static let limit = 5
    public private(set) var items: [CallDisplayItem] = []

    public init() {}

    public var isEmpty: Bool { items.isEmpty }

    public mutating func apply(_ item: CallDisplayItem) {
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
    }

    public mutating func clear() { items = [] }
}

/// The words and the safety checks of the call screen's cards. No em-dashes.
public enum CallDisplayPresentation {
    public static let clearTitle = "Clear"
    public static let clearHint = "Removes what the bot showed from this screen. The call goes on"
    public static let imageUnavailable = "This picture cannot be shown."
    public static let linkUnavailable = "This link cannot be opened."

    public static func title(_ item: CallDisplayItem) -> String {
        let trimmed = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kindName(item.kind) : trimmed
    }

    public static func kindName(_ kind: CallDisplayKind) -> String {
        switch kind {
        case .markdown: "Note"
        case .url: "Link"
        case .image: "Picture"
        }
    }

    /// SF Symbol per kind.
    public static func symbol(_ kind: CallDisplayKind) -> String {
        switch kind {
        case .markdown: "doc.text"
        case .url: "link"
        case .image: "photo"
        }
    }

    /// "Link, Report".
    public static func accessibilityLabel(_ item: CallDisplayItem) -> String {
        "\(kindName(item.kind)), \(title(item))"
    }

    public static func pageLabel(index: Int, count: Int) -> String { "Item \(index + 1) of \(count)" }

    /// The link when it is https, has no credentials and points at a public host; nil for anything else, whatever the hub said.
    public static func secureURL(_ item: CallDisplayItem) -> URL? {
        guard item.kind != .markdown, let text = item.url else { return nil }
        return secureURL(text)
    }

    public static func secureURL(_ text: String) -> URL? {
        guard text.count <= 1000, !text.contains(where: { $0.isWhitespace || $0.isNewline }),
            let components = URLComponents(string: text), components.scheme?.lowercased() == "https",
            components.user == nil, components.password == nil,
            let host = components.host, !isPrivate(host: host), let url = components.url
        else { return nil }
        return url
    }

    /// Inline markdown only (bold, italic, code, links). Links that are not https lose their link. Plain text when it cannot be read.
    public static func attributed(markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard var text = try? AttributedString(markdown: markdown, options: options) else { return AttributedString(markdown) }
        for run in text.runs {
            guard let link = run.link, secureURL(link.absoluteString) == nil else { continue }
            text[run.range].link = nil
        }
        return text
    }

    private static func isPrivate(host raw: String) -> Bool {
        let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if host.isEmpty || host.hasPrefix("[") || host.contains(":") || !host.contains(".") { return true }
        let internalSuffixes = ["localhost", "local", "internal", "lan", "home", "corp", "intranet", "ts.net", "onion"]
        if internalSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, parts.count == 4 else { return host.allSatisfy { $0.isNumber || $0 == "." } }
        let (a, b) = (numbers[0], numbers[1])
        return a == 0 || a == 10 || a == 127 || a >= 224 || (a == 100 && (64...127).contains(b)) || (a == 169 && b == 254)
            || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 192 && b == 0 && numbers[2] == 0)
    }
}
