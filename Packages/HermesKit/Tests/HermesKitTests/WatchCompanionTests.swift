import Foundation
import HermesKit
import Testing

@Test func watchCompanionKeepsIdenticalProfilesOnDifferentGatewaysSeparate() throws {
    let first = WatchCompanion.BotID(gateway: UUID(), profile: "ops")
    let second = WatchCompanion.BotID(gateway: UUID(), profile: "ops")
    #expect(first != second)
    let request = WatchCompanion.Request.latestReply(second)
    let encoded = try JSONEncoder().encode(request)
    #expect(try JSONDecoder().decode(WatchCompanion.Request.self, from: encoded) == request)

    let response = WatchCompanion.Response.roster([
        .init(id: first, title: "Ops", gatewayName: "Home", state: .offline),
        .init(id: second, title: "Ops", gatewayName: "Studio", state: .working)
    ], hasUnavailableGateway: true)
    let payload = try JSONEncoder().encode(response)
    #expect(try JSONDecoder().decode(WatchCompanion.Response.self, from: payload) == response)
}

@Test func watchCompanionShowsOnlyTheNewestVisibleAnswer() {
    let messages: [SessionMessage] = [
        .init(role: "assistant", content: .text("First answer")),
        .init(role: "user", content: .text("And next?")),
        .init(role: "assistant", content: .text("Latest answer")),
        .init(role: "user", content: .text("Run in the background")),
        .init(role: "assistant", content: .text("[SILENT]")),
        .init(role: "assistant", content: .text("Internal note"), displayKind: "hidden"),
        .init(role: "user", content: .text("[CONTEXT SUMMARY]: summary")),
        .init(role: "user", content: .text("Still waiting")),
        .init(role: "tool", content: .text("Tool result"))
    ]
    #expect(WatchCompanion.latestReply(in: messages) == "Latest answer")
    #expect(WatchCompanion.latestReply(in: Array(messages.suffix(2))) == nil)
}

@Test func watchCompanionBoundsTheReplyBeforeTransferringIt() {
    let text = String(repeating: "💬", count: 3_000)
    let message = SessionMessage(role: "assistant", content: .text(text))
    #expect(WatchCompanion.latestReply(in: [message]) == String(text.prefix(2_000)) + "…")
}
