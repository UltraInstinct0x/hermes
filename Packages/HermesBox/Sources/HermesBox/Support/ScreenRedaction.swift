import Foundation

/// Takes a one-time screen ticket out of any text that may be shown or copied. A failed WebSocket carries the
/// URL it dialled (`NSErrorFailingURLStringKey=wss://...?display_ticket=...`); the ticket is a credential for
/// that one stream, so it never reaches the screen, the clipboard or a log (CLAUDE.md: never print secrets).
public enum ScreenRedaction {
    public static let placeholder = "redacted"

    /// Query parameters whose value is a credential. Matched case-insensitively; the value ends at `&`, whitespace,
    /// a quote, a bracket or a comma, so a whole `NSError` description is cleaned in one pass.
    private static let pattern = try? NSRegularExpression(
        pattern: #"((?:display_|stream_|viewer_)?ticket)=([^&\s"'<>,;)\]}]*)"#, options: [.caseInsensitive])

    public static func redactTickets(_ text: String) -> String {
        guard let pattern else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return pattern.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1=\(placeholder)")
    }
}
