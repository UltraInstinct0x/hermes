import Foundation
import HermesActivityKit
import Testing

@testable import HermesBox

@Suite("Hermes Neo: the box's request alerts and what an action on one means")
struct BoxRequestNotificationsTests {
    /// What `push-planner.mjs` puts at the top level of a request alert.
    private let alert: [AnyHashable: Any] = [
        "aps": ["alert": ["title": "Hermes Bot", "body": "rm -rf /tmp/build"], "category": "hermes.request.approval"],
        "botKey": "oracle::hermesbot", "requestId": "req-9",
    ]

    @Test func legacyActionsOnBoxAlertsOnlyOpenTheApp() {
        #expect(BoxRequestNotifications.reply(userInfo: alert, action: "hermes.request.approve")
            == .open(botKey: "oracle::hermesbot"))
        #expect(BoxRequestNotifications.reply(userInfo: alert, action: "hermes.request.deny")
            == .open(botKey: "oracle::hermesbot"))
    }

    @Test func aTapOpensAndASwipeDoesNothing() {
        #expect(BoxRequestNotifications.reply(userInfo: alert, action: "com.apple.UNNotificationDefaultActionIdentifier") == .open(botKey: "oracle::hermesbot"))
        #expect(BoxRequestNotifications.reply(userInfo: alert, action: "com.apple.UNNotificationDismissActionIdentifier") == .dismissed)
    }

    @Test func upstreamsRelayNoticesAndOtherPayloadsAreNotTheBoxs() {
        #expect(BoxRequestNotifications.reply(userInfo: ["aps": [:], "hermes": "sealed", "botKey": "oracle::hermesbot", "requestId": "r1"], action: "x") == nil)
        #expect(BoxRequestNotifications.reply(userInfo: ["aps": ["alert": "Test notification"]], action: "x") == nil)
        #expect(BoxRequestNotifications.reply(userInfo: ["botKey": "no-separator"], action: "x") == nil)
    }

    @Test func aChatAlertWithoutARequestIsNotIntercepted() {
        #expect(BoxRequestNotifications.reply(userInfo: ["botKey": "oracle::hermesbot"], action: "hermes.request.approve") == nil)
    }

    @Test func theIdentifiersAreTheOnesTheBoxSends() {
        // box/bff/push-planner.mjs CATEGORIES
        #expect(BoxRequestNotifications.approvalCategory == "hermes.request.approval")
        #expect(BoxRequestNotifications.questionCategory == "hermes.request.question")
    }

    @Test func onlyExactPlainCommandsCanBeAnswered() throws {
        var payload = alert
        payload["sessionId"] = "session-1"
        payload["executionGeneration"] = 7
        payload["command"] = "git status"
        let ref = try #require(RequestReference(botKey: "oracle::hermesbot", requestId: "req-9",
                                                 sessionId: "session-1", executionGeneration: 7))
        #expect(BoxRequestNotifications.reply(userInfo: payload, action: BoxRequestNotifications.approveAction, answersEnabled: true) == nil)
        payload["approvalKind"] = "command"
        #expect(BoxRequestNotifications.reply(userInfo: payload, action: BoxRequestNotifications.approveAction) == nil)
        #expect(BoxRequestNotifications.reply(userInfo: payload, action: BoxRequestNotifications.approveAction, answersEnabled: true)
            == .answer(ref, .approval(allow: true), shown: "git status"))
        payload["approvalKind"] = "restricted"
        #expect(BoxRequestNotifications.reply(userInfo: payload, action: BoxRequestNotifications.denyAction, answersEnabled: true) == nil)
    }

    @Test func nativeQuestionChoicesAndTypingMatchTheDisplayedActions() throws {
        var payload = alert
        payload["aps"] = ["category": BoxRequestNotifications.questionCategory]
        payload["sessionId"] = "session-1"
        payload["executionGeneration"] = 7
        payload["prompt"] = "Which color?"
        payload["choices"] = ["Red", "Blue"]
        payload["needsApp"] = false
        let ref = try #require(RequestReference(botKey: "oracle::hermesbot", requestId: "req-9",
                                                 sessionId: "session-1", executionGeneration: 7))
        #expect(BoxRequestNotifications.reply(userInfo: payload, action: "hermes.request.choice.1", answersEnabled: true)
            == .answer(ref, .clarification("Blue"), shown: "Which color?"))
        #expect(BoxRequestNotifications.reply(userInfo: payload, action: "hermes.request.choice.2", answersEnabled: true) == nil)
        payload["needsApp"] = true
        #expect(BoxRequestNotifications.reply(userInfo: payload, action: BoxRequestNotifications.typeAction, answersEnabled: true) == .type(ref))
        #expect(BoxRequestNotifications.reply(userInfo: payload, action: "hermes.request.choice.1", answersEnabled: true) == nil)
    }
}
