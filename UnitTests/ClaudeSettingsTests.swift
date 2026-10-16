import XCTest
@testable import HerdrOrb

final class ClaudeSettingsTests: XCTestCase {
    func testRestartResumesExactSessionWithoutChangingPermissions() async throws {
        let connection = RestartClaudeConnection()
        try await ClaudeSettingsBridge(connection: connection, paneID: "fixture").restart(machine: .local, sessionID: RestartClaudeConnection.sessionID, bypass: false)
        let args = await connection.startArgs
        XCTAssertEqual(args, ["--resume", RestartClaudeConnection.sessionID, "--permission-mode", "default"])
    }
    func testExplicitBypassRestartIncludesRequiredFlags() async throws {
        let connection = RestartClaudeConnection()
        try await ClaudeSettingsBridge(connection: connection, paneID: "fixture").restart(machine: .local, sessionID: RestartClaudeConnection.sessionID, bypass: true)
        let args = await connection.startArgs
        XCTAssertEqual(args, ["--resume", RestartClaudeConnection.sessionID, "--permission-mode", "bypassPermissions", "--allow-dangerously-skip-permissions"])
    }
    func testModernSetupShowsOnlyCurrentChoices() {
        let screen = TerminalSetupScreen.parse("""
        ❯ /exit
        WARNING: Claude Code running in Bypass Permissions mode
        Permission prompts will be skipped.
        ❯ No, exit
          Yes, I accept
        Enter to confirm · Esc to cancel
        """)
        XCTAssertEqual(screen?.options, ["No, exit", "Yes, I accept"])
        XCTAssertEqual(screen?.selectedOption, "❯ No, exit")
        XCTAssertTrue(screen?.continueDetails?.contains("Permission prompts will be skipped.") == true)
    }
    func testRestartRefusesWrongConversation() async {
        let connection = RestartClaudeConnection()
        do {
            try await ClaudeSettingsBridge(connection: connection, paneID: "fixture").restart(machine: .local, sessionID: UUID().uuidString, bypass: true)
            XCTFail("Must not exit another chat")
        } catch {}
        let mutations = await connection.mutations
        XCTAssertEqual(mutations, 0)
    }
    func testNewModelsAreNotFiltered() {
        let rows = ClaudeSettingsScreen.models("Select model\n❯ 1. Fable 5.1 ✔  Most capable\n  2. Opus 5.5  Powerful\nEnter to confirm · Esc to cancel")
        XCTAssertEqual(rows.map(\.label), ["Fable 5.1", "Opus 5.5"])
    }
    func testClassicModelMenuAndEmptyPlaceholder() {
        let text = "──────\n❯\u{00a0}Try \"write a test for <filepath>\"\n──────\nContext: 1% used"
        XCTAssertEqual(ClaudeSettingsScreen.prompt(text), "")
        XCTAssertEqual(ClaudeSettingsScreen.mode(text), "manual")
        XCTAssertEqual(ClaudeSettingsScreen.models(ClassicClaudeConnection.menu(current: 0, highlighted: 0, effort: "Medium")).count, 3)
        XCTAssertEqual(ClaudeSettingsScreen.effort(ClassicClaudeConnection.menu(current: 0, highlighted: 0, effort: "Medium")).selected, "medium")
        XCTAssertNil(TerminalSetupScreen.parse(ClassicClaudeConnection.menu(current: 0, highlighted: 0, effort: "Medium")))
    }
    func testClaudeTerminalChromeDoesNotBecomeMessages() {
        let raw = "Welcome to Claude Code v2.1.80\n╭────╮\n│ Welcome back Andrew! │\n╰────╯\n\n❯ hello\n\n⏺ Hello! How can I help you today?\n\n❯ /model\n  ⎿  Set model to Opus\n\n──────────────\n❯\n──────────────\nContext: 1% used     ◐ medium · /effort"
        let messages = TerminalPresentation.messages(raw, kind: "claude")
        XCTAssertEqual(messages.map(\.text), ["hello", "Hello! How can I help you today?"])
        XCTAssertEqual(messages.map(\.fromUser), [true, false])
    }
    func testClassicBridgeReadsAndChangesNativeSettings() async throws {
        let connection = ClassicClaudeConnection()
        let bridge = ClaudeSettingsBridge(connection: connection, paneID: "fixture")
        var result = try await bridge.refresh()
        XCTAssertEqual(result.model, "Default (recommended)")
        XCTAssertEqual(result.access, "manual")
        XCTAssertEqual(result.accessOptions, ["manual", "acceptEdits", "plan"])
        XCTAssertEqual(result.effort, "medium")
        result = try await bridge.update(key: "model", value: "Sonnet", current: result)
        XCTAssertEqual(result.model, "Sonnet")
        result = try await bridge.update(key: "effort", value: "high", current: result)
        XCTAssertEqual(result.effort, "high")
        result = try await bridge.update(key: "access", value: "plan", current: result)
        XCTAssertEqual(result.access, "plan")
        let screen = await connection.display()
        XCTAssertEqual(ClaudeSettingsScreen.prompt(screen), "")
        XCTAssertFalse(ClaudeSettingsScreen.menu(screen))
    }
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

private actor ClassicClaudeConnection: HerdrConnection {
    var isMenu = false
    var draft = ""
    var current = 0
    var highlighted = 0
    var effort = 1
    var access = 0
    static let labels = ["Default (recommended)", "Sonnet", "Haiku"]
    static func menu(current: Int, highlighted: Int, effort: String) -> String {
        "Select model\n" + labels.enumerated().map { i, label in
            "\(i == highlighted ? "❯" : " ") \(i+1). \(label)\(i == current ? " ✔" : "")  Description"
        }.joined(separator: "\n") + "\n◐ \(effort) effort (default) ← → to adjust\nEnter to confirm · Esc to exit"
    }
    func display() -> String {
        if isMenu { return Self.menu(current: current, highlighted: highlighted, effort: ["Low", "Medium", "High"][effort]) }
        return "────────\n❯ \(draft)\n────────\n" + ["Context: 1% used", "accept edits on", "plan mode on"][access]
    }
    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        if method == "pane.read" { return ["read": ["text": display()]] }
        if method == "pane.send_text" { draft = params["text"] as! String; return [:] }
        if method == "pane.send_keys" {
            for key in params["keys"] as! [String] {
                switch key {
                case "enter":
                    if isMenu { current = highlighted; isMenu = false }
                    else if draft == "/model" { isMenu = true; highlighted = current }
                    else { throw BridgeError.message("Unexpected command: \(draft)") }
                    draft = ""
                case "escape": isMenu = false
                case "up": highlighted = max(0, highlighted - 1)
                case "down": highlighted = min(2, highlighted + 1)
                case "left": effort = max(0, effort - 1)
                case "right": effort = min(2, effort + 1)
                case "shift+tab": access = (access + 1) % 3
                case "ctrl+u": draft = ""
                default: throw BridgeError.message("Unexpected key: \(key)")
                }
            }
            return [:]
        }
        throw BridgeError.message("Unexpected request")
    }
    func events() async throws -> AsyncThrowingStream<Data, Error> { AsyncThrowingStream { $0.finish() } }
    func shutdown() async {}
}

private actor RestartClaudeConnection: HerdrConnection {
    static let sessionID = "57a52089-8d4e-48e2-b4a7-6aa54a3f11cb"
    var exited = false
    var draft = ""
    var mutations = 0
    var startArgs: [String] = []
    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        if method == "session.snapshot" {
            let agent: [String: Any] = ["pane_id": "fixture", "agent": "claude", "agent_status": "done", "agent_session": ["agent": "claude", "kind": "id", "value": Self.sessionID, "source": "herdr:claude"]]
            return ["snapshot": ["protocol": 22, "panes": [["pane_id": "fixture", "terminal_id": "terminal"]], "agents": exited ? [] : [agent]]]
        }
        if method == "pane.read" { return ["read": ["text": "──────\n❯ \(draft)\n──────\n manual mode on"]] }
        mutations += 1
        if method == "pane.send_text" { draft = params["text"] as! String }
        if method == "pane.send_keys" { XCTAssertEqual(draft, "/exit"); exited = true }
        if method == "agent.start" { XCTAssertTrue(exited); startArgs = params["args"] as! [String] }
        return [:]
    }
    func events() async throws -> AsyncThrowingStream<Data, Error> { AsyncThrowingStream { $0.finish() } }
    func shutdown() async {}
}
