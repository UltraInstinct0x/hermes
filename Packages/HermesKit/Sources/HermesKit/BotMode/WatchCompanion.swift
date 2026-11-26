import Foundation
import HermesMarkdown

public enum WatchCompanion {
    public enum Request: Codable, Sendable, Equatable {
        case roster
        case latestReply(BotID)
    }

    public enum Response: Codable, Sendable, Equatable {
        case roster([Bot], hasUnavailableGateway: Bool)
        case latestReply(String?)
        case unavailable
        case botNotFound
    }

    public struct BotID: Hashable, Codable, Sendable {
        public let gateway: UUID
        public let profile: String

        public init(gateway: UUID, profile: String) {
            self.gateway = gateway
            self.profile = profile
        }
    }

    public struct Bot: Identifiable, Codable, Sendable, Equatable {
        public enum State: String, Codable, Sendable {
            case idle, working, offline
        }

        public let id: BotID
        public let title: String
        public let gatewayName: String
        public let state: State

        public init(id: BotID, title: String, gatewayName: String, state: State) {
            self.id = id
            self.title = title
            self.gatewayName = gatewayName
            self.state = state
        }
    }

    public static func latestReply(in messages: [SessionMessage], hasEarlier: Bool = false) -> String? {
        let items = TranscriptBuilder.build(messages, hidesSilence: true)
        // A turn at the page boundary might be echoing a delivery on an earlier page.
        let complete = hasEarlier ? items.drop(while: { item in
            switch item {
            case .assistant: true
            case .user(let entry): entry.isSteer
            default: false
            }
        }) : items[...]
        for item in complete.reversed() {
            guard case .assistant(let turn) = item, !turn.answer.isEmpty else { continue }
            let limit = 2_000
            let preview = String(turn.answer.unicodeScalars.prefix(limit))
            return preview == turn.answer ? preview : preview + "…"
        }
        return nil
    }

    public static func gatewayLabels(for bots: [Bot]) -> [BotID: String] {
        let byTitle = Dictionary(grouping: bots) { labelKey($0.title) }
        var labels: [BotID: String] = [:]
        for (title, matches) in byTitle where Set(matches.map(\.id.gateway)).count > 1 {
            for bot in matches where !labelKey(bot.gatewayName).isEmpty && labelKey(bot.gatewayName) != title {
                labels[bot.id] = bot.gatewayName
            }
        }
        return labels
    }

    private static func labelKey(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive], locale: nil)
    }

    public static func formattedReply(_ markdown: String) -> AttributedString {
        let units = ReplyPlainText.units(MarkdownDocument(parsing: markdown).blocks)
        var result = AttributedString()
        for unit in units {
            let content: AttributedString
            switch unit.content {
            case .paragraph(let inlines):
                content = styled(inlines)
            case .heading(_, let inlines):
                content = styled(inlines, intent: .stronglyEmphasized)
            case .block(.codeBlock):
                content = styledText(unit.text, intent: .code)
            default:
                content = AttributedString(unit.text)
            }
            guard !content.characters.isEmpty || !unit.prefix.isEmpty else { continue }
            if !result.characters.isEmpty { result += AttributedString(unit.separator) }
            result += AttributedString(unit.prefix) + content
        }
        return result
    }

    private static func styled(
        _ inlines: [MarkdownInline], intent: InlinePresentationIntent = []
    ) -> AttributedString {
        inlines.reduce(into: AttributedString()) { result, inline in
            let span = switch inline {
            case .emphasis(let content): styled(content, intent: intent.union(.emphasized))
            case .strong(let content): styled(content, intent: intent.union(.stronglyEmphasized))
            case .strikethrough(let content): styled(content, intent: intent.union(.strikethrough))
            case .link(_, let content): styled(content, intent: intent)
            case .code(let code): styledText(code, intent: intent.union(.code))
            default: styledText(inline.plainText, intent: intent)
            }
            result += span
        }
    }

    private static func styledText(_ text: String, intent: InlinePresentationIntent) -> AttributedString {
        var result = AttributedString(text)
        if !intent.isEmpty { result.inlinePresentationIntent = intent }
        return result
    }
}
