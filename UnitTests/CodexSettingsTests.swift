import XCTest
@testable import HerdrOrb

final class CodexSettingsTests: XCTestCase {
    func testCurrentFooterWinsOverAnOlderStatusCard() {
        let text = """
        │ Model: gpt-5.5 (reasoning high, summaries auto) │
        │ Permissions: Full Access │
        › Ask Codex to do anything

          GPT-6-Astra low fast · ~/project
        """
        let settings = CodexSessionSettings.status(in: text)
        XCTAssertEqual(settings.model, "gpt-6-astra")
        XCTAssertEqual(settings.effort, "low")
        XCTAssertEqual(settings.speed, "fast")
        XCTAssertEqual(settings.access, "full")
    }

    func testConversationProseDoesNotSetTheControls() {
        let text = "I used gpt-6-astra low fast · and recommend Full Access."
        XCTAssertEqual(CodexSessionSettings.observed(in: text), CodexSessionSettings())
    }

    func testMultilineNativeDraftIsNotAnEmptyComposer() {
        XCTAssertFalse(CodexSettingsBridge.isEmptyComposer("›\n  Keep this draft\n\n  gpt-6-astra low fast · ~/project"))
        XCTAssertTrue(CodexSettingsBridge.isEmptyComposer(Self.ready))
    }

    func testPermissionMenuExcludesDisabledRowsAndKeepsCurrentSeparateFromHighlight() throws {
        let menu = try XCTUnwrap(CodexSettingsMenu.parse("""
          Update Model Permissions

        › 1. Ask for approval  Workspace files and commands
             Approve for me (disabled)  Disabled by policy
          2. Full Access (current)  Unrestricted

          enter select · esc back
        """))
        XCTAssertEqual(menu.kind, .permissions)
        XCTAssertEqual(menu.items.map(\.label), ["Ask for approval", "Full Access"])
        XCTAssertTrue(menu.items[0].highlighted)
        XCTAssertFalse(menu.items[0].current)
        XCTAssertTrue(menu.items[1].current)
    }

    func testAdvancedEffortsRemainAvailableWhenTheBasicMenuIsRead() throws {
        let menu = try XCTUnwrap(CodexSettingsMenu.parse("""
          Select Reasoning Level for GPT-6-Astra

        › 1. Low (default) (current)  Fast responses with lighter reasoning
          2. Medium  Balanced reasoning
          3. High  Greater depth
          4. Extra high  Extra depth
          5. More reasoning…  Max and Ultra consume usage limits faster

          enter default · s session · esc back
        """))
        XCTAssertEqual(menu.efforts, ["low", "medium", "high", "xhigh", "max", "ultra"])
        XCTAssertTrue(menu.sessionAction)
        XCTAssertTrue(menu.items[0].isDefault)
    }

    func testRefusingAnExistingMenuDoesNotDismissIt() async {
        let screen = "Update Model Permissions\n› 1. Full Access (current)  Unrestricted\n\nenter select · esc back"
        let connection = SettingsProbe(screen: screen)
        do { _ = try await CodexSettingsBridge(connection: connection, paneID: "test").read(); XCTFail("Should refuse a preexisting menu") }
        catch { }
        let writes = await connection.writes
        XCTAssertTrue(writes.isEmpty)
    }

    func testFailureAfterPreparingACommandClearsOnlyThatCommand() async {
        let connection = SettingsProbe(screen: Self.ready, failAfterTyping: true)
        do { _ = try await CodexSettingsBridge(connection: connection, paneID: "test").read(); XCTFail("Expected failure") }
        catch { }
        let screen = await connection.screen
        let writes = await connection.writes
        XCTAssertEqual(screen, Self.ready)
        XCTAssertEqual(writes, ["text:/status", "key:ctrl+u"])
    }

    func testFailureDoesNotClearInputChangedByAnotherClient() async {
        let connection = SettingsProbe(screen: Self.ready, failAfterTyping: true, concurrentDraft: true)
        do { _ = try await CodexSettingsBridge(connection: connection, paneID: "test").read(); XCTFail("Expected failure") }
        catch { }
        let screen = await connection.screen
        let writes = await connection.writes
        XCTAssertTrue(screen.contains("/status preserve this"))
        XCTAssertEqual(writes, ["text:/status"])
    }

    func testFastToggleUsesFreshFooterWithoutStatusRoundTrips() async throws {
        let connection = ResponsiveSettingsProbe()
        let result = try await CodexSettingsBridge(connection: connection, paneID: "test")
            .update(key: "speed", value: "standard", current: .preview)
        XCTAssertEqual(result.speed, "standard")
        let commands = await connection.commands
        XCTAssertEqual(commands, ["/fast"])
    }

    func testModelNavigationBatchesArrowsAndVerifiesTheResult() async throws {
        let connection = ResponsiveSettingsProbe()
        let result = try await CodexSettingsBridge(connection: connection, paneID: "test")
            .update(key: "model", value: "gpt-6-luna", current: .preview)
        XCTAssertEqual(result.model, "gpt-6-luna")
        let commands = await connection.commands
        let batches = await connection.keyBatches
        XCTAssertEqual(commands, ["/model", "/fast"])
        XCTAssertTrue(batches.contains(["down", "down"]))
        XCTAssertTrue(batches.contains(["s"]))
    }

    static let ready = "› Ask Codex to do anything\n\n  gpt-6-astra low fast · ~/project"
}

private actor SettingsProbe: HerdrConnection {
    var screen: String
    var writes: [String] = []
    let failAfterTyping: Bool
    let concurrentDraft: Bool
    init(screen: String, failAfterTyping: Bool = false, concurrentDraft: Bool = false) {
        self.screen = screen; self.failAfterTyping = failAfterTyping; self.concurrentDraft = concurrentDraft
    }
    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        if method == "pane.read" { return ["read": ["text": screen]] }
        if method == "pane.send_text" {
            let text = params["text"] as! String
            writes.append("text:" + text)
            screen = "› " + text + (concurrentDraft ? " preserve this" : "") + "\n\n /status  Show status"
            if failAfterTyping { throw CancellationError() }
        }
        if method == "pane.send_keys" {
            for key in params["keys"] as! [String] {
                writes.append("key:" + key)
                if key == "ctrl+u" { screen = CodexSettingsTests.ready }
            }
        }
        return [:]
    }
    func events() async throws -> AsyncThrowingStream<Data, Error> { AsyncThrowingStream { $0.finish() } }
    func shutdown() async { }
}

/// Simulates a CLI that redraws after each RPC, including its live model footer.
private actor ResponsiveSettingsProbe: HerdrConnection {
    var commands: [String] = []
    var keyBatches: [[String]] = []
    var model = "gpt-6-astra"
    var fast = true
    var typed: String?
    var inModels = false
    var highlighted = 0
    let models = ["gpt-6-astra", "gpt-6-sol", "gpt-6-luna"]
    var screen: String {
        if inModels {
            return "Select Model\n" + models.enumerated().map { index, value in
                "\(index == highlighted ? "›" : " ") \(index + 1). \(value)\(value == model ? " (current)" : "")  Description"
            }.joined(separator: "\n") + "\nenter default · s session · esc back"
        }
        if let typed { return "› " + typed + "\n\n  " + typed + "  Change settings" }
        return "› Ask Codex to do anything\n\n  \(model) low\(fast ? " fast" : "") · ~/project"
    }
    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        if method == "pane.read" { return ["read": ["text": screen]] }
        if method == "pane.send_text" { typed = params["text"] as? String; commands.append(typed!) }
        if method == "pane.send_keys" {
            let keys = params["keys"] as! [String]
            keyBatches.append(keys)
            for key in keys {
                if inModels {
                    switch key {
                    case "down": highlighted = min(highlighted + 1, models.count - 1)
                    case "up": highlighted = max(highlighted - 1, 0)
                    case "s": model = models[highlighted]; inModels = false
                    case "escape": inModels = false
                    default: break
                    }
                } else if key == "enter" {
                    if typed == "/fast" { fast.toggle() }
                    if typed == "/model" { inModels = true; highlighted = models.firstIndex(of: model)! }
                    typed = nil
                } else if key == "ctrl+u" { typed = nil }
            }
        }
        return [:]
    }
    func events() async throws -> AsyncThrowingStream<Data, Error> { AsyncThrowingStream { $0.finish() } }
    func shutdown() async {}
}
