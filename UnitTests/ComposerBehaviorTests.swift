import XCTest
@testable import HerdrOrb

final class ComposerBehaviorTests: XCTestCase {
    @MainActor func testSettingsRespectFreshWorkingAndBlockedStatusWithoutTerminalInput() async throws {
        let context = try await makeContext()
        let staleAgent = try XCTUnwrap(context.model.agents.first)
        let draft = "Please keep this unfinished request."
        context.model.state(staleAgent).draft = draft

        for status in ["working", "blocked"] {
            context.model.agents[0].agent_status = status
            XCTAssertFalse(context.model.canChangeCodexSettings(staleAgent), "A stale idle view must respect the latest agent status")
            await context.model.refreshCodexSettings(staleAgent)
            await context.model.updateCodexSetting(staleAgent, key: "access", value: "full")
            XCTAssertEqual(context.model.state(staleAgent).draft, draft)
            XCTAssertFalse(context.model.state(staleAgent).settingsBusy)
        }

        let requests = await context.transport.nonInventoryRequests
        XCTAssertTrue(requests.isEmpty, "Working or blocked agents must not receive slash commands, keys, or prompts: \(requests)")
    }

    @MainActor func testOfflineTerminalAndBusySessionsDoNotReceiveSettingsCommands() async throws {
        let context = try await makeContext()
        let agent = try XCTUnwrap(context.model.agents.first)
        let session = context.model.state(agent)
        session.draft = "Unsent local draft"

        context.model.connection[agent.machineID] = .offline
        await context.model.refreshCodexSettings(agent)
        await context.model.updateCodexSetting(agent, key: "model", value: "gpt-6-astra")

        context.model.connection[agent.machineID] = .online
        session.terminal = true
        await context.model.refreshCodexSettings(agent)
        await context.model.updateCodexSetting(agent, key: "speed", value: "fast")

        session.terminal = false
        session.busy = true
        await context.model.refreshCodexSettings(agent)
        await context.model.updateCodexSetting(agent, key: "effort", value: "high")

        session.busy = false
        session.settingsBusy = true
        await context.model.refreshCodexSettings(agent)
        await context.model.updateCodexSetting(agent, key: "effort", value: "high")

        let requests = await context.transport.nonInventoryRequests
        XCTAssertTrue(requests.isEmpty, "Unavailable composers must not send terminal input: \(requests)")
        XCTAssertEqual(session.draft, "Unsent local draft")
        XCTAssertTrue(session.pending.isEmpty)
        session.settingsBusy = false
    }

    @MainActor func testSettingsTransactionPreservesDraftsAndPreventsSendingIntoCommandMenu() async throws {
        let context = try await makeContext()
        let first = try XCTUnwrap(context.model.agents.first)
        let second = try XCTUnwrap(context.model.agents.last)
        let firstSession = context.model.state(first)
        let secondSession = context.model.state(second)
        firstSession.draft = "A message that must not become a terminal command."
        secondSession.draft = "A different conversation's draft."
        await context.transport.pauseNextSettingsRead()

        let update = Task { await context.model.updateCodexSetting(first, key: "speed", value: "fast") }
        for _ in 0..<100 {
            if await context.transport.hasPausedRead { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let paused = await context.transport.hasPausedRead
        XCTAssertTrue(paused, "Fixture should pause a real bridge read while the settings transaction is active")
        XCTAssertTrue(firstSession.settingsBusy)
        await context.model.send(to: first)
        XCTAssertEqual(firstSession.draft, "A message that must not become a terminal command.")
        XCTAssertTrue(firstSession.pending.isEmpty)

        await context.transport.failPausedRead()
        await update.value
        XCTAssertFalse(firstSession.settingsBusy, "A failed read must release the transaction lock")
        XCTAssertNotNil(firstSession.notice)
        XCTAssertEqual(firstSession.draft, "A message that must not become a terminal command.")
        XCTAssertEqual(secondSession.draft, "A different conversation's draft.")
        XCTAssertTrue(secondSession.pending.isEmpty)
        let requests = await context.transport.nonInventoryRequests
        XCTAssertFalse(requests.contains("agent.prompt"), "Settings must never submit the user's draft as an agent message")
    }

    @MainActor func testUnbundledDictationReportsHowToEnableItWithoutOpeningMicrophone() async throws {
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") == nil else {
            throw XCTSkip("This test requires the unbundled Swift test runner; it never requests microphone access.")
        }
        let dictation = VoiceDictation()
        await dictation.start()
        XCTAssertFalse(dictation.isRecording)
        XCTAssertFalse(dictation.isPreparing)
        XCTAssertFalse(dictation.isFinishing)
        XCTAssertTrue(dictation.transcript.isEmpty)
        XCTAssertTrue(dictation.error?.contains("installed herdrorb app") == true)
    }

    @MainActor func testCanceledDictationStartDoesNotEnterPermissionOrCaptureFlow() async {
        let dictation = VoiceDictation()
        // Both operations happen on the main actor before the child task can begin.
        let start = Task { await dictation.start() }
        start.cancel()
        await start.value
        XCTAssertFalse(dictation.isPreparing)
        XCTAssertFalse(dictation.isRecording)
        XCTAssertFalse(dictation.isFinishing)
        XCTAssertTrue(dictation.transcript.isEmpty)
        XCTAssertNil(dictation.error, "A canceled start must return before even the bundle/permission checks")
    }

    @MainActor private func makeContext() async throws -> ComposerTestContext {
        let context = ComposerTestContext()
        addTeardownBlock { await context.close() }
        await context.model.start()
        for _ in 0..<100 where context.model.connection["local"] != .online {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(context.model.connection["local"], .online)
        XCTAssertEqual(context.model.agents.count, 2)
        return context
    }
}

@MainActor private final class ComposerTestContext {
    let suite = "herdrorb-composer-tests-" + UUID().uuidString
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("herdrorb-composer-tests-" + UUID().uuidString)
    let preferences: UserDefaults
    let transport = ComposerFixtureConnection()
    let model: BubbleModel

    init() {
        preferences = UserDefaults(suiteName: suite)!
        preferences.set(false, forKey: "saveConversations")
        let fixture = transport
        model = BubbleModel(cache: ConversationCache(directory: directory), preferences: preferences,
                            discover: { [.local] }, makeTransport: { _ in fixture })
    }

    func close() async {
        await transport.failPausedRead()
        await model.stop()
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor ComposerFixtureConnection: HerdrConnection {
    private var requests: [String] = []
    private var shouldPauseRead = false
    private var pausedRead: CheckedContinuation<[String: Any], Error>?
    var nonInventoryRequests: [String] { requests.filter { $0 != "session.snapshot" } }
    var hasPausedRead: Bool { pausedRead != nil }

    func pauseNextSettingsRead() { shouldPauseRead = true }
    func failPausedRead() {
        shouldPauseRead = false
        pausedRead?.resume(throwing: BridgeError.message("Fixture connection interrupted"))
        pausedRead = nil
    }

    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        requests.append(method)
        switch method {
        case "session.snapshot":
            return ["snapshot": ["protocol": 22,
                "panes": [["pane_id": "first", "terminal_id": "first-terminal"], ["pane_id": "second", "terminal_id": "second-terminal"]],
                "agents": [["pane_id": "first", "agent": "codex", "agent_status": "idle"], ["pane_id": "second", "agent": "codex", "agent_status": "idle"]]]]
        case "pane.read", "agent.read":
            if shouldPauseRead {
                shouldPauseRead = false
                return try await withCheckedThrowingContinuation { pausedRead = $0 }
            }
            return ["read": ["text": "› \n  GPT-6-Astra medium · ~/project"]]
        case "pane.send_keys", "pane.send_text": return [:]
        default: throw BridgeError.message("Unexpected composer request: \(method)")
        }
    }

    func events() async throws -> AsyncThrowingStream<Data, Error> { AsyncThrowingStream { _ in } }
    func shutdown() async { failPausedRead() }
}
