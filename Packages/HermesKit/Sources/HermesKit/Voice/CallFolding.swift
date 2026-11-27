import Foundation

/// Which chat rows belong to a call that ended (`callSummary`, `docs/voice.md` §4.3): its
/// messages and replies fold into one card, which sits where the last of them was.
public enum CallFolding {
    public struct Span: Sendable, Hashable {
        public var id: UUID
        public var start: Date
        public var end: Date

        public init(id: UUID, start: Date, end: Date) {
            self.id = id
            self.start = start
            self.end = end
        }
    }

    public struct Folds: Sendable, Equatable {
        /// Row id → the call it belongs to.
        public var rows: [String: UUID] = [:]
        /// The call whose card goes after this row (its last).
        public var cardAfter: [String: UUID] = [:]
    }

    /// Messages and replies inside a call's time (2 s of slack before it starts, as the first
    /// words are sent as it opens). Notices and commands stay where they are.
    public static func folds(_ items: [TranscriptItem], spans: [Span]) -> Folds {
        var folds = Folds()
        guard !spans.isEmpty else { return folds }
        for item in items {
            let at: Date?
            switch item {
            case .user(let entry): at = entry.timestamp
            case .assistant(let turn): at = turn.startedAt
            default: at = nil
            }
            guard let at, let span = spans.first(where: { at >= $0.start.addingTimeInterval(-2) && at <= $0.end }) else { continue }
            folds.rows[item.id] = span.id
        }
        for span in spans {
            if let last = items.last(where: { folds.rows[$0.id] == span.id }) {
                folds.cardAfter[last.id] = span.id
            } else if let before = items.last(where: { item in
                // A call none of whose words are in this chat (Hermes Neo: a bot's call through the box): its card
                // goes after the last message from before it ended, unless another call's card is there.
                guard folds.cardAfter[item.id] == nil else { return false }
                switch item {
                case .user(let entry): return entry.timestamp.map { $0 <= span.end } ?? false
                case .assistant(let turn): return turn.startedAt.map { $0 <= span.end } ?? false
                default: return false
                }
            }) {
                folds.cardAfter[before.id] = span.id
            }
        }
        return folds
    }
}
