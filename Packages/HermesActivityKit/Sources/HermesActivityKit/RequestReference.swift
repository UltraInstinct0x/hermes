import Foundation

public struct RequestReference: Codable, Hashable, Sendable {
    public let botKey: String
    public let requestId: String
    public let sessionId: String
    public let executionGeneration: Int?
    public var isFrame: Bool { requestId.hasPrefix("srq-") }

    public init?(botKey: String, requestId: String, sessionId: String?, executionGeneration: Int?) {
        let bot = botKey.components(separatedBy: "::")
        guard bot.count == 2, bot.allSatisfy(Self.isIdentifier), Self.isIdentifier(requestId),
              let sessionId, Self.isIdentifier(sessionId),
              requestId.hasPrefix("srq-") ? requestId.count > 4 && executionGeneration == nil
                : executionGeneration.map({ $0 >= 0 }) == true else { return nil }
        self.botKey = botKey
        self.requestId = requestId
        self.sessionId = sessionId
        self.executionGeneration = executionGeneration
    }

    public init?(_ state: RequestActivityAttributes.ContentState) {
        self.init(botKey: state.botKey, requestId: state.requestId, sessionId: state.sessionId,
                  executionGeneration: state.executionGeneration)
    }

    private static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && !value.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
    }
}

public enum RequestSelection: Sendable, Equatable {
    case approval(allow: Bool)
    case clarification(String, questionId: String? = nil)
}

public enum InlineApproval {
    public static func isOrdinary(smartDenied: Bool?, memorySave: Bool?, paymentFill: Bool?) -> Bool {
        smartDenied == false && memorySave == false && paymentFill == false
    }

    public static func showsWholeCommand(_ command: String) -> Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && command.count <= 240 && command.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count <= 4
    }
}
