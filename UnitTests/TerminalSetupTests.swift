import XCTest
@testable import HerdrOrb

final class TerminalSetupTests: XCTestCase {
    func testWrappedLoginLinkPreservesEveryCharacter() {
        let url = "https://claude.ai/oauth/authorize?code=true&client_id=test&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=user%3Aprofile+user%3Ainference&code_challenge=zero0OhO_under-score&code_challenge_method=S256&state=abc"
        for width in [43, 60, 80, 120] {
            let chars = Array(url)
            let wrapped = stride(from: 0, to: chars.count, by: width).map { String(chars[$0..<min($0 + width, chars.count)]) }.joined(separator: "\n")
            let screen = TerminalSetupScreen.parse("Browser didn't open? Use the url below\n\n" + wrapped + "\n\nPaste code here if prompted >")
            XCTAssertEqual(screen?.link?.absoluteString, url)
            XCTAssertEqual(screen?.waitingForCode, true)
        }
    }
    func testChoicesAndThemeScreen() {
        let screen = TerminalSetupScreen.parse("Select login method:\n❯ 1. Claude account with subscription\n  2. Anthropic Console account\n  3. Third-party platform")
        XCTAssertEqual(screen?.options.count, 3)
        XCTAssertEqual(screen?.options.first, "1. Claude account with subscription")
        XCTAssertNil(screen?.link)
        XCTAssertNotNil(TerminalSetupScreen.parse("Choose the text style that looks best\n1. Dark mode\n2. Light mode"))
    }
    func testLoginSuccessAndContinuationRemainInteractive() {
        let text = "Welcome to Claude Code\n ░▒▓\nLogged in as test@example.com\nLogin successful. Press Enter to continue...\n\n"
        let screen = TerminalSetupScreen.parse(text)
        XCTAssertEqual(screen?.continueMessage, "Login successful. Press Enter to continue...")
        XCTAssertEqual(screen?.waitingForCode, false)
        XCTAssertNil(screen?.link)
        XCTAssertEqual(TerminalSetupScreen.parse("Security notes\nReview generated code\nPress Enter to continue…")?.continueDetails, "Security notes\nReview generated code")
        XCTAssertNil(TerminalSetupScreen.parse("Login successful. Press Enter to continue...\nNow ready for a chat"))
    }
    func testTrustMenuPreservesWarningAndChoices() {
        let screen = TerminalSetupScreen.parse("Accessing workspace: /fixture\nClaude can read, edit, and execute files here.\n❯ 1. Yes, I trust this folder\n  2. No, exit\nEnter to confirm · Esc to cancel")
        XCTAssertEqual(screen?.options.count, 2)
        XCTAssertTrue(screen?.continueDetails?.contains("read, edit, and execute") == true)
        XCTAssertTrue(screen?.continueDetails?.contains("/fixture") == true)
    }
    func testNormalConversationIsNotSetup() {
        XCTAssertNil(TerminalSetupScreen.parse("Here are the results:\n1. First\n2. Second"))
        XCTAssertNil(TerminalSetupScreen.parse("https://example.com\nAll done"))
    }
}

private actor SetupConnection: HerdrConnection {
    var screen = "Browser didn't open?\nhttps://claude.ai/oauth/authorize?state=fixture\n\nPaste code here if prompted >"
    var sent: [String] = []
    func changeScreen() { screen = "Ordinary chat prompt" }
    func loginSuccess() { screen = "Login successful. Press Enter to continue..." }
    func choiceScreen() { screen = "Accessing workspace: /fixture\n❯ 1. Yes, I trust this folder\n  2. No, exit\nEnter to confirm · Esc to cancel" }
    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        if method == "session.snapshot" { return ["snapshot": ["protocol": 22, "panes": [["pane_id": "p", "terminal_id": "t"]], "agents": [["pane_id": "p", "agent": "claude", "agent_status": "idle"]]]] }
        if method == "pane.read" { return ["read": ["text": screen]] }
        if method == "pane.send_text" { sent.append(params["text"] as! String); return [:] }
        if method == "pane.send_keys" { sent += params["keys"] as! [String]; return [:] }
        throw BridgeError.message("Unexpected \(method)")
    }
    func events() async throws -> AsyncThrowingStream<Data, Error> { AsyncThrowingStream { _ in } }
    func shutdown() async {}
}
extension TerminalSetupTests {
    @MainActor func testCodesGoDirectlyToTerminalAndChangedPromptStopsInput() async throws {
        let suite = "setup-tests-" + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        prefs.set(false, forKey: "saveConversations")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let connection = SetupConnection()
        let model = BubbleModel(cache: ConversationCache(directory: directory), preferences: prefs, discover: { [.local] }, makeTransport: { _ in connection })
        await model.start()
        for _ in 0..<100 where model.agents.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let agent = try XCTUnwrap(model.agents.first)
        let session = model.state(agent)
        session.output = await connection.screen
        session.draft = "Keep my chat draft"
        XCTAssertFalse(model.canChangeAgentSettings(agent))
        await model.setupInput(agent, code: "test-code#test-state")
        var sent = await connection.sent
        XCTAssertEqual(sent, ["test-code#test-state", "enter"])
        XCTAssertEqual(session.draft, "Keep my chat draft")
        XCTAssertTrue(session.pending.isEmpty)
        await connection.changeScreen()
        await model.setupInput(agent, key: "1")
        sent = await connection.sent
        XCTAssertEqual(sent.count, 2)
        XCTAssertTrue(session.notice?.contains("changed") == true)
        await connection.loginSuccess()
        session.output = await connection.screen
        XCTAssertFalse(model.canChangeAgentSettings(agent))
        await model.setupInput(agent, key: "enter")
        sent = await connection.sent
        XCTAssertEqual(sent, ["test-code#test-state", "enter", "enter"])
        await connection.choiceScreen()
        session.output = await connection.screen
        await model.setupInput(agent, option: "2. No, exit")
        sent = await connection.sent
        XCTAssertEqual(sent, ["test-code#test-state", "enter", "enter", "down"], "Highlighting must not confirm a choice")
        await model.stop()
        prefs.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
