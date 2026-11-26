import Foundation

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

    public static func latestReply(in messages: [SessionMessage]) -> String? {
        for item in TranscriptBuilder.build(messages, hidesSilence: true).reversed() {
            guard case .assistant(let turn) = item, !turn.answer.isEmpty else { continue }
            let limit = 2_000
            let preview = String(turn.answer.unicodeScalars.prefix(limit))
            return preview == turn.answer ? preview : preview + "…"
        }
        return nil
    }
}
