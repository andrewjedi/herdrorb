import XCTest
@testable import HerdrOrb

final class ConversationApprovalTests: XCTestCase {
    static func menu(_ provider: String) -> String {
        let marker = provider == "claude" ? "❯" : "›"
        return """
        Bash command
        swift test
        Do you want to proceed?
        \(marker) 1. Yes, run once
          2. Yes, and don’t ask again for this command
          3. No, cancel
        Press Enter to confirm · Esc to cancel
        """
    }
    func testBothProviderMenusPreserveChoicesAndUseExactSelection() throws {
        for provider in ["codex", "claude"] {
            let menu = Self.menu(provider)
            let request = try XCTUnwrap(ConversationApproval.parse(menu, provider: provider))
            XCTAssertEqual(request.selected, 1)
            XCTAssertEqual(request.choices.count, 3)
            XCTAssertTrue(request.context.contains("swift test"))
            XCTAssertTrue(request.choices[1].title.contains("don’t ask again"))
            XCTAssertEqual(request.keys(for: 3), ["down", "down", "enter"])
            XCTAssertEqual(request.keys(for: 1), ["enter"])
            XCTAssertNil(request.keys(for: 4))
        }
    }
    func testQuotedOldAndUnknownMenusAreNotActionable() {
        let menu = Self.menu("claude")
        XCTAssertNil(ConversationApproval.parse("```\n" + menu + "\n```", provider: "claude"))
        XCTAssertNil(ConversationApproval.parse(menu + "\n❯ Ask anything", provider: "claude"))
        XCTAssertNil(ConversationApproval.parse(menu.replacingOccurrences(of: "Do you want to proceed?", with: "Pick a theme"), provider: "claude"))
        XCTAssertNil(ConversationApproval.parse(menu.replacingOccurrences(of: "3. No", with: "5. No"), provider: "claude"))
        XCTAssertNil(ConversationApproval.parse(menu, provider: "other"))
    }
    @MainActor func testChoosingAnOptionChecksFreshScreenAndPreservesDraft() async throws {
        let context = try await makeContext()
        defer { context.preferences.removePersistentDomain(forName: context.suite) }
        let agent = try XCTUnwrap(context.model.agents.first)
        let state = context.model.state(agent)
        state.draft = "Keep my unfinished message"
        state.approval = ConversationApproval.parse(Self.menu("claude"), provider: "claude")
        await context.model.respondToApproval(agent, choice: 3)
        let sent = await context.transport.sent
        XCTAssertEqual(sent, [["down", "down", "enter"]])
        XCTAssertEqual(state.draft, "Keep my unfinished message")
        XCTAssertTrue(state.pending.isEmpty)
        XCTAssertNil(state.approval)
        await context.model.stop()
    }
    @MainActor func testChangedScreenSendsNothingAndAmbiguousResponseNeverRetries() async throws {
        let context = try await makeContext()
        defer { context.preferences.removePersistentDomain(forName: context.suite) }
        let agent = try XCTUnwrap(context.model.agents.first)
        let state = context.model.state(agent)
        state.approval = ConversationApproval.parse(Self.menu("claude"), provider: "claude")
        await context.transport.setScreen("Ordinary chat prompt")
        await context.model.respondToApproval(agent, choice: 1)
        var sent = await context.transport.sent
        XCTAssertTrue(sent.isEmpty)
        XCTAssertNil(state.approval)
        await context.transport.setScreen(Self.menu("claude"))
        state.approval = ConversationApproval.parse(Self.menu("claude"), provider: "claude")
        await context.transport.failResponse()
        await context.model.respondToApproval(agent, choice: 1)
        await context.model.respondToApproval(agent, choice: 1)
        sent = await context.transport.sent
        XCTAssertEqual(sent.count, 1)
        XCTAssertNotNil(state.uncertainApproval)
        XCTAssertNil(state.approval)
        await context.model.stop()
    }
    @MainActor private func makeContext() async throws -> (model: BubbleModel, transport: ApprovalConnection, preferences: UserDefaults, suite: String) {
        let suite = "herdrorb-approval-test-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set(false, forKey: "saveConversations")
        let transport = ApprovalConnection()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let model = BubbleModel(cache: ConversationCache(directory: directory), preferences: preferences, discover: { [.local] }, makeTransport: { _ in transport })
        await model.start()
        for _ in 0..<100 where model.connection["local"] != .online { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.connection["local"], .online)
        return (model, transport, preferences, suite)
    }
}

private actor ApprovalConnection: HerdrConnection {
    var screen = ConversationApprovalTests.menu("claude")
    var sent: [[String]] = []
    private var fails = false
    func setScreen(_ text: String) { screen = text }
    func failResponse() { fails = true }
    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        switch method {
        case "session.snapshot":
            return ["snapshot": ["protocol": 22, "panes": [["pane_id": "p", "terminal_id": "t"]],
                                 "agents": [["pane_id": "p", "agent": "claude", "agent_status": "blocked"]]]]
        case "pane.read": return ["read": ["text": screen]]
        case "pane.send_keys":
            sent.append(params["keys"] as! [String])
            if fails { throw BridgeError.message("Uncertain response") }
            return [:]
        default: throw BridgeError.message("Unexpected request: " + method)
        }
    }
    func events() async throws -> AsyncThrowingStream<Data, Error> { AsyncThrowingStream { _ in } }
    func shutdown() async { }
}
