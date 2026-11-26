import XCTest

final class WatchCompanionUITests: XCTestCase {
    @MainActor
    func testShowsBotStatesAndOpensLatestReply() {
        let app = XCUIApplication()
        app.launchArguments = ["-HERMES_WATCH_FIXTURE", "YES"]
        app.launch()

        let ops = app.buttons["watchBot-00000000-0000-0000-0000-000000000001-ops"]
        XCTAssertTrue(ops.waitForExistence(timeout: 10))
        XCTAssertTrue(ops.label.contains("Working"))
        let ada = app.buttons["watchBot-00000000-0000-0000-0000-000000000001-writer"]
        XCTAssertTrue(ada.exists)
        XCTAssertTrue(ada.label.contains("Offline"))

        ops.tap()
        let reply = app.staticTexts["watchLatestReply"]
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        XCTAssertEqual(reply.label, "The backups finished.")
    }
}
