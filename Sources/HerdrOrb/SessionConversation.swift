import SwiftUI
import AppKit

struct SessionConversation: View {
    let model: BubbleModel
    let agent: Agent
    let machine: Machine
    @ObservedObject var session: SessionState
    @AppStorage("automaticallyScrollToNewMessages") private var automaticallyScroll = true
    @State private var loginCode = ""
    @State private var showingAccountHelp = false
    @State private var find = ""
    @State private var searching = false
    @State private var confirmingDelete = false
    @State private var expandedActivity: Set<String> = []
    @State private var prependRevision = 0
    @State private var searchLimit = ConversationWindow.pageSize
    @State private var searchPage: ConversationArchive.Page?
    @State private var searchBusy = false
    @State private var searchError: String?
    @State private var pageRevision = 0
    @State private var awayFromLatest = false
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    modePicker(compact: false).fixedSize()
                    modePicker(compact: true).fixedSize()
                }
                .padding(3)
                .background(OrbTheme.surface, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(OrbTheme.line, lineWidth: 0.8))
                Spacer(minLength: 0)
                if !agent.isShell && !session.terminal && session.terminalSetup == nil {
                    ContextUsageIndicator(provider: agent.kind, usage: session.cached || session.settingsBusy ? nil : session.contextUsage, connect: { Task { await model.connectHistory(agent) } })
                }
                if session.terminal && !session.terminalConnected {
                    ProgressView().controlSize(.small).help("Connecting terminal…")
                } else if !session.terminal && session.cached {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                        .help("Showing saved conversation while reconnecting")
                }
                if !session.terminal {
                    Rectangle().fill(OrbTheme.line).frame(width: 1, height: 20).padding(.trailing, 4)
                    Button {
                        searching.toggle()
                        if searching { searchFocused = true } else { find = "" }
                    } label: {
                        Image(systemName: "magnifyingglass").frame(width: 24, height: 24)
                            .background(searching ? Color.white.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }.help("Find in conversation").accessibilityLabel("Find in conversation")
                }
                if agent.agent == "claude" {
                    Button { showingAccountHelp = true } label: {
                        Image(systemName: "person.crop.circle").frame(width: 24, height: 24)
                    }.help("Claude account and sign out").accessibilityLabel("Claude account and sign out")
                    .popover(isPresented: $showingAccountHelp) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Claude account on \(machine.label)").font(.headline)
                            Text("In Claude Code, run /logout to sign out, then /login to choose another account. This affects Claude Code on this device.").fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button("Sign out") { showingAccountHelp = false; Task { await model.claudeAccount(agent, signOut: true) } }
                                Button("Switch account") { showingAccountHelp = false; Task { await model.claudeAccount(agent, signOut: false) } }
                            }.buttonStyle(OrbButtonStyle()).disabled(session.busy || session.settingsBusy || agent.agent_status == "working" || !model.canInteract(agent))
                            Button("Open account controls in Terminal") {
                                showingAccountHelp = false
                                model.respondInTerminal(agent)
                            }.buttonStyle(OrbButtonStyle(kind: .primary))
                        }.padding(18).frame(width: 310)
                    }
                }
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Image(systemName: "trash").frame(width: 24, height: 24)
                }.help("Delete session").accessibilityLabel("Delete session")
                    .disabled(!model.canInteract(agent) || session.settingsBusy)
            }.buttonStyle(.plain).font(.system(size: 12)).padding(.horizontal, 18).padding(.vertical, 6)
                .overlay(alignment: .bottom) { OrbRule() }
                .sheet(isPresented: $confirmingDelete) {
                    SessionDeleteSheet(name: model.sessionLabel(agent), cancel: { confirmingDelete = false }) {
                        confirmingDelete = false
                        Task { await model.deleteSession(agent) }
                    }
                }
            if session.terminal && model.isDemo {
                DemoTerminal().padding(16).background(Color(hex: 0x0C0D10), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(OrbTheme.line, lineWidth: 0.8))
                    .padding(.horizontal, 12).padding(.bottom, 12)
            } else if session.terminal {
                EmbeddedTerminal(agent: agent, machine: machine, initialInput: session.terminalSeed ?? "",
                                 onReady: { model.terminalAttached(agent) }, onExit: { model.terminalExited(agent) }).id(agent.id)
                    .padding(12).background(Color(hex: 0x0C0D10), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(OrbTheme.line, lineWidth: 0.8))
                    .padding(.horizontal, 12).padding(.bottom, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if session.commandMode {
                    Text("↑ ↓ Navigate  ·  Return Select  ·  Esc Dismiss")
                        .font(.system(size: 12)).foregroundStyle(OrbTheme.secondary).padding(.vertical, 6)
                }
            } else if agent.agent == "claude", let setup = session.terminalSetup {
                setupView(setup)
            } else {
                if searching {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find in conversation", text: $find).textFieldStyle(.plain).focused($searchFocused)
                        .onExitCommand { searching = false; find = "" }
                    if !find.isEmpty { Button { find = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                }.font(.system(size: 11)).padding(.horizontal, 24).padding(.bottom, 8)
                }
                if let notice = session.transcriptNotice {
                    HStack(spacing: 8) {
                        Text(notice).font(.system(size: 11)).foregroundStyle(OrbTheme.secondary)
                        if !session.structuredHistory && agent.providerSession == nil {
                            Button("Connect history") { Task { await model.connectHistory(agent) } }
                                .buttonStyle(.plain).font(.system(size: 11)).disabled(session.settingsBusy)
                        }
                    }.padding(.horizontal, 24).padding(.bottom, 8)
                }
                if agent.agent_status == "working", let notice = session.activityMessage {
                    Text(notice).font(.system(size: 11)).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 8)
                }
                ConversationRows(follow: automaticallyScroll && session.follow && find.isEmpty, offset: session.scrollOffset,
                                   version: ConversationContentVersion(messages: session.messageRevision, pending: session.pending, filter: find, raw: nil, status: agent.agent_status, loading: session.reading, disclosures: expandedActivity, cached: session.cached, historyStart: session.scrollAnchor, prepend: prependRevision, searchLimit: searchLimit + pageRevision), changed: { follow, offset in
                    guard find.isEmpty else { return }
                    if !session.browsingHistory && session.follow != follow { session.follow = follow }
                    session.scrollOffset = offset
                    model.persist(agent)
                }, rows: conversationRows, latestVisibilityChanged: { awayFromLatest = $0 })
                    .overlay(alignment: .bottom) {
                        if !session.follow && find.isEmpty && (awayFromLatest || session.browsingHistory) {
                            Button {
                                if session.browsingHistory { Task { await model.historyPage(agent, earlier: false); session.follow = true; pageRevision += 1 } }
                                else { session.follow = true; model.persist(agent) }
                            } label: { Label("Latest", systemImage: "arrow.down") }
                                .buttonStyle(OrbButtonStyle(compact: true)).padding(.bottom, 9)
                        }
                    }
                if !agent.isShell && model.needsTerminalResponse(agent) {
                    if let approval = session.approval {
                        ConversationApprovalCard(approval: approval, provider: agent.kind,
                            busy: session.busy || session.settingsBusy,
                            choose: { choice in Task { await model.respondToApproval(agent, choice: choice) } },
                            openTerminal: { model.respondInTerminal(agent) })
                            .frame(maxWidth: 780).padding(.horizontal, 28).frame(maxWidth: .infinity).padding(.vertical, 10)
                    } else {
                    HStack(alignment: .center, spacing: 14) {
                        Image(systemName: "hand.raised").foregroundStyle(OrbTheme.warning)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(agent.kind) is waiting for you").font(.system(size: 13, weight: .medium))
                            Text("Choose a response in Terminal. Your draft is saved.")
                                .font(.system(size: 11)).foregroundStyle(OrbTheme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Button { model.respondInTerminal(agent) } label: {
                            Label("Respond", systemImage: "terminal")
                        }.buttonStyle(OrbButtonStyle(compact: true)).disabled(!model.canInteract(agent) || session.settingsBusy)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14).background(OrbTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 28).padding(.vertical, 12)
                    }
                } else if !agent.isShell {
                    ConversationComposer(model: model, agent: agent, session: session)
                }
            }
        }.task(id: find) {
                searchPage = nil; searchError = nil
                guard !find.isEmpty else { return }
                searchBusy = true
                do {
                    try await Task.sleep(for: .milliseconds(200))
                    let page = try await model.searchHistory(agent, query: find)
                    try Task.checkCancellation()
                    searchPage = page; pageRevision += 1
                } catch is CancellationError { return }
                catch { searchError = error.localizedDescription; pageRevision += 1 }
                searchBusy = false
            }
            .onDisappear { model.persist(agent) }
            .onAppear {
                if AppPreferences.isDemo, let screen = DesignPreviewScreen.requested, [.workDetails, .claudeWorkDetails].contains(screen) {
                    if let work = ConversationTimeline.items(session.messages, provider: agent.agent, working: false).first(where: { $0.kind == .work }) {
                        expandedActivity.insert(work.id)
                        expandedActivity.insert("preview-tool-1")
                    }
                }
            }
    }
    private func setupView(_ setup: TerminalSetupScreen) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(setup.continueMessage == nil ? "Set up Claude Code" : "Continue Claude Code setup").font(.title2.weight(.semibold))
                Text("Complete the setup on \(machine.label). These controls go directly to its terminal.")
                    .foregroundStyle(OrbTheme.secondary)
                if let link = setup.link {
                    HStack {
                        Link("Sign in to Claude", destination: link).buttonStyle(OrbButtonStyle(kind: .primary))
                        Button("Copy login link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link.absoluteString, forType: .string)
                        }.buttonStyle(OrbButtonStyle())
                    }
                    Text("Open the link, then paste the authorization code below if prompted.")
                        .foregroundStyle(OrbTheme.secondary)
                }
                if !setup.options.isEmpty {
                    Text("Choose an option, then press Enter or click Confirm.").foregroundStyle(OrbTheme.secondary)
                }
                if setup.continueMessage == nil, let details = setup.continueDetails {
                    Text(details).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(setup.options, id: \.self) { option in
                    Button((setup.selectedOption?.contains(option) == true ? "✓ " : "") + option) { Task { await model.setupInput(agent, option: option) } }
                        .buttonStyle(OrbButtonStyle())
                }
                if let message = setup.continueMessage {
                    if let details = setup.continueDetails {
                        Text(details).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(message).foregroundStyle(OrbTheme.text)
                    Button("Continue") { Task { await model.setupInput(agent, key: "enter") } }
                        .buttonStyle(OrbButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                } else {
                HStack {
                    Button("↑ Up") { Task { await model.setupInput(agent, key: "up") } }.keyboardShortcut(.upArrow, modifiers: [])
                    Button("↓ Down") { Task { await model.setupInput(agent, key: "down") } }.keyboardShortcut(.downArrow, modifiers: [])
                    if !setup.waitingForCode {
                        Button("Confirm") { Task { await model.setupInput(agent, key: "enter") } }.keyboardShortcut(.defaultAction)
                    }
                    Button("Cancel") { Task { await model.setupInput(agent, key: "escape") } }.keyboardShortcut(.cancelAction)
                }.buttonStyle(OrbButtonStyle())
                }
                if setup.waitingForCode {
                    SecureField("Paste authorization code", text: $loginCode)
                        .textFieldStyle(.roundedBorder)
                    Button("Submit code") {
                        let code = loginCode
                        loginCode = ""
                        Task { await model.setupInput(agent, code: code) }
                    }.buttonStyle(OrbButtonStyle(kind: .primary)).disabled(loginCode.isEmpty)
                }
                Button("Open full Terminal") { model.respondInTerminal(agent) }
                    .buttonStyle(OrbButtonStyle())
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                .disabled(session.busy || session.settingsBusy || !model.canInteract(agent) || session.cached)
        }.onDisappear { loginCode = "" }
    }
    private func entry(_ id: String, message: SessionMessage? = nil, messages: [SessionMessage]? = nil, state: String = "", @ViewBuilder content: @escaping () -> some View) -> ConversationRowEntry {
        ConversationRowEntry(id: id, message: message, messages: messages, state: state) {
            AnyView(content().frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .font(OrbTheme.bodyFont).foregroundStyle(OrbTheme.text)
                .tint(OrbTheme.accent).preferredColorScheme(.dark))
        }
    }
    private var conversationRows: [ConversationRowEntry] {
        var result: [ConversationRowEntry] = []
        if session.messages.isEmpty && session.reading { result.append(entry("loading") { OrbSkeleton() }) }
        if session.cached { result.append(entry("cached") { CachedConversationNotice() }) }
        if find.isEmpty && session.earlierMessages > 0 {
            result.append(entry("earlier", state: String(session.earlierMessages) + String(session.loadingHistory)) {
                Button("Earlier messages (\(session.earlierMessages))") {
                    expandedActivity.removeAll()
                    Task { await model.historyPage(agent, earlier: true); pageRevision += 1 }
                }.buttonStyle(OrbButtonStyle(compact: true)).disabled(session.loadingHistory)
            })
        }
        if find.isEmpty && !session.follow && session.totalMessages > session.messages.count {
            result.append(entry("latest") {
                Button("Back to latest") {
                    expandedActivity.removeAll()
                    Task { await model.historyPage(agent, earlier: false); pageRevision += 1 }
                }.buttonStyle(OrbButtonStyle(compact: true))
            })
        }
        if !find.isEmpty, let searchError {
            result.append(entry("searchError", state: searchError) { Text(searchError).font(.caption) })
        }
        let timeline = ConversationTimeline.items(visibleMessages, provider: agent.agent, working: agent.agent_status == "working")
        for (index, item) in timeline.enumerated() {
            let active = find.isEmpty && index == timeline.count - 1 && !session.browsingHistory
            if item.kind == .work {
                let state = String(active) + agent.agent_status + expandedActivity.sorted().joined(separator: "|") + find
                result.append(entry(item.id, messages: item.messages, state: state) {
                    ConversationWorkGroup(item: item, working: active && agent.agent_status == "working",
                                          blocked: active && agent.agent_status == "blocked",
                                          disclosures: expandedActivity, find: find, machine: machine, cwd: agent.cwd, toggle: toggleDisclosure)
                })
            } else if let message = item.messages.first {
                let status = active ? agent.agent_status + String(session.pending.isEmpty) : ""
                result.append(entry(item.id, message: message,
                    state: status + find + (agent.agent ?? "") + (agent.cwd ?? "")) { row(message) })
            }
        }
        if !find.isEmpty, let page = searchPage, page.hasEarlier && !page.messages.isEmpty {
            result.append(entry("moreMatches", state: String(pageRevision)) {
                Button("Earlier matches") {
                    let query = find, before = page.messages.first?.id
                    Task {
                        do {
                            let next = try await model.searchHistory(agent, query: query, before: before)
                            guard find == query else { return }
                            searchPage = next; pageRevision += 1
                        } catch { searchError = error.localizedDescription; pageRevision += 1 }
                    }
                }.buttonStyle(OrbButtonStyle(compact: true))
            })
        }
        if !session.pending.isEmpty {
            result.append(entry("delivery-receipts", state: session.pending.map { $0.id.uuidString + $0.state }.joined() + String(expandedActivity.contains("delivery-receipts"))) {
                ConversationDeliveryReceipts(pending: session.pending, expanded: expandedActivity.contains("delivery-receipts"),
                    toggle: { toggleDisclosure("delivery-receipts") }, dismiss: { model.dismissReceipt($0, agent: agent) })
            })
        }
        if find.isEmpty && agent.agent_status == "working" && timeline.last?.kind != .work && session.messages.last?.phase != "final_answer" {
            result.append(entry("thinking") { ConversationActivityLabel(title: "Working…", working: true) })
        }
        return result
    }
    private var matchingMessages: [SessionMessage] {
        session.messages.filter { $0.text.localizedCaseInsensitiveContains(find) }
    }
    private var visibleMessages: [SessionMessage] {
        if !find.isEmpty { return searchPage?.messages ?? Array(matchingMessages.prefix(40)) }
        let start = ConversationWindow.start(in: session.messages, anchor: session.scrollAnchor)
        return Array(session.messages.dropFirst(start))
    }
    private func modePicker(compact: Bool) -> some View {
        HStack(spacing: 3) {
            if !agent.isShell { modeButton("Conversation", icon: "bubble.left.and.bubble.right", terminal: false, compact: compact) }
            modeButton("Terminal", icon: "terminal", terminal: true, compact: compact)
        }
    }
    private func modeButton(_ title: String, icon: String, terminal: Bool, compact: Bool) -> some View {
        OrbSegment(title: title, symbol: icon, selected: session.terminal == terminal, compact: true) {
            guard session.terminal != terminal, !session.settingsBusy else { return }
            if terminal {
                session.terminalConnected = model.isDemo
                session.terminal = true
                model.resumeLive()
            } else { model.closeTerminal(agent) }
        }.help(terminal ? "Interact with the live terminal" : "Read the formatted conversation")
    }
    private func toggleDisclosure(_ id: String) {
        session.follow = false
        if expandedActivity.contains(id) { expandedActivity.remove(id) }
        else { expandedActivity.insert(id) }
    }
    private func row(_ message: SessionMessage) -> some View {
        ConversationMessageRow(message: message, kind: agent.agent, machine: machine, cwd: agent.cwd,
            working: agent.agent_status == "working" && message.id == session.messages.last?.id,
            blocked: agent.agent_status == "blocked" && message.id == session.messages.last?.id,
            disclosed: expandedActivity.contains(message.id), find: find) { toggleDisclosure(message.id) }.equatable()
    }
}

/// Unchanged rows do not parse Markdown, rediscover artifacts, or rebuild image
/// views when the composer, status, or streaming tail changes.
struct ConversationMessageRow: View, Equatable {
    let message: SessionMessage
    let kind: String?
    let machine: Machine
    let cwd: String?
    let working: Bool
    let blocked: Bool
    let disclosed: Bool
    let find: String
    var toggleDisclosure: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message && lhs.kind == rhs.kind && lhs.machine == rhs.machine && lhs.cwd == rhs.cwd
            && lhs.working == rhs.working && lhs.blocked == rhs.blocked && lhs.disclosed == rhs.disclosed && lhs.find == rhs.find
    }
    @State private var hovered = false
    @State private var copied = false
    @FocusState private var copyFocused: Bool
    var body: some View {
        let displayed = LongMessagePresentation.preview(message)
        return VStack(alignment: message.fromUser ? .trailing : .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 0) {
                if message.fromUser { Spacer(minLength: 64) }
                VStack(alignment: .leading, spacing: 12) {
                    if message.fromUser {
                        Text(displayed.text).font(.system(size: 14.5)).lineSpacing(4).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else { ConversationMarkdown(text: displayed.text).equatable() }
                    if displayed.text != message.text {
                        Button { FullMessageWindow.show(message.text) } label: {
                            Label("Read complete message", systemImage: "arrow.up.left.and.arrow.down.right")
                        }.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(OrbTheme.accent)
                    }
                    ForEach(Array(message.artifacts.prefix(20))) { artifact in
                        ArtifactCard(artifact: artifact, machine: machine, cwd: cwd)
                    }
                }
                .foregroundStyle(OrbTheme.text)
                .padding(.horizontal, message.fromUser ? 14 : 0).padding(.vertical, message.fromUser ? 11 : 0)
                .background(message.fromUser ? OrbTheme.raised.opacity(0.8) : .clear, in: RoundedRectangle(cornerRadius: 14))
                .frame(maxWidth: message.fromUser ? nil : .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string); copied = true
                } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(.plain).focused($copyFocused).help("Copy message").accessibilityLabel(copied ? "Message copied" : "Copy message")
                if let date = message.createdAt { Text(date.formatted(date: .omitted, time: .shortened)).monospacedDigit() }
                if copied { Text("Copied").foregroundStyle(OrbTheme.online) }
            }.font(.system(size: 10)).foregroundStyle(OrbTheme.muted).frame(height: 17)
                .padding(.horizontal, message.fromUser ? 5 : 0)
                .opacity(hovered || copyFocused || copied ? 1 : 0)
        }.onHover { hovered = $0 }
            .task(id: copied) {
                guard copied else { return }; try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }; copied = false
            }
    }
}

private struct ConversationActivityLabel: View {
    let title: String
    let working: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 9) {
            if working {
                if reduceMotion {
                    Circle().fill(OrbTheme.secondary).frame(width: 6, height: 6)
                } else {
                    TimelineView(.animation(minimumInterval: 0.05)) { context in
                        Circle().trim(from: 0, to: 0.7)
                            .stroke(OrbTheme.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.5) / 1.5 * 360))
                    }.frame(width: 12, height: 12)
                }
            }
            Text(title).font(.system(size: 13)).foregroundStyle(OrbTheme.secondary)
        }.accessibilityElement(children: .combine)
    }
}


private struct ContextUsageIndicator: View {
    let provider: String
    let usage: ContextUsage?
    var connect: () -> Void = {}
    @State private var showingDetails = false
    private var tint: Color { (usage?.usedPercent ?? 0) >= 80 ? OrbTheme.warning : OrbTheme.secondary }
    var body: some View {
        Button { showingDetails.toggle() } label: {
            HStack(spacing: 5) {
                ZStack {
                    Circle().stroke(OrbTheme.line, lineWidth: 2)
                    if let usage {
                        Circle().trim(from: 0, to: usage.usedPercent / 100)
                            .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                }.frame(width: 12, height: 12)
                Text(usage.map { "\(Int($0.usedPercent.rounded()))%" } ?? "—")
                    .monospacedDigit()
            }.foregroundStyle(tint).padding(5).contentShape(Rectangle())
        }
        .help("\(provider) context: " + (usage.map { "\(Int($0.usedPercent.rounded()))% used" } ?? "unavailable"))
        .accessibilityLabel("\(provider) context window")
        .accessibilityValue(usage.map { "\(Int($0.usedPercent.rounded())) percent used" } ?? "Unavailable")
        .popover(isPresented: $showingDetails) {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(provider) context window").font(.headline)
                if let usage {
                    Text("\(Int(usage.usedPercent.rounded()))% used · \(Int((100 - usage.usedPercent).rounded()))% remaining")
                    Text("Source: \(usage.source). This is context capacity, separate from account usage limits.")
                    if usage.source == "Codex session usage" {
                        Text("The percentage matches Codex’s calculation, which reserves space for instructions and tools.")
                    }
                    if let tokens = usage.tokens, let capacity = usage.capacity {
                        Text("\(tokens.formatted()) tokens · \(capacity.formatted()) token capacity")
                    }
                    if let observed = usage.observedAt { Text("Last reported \(observed.formatted(date: .omitted, time: .shortened))") }
                    Text("For a new topic, start a new chat. To continue this task, the CLI can compact earlier messages; usage may decrease after compaction.")
                } else {
                    Text("No current context reading is available for this session.")
                    Text(provider == "Codex"
                        ? "Connect the provider session to read its saved usage. Existing Codex terminals may need to resume once after the integration is installed."
                        : "Connect Claude context to read its official usage data. This adds a project-local wrapper that preserves your existing status line.")
                    Button("Connect history and context", action: connect)
                }
            }.font(.system(size: 12)).foregroundStyle(OrbTheme.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(16).frame(width: 300)
        }
    }
}

private struct ConversationDeliveryReceipts: View {
    let pending: [PendingMessage]
    let expanded: Bool
    let toggle: () -> Void
    let dismiss: (UUID) -> Void
    private var uncertain: Bool { pending.contains { $0.state == "Not confirmed" } }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 7) {
                    Image(systemName: uncertain ? "exclamationmark.circle" : "arrow.up.circle")
                    Text(uncertain ? "Check message delivery" : pending.last?.state == "Sending…" ? "Sending…" : "Delivery status")
                    Text("\(pending.count)").monospacedDigit().foregroundStyle(OrbTheme.muted)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8))
                }.font(.system(size: 11)).foregroundStyle(uncertain ? OrbTheme.warning : OrbTheme.muted)
            }.buttonStyle(.plain)
            if expanded || uncertain {
                ForEach(pending) { receipt in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(receipt.text).lineLimit(2).foregroundStyle(OrbTheme.secondary)
                            Text(receipt.state).foregroundStyle(OrbTheme.muted)
                        }.font(.system(size: 11)).textSelection(.enabled)
                        Spacer(minLength: 0)
                        if receipt.state != "Sending…" {
                            Button { dismiss(receipt.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                                .buttonStyle(.plain).help("Dismiss receipt").accessibilityLabel("Dismiss delivery receipt")
                        }
                    }.padding(10).background(OrbTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}
