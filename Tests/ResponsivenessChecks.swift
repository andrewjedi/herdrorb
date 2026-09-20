import Foundation

actor FakeConnection: HerdrConnection {
    let machine: Machine
    var delay: UInt64 = 0
    var failed = false
    var sends = 0
    var renameLabel = "1"
    var createCount = 0
    var agentPresent = true
    init(_ machine: Machine) { self.machine = machine }
    func setDelay(_ value: UInt64) { delay = value }
    func setFailure(_ value: Bool) { failed = value }
    func setAgentPresent(_ value: Bool) { agentPresent = value }
    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if failed { throw RPCError(code: "transport", message: "Offline fixture") }
        switch method {
        case "session.snapshot":
            return ["snapshot": ["protocol": 22, "panes": [["pane_id": "p1", "terminal_id": "t1", "tab_id": "tab1", "workspace_id": "w1"]],
                                 "agents": agentPresent ? [["pane_id": "p1", "agent": "codex", "agent_status": "idle"]] : [],
                                 "tabs": [["tab_id": "tab1", "label": renameLabel]], "workspaces": [["workspace_id": "w1", "label": "Project"]]]]
        case "pane.read": return ["read": ["text": "› Hello\n\n• Reply for \(params["pane_id"] as? String ?? "unknown")", "revision": 1]]
        case "agent.prompt": sends += 1; try await Task.sleep(nanoseconds: 200_000_000); return ["sent": true]
        case "tab.rename": renameLabel = params["label"] as! String; return ["renamed": true]
        case "tab.create": createCount += 1; return ["root_pane": ["pane_id": "p1"]]
        case "agent.start": throw RPCError(code: "agent_not_ready", message: "Approval required")
        default: return [:]
        }
    }
    func events() async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { _ in }
    }
    func shutdown() async {}
}

@main struct ResponsivenessChecks {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = Machine(id: "a", label: "Fast"), b = Machine(id: "b", label: "Slow")
        let fast = FakeConnection(a), slow = FakeConnection(b)
        await slow.setDelay(2_000_000_000)
        let suite = "HerdrModelTests-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = BubbleModel(cache: ConversationCache(directory: folder), preferences: preferences, probeAgents: { _ in AgentAvailability(codex: true, claude: true) }, discover: { [a,b] }, makeTransport: { $0.id == "a" ? fast : slow })
        await model.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        assert(model.connection["a"] == .online, "A slow machine must not delay another")
        assert(model.connection["b"] != .online)
        let first = model.agents.first!
        var second = first; second.terminal_id = "t2"; second.pane_id = "p2"
        await model.choose(first); model.draft = "Keep this draft"
        await model.choose(second); model.draft = "Second draft"
        await model.choose(first)
        assert(model.draft == "Keep this draft")
        let send = Task { await model.send() }
        try await Task.sleep(nanoseconds: 20_000_000)
        assert(model.current.pending.count == 1 && model.draft.isEmpty)
        await model.send()
        await model.choose(second)
        assert(!model.current.busy && model.draft == "Second draft")
        await send.value
        let count = await fast.sends
        assert(count == 1, "Repeated Return must not duplicate submission")
        assert(model.draft == "Second draft", "Completing a send must not clear another draft")
        await model.choose(first)
        await fast.setFailure(true)
        model.draft = "Restore on failure"
        await model.send()
        assert(model.draft == "Restore on failure")
        assert(model.current.pending.last?.state == "Not confirmed")
        await model.refreshMachine(a)
        assert(model.agents.contains(where: { $0.id == first.id }), "Offline inventory must remain visible")
        await fast.setFailure(false)
        await model.refreshMachine(a)
        model.rename(first, to: "Shared title")
        try await Task.sleep(nanoseconds: 20_000_000)
        let name = await fast.renameLabel
        assert(name == "Shared title")
        await model.launch(kind: "codex", machine: a, directory: "")
        assert(model.selected == nil && model.notice != nil && model.selectedMachineID == a.id, "Failed startup must retain the target device and explain the failure")
        let creations = await fast.createCount
        assert(creations == 1)
        model.agents.append(second)
        await model.choose(first)
        await fast.setDelay(200_000_000)
        let olderRead = Task { await model.readSelected() }
        try await Task.sleep(nanoseconds: 20_000_000)
        await model.choose(second)
        await fast.setDelay(0)
        await model.readSelected()
        await olderRead.value
        assert(model.current.output.contains("Reply for p2"), "A late reply must not replace another session's output")
        await fast.setDelay(2_000_000_000)
        let cancelledRead = Task { await model.readSelected() }
        try await Task.sleep(nanoseconds: 20_000_000)
        let cancelledAt = Date()
        cancelledRead.cancel(); await cancelledRead.value
        assert(Date().timeIntervalSince(cancelledAt) < 0.5)
        assert(!model.current.liveReadInFlight && !model.current.reading)
        await fast.setDelay(0)
        var switches: [Double] = []
        for i in 0..<100 {
            let start = Date(); await model.choose(i.isMultiple(of: 2) ? first : second)
            switches.append(Date().timeIntervalSince(start) * 1000)
        }
        switches.sort()
        assert(switches[94] < 100, "Warm session state switching should remain immediate")
        print("Warm session-state switch median \(switches[49]) ms, p95 \(switches[94]) ms (model, not rendered frames)")
        await model.choose(first)
        let promptsBeforeSlash = await fast.sends
        model.composerChanged(first, text: "/")
        assert(model.current.terminal && model.current.commandMode && model.current.terminalSeed == "/")
        assert(model.current.draft == "/", "Keep the draft until the terminal actually accepts the handoff")
        model.composerChanged(first, text: "/model")
        assert(model.current.terminalSeed == "/model", "Preserve typing during the view transition")
        model.terminalAttached(first)
        assert(model.current.draft.isEmpty && model.current.terminalSeed == nil)
        model.closeTerminal(first)
        model.draft = "Keep my chat draft"
        model.openSlashCommands(first)
        model.terminalAttached(first)
        assert(model.draft == "Keep my chat draft", "The Commands button must preserve an unrelated chat draft")
        model.closeTerminal(first)
        model.draft = "/help"
        await model.send()
        assert(model.current.terminalSeed == "/help\r")
        model.terminalExited(first)
        assert(model.draft == "/help" && model.current.notice != nil)
        model.closeTerminal(first)
        let promptsAfterSlash = await fast.sends
        assert(promptsAfterSlash == promptsBeforeSlash, "Slash commands must not become agent.prompt chat messages")
        assert(!BubbleModel.isSlashCommand("Explain /model"))
        assert(!BubbleModel.isSlashCommand("/example\nThis is a multiline message"))
        print("Slash command routing, draft handoff, failed attach recovery and chat-draft preservation passed")
        assert(model.activeSessions.contains { $0.id == first.id }, "An idle agent remains a real session")
        model.draft = "Keep after agent exits"
        await fast.setAgentPresent(false)
        await model.refreshMachine(a)
        assert(model.agents.contains { $0.machineID == a.id && $0.isShell }, "Do not delete underlying shell inventory")
        assert(!model.activeSessions.contains { $0.machineID == a.id }, "Shell-only panes must not appear as sessions")
        assert(model.selected == nil && model.selectedMachineID == a.id, "Agent exit must show the empty state on its own device")
        assert(model.state(first).draft == "Keep after agent exits", "Hiding an ended session must preserve its draft")
        assert(preferences.string(forKey: "lastMachine") == a.id && preferences.string(forKey: "lastSession") == nil)
        await model.choose(model.agents.first { $0.machineID == a.id }!)
        assert(model.selected == nil, "A restored shell must not reopen a phantom conversation")
        await fast.setAgentPresent(true)
        await model.refreshMachine(a)
        assert(model.activeSessions.contains { $0.id == first.id }, "Agents started in Herdr must reappear")
        print("Idle agents, shell-only filtering, exit-to-empty state, device targeting and draft preservation passed")
        await model.stop()
        let command = Task { try await ProcessRunner.run("/bin/sleep", ["10"]) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let cancelStarted = Date(); command.cancel()
        do { _ = try await command.value; assertionFailure("Cancelled process must fail") }
        catch is CancellationError {}
        assert(Date().timeIntervalSince(cancelStarted) < 2, "Cancellation must stop the subprocess promptly")
        let timeoutStarted = Date()
        do { _ = try await ProcessRunner.run("/bin/sleep", ["10"], timeout: 0.1); assertionFailure("Timed-out process must fail") }
        catch {}
        assert(Date().timeIntervalSince(timeoutStarted) < 2)
        print("Out-of-order reads, cancellation, subprocess cancellation and timeout passed")
        print("Independent machines, draft preservation, immediate sending, duplicate prevention, send isolation, failure recovery, offline inventory, shared renaming and recoverable startup passed")
    }
}
