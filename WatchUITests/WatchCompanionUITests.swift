import XCTest

final class WatchCompanionUITests: XCTestCase {
    @MainActor
    func testShowsBotStatesAndOpensLatestReply() {
        let app = XCUIApplication()
        app.launchArguments = ["-HERMES_WATCH_FIXTURE", "YES"]
        app.launch()

        let hermes = app.buttons["watchBot-00000000-0000-0000-0000-000000000001-default"]
        XCTAssertTrue(hermes.waitForExistence(timeout: 10))
        XCTAssertTrue(hermes.label.contains("Working"))
        XCTAssertEqual(hermes.label.components(separatedBy: "Hermes").count, 2)
        let ada = app.buttons["watchBot-00000000-0000-0000-0000-000000000001-writer"]
        if !ada.exists { app.swipeUp() }
        XCTAssertTrue(ada.exists)
        XCTAssertTrue(ada.label.contains("Offline"))
        XCTAssertFalse(ada.label.contains("Hermes"))

        if !hermes.isHittable { app.swipeDown() }
        hermes.tap()
        let reply = app.staticTexts["watchLatestReply"]
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        XCTAssertEqual(reply.label, "The backups finished.")
    }

    @MainActor
    func testShowsRequestsAndSendsClarifyAnswer() {
        let app = launchRequests()
        let approval = app.buttons["watchRequest-srq-backup"]
        XCTAssertTrue(approval.waitForExistence(timeout: 5))
        XCTAssertTrue(approval.label.contains("Ops"))
        let clarify = app.buttons["watchRequest-srq-report"]
        XCTAssertTrue(clarify.exists)
        capture("watch-requests", in: app)

        clarify.tap()
        let pick = app.buttons["PDF"]
        let markdown = app.buttons["Markdown"]
        let send = app.buttons["Send"]
        XCTAssertTrue(pick.waitForExistence(timeout: 5))
        XCTAssertFalse(pick.isSelected)
        XCTAssertFalse(markdown.isSelected)
        capture("watch-clarify-unselected", in: app)
        if !send.isHittable { app.swipeUp() }
        XCTAssertFalse(send.isEnabled)
        if !pick.isHittable { app.swipeDown() }
        pick.tap()
        XCTAssertTrue(pick.isSelected)
        XCTAssertFalse(markdown.isSelected)
        capture("watch-clarify-choice", in: app)
        if !send.isHittable { app.swipeUp() }
        XCTAssertTrue(send.isEnabled)
        send.tap()
        let status = app.staticTexts["watchAnswerStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "Answer sent")
        XCTAssertEqual(app.staticTexts["watchAnswerSource"].label, "Research Buddy")
        XCTAssertEqual(app.staticTexts["watchSubmittedAnswer"].label, "PDF")
        capture("watch-clarify-answer", in: app)
        let back = app.buttons["Back to Requests"]
        if !back.isHittable { app.swipeUp() }
        back.tap()
        XCTAssertTrue(approval.waitForExistence(timeout: 5))
        XCTAssertTrue(clarify.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testApprovalReceiptShowsDecisionAndOwner() {
        let app = launchRequests()
        let approval = app.buttons["watchRequest-srq-backup"]
        XCTAssertTrue(approval.waitForExistence(timeout: 5))
        approval.tap()

        let allow = app.buttons["Allow Once"]
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
        if !allow.isHittable { app.swipeUp() }
        allow.tap()
        let status = app.staticTexts["watchAnswerStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "Answer sent")
        XCTAssertEqual(app.staticTexts["watchAnswerSource"].label, "Ops · Backups")
        XCTAssertEqual(app.staticTexts["watchSubmittedAnswer"].label, "Allowed once")
    }

    @MainActor
    func testShowsApprovalCommandAndReportsSettledRequest() {
        let app = launchRequests()
        let approval = app.buttons["watchRequest-srq-backup"]
        XCTAssertTrue(approval.waitForExistence(timeout: 5))
        approval.tap()

        XCTAssertTrue(app.staticTexts["tar -czf backup.tar.gz reports/"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Allow Once"].exists)
        capture("watch-approval", in: app)
        let deny = app.buttons["Deny"]
        if !deny.isHittable { app.swipeUp() }
        deny.tap()
        let status = app.staticTexts["watchAnswerStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("no longer pending"))
    }

    @MainActor
    private func launchRequests() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HERMES_WATCH_FIXTURE", "YES"]
        app.launch()
        let requests = app.buttons["Requests"]
        XCTAssertTrue(requests.waitForExistence(timeout: 5))
        requests.tap()
        return app
    }

    @MainActor
    private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
