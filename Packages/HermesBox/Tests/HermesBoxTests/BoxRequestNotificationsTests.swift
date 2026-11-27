import Foundation
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
}
