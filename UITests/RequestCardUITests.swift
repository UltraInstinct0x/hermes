import XCTest

/// The request card above the composer is never wider than the screen (`docs/quick-actions.md` §1):
/// a two-question clarify whose first answer is long, answered, then "Question 2 of 2" checked
/// element by element against the window. The answer's one-line summary, laid out at its own
/// width, once made the whole bottom bar wider than the screen, clipped on both sides. Start the
/// mock first: `python3 -I Tools/mock-hermes/backend.py --port 19119 --gateway-port 18642`.
/// Run it on the smallest iPhone, a large one and an iPad.
final class RequestCardUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testNeedsYouShowsRequestsAcrossChats() async throws {
        _ = try await seedNeedsYouApprovals()
        let app = try await showNeedsYou()
        for profile in ["default", "writer"] {
            XCTAssertTrue(denyButton(in: app, profile: profile).waitForExistence(timeout: 25))
        }
        attachScreenshot("needs-you-across-chats")
    }

    @MainActor
    func testNeedsYouDeniesOnlyTheSelectedUnattachedRequest() async throws {
        let sessions = try await seedNeedsYouApprovals()
        let app = try await showNeedsYou()
        let selected = denyButton(in: app, profile: "writer")
        let other = denyButton(in: app, profile: "default")
        XCTAssertTrue(selected.waitForExistence(timeout: 25))
        XCTAssertTrue(other.waitForExistence(timeout: 25))

        let before = try await federatedLedger()
        func ledgerID(_ profile: String) throws -> String {
            try XCTUnwrap(before["open"]?.first { ($0["session_id"] as? String) == sessions[profile] }?["ledger_id"] as? String)
        }
        let selectedID = try ledgerID("writer")
        let otherID = try ledgerID("default")
        XCTAssertNotEqual(selectedID, otherID)

        selected.tap()
        XCTAssertTrue(selected.waitForNonExistence(timeout: 20))
        XCTAssertTrue(other.exists)
        let receipt = element(app, "label BEGINSWITH 'Answered by Hermes'")
        XCTAssertTrue(receipt.waitForExistence(timeout: 10))
        let after = try await federatedLedger()
        XCTAssertTrue(after["open"]?.contains { ($0["ledger_id"] as? String) == otherID } == true)
        XCTAssertFalse(after["open"]?.contains { ($0["ledger_id"] as? String) == selectedID } == true)
        let settled = try XCTUnwrap(after["recent"]?.first { ($0["ledger_id"] as? String) == selectedID })
        XCTAssertEqual(settled["outcome"] as? String, "deny")
        let winner = try XCTUnwrap((settled["answered_by"] as? [String: Any])?["label"] as? String)
        XCTAssertEqual(receipt.label, "Answered by \(winner)")
        attachScreenshot("needs-you-answer-receipt")
    }

    @MainActor
    private func seedNeedsYouApprovals() async throws -> [String: String] {
        let stopped = try await mock("stop-turns", [:])
        XCTAssertEqual(stopped, 200)
        let (backend, token) = try await mockBackend()
        var endpoint = try XCTUnwrap(URLComponents(url: backend.appending(path: "api/ws"), resolvingAgainstBaseURL: false))
        endpoint.scheme = "ws"
        endpoint.queryItems = [URLQueryItem(name: "token", value: token)]
        let socket = URLSession.shared.webSocketTask(with: try XCTUnwrap(endpoint.url))
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
            let id = UUID().uuidString
            let frame = try JSONSerialization.data(withJSONObject: ["id": id, "jsonrpc": "2.0", "method": method, "params": params])
            try await socket.send(.string(String(decoding: frame, as: UTF8.self)))
            while case .string(let text) = try await socket.receive() {
                let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                if reply["id"] as? String == id { return try XCTUnwrap(reply["result"] as? [String: Any]) }
            }
            throw URLError(.badServerResponse)
        }

        _ = try await call("client.capabilities", ["server_requests": true])
        var sessions: [String: String] = [:]
        for profile in ["default", "writer"] {
            let chat = try await call("session.create", ["profile": profile])
            let runtime = try XCTUnwrap(chat["session_id"] as? String)
            sessions[profile] = try XCTUnwrap(chat["stored_session_id"] as? String)
            _ = try await call("prompt.submit", ["session_id": runtime, "text": "approve"])
        }
        return sessions
    }

    @MainActor
    private func federatedLedger() async throws -> [String: [[String: Any]]] {
        let (backend, token) = try await mockBackend()
        var request = URLRequest(url: backend.appending(path: "bff/ledger"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return ["open": try XCTUnwrap(snapshot["open"] as? [[String: Any]]),
                "recent": try XCTUnwrap(snapshot["recent"] as? [[String: Any]])]
    }

    @MainActor
    private func showNeedsYou() async throws -> XCUIApplication {
        let app = try await launch(["-HERMES_OPEN", "bots"])
        let chats = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Chats'")).firstMatch
        if !chats.isHittable {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(back.waitForExistence(timeout: 10), "no back button on the Bots page")
            back.tap()
        }
        XCTAssertTrue(chats.waitForExistence(timeout: 30), "sidebar did not open")
        chats.tap()
        let filter = app.buttons["inbox.filter"].firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 30))
        filter.tap()
        element(app, "label BEGINSWITH 'Needs You'").tap()
        return app
    }

    @MainActor
    private func denyButton(in app: XCUIApplication, profile: String) -> XCUIElement {
        app.cells.containing(.staticText, identifier: profile).buttons["needsYou.deny"]
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testALongAnswerKeepsTheNextQuestionOnScreen() async throws {
        let app = try await launch(["-HERMES_OPEN", "bot:researcher", "-HERMES_SEND_HERE", "clarify pair", "-HERMES_SEND_HERE_AFTER", "4"])
        XCTAssertTrue(element(app, "label BEGINSWITH 'Question 1 of 2'").waitForExistence(timeout: 60), "no clarify card")
        try expectOnScreen(app, "question 1")

        let pick = element(app, "label BEGINSWITH 'Yes—Gmail'")
        XCTAssertTrue(pick.waitForExistence(timeout: 5), "no long pick")
        pick.tap()
        app.buttons["Next"].tap()
        XCTAssertTrue(element(app, "label BEGINSWITH 'Question 2 of 2'").waitForExistence(timeout: 10), "didn't move to question 2")
        // The card moves in with a blur; measure where it settles.
        try await Task.sleep(for: .seconds(1))
        try expectOnScreen(app, "question 2")
        XCTAssertTrue(element(app, "label BEGINSWITH 'Which Google Workspace'").exists, "no summary of the first answer")

        // Answered, the card goes.
        element(app, "label BEGINSWITH 'No or not sure'").tap()
        app.buttons["Send"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["requestCard"].waitForNonExistence(timeout: 10), "the card stayed")
    }

    /// Answered on another device (`docs/quick-actions.md` §1): Hermes tells no one else, so this
    /// device finds out as the chat moves on, takes the card down and says so.
    @MainActor
    func testACardAnsweredElsewhereGoes() async throws {
        let app = try await launch(["-HERMES_OPEN", "bot:researcher", "-HERMES_SEND_HERE", "clarify pair", "-HERMES_SEND_HERE_AFTER", "4"])
        XCTAssertTrue(element(app, "label BEGINSWITH 'Question 1 of 2'").waitForExistence(timeout: 60), "no clarify card")
        try await answerElsewhere("clarify")
        XCTAssertTrue(app.descendants(matching: .any)["requestCard"].waitForNonExistence(timeout: 10), "the card stayed")
        XCTAssertTrue(element(app, "label CONTAINS 'Answered on another device'").waitForExistence(timeout: 5), "no receipt")
    }

    /// Away while another device answered: coming back, the card is gone.
    @MainActor
    func testACardAnsweredWhileAwayIsGoneOnReturn() async throws {
        let app = try await launch(["-HERMES_OPEN", "bot:researcher", "-HERMES_SEND_HERE", "clarify pair", "-HERMES_SEND_HERE_AFTER", "4"])
        XCTAssertTrue(element(app, "label BEGINSWITH 'Question 1 of 2'").waitForExistence(timeout: 60), "no clarify card")
        XCUIDevice.shared.press(.home)
        try await Task.sleep(for: .seconds(20))
        try await answerElsewhere("clarify")
        try await Task.sleep(for: .seconds(3))
        app.activate()
        XCTAssertTrue(app.descendants(matching: .any)["requestCard"].waitForNonExistence(timeout: 15), "the card was still there on return")
    }

    // MARK: Helpers

    /// `POST /api/mock/answer-elsewhere`: another device answers the newest open `method`.
    private func answerElsewhere(_ method: String) async throws {
        let status = try await mock("answer-elsewhere", ["method": method])
        XCTAssertEqual(status, 200, "the mock had no open \(method) (restart it after pulling)")
    }

    private func mockBackend() async throws -> (URL, String) {
        let backend = URL(string: (Bundle(for: RequestCardUITests.self).object(forInfoDictionaryKey: "HermesMockBackend") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "http://127.0.0.1:19119")!
        let (page, _) = try await URLSession.shared.data(from: backend)
        let html = String(decoding: page, as: UTF8.self)
        guard let start = html.range(of: "__HERMES_SESSION_TOKEN__=\"")?.upperBound,
              let end = html[start...].firstIndex(of: "\"") else { throw URLError(.userAuthenticationRequired) }
        return (backend, String(html[start..<end]))
    }

    /// `POST /api/mock/<path>` on the mock backend, with the dashboard's session token; its status.
    private func mock(_ path: String, _ body: [String: String]) async throws -> Int? {
        let (backend, token) = try await mockBackend()
        var request = URLRequest(url: backend.appending(path: "api/mock/\(path)"))
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode
    }

    /// Every part of the card, and the composer under it, inside the window (half a point's grace
    /// for rounding), with a screenshot to look at.
    @MainActor
    private func expectOnScreen(_ app: XCUIApplication, _ name: String) throws {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "request-card-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)

        let window = app.windows.firstMatch.frame.insetBy(dx: -0.5, dy: -0.5)
        let card = app.descendants(matching: .any)["requestCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 5), "no request card")
        XCTAssertTrue(window.contains(card.frame), "the card is \(card.frame), the window \(window)")
        var outside: [String] = []
        func walk(_ node: any XCUIElementSnapshot) {
            if !node.frame.isEmpty, !window.contains(node.frame) {
                outside.append("\(node.label.isEmpty ? node.identifier : node.label) at \(node.frame)")
            }
            node.children.forEach(walk)
        }
        walk(try card.snapshot())
        XCTAssertEqual(outside, [], "past the window's edges (\(window))")

        let composer = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(composer.exists, "no composer")
        XCTAssertTrue(window.contains(composer.frame), "the composer is \(composer.frame), the window \(window)")
    }

    /// Launched with Research Buddy quiet: a turn an earlier test left running in its chat would make
    /// this one's message a redirect (Hermes's default busy mode), so it's stopped first.
    @MainActor
    private func launch(_ arguments: [String]) async throws -> XCUIApplication {
        let stopped = try await mock("stop-turns", ["profile": "researcher"])
        XCTAssertEqual(stopped, 200, "Research Buddy's turn didn't stop (restart the mock after pulling)")
        let bundle = Bundle(for: RequestCardUITests.self)
        func setting(_ key: String, _ fallback: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        }
        let app = XCUIApplication()
        app.launchArguments = [
            "-HERMES_BOOTSTRAP_URL", setting("HermesMockGateway", "http://127.0.0.1:18642"),
            "-HERMES_BOOTSTRAP_KEY", "dev-key-0123456789abcdef",
            "-HERMES_BOOTSTRAP_BACKEND", setting("HermesMockBackend", "http://127.0.0.1:19119"),
            "-HERMES_TIPS", "hide", "-HERMES_WHATS_NEW", "NO",
            // One message, and no notifications ask over the chat.
            "-HERMES_SEND_HERE_ROUNDS", "1", "-push.primeDeclines", "2",
        ] + arguments
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ format: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: format)).firstMatch
    }
}
