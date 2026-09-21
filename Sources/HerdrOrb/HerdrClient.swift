import Foundation
import Combine

struct Machine: Identifiable, Codable, Hashable {
    var id: String
    var label: String
    var enabled: Bool = true
    var target: String?
    var session: String?
    var executablePath: String?
    static let local = Machine(id: "local", label: "This Mac")
    var identity: String { [id, target ?? "local", session ?? "default"].joined(separator: "|") }
}
struct Agent: Identifiable, Codable, Hashable {
    var terminal_id: String
    var name: String?
    var agent: String?
    var title: String?
    var agent_status: String
    var pane_id: String
    var cwd: String?
    var machineID: String = "local"
    var tabID: String?
    var workspaceID: String?
    var workspaceLabel: String?
    var tabLabel: String?
    var profileIdentity: String?
    var id: String { machineID + ":" + terminal_id + ":" + pane_id }
    var label: String { tabLabel ?? title ?? name ?? agent ?? "Terminal" }
    var kind: String { agent == "claude" ? "Claude Code" : (agent ?? "Terminal").capitalized }
    var isShell: Bool { agent == nil }
}
struct MachineInventory: Codable, Equatable {
    var machine: Machine
    var agents: [Agent]
}
enum BridgeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
protocol HerdrConnection: Sendable {
    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any]
    func events() async throws -> AsyncThrowingStream<Data, Error>
    func shutdown() async
}
extension MachineTransport: HerdrConnection {}
extension HerdrConnection {
    func call(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 10) async throws -> [String: Any] { try await request(method, params, timeout: timeout) }
}
enum HerdrClient {
    static func run(_ args: [String], machine: String = "local") async throws -> Data {
        try await ProcessRunner.run(HerdrInstallation.resolve(), (machine == "local" ? [] : ["--machine", machine]) + args)
    }
    static func result(_ data: Data) throws -> [String: Any] {
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BridgeError.message("Invalid Herdr response") }
        if let error = envelope["error"] as? [String: Any] {
            throw RPCError(code: error["code"] as? String ?? "server", message: error["message"] as? String ?? "Herdr rejected the request")
        }
        guard let result = envelope["result"] as? [String: Any] else { throw BridgeError.message("Missing Herdr result") }
        return result
    }
    static func machines() async throws -> [Machine] {
        let data = try await run(["machine", "list", "--json"])
        return [.local] + (try JSONDecoder().decode([Machine].self, from: data)).filter(\.enabled)
    }
    static func sessionName(kind: String, id: UUID = UUID()) -> String { "bubble-" + kind.lowercased() + "-" + id.uuidString.lowercased().prefix(8) }
    static func inventory(_ result: [String: Any], machine: Machine) throws -> [Agent] {
        guard let snapshot = result["snapshot"] as? [String: Any], let protocolVersion = snapshot["protocol"] as? Int else { throw BridgeError.message("Herdr did not return a session snapshot") }
        guard protocolVersion == HerdrInstallation.supportedProtocol else { throw RPCError(code: "incompatible", message: "Herdr on \(machine.label) uses protocol \(protocolVersion). This build supports protocol 22; update compatible installations before connecting.") }
        let agents = snapshot["agents"] as? [[String: Any]] ?? []
        let tabs = snapshot["tabs"] as? [[String: Any]] ?? []
        let workspaces = snapshot["workspaces"] as? [[String: Any]] ?? []
        return (snapshot["panes"] as? [[String: Any]] ?? []).compactMap { pane in
            guard let paneID = pane["pane_id"] as? String, let terminal = pane["terminal_id"] as? String else { return nil }
            let live = agents.first { $0["pane_id"] as? String == paneID }
            let tab = tabs.first { $0["tab_id"] as? String == pane["tab_id"] as? String }
            let workspace = workspaces.first { $0["workspace_id"] as? String == pane["workspace_id"] as? String }
            return Agent(terminal_id: terminal, name: live?["name"] as? String, agent: live?["agent"] as? String,
                         title: live?["title"] as? String, agent_status: live?["agent_status"] as? String ?? "shell", pane_id: paneID,
                         cwd: pane["cwd"] as? String, machineID: machine.id, tabID: pane["tab_id"] as? String,
                         workspaceID: pane["workspace_id"] as? String, workspaceLabel: workspace?["label"] as? String,
                         tabLabel: tab?["label"] as? String, profileIdentity: machine.identity)
        }
    }
}

struct PendingMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var state: String = "Sending…"
}
@MainActor final class SessionState: ObservableObject {
    let identity: String
    @Published var output = ""
    @Published var history = ""
    @Published var messages: [SessionMessage] = []
    var messageRevision = 0
    var lastCleanOutput: String?
    @Published var draft = ""
    @Published var notice: String?
    @Published var busy = false
    @Published var reading = false
    @Published var cached = true
    @Published var follow = true
    @Published var scrollAnchor: String?
    var scrollOffset: Double?
    @Published var pending: [PendingMessage] = []
    @Published var unread = false
    @Published var terminal = false
    @Published var commandMode = false
    @Published var terminalConnected = false
    var terminalSeed: String?
    var terminalSeedFromDraft = false
    var restored = false
    var revision: Int?
    var liveReadInFlight = false
    var parseVersion = 0
    init(identity: String) { self.identity = identity }
}

@MainActor final class BubbleModel: ObservableObject {
    @Published var machines: [Machine] = []
    @Published var agents: [Agent] = []
    @Published var connection: [String: ConnectionState] = [:]
    @Published var connectionDetails: [String: String] = [:]
    @Published var herdrVersions: [String: String] = [:]
    @Published var availability: [String: AgentAvailability] = [:]
    @Published var availabilityErrors: [String: String] = [:]
    @Published var checkingAgents: Set<String> = []
    @Published var showingSetup = false
    @Published var failedLaunches: [String: FailedLaunch] = [:]
    @Published var privacyNotice: String?
    @Published var savingConversations = true
    let isDemo: Bool
    private var suppressPersistence = false
    private let probeAgents: (Machine) async throws -> AgentAvailability
    @Published var selected: Agent?
    @Published var selectedMachineID = "local"
    @Published var refreshing = false
    @Published var launching = false
    @Published var globalNotice: String?
    @Published var lastUpdated: Date?
    @Published var panelVisible = false
    private var states: [String: SessionState] = [:]
    private var observers: [String: [AnyCancellable]] = [:]
    private let emptyState = SessionState(identity: "empty")
    private let cache: ConversationCache
    private let sessionNames: SessionNames
    let preferences: UserDefaults
    private var transports: [String: any HerdrConnection] = [:]
    private let makeTransport: (Machine) -> any HerdrConnection
    private let discover: () async throws -> [Machine]
    private var workers: [String: Task<Void, Never>] = [:]
    private var eventWorkers: [String: Task<Void, Never>] = [:]
    private var eventTokens: [String: UUID] = [:]
    private var snapshotBusy: Set<String> = []
    private var liveTask: Task<Void, Never>?
    private var selectionVersion = 0
    private var saveTasks: [String: Task<Void, Never>] = [:]
    private var started = false
    var current: SessionState { selected.map(state) ?? emptyState }
    var output: String { current.output }
    var messages: [SessionMessage] { current.messages }
    var reading: Bool { current.reading }
    var showingCachedOutput: Bool { current.cached }
    var draft: String { get { current.draft } set { current.draft = newValue; persistCurrent() } }
    var notice: String? { get { current.notice ?? globalNotice } set { current.notice = newValue; globalNotice = newValue } }
    var busy: Bool { current.busy || launching }
    // Keep shell panes in inventory for Herdr bookkeeping, but only agents are conversations.
    var activeSessions: [Agent] { agents.filter { !$0.isShell } }
    var attention: Int { activeSessions.filter { $0.agent_status == "blocked" || state($0).unread }.count }
    init(cache: ConversationCache = ConversationCache(), preferences: UserDefaults = AppPreferences.current, isDemo: Bool = false, probeAgents: @escaping (Machine) async throws -> AgentAvailability = { try await AgentAvailability.check($0) }, discover: @escaping () async throws -> [Machine] = { try await HerdrClient.machines() }, makeTransport: @escaping (Machine) -> any HerdrConnection = { MachineTransport($0) }) {
        self.cache = cache; self.makeTransport = makeTransport; self.discover = discover
        self.isDemo = isDemo; self.probeAgents = probeAgents
        self.showingSetup = !isDemo && !preferences.bool(forKey: "completedSetup")
        self.savingConversations = preferences.object(forKey: "saveConversations") as? Bool ?? true
        self.preferences = preferences; self.sessionNames = SessionNames(defaults: preferences)
        self.selectedMachineID = preferences.string(forKey: "lastMachine") ?? "local"
    }
    func state(_ agent: Agent) -> SessionState {
        let key = ConversationCache.key(for: agent)
        if let state = states[key] { return state }
        let state = SessionState(identity: key); states[key] = state
        observers[key] = [
            state.$unread.dropFirst().sink { [weak self] _ in self?.objectWillChange.send() },
            state.$notice.dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }
        ]
        return state
    }
    func sessionLabel(_ agent: Agent) -> String { agent.tabLabel ?? sessionNames.name(for: agent) }
    func projectFolder(for machine: Machine) -> String {
        (preferences.dictionary(forKey: "projectFolders") as? [String: String])?[machine.identity] ?? ""
    }
    func setProjectFolder(_ path: String, for machine: Machine) {
        var folders = preferences.dictionary(forKey: "projectFolders") as? [String: String] ?? [:]
        folders[machine.identity] = path.isEmpty ? nil : path
        objectWillChange.send()
        preferences.set(folders, forKey: "projectFolders")
    }
    func start() async {
        guard !started else { return }; started = true
        await cache.setEnabled(savingConversations)
        let inventory = await cache.loadInventory()
        if !inventory.isEmpty {
            machines = inventory.map(\.machine); agents = inventory.flatMap(\.agents)
            for machine in machines { connection[machine.id] = .reconnecting }
            if let key = preferences.string(forKey: "lastSession"), let agent = agents.first(where: { ConversationCache.key(for: $0) == key }) { await choose(agent) }
        }
        await refresh()
    }
    func refresh() async {
        guard !refreshing else { return }; refreshing = true
        defer { refreshing = false }
        do {
            var found = try await discover()
            let overrides = preferences.dictionary(forKey: "remoteHerdrExecutables") as? [String: String] ?? [:]
            for index in found.indices where found[index].id != "local" { found[index].executablePath = overrides[found[index].identity] }
            globalNotice = nil
            for old in machines where !found.contains(old) {
                workers[old.id]?.cancel(); eventWorkers[old.id]?.cancel()
                workers[old.id] = nil; eventWorkers[old.id] = nil
                await transports[old.id]?.shutdown(); transports[old.id] = nil
            }
            if machines != found { machines = found }
            agents.removeAll { agent in !found.contains { $0.id == agent.machineID && $0.identity == agent.profileIdentity } }
            for machine in found {
                if transports[machine.id] == nil { transports[machine.id] = makeTransport(machine) }
                if workers[machine.id] == nil { startWorker(machine) }
                else { Task { await self.refreshMachine(machine) } }
            }
            if selected != nil { resumeLive() }
        } catch {
            connection["local"] = ConnectionState.failure(error)
            connectionDetails["local"] = error.localizedDescription
            if machines.isEmpty { machines = [.local] }
            if !connection.values.contains(.online) { showingSetup = true }
        }
    }
    private func startWorker(_ machine: Machine) {
        workers[machine.id] = Task { [weak self] in
            var delay: UInt64 = 1
            while !Task.isCancelled {
                guard let self else { break }
                await self.refreshMachine(machine)
                let online = self.connection[machine.id] == .online
                if online { delay = 1; self.startEvents(machine) }
                do { try await Task.sleep(nanoseconds: (online ? 15 : delay) * 1_000_000_000) } catch { break }
                if !online { delay = min(delay * 2, 30) }
            }
        }
    }
    private func startEvents(_ machine: Machine) {
        guard eventWorkers[machine.id] == nil, let transport = transports[machine.id] else { return }
        let token = UUID(); eventTokens[machine.id] = token
        eventWorkers[machine.id] = Task { [weak self] in
            defer { if self?.eventTokens[machine.id] == token { self?.eventWorkers[machine.id] = nil } }
            var retry: UInt64 = 1
            while !Task.isCancelled {
                do {
                    let events = try await transport.events()
                    for try await data in events {
                        try Task.checkCancellation()
                        guard let self else { return }
                        let event = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                        if event?["error"] != nil { throw BridgeError.message("Event stream needs resynchronization") }
                        if let type = event?["event"] as? String {
                            await self.refreshMachine(machine)
                            if ["pane.created", "pane.closed", "pane_created", "pane_closed"].contains(type) { break }
                        }
                    }
                    retry = 1
                } catch {
                    if Task.isCancelled { break }
                    await self?.refreshMachine(machine)
                }
                do { try await Task.sleep(nanoseconds: retry * 1_000_000_000) } catch { break }
                retry = min(retry * 2, 30)
            }
        }
    }

    func refreshMachine(_ machine: Machine) async {
        guard !snapshotBusy.contains(machine.id), let transport = transports[machine.id] else { return }
        snapshotBusy.insert(machine.id); defer { snapshotBusy.remove(machine.id) }
        if connection[machine.id] != .online { connection[machine.id] = .connecting }
        do {
            let result = try await transport.call("session.snapshot")
            try Task.checkCancellation()
            var found = try HerdrClient.inventory(result, machine: machine)
            if let version = result["_herdrorb_version"] as? String { herdrVersions[machine.id] = version }
            connectionDetails[machine.id] = nil
            if let failed = failedLaunches[machine.id], !found.contains(where: { $0.pane_id == failed.paneID && $0.isShell }) {
                failedLaunches[machine.id] = nil
            }
            for index in found.indices {
                let agent = found[index]
                if sessionNames.needsSync(agent), let saved = sessionNames.existingName(for: agent), let tab = agent.tabID {
                    _ = try await transport.call("tab.rename", ["tab_id": tab, "label": saved])
                    found[index].tabLabel = saved; sessionNames.markSynced(agent)
                }
            }
            guard machines.contains(machine) else { return }
            for agent in found {
                if let old = agents.first(where: { $0.id == agent.id }), old.agent_status != agent.agent_status,
                   ["done", "blocked"].contains(agent.agent_status), selected?.id != agent.id { state(agent).unread = true }
            }
            let previous = agents.filter { $0.machineID == machine.id }
            if previous != found { agents.removeAll { $0.machineID == machine.id }; agents += found }
            if connection[machine.id] != .online { connection[machine.id] = .online }; lastUpdated = Date()
            if let selected, selected.machineID == machine.id {
                if let fresh = found.first(where: { $0.id == selected.id && (!$0.isShell || state(selected).terminal) }) {
                    if self.selected != fresh { self.selected = fresh }
                } else { showMachine(machine.id) }
            }
            let inventory = machines.map { machine in MachineInventory(machine: machine, agents: agents.filter { $0.machineID == machine.id }) }
            await cache.saveInventory(inventory)
        } catch {
            if Task.isCancelled { return }
            connection[machine.id] = ConnectionState.failure(error)
            connectionDetails[machine.id] = error.localizedDescription
            if selected?.machineID == machine.id { current.notice = error.localizedDescription; current.cached = true }
        }
    }
    func showMachine(_ id: String) {
        persistCurrent(); suspendLive(); selectionVersion += 1
        selectedMachineID = id; selected = nil
        preferences.set(id, forKey: "lastMachine")
        preferences.removeObject(forKey: "lastSession")
    }
    func choose(_ agent: Agent) async {
        guard !agent.isShell else { showMachine(agent.machineID); return }
        if selected?.id == agent.id && liveTask != nil { return }
        persistCurrent(); liveTask?.cancel(); selectionVersion += 1
        let version = selectionVersion, started = Date()
        selected = agent
        selectedMachineID = agent.machineID
        preferences.set(agent.machineID, forKey: "lastMachine")
        preferences.set(ConversationCache.key(for: agent), forKey: "lastSession")
        let state = state(agent); state.unread = false
        if !state.restored {
            state.restored = true
            let snapshot = await cache.snapshot(for: agent)
            if let snapshot {
                state.output = snapshot.text; state.history = snapshot.history
                if state.draft.isEmpty { state.draft = snapshot.draft }
                state.follow = snapshot.follow; state.scrollAnchor = snapshot.scrollAnchor; state.scrollOffset = snapshot.scrollOffset
                await parse(agent, state: state)
            }
        }
        guard version == selectionVersion else { return }
        Metrics.record("session.cached-display", milliseconds: Date().timeIntervalSince(started) * 1000)
        resumeLive()
    }
    func suspendLive() { liveTask?.cancel(); liveTask = nil }
    func resumeLive() {
        liveTask?.cancel()
        guard panelVisible, let agent = selected, !state(agent).terminal else { liveTask = nil; return }
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.transports[agent.machineID] != nil else {
                    do { try await Task.sleep(nanoseconds: 200_000_000) } catch { break }; continue
                }
                let state = self.state(agent)
                if !self.panelVisible || state.terminal {
                    do { try await Task.sleep(nanoseconds: 250_000_000) } catch { break }; continue
                }
                await self.readSelected()
                if Task.isCancelled { break }
                // Herdr 0.9.1 rejects output-change waits at runtime. Keep visible reads
                // lightweight and adaptive over the retained connection; status is event-driven.
                let working = self.selected?.agent_status == "working" || state.busy
                do { try await Task.sleep(nanoseconds: working ? 100_000_000 : 500_000_000) } catch { break }
            }
        }
    }
    func canInteract(_ agent: Agent) -> Bool {
        connection[agent.machineID] == .online && agents.contains { $0.id == agent.id && $0.profileIdentity == agent.profileIdentity }
    }
    func needsTerminalResponse(_ agent: Agent) -> Bool {
        let current = agents.first { $0.id == agent.id && $0.profileIdentity == agent.profileIdentity } ?? agent
        return current.agent_status == "blocked"
    }
    func respondInTerminal(_ agent: Agent) {
        guard canInteract(agent) else { return }
        let state = state(agent)
        // A chat draft, including "yes", must never become terminal approval input.
        state.terminalSeed = nil; state.terminalSeedFromDraft = false
        state.commandMode = true; state.terminalConnected = isDemo; state.terminal = true
        state.notice = nil
        resumeLive()
    }
    func readSelected() async {
        guard let agent = selected, canInteract(agent), let transport = transports[agent.machineID] else { return }
        let state = state(agent)
        guard !state.reading && !state.liveReadInFlight else { return }
        state.liveReadInFlight = true
        if state.output.isEmpty { state.reading = true }
        defer { state.liveReadInFlight = false; if state.reading { state.reading = false } }
        do {
            let result = try await transport.call("pane.read", ["pane_id": agent.pane_id, "source": "visible", "format": "text", "strip_ansi": true])
            try Task.checkCancellation()
            guard let read = result["read"] as? [String: Any], let text = read["text"] as? String else { return }
            state.revision = read["revision"] as? Int
            if state.cached { state.notice = nil; state.cached = false }
            if state.output != text {
                state.output = text
                let clean = TerminalPresentation.conversation(text, kind: agent.agent)
                if state.lastCleanOutput != clean {
                    state.lastCleanOutput = clean
                    state.history = String(TerminalPresentation.mergeHistory(state.history, live: clean).suffix(250_000))
                    await parse(agent, state: state)
                }
                state.pending.removeAll { text.contains($0.text) }
                persist(agent)
            }
        } catch {
            if !Task.isCancelled { state.notice = error.localizedDescription; state.cached = true }
        }
    }
    private func parse(_ agent: Agent, state: SessionState) async {
        state.parseVersion += 1
        let version = state.parseVersion
        let output = state.history.isEmpty ? state.output : state.history
        let kind = agent.agent
        let messages = await Task.detached(priority: .userInitiated) { TerminalPresentation.messages(output, kind: kind) }.value
        if version == state.parseVersion && state.messages != messages {
            state.messageRevision += 1
            state.messages = messages
        }
    }
    func loadHistory() async {
        guard let agent = selected, canInteract(agent), let transport = transports[agent.machineID] else { return }
        let state = state(agent)
        guard !state.reading else { return }
        liveTask?.cancel(); state.reading = true
        defer { state.reading = false; resumeLive() }
        do {
            let result = try await transport.call(agent.isShell ? "pane.read" : "agent.read", [agent.isShell ? "pane_id" : "target": agent.pane_id, "source": "recent_unwrapped", "lines": 1000, "format": "text"], timeout: 25)
            guard let read = result["read"] as? [String: Any], let text = read["text"] as? String else { return }
            state.history = TerminalPresentation.conversation(text, kind: agent.agent); await parse(agent, state: state); persist(agent)
        } catch { state.notice = error.localizedDescription }
    }
    static func isSlashCommand(_ text: String) -> Bool {
        text.hasPrefix("/") && !text.contains("\n") && !text.contains("\r")
    }
    func composerChanged(_ agent: Agent, text: String) {
        let state = state(agent)
        state.draft = text; persist(agent)
        if !state.terminal && Self.isSlashCommand(text) { openSlashCommands(agent, text: text, fromDraft: true) }
        else if state.terminalSeedFromDraft && !state.terminalConnected { state.terminalSeed = text }
    }
    func openSlashCommands(_ agent: Agent, text: String = "/", fromDraft: Bool = false, submit: Bool = false) {
        let state = state(agent)
        guard !state.terminal, !state.busy else { return }
        guard canInteract(agent), !agent.isShell else {
            state.notice = "Reconnect to this agent before opening its command menu."; return
        }
        state.terminalSeed = text + (submit && text != "/" ? "\r" : "")
        state.terminalSeedFromDraft = fromDraft
        state.commandMode = true; state.terminalConnected = false; state.terminal = true
        state.notice = nil
        resumeLive()
    }
    func terminalAttached(_ agent: Agent) {
        let state = state(agent)
        state.terminalConnected = true
        if state.terminalSeedFromDraft, let seed = state.terminalSeed,
           state.draft == seed.trimmingCharacters(in: .newlines) { state.draft = "" }
        state.terminalSeed = nil; state.terminalSeedFromDraft = false
        persist(agent)
    }
    func terminalExited(_ agent: Agent) {
        let state = state(agent)
        state.terminalConnected = false
        if state.terminalSeed != nil { state.notice = "The terminal could not connect. Your command draft has been kept; return to Conversation to retry." }
        else { state.notice = "Terminal disconnected. Return to Conversation and reopen Terminal to reconnect." }
    }
    func closeTerminal(_ agent: Agent) {
        let state = state(agent)
        state.terminal = false; state.commandMode = false; state.terminalConnected = false
        state.terminalSeed = nil; state.terminalSeedFromDraft = false
        resumeLive()
    }
    func send(to target: Agent? = nil) async {
        guard let agent = target ?? selected, !agent.isShell else { return }
        guard canInteract(agent), let transport = transports[agent.machineID] else {
            state(agent).notice = "This terminal is not connected. Your draft is saved; reconnect before sending."
            return
        }
        let state = state(agent)
        let text = state.draft
        guard !needsTerminalResponse(agent) else {
            state.notice = "This session needs a response in Terminal. Your chat draft has been kept."
            return
        }
        if Self.isSlashCommand(text) {
            openSlashCommands(agent, text: text, fromDraft: true, submit: true)
            return
        }
        guard !state.busy, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let pending = PendingMessage(text: text)
        state.pending.append(pending); state.draft = ""; state.busy = true; state.notice = nil; persist(agent)
        defer { state.busy = false }
        do {
            _ = try await transport.call("agent.prompt", ["target": agent.pane_id, "text": text], timeout: 20)
            if let index = state.pending.firstIndex(where: { $0.id == pending.id }) {
                state.pending[index].state = agent.agent_status == "working" ? "Delivered · Codex may queue this follow-up" : "Delivered to Codex"
            }
        } catch {
            if let index = state.pending.firstIndex(where: { $0.id == pending.id }) { state.pending[index].state = "Not confirmed" }
            if state.draft.isEmpty { state.draft = text }
            state.notice = "Message delivery was not confirmed. Check the terminal before resending. \(error.localizedDescription)"
            persist(agent)
        }
    }
    func interrupt() async {
        guard let agent = selected, canInteract(agent), let transport = transports[agent.machineID] else { return }
        do { _ = try await transport.call("pane.send_keys", ["pane_id": agent.pane_id, "keys": ["ctrl+c"]]) }
        catch { state(agent).notice = error.localizedDescription }
    }
    func deleteSession(_ agent: Agent) async {
        guard canInteract(agent), let transport = transports[agent.machineID] else { return }
        do {
            _ = try await transport.call("pane.close", ["pane_id": agent.pane_id])
            closeTerminal(agent)
            if let machine = machines.first(where: { $0.id == agent.machineID }) {
                await refreshMachine(machine)
            }
        } catch { globalNotice = "Could not delete session \(sessionLabel(agent)): \(error.localizedDescription)" }
    }
    func rename(_ agent: Agent, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, canInteract(agent), let tab = agent.tabID, let transport = transports[agent.machineID] else { return }
        Task {
            do {
                _ = try await transport.call("tab.rename", ["tab_id": tab, "label": name])
                for index in agents.indices where agents[index].machineID == agent.machineID && agents[index].tabID == tab { agents[index].tabLabel = name }
                if selected?.machineID == agent.machineID && selected?.tabID == tab { selected?.tabLabel = name }
            } catch { state(agent).notice = error.localizedDescription }
        }
    }
    func launch(kind: String, machine: Machine, directory: String) async {
        guard !launching, connection[machine.id] == .online, let transport = transports[machine.id] else { return }
        launching = true; globalNotice = nil
        defer { launching = false }
        showMachine(machine.id)
        var paneID: String?
        do {
            let installed = try await probeAgents(machine)
            availability[machine.id] = installed
            guard installed.contains(kind) else { throw BridgeError.message("Install \(kind == "claude" ? "Claude Code" : "Codex") on \(machine.label) and sign in from Terminal before starting a session.") }
            var params: [String: Any] = ["focus": false, "label": sessionNames.reserveNumber()]
            let folder = directory.trimmingCharacters(in: .whitespacesAndNewlines)
            if !folder.isEmpty { params["cwd"] = folder }
            let result = try await transport.call("tab.create", params)
            guard let pane = result["root_pane"] as? [String: Any], let paneId = pane["pane_id"] as? String else { throw BridgeError.message("Tab created without a pane ID") }
            paneID = paneId
            await refreshMachine(machine)
            _ = try await transport.call("agent.start", ["name": HerdrClient.sessionName(kind: kind), "kind": kind, "pane_id": paneId, "timeout_ms": 30_000], timeout: 35)
            await refreshMachine(machine)
            if let agent = agents.first(where: { $0.machineID == machine.id && $0.pane_id == paneId }) { await choose(agent) }
        } catch {
            await refreshMachine(machine)
            if let paneID { failedLaunches[machine.id] = FailedLaunch(paneID: paneID, kind: kind, detail: error.localizedDescription) }
            globalNotice = "\(paneID == nil ? "Session could not be created." : "The agent could not start. Its terminal is available in Herdr for troubleshooting.") \(error.localizedDescription)"
        }
    }

    func completeSetup() {
        preferences.set(true, forKey: "completedSetup"); showingSetup = false
    }
    func checkAgents(_ machine: Machine) async {
        guard !checkingAgents.contains(machine.id) else { return }
        checkingAgents.insert(machine.id); defer { checkingAgents.remove(machine.id) }
        availabilityErrors[machine.id] = nil
        do { availability[machine.id] = try await probeAgents(machine) }
        catch { availability[machine.id] = nil; availabilityErrors[machine.id] = error.localizedDescription }
    }
    func testConnection(_ machine: Machine) async {
        if transports[machine.id] == nil { await refresh() }
        await refreshMachine(machine)
        if connection[machine.id] == .online { await checkAgents(machine) }
    }
    func setExecutable(_ path: String, for machine: Machine = .local) async {
        if machine.id == "local" { preferences.set(path.isEmpty ? nil : path, forKey: "herdrExecutable") }
        else {
            var overrides = preferences.dictionary(forKey: "remoteHerdrExecutables") as? [String: String] ?? [:]
            overrides[machine.identity] = path.isEmpty ? nil : path
            preferences.set(overrides, forKey: "remoteHerdrExecutables")
        }
        workers[machine.id]?.cancel(); workers[machine.id] = nil
        eventWorkers[machine.id]?.cancel(); eventWorkers[machine.id] = nil
        await transports[machine.id]?.shutdown(); transports[machine.id] = nil
        await refresh()
    }
    var diagnostics: String {
        Diagnostics.text(connections: machines.map { (connection[$0.id] ?? .connecting, herdrVersions[$0.id]) })
    }
    func setSavingConversations(_ enabled: Bool) async {
        suppressPersistence = true
        for task in saveTasks.values { task.cancel(); await task.value }
        saveTasks.removeAll()
        savingConversations = enabled
        preferences.set(enabled, forKey: "saveConversations")
        await cache.setEnabled(enabled)
        if !enabled {
            do { try await cache.clear() }
            catch { privacyNotice = "Saving is off, but existing cache files could not be removed: \(error.localizedDescription)" }
        }
        suppressPersistence = false
    }
    func clearSavedConversations() async {
        suppressPersistence = true
        for task in saveTasks.values { task.cancel(); await task.value }
        saveTasks.removeAll()
        do {
            try await cache.clear()
            // Retain live terminal connections and unsent in-memory drafts.
            for state in states.values { state.history = state.output; state.lastCleanOutput = nil }
            privacyNotice = "Saved conversations and drafts cleared. Live sessions and current drafts remain open."
        } catch { privacyNotice = "Could not clear saved data: \(error.localizedDescription)" }
        suppressPersistence = false
    }
    func openRecoveryTerminal(_ machine: Machine) async {
        guard let failed = failedLaunches[machine.id], let agent = agents.first(where: { $0.machineID == machine.id && $0.pane_id == failed.paneID }) else { return }
        persistCurrent(); suspendLive(); selectionVersion += 1
        selectedMachineID = machine.id; selected = agent
        state(agent).terminal = true; state(agent).terminalConnected = false
    }
    func retryLaunch(_ machine: Machine) async {
        guard !launching, let failed = failedLaunches[machine.id], let transport = transports[machine.id], connection[machine.id] == .online else { return }
        launching = true; globalNotice = nil; defer { launching = false }
        await refreshMachine(machine)
        // A timeout may have started the agent. Never submit another start if it is already present.
        guard let pane = agents.first(where: { $0.machineID == machine.id && $0.pane_id == failed.paneID }) else { return }
        if !pane.isShell { failedLaunches[machine.id] = nil; await choose(pane); return }
        do {
            _ = try await transport.call("agent.start", ["name": HerdrClient.sessionName(kind: failed.kind), "kind": failed.kind, "pane_id": failed.paneID, "timeout_ms": 30_000], timeout: 35)
            failedLaunches[machine.id] = nil
            await refreshMachine(machine)
            if let agent = agents.first(where: { $0.machineID == machine.id && $0.pane_id == failed.paneID && !$0.isShell }) { await choose(agent) }
        } catch { failedLaunches[machine.id]?.detail = error.localizedDescription }
    }

    func persistCurrent() { if let selected { persist(selected) } }
    func persist(_ agent: Agent) {
        guard savingConversations, !suppressPersistence, !isDemo else { return }
        let state = state(agent)
        let snapshot = ConversationCache.Snapshot(text: state.output, updatedAt: Date(), draft: state.draft, follow: state.follow, scrollAnchor: state.scrollAnchor, history: state.history, scrollOffset: state.scrollOffset)
        saveTasks[agent.id]?.cancel()
        saveTasks[agent.id] = Task { await cache.store(snapshot, for: agent) }
    }
    func stop() async {
        liveTask?.cancel()
        for task in workers.values { task.cancel() }; for task in eventWorkers.values { task.cancel() }
        persistCurrent()
        for task in saveTasks.values { await task.value }
        await cache.flush()
        for transport in transports.values { await transport.shutdown() }
    }
}

struct FailedLaunch: Equatable { let paneID: String; let kind: String; var detail: String }
