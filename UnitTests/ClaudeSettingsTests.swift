import XCTest
@testable import HerdrOrb

final class ClaudeSettingsTests: XCTestCase {
    func testModeOnlyReadsTheCurrentFooter() {
        XCTAssertNil(ClaudeSettingsScreen.mode("I suggest bypass permissions on."))
        XCTAssertEqual(ClaudeSettingsScreen.mode("──────\n❯ \n──────\n ⏸ plan mode on · ? for shortcuts"), "plan")
        XCTAssertNil(ClaudeSettingsScreen.prompt("──────\n❯ draft\n  second line\n──────\n manual mode on"))
    }
    func testModelsKeepHighlightSeparateFromSelection() {
        let rows = ClaudeSettingsScreen.models("""
        Select model
        ❯ 1. Default (recommended)    Use the default model
          2. Opus (1M context) ✔      Most capable
          3. Sonnet                  Efficient
        Enter to set as default · s to use this session only · Esc to cancel
        """)
        XCTAssertEqual(rows.map(\.label), ["Default (recommended)", "Opus (1M context)", "Sonnet"])
        XCTAssertTrue(rows[0].highlighted)
        XCTAssertTrue(rows[1].current)
        XCTAssertFalse(rows[0].current)
    }
    func testClaudeEffortDoesNotBecomeCodexUltra() {
        let parsed = ClaudeSettingsScreen.effort("""
        Effort
        ───────────────▲─────────────────
        low   medium   high   xhigh   max   ultracode
        ←/→ to adjust · Enter to confirm · Esc to cancel
        """)
        XCTAssertEqual(parsed.values, ["low", "medium", "high", "xhigh", "max", "ultracode"])
        XCTAssertEqual(parsed.selected, "high")
        XCTAssertEqual(ComposerLabels.effort("low", provider: "claude"), "Low")
        XCTAssertEqual(ComposerLabels.effort("low"), "Light")
    }
    func testSettingsEchoesStayOutOfConversation() {
        let text = "❯ /model\n  ⎿  Kept model as Opus\n\n❯ Explain this\nHere is the answer."
        let output = TerminalPresentation.conversation(text, kind: "claude")
        XCTAssertFalse(output.contains("Kept model"))
        XCTAssertTrue(output.contains("Explain this"))
        let fenced = "```\n❯ /model\n  ⎿  Kept model as Opus\n```"
        XCTAssertEqual(TerminalPresentation.conversation(fenced, kind: "claude"), fenced)
    }
    func testBridgeRefusesExistingDraftWithoutSendingKeys() async {
        let connection = DraftClaudeConnection()
        do { _ = try await ClaudeSettingsBridge(connection: connection, paneID: "test").refresh(); XCTFail("Must refuse") }
        catch { XCTAssertTrue(error.localizedDescription.contains("input")) }
        let count = await connection.mutations
        XCTAssertEqual(count, 0)
    }
}
private actor DraftClaudeConnection: HerdrConnection {
    var mutations = 0
    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        if method != "pane.read" { mutations += 1 }
        return ["read": ["text": "──────\n❯ My unfinished draft\n──────\n ⏸ manual mode on"]]
    }
    func events() async throws -> AsyncThrowingStream<Data, Error> { AsyncThrowingStream { $0.finish() } }
    func shutdown() async {}
}
