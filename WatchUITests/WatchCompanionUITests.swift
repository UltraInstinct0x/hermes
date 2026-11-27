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
        XCTAssertTrue(ada.exists)
        XCTAssertTrue(ada.label.contains("Offline"))
        XCTAssertFalse(ada.label.contains("Hermes"))

        hermes.tap()
        let reply = app.staticTexts["watchLatestReply"]
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        XCTAssertEqual(reply.label, "The backups finished.")
    }
}
