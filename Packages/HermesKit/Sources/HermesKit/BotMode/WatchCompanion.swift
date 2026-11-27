import Foundation
import HermesMarkdown
import HermesPush

public enum WatchCompanion {
    public enum Request: Codable, Sendable, Equatable {
        case roster
        case latestReply(BotID)
        case openRequests
        case answer(RequestCard, RequestAnswer)
    }

    public enum Response: Codable, Sendable, Equatable {
        case roster([Bot], hasUnavailableGateway: Bool)
        case latestReply(String?)
        case unavailable
        case botNotFound
        case openRequests([RequestCard], incomplete: Bool)
        case answer(AnswerStatus)
    }

    public enum AnswerStatus: String, Codable, Sendable, Equatable {
        case sent, noLongerPending, invalidAnswer, unavailable
    }

    public enum RequestAnswer: Codable, Sendable, Equatable {
        case approval(Decision)
        case clarify([String: ClarifyAnswer])
    }

    public enum Decision: String, Codable, Sendable, Equatable {
        case once, deny
    }

    public enum ClarifyAnswer: Codable, Sendable, Equatable {
        case text(String)
        case choices([String])
    }

    public struct RequestCard: Identifiable, Codable, Sendable, Equatable {
        public struct ID: Hashable, Codable, Sendable {
            public let row: LedgerRow.ID?
            public let requestID: String
            let sessionID: String?
            let profile: String
        }

        public struct Question: Identifiable, Codable, Sendable, Equatable {
            public let id: String
            public let prompt: String
            public let choices: [String]
            public let multiSelect: Bool

            public init(id: String, prompt: String, choices: [String], multiSelect: Bool = false) {
                self.id = id
                self.prompt = prompt
                self.choices = choices
                self.multiSelect = multiSelect
            }
        }

        public enum Content: Codable, Sendable, Equatable {
            case approval(command: String, decisions: [Decision])
            case clarify([Question])
            case openOnPhone(isApproval: Bool)
        }

        public let id: ID
        public let source: String
        public let content: Content
        public let expiresAt: TimeInterval?

        public init(requestID: String, source: String, content: Content, expiresAt: TimeInterval? = nil) {
            id = ID(row: nil, requestID: requestID, sessionID: nil, profile: "")
            self.source = source
            self.content = content
            self.expiresAt = expiresAt
        }

        public init?(row: LedgerRow, snapshot: JSONValue, source: String, now: Date = .now) {
            guard row.state == "open", let sessionID = row.sessionID, !sessionID.isEmpty,
                  let request = row.openRequest(in: snapshot) else { return nil }
            id = Self.identity(of: row)
            self.source = source
            expiresAt = request.params["expires_at"]?.doubleValue ?? row.expiresAt
            if Self.isExpired(at: now, expiresAt: expiresAt) { return nil }

            switch request.method {
            case "approval":
                guard let approval = GatewayTurnDecoder.approval(from: request) else { return nil }
                if approval.smartDenied || approval.isMemorySave || approval.isPaymentFill {
                    content = .openOnPhone(isApproval: true)
                } else {
                    var decisions: [Decision] = []
                    if let command = approval.command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       approval.choices.contains(.once) {
                        decisions.append(.once)
                    }
                    if approval.choices.contains(.deny) { decisions.append(.deny) }
                    content = .approval(command: approval.command ?? approval.summary, decisions: decisions)
                }
            case "clarify":
                guard let clarify = HermesRequest.parse(request), case .clarify(let questions) = clarify.kind,
                      Set(questions.map(\.id)).count == questions.count else { return nil }
                let pending = questions.filter { request.params["answers"]?[$0.id] == nil }
                guard !pending.isEmpty else { return nil }
                content = .clarify(pending.map {
                    Question(id: $0.id, prompt: VisibleText.of($0.question), choices: $0.choices, multiSelect: $0.multiSelect)
                })
            default:
                return nil
            }
        }

        public static func identity(of row: LedgerRow) -> ID {
            ID(row: row.id, requestID: row.requestID, sessionID: row.sessionID, profile: row.profileID ?? row.profile)
        }

        public func isExpired(at now: Date = .now) -> Bool {
            Self.isExpired(at: now, expiresAt: expiresAt)
        }

        private static func isExpired(at now: Date, expiresAt: TimeInterval?) -> Bool {
            expiresAt.map { $0 <= now.timeIntervalSince1970 } ?? false
        }

        public func result(for answer: RequestAnswer) -> JSONValue? {
            switch (content, answer) {
            case (.approval(_, let decisions), .approval(let choice)) where decisions.contains(choice):
                return .object(["choice": .string(choice.rawValue)])
            case (.clarify(let questions), .clarify(let answers)) where questions.count == answers.count:
                var values: [String: JSONValue] = [:]
                for question in questions {
                    switch answers[question.id] {
                    case .text(let text) where !question.multiSelect:
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return nil }
                        values[question.id] = .string(question.choices.contains(text) ? text : trimmed)
                    case .choices(let choices) where question.multiSelect:
                        let selected = Set(choices)
                        guard !selected.isEmpty, selected.isSubset(of: question.choices) else { return nil }
                        values[question.id] = .array(question.choices.filter(selected.contains).map(JSONValue.string))
                    default:
                        return nil
                    }
                }
                return .object(["answers": .object(values)])
            default:
                return nil
            }
        }
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
            let text = watchReplyText(turn.answer)
            let limit = 2_000
            let preview = String(text.unicodeScalars.prefix(limit))
            return preview == text ? preview : preview + "…"
        }
        return nil
    }

    private static func watchReplyText(_ answer: String) -> String {
        let fallback = String(localized: "View this card in Hermes on your iPhone.")
        return ReplySplitter.split(answer).map { segment in
            switch segment {
            case .markdown(let markdown): markdown
            case .widget(let directive): directive.alt ?? fallback
            case .inline, .typed, .unreadable: fallback
            }
        }.joined(separator: "\n\n")
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
