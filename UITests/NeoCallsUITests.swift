import XCTest

/// Hermes Neo's calls from your bots (`docs/neo-calls.md`), on iPhone and iPad:
/// - Settings → Calls: the switch, Test ring, and what turning it on says when no box answers
///   (the mocks have no box, so pairing on the gateway login fails and must say so, with Retry);
/// - the call screen, the end screen and the call pill, on a scripted call
///   (`-NEO_CALL_DEMO transcript|ended|bar`, Debug only). No box, no audio.
/// Start the mock first: `python3 -I Tools/mock-hermes/backend.py --port 19119 --gateway-port 18642`.
final class NeoCallsUITests: XCTestCase {
    private let gateway: URL = setting("HermesMockGateway", "http://127.0.0.1:18642")
    private let backend: URL = setting("HermesMockBackend", "http://127.0.0.1:19119")

    override func setUp() async throws {
        continueAfterFailure = false
    }

    /// Off by default: the switch reads off, and Test ring waits for it.
    @MainActor
    func testCallsSectionIsOffWithTestRingDisabled() throws {
        let app = launch(["-HERMES_OPEN", "settings", "-hermes.callsFromBots.enabled", "NO"])
        let toggle = callsSwitch(in: app)
        XCTAssertEqual(toggle.value as? String, "0", "Calls from your bots isn't off")
        let testRing = app.buttons["Test ring"]
        XCTAssertTrue(testRing.waitForExistence(timeout: 5), "no Test ring row")
        XCTAssertFalse(testRing.isEnabled, "Test ring can be tapped with calls off")
        attach("Settings, Calls off")
    }

    /// On, with no box behind the gateway: it asks for the microphone, tries to pair on the gateway
    /// login, and shows why it couldn't with Retry and Copy Details, instead of failing quietly.
    @MainActor
    func testTurningCallsOnWithoutABoxSaysWhyWithRetry() throws {
        let app = launch(["-HERMES_OPEN", "settings", "-hermes.callsFromBots.enabled", "NO"])
        let toggle = callsSwitch(in: app)
        flip(toggle)
        allowMicrophone()
        XCTAssertTrue(becomes(toggle, "value == '1'", timeout: 15), "Calls from your bots didn't turn on")
        let retry = app.buttons["Retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 60), "no Retry after pairing failed")
        XCTAssertTrue(app.buttons["Copy Details"].exists, "no Copy Details beside Retry")
        let sentence = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'try again'")).firstMatch
        XCTAssertTrue(sentence.exists, "no sentence saying what went wrong")
        XCTAssertFalse(app.buttons["Test ring"].isEnabled, "Test ring can be tapped before the box has the phone")
        attach("Settings, Calls on without a box")
        retry.tap()
        XCTAssertTrue(retry.waitForExistence(timeout: 60), "Retry went away without pairing")
        flip(toggle)
        XCTAssertTrue(becomes(toggle, "value == '0'", timeout: 15), "Calls from your bots didn't turn off")
        XCTAssertFalse(app.buttons["Copy Details"].exists, "the failure stayed after turning calls off")
    }

    /// The call screen on a scripted call: the transcript, the engine, and the call's buttons.
    /// Hiding it leaves the call running, with its pill over the app; the pill opens it again.
    @MainActor
    func testCallScreenShowsTranscriptAndControlsAndHidesToThePill() throws {
        let app = launch(["-NEO_CALL_DEMO", "transcript"])
        let hide = app.buttons["Hide the call"]
        XCTAssertTrue(hide.waitForExistence(timeout: 30), "no call screen")
        XCTAssertTrue(text("You: Is my flight still on time?", in: app).waitForExistence(timeout: 10), "no line of yours in the transcript")
        XCTAssertTrue(text("Hermes Bot: SXS 123 is on time", in: app).exists, "no bot line in the transcript")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Engine '")).firstMatch.exists, "no engine")
        for control in ["Mute", "Audio route", "Type", "View", "End call"] {
            XCTAssertTrue(app.descendants(matching: .any)[control].exists, "no \(control) button")
        }
        attach("Call screen")
        hide.tap()
        XCTAssertTrue(becomes(hide, "exists == false", timeout: 10), "hiding didn't close the call screen")
        let pill = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Talking with Hermes Bot'")).firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 10), "no call pill after hiding the call")
        attach("Call pill")
        pill.tap()
        XCTAssertTrue(hide.waitForExistence(timeout: 10), "the pill didn't open the call again")
    }

    /// Mute on the call screen turns into Unmute and back.
    @MainActor
    func testMuteOnTheCallScreen() throws {
        let app = launch(["-NEO_CALL_DEMO", "transcript"])
        let mute = app.buttons["Mute"]
        XCTAssertTrue(mute.waitForExistence(timeout: 30), "no Mute on the call screen")
        mute.tap()
        let unmute = app.buttons["Unmute"]
        XCTAssertTrue(unmute.waitForExistence(timeout: 5), "Mute didn't mute")
        unmute.tap()
        XCTAssertTrue(mute.waitForExistence(timeout: 5), "Unmute didn't unmute")
    }

    /// The end screen after a hang-up: what was shown during the call, Call again and Done.
    @MainActor
    func testCallEndedScreenOffersCallAgainAndDone() throws {
        let app = launch(["-NEO_CALL_DEMO", "ended"])
        let callAgain = app.buttons["Call again"]
        XCTAssertTrue(callAgain.waitForExistence(timeout: 30), "no end screen")
        XCTAssertTrue(app.buttons["Done"].exists, "no Done")
        XCTAssertFalse(app.descendants(matching: .any)["Copy details"].exists, "Copy details is for failed calls, not a hang-up")
        XCTAssertTrue(app.descendants(matching: .any)["Shown during the call"].exists, "no list of what was shown")
        XCTAssertFalse(app.buttons["End call"].exists, "an ended call still offers End call")
        attach("Call ended")
        app.buttons["Done"].tap()
        XCTAssertTrue(becomes(callAgain, "exists == false", timeout: 10), "Done didn't close the end screen")
    }

    /// Minimised from the start, the call is its pill over the app: who, Mute and End call.
    @MainActor
    func testMinimisedCallIsAPillOverTheApp() throws {
        let app = launch(["-NEO_CALL_DEMO", "bar"])
        let pill = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Talking with Hermes Bot'")).firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "no call pill")
        XCTAssertTrue(app.buttons["Mute"].exists, "no Mute on the call pill")
        XCTAssertTrue(app.buttons["End call"].exists, "no End call on the call pill")
        XCTAssertFalse(app.buttons["Hide the call"].exists, "the call screen is up")
        attach("Call pill over the app")
    }

    // MARK: Helpers

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-HERMES_BOOTSTRAP_URL", gateway.absoluteString, "-HERMES_BOOTSTRAP_KEY", "dev-key-0123456789abcdef",
            "-HERMES_BOOTSTRAP_BACKEND", backend.absoluteString,
            "-HERMES_TIPS", "hide", "-HERMES_WHATS_NEW", "NO", "-HERMES_PASTEBOARD", "none",
            "-push.primeDeclines", "2", "-welcome.checklist.hidden", "YES",
        ] + arguments
        app.launch()
        return app
    }

    /// The Calls switch, scrolled into view in Settings.
    @MainActor
    private func callsSwitch(in app: XCUIApplication) -> XCUIElement {
        let toggle = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Calls from your bots'")).firstMatch
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 30), "Settings didn't open")
        for _ in 0..<12 where !(toggle.exists && toggle.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(toggle.exists && toggle.isHittable, "no Calls from your bots switch in Settings")
        return toggle
    }

    /// Taps the switch itself: a tap on the middle of the row lands on its label, which doesn't flip it.
    @MainActor
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    @MainActor
    private func text(_ fragment: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    /// Answers the microphone prompt, which SpringBoard shows over the app, when it comes up.
    @MainActor
    private func allowMicrophone() {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        guard alert.waitForExistence(timeout: 5) else { return }
        for title in ["Allow", "OK"] where alert.buttons[title].exists {
            alert.buttons[title].tap()
            return
        }
    }

    @MainActor
    private func becomes(_ element: XCUIElement, _ predicate: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

private func setting(_ key: String, _ fallback: String) -> URL {
    let value = Bundle(for: NeoCallsUITests.self).object(forInfoDictionaryKey: key) as? String
    return URL(string: value.flatMap { $0.isEmpty ? nil : $0 } ?? fallback)!
}
