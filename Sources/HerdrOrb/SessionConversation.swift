import SwiftUI
import AppKit

struct SessionConversation: View {
    let model: BubbleModel
    let agent: Agent
    let machine: Machine
    @ObservedObject var session: SessionState
    @AppStorage("automaticallyScrollToNewMessages") private var automaticallyScroll = true
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
                if !agent.isShell && !session.terminal {
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
                }, rows: conversationRows)
                if !agent.isShell && model.needsTerminalResponse(agent) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Terminal response needed", systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(OrbTheme.warning)
                        Text("This session is waiting for an approval or another terminal response. Open Terminal, choose an option, and press Return.")
                            .font(.system(size: 13)).foregroundStyle(OrbTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button { model.respondInTerminal(agent) } label: {
                            Label("Respond in Terminal", systemImage: "terminal")
                        }.buttonStyle(OrbButtonStyle(kind: .primary)).disabled(!model.canInteract(agent) || session.settingsBusy)
                        if !session.draft.isEmpty {
                            Text("Your chat draft is saved. It will not be sent to the terminal.")
                                .font(.system(size: 12)).foregroundStyle(OrbTheme.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24).padding(.vertical, 16)
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
    }
    private func entry(_ id: String, message: SessionMessage? = nil, state: String = "", @ViewBuilder content: @escaping () -> some View) -> ConversationRowEntry {
        ConversationRowEntry(id: id, message: message, state: state) {
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
        for message in visibleMessages {
            let status = message.id == session.messages.last?.id ? agent.agent_status + String(session.pending.isEmpty) : ""
            result.append(entry("message:" + message.id, message: message,
                state: status + String(expandedActivity.contains(message.id)) + find + (agent.agent ?? "") + (agent.cwd ?? "")) { row(message) })
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
        for pending in session.pending {
            result.append(entry("pending:" + pending.id.uuidString, state: pending.text + String(describing: pending.state)) {
                VStack(alignment: .leading, spacing: 5) {
                    PendingMessageView(text: String(pending.text.prefix(LongMessagePresentation.limit)), state: pending.state)
                    if pending.text.count > LongMessagePresentation.limit {
                        Button("Open complete message") { FullMessageWindow.show(pending.text) }.buttonStyle(.plain).font(.caption)
                    }
                    if pending.state != "Sending…" {
                        Button("Dismiss receipt") { model.dismissReceipt(pending.id, agent: agent) }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(OrbTheme.secondary)
                    }
                }
            })
        }
        if find.isEmpty && agent.agent_status == "working" && (session.messages.last?.fromUser != false || !session.pending.isEmpty || agent.agent != "codex") {
            result.append(entry("thinking") { ConversationActivityLabel(title: "Thinking…", working: true) })
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
    private func row(_ message: SessionMessage) -> some View {
        ConversationMessageRow(message: message, kind: agent.agent, machine: machine, cwd: agent.cwd,
            working: agent.agent_status == "working" && session.pending.isEmpty && message.id == session.messages.last?.id,
            blocked: agent.agent_status == "blocked" && message.id == session.messages.last?.id,
            disclosed: expandedActivity.contains(message.id), find: find) {
                session.follow = false
                if expandedActivity.contains(message.id) { expandedActivity.remove(message.id) }
                else { expandedActivity.insert(message.id) }
            }.equatable()
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
    var body: some View {
        let displayed = LongMessagePresentation.preview(message)
        let response = TerminalPresentation.response(displayed, kind: kind, working: working || blocked)
        let searchActivity = !find.isEmpty && response.activity.localizedCaseInsensitiveContains(find)
        let expanded = disclosed || searchActivity
        let codex = !message.fromUser && kind == "codex" && message.source == nil
        return HStack(alignment: .top, spacing: 0) {
            if message.fromUser { Spacer(minLength: 80) }
            VStack(alignment: .leading, spacing: 12) {
                if codex && (!response.activity.isEmpty || working || response.duration != nil) {
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            toggleDisclosure()
                        } label: {
                            HStack(spacing: 7) {
                                ConversationActivityLabel(title: working ? "Thinking…" : blocked ? "Waiting for your response" : response.duration ?? "Work details", working: working)
                                if !response.activity.isEmpty {
                                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 10, weight: .medium)).foregroundStyle(OrbTheme.muted)
                                }
                            }.frame(minHeight: 26).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(response.activity.isEmpty || searchActivity)
                            .accessibilityLabel(working ? "Thinking" : blocked ? "Waiting for your response" : response.duration ?? "Work details")
                            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                            .accessibilityHint(searchActivity ? "Activity is expanded to show search matches" : "Show or hide intermediate updates and commands")
                        if expanded && !response.activity.isEmpty {
                            Text(response.activity)
                                .font(.system(size: 12)).foregroundStyle(OrbTheme.secondary)
                                .lineSpacing(4).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 15).padding(.vertical, 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .overlay(alignment: .leading) { Rectangle().fill(OrbTheme.line).frame(width: 1) }
                        }
                    }
                }
                if codex {
                    if !response.answer.isEmpty {
                        ConversationMarkdown(text: response.answer).equatable()
                            .font(.system(size: 15)).foregroundStyle(OrbTheme.text).lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    ForEach(Array(displayed.parts.enumerated()), id: \.offset) { partIndex, part in
                        Group {
                            if message.fromUser || part.status { Text(part.text) }
                            else { ConversationMarkdown(text: message.source == nil && partIndex == 0 && (part.text.hasPrefix("• ") || part.text.hasPrefix("● ")) ? String(part.text.dropFirst(2)) : part.text).equatable() }
                        }
                        .font(.system(size: part.status ? 12 : 15)).foregroundStyle(part.status ? OrbTheme.secondary : OrbTheme.text)
                        .lineSpacing(part.status ? 1 : 4).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if displayed.text != message.text {
                    Button("Open complete message (\(message.text.count.formatted()) characters)") {
                        FullMessageWindow.show(message.text)
                    }.buttonStyle(OrbButtonStyle(compact: true))
                }
                ForEach(Array((codex ? response.artifacts : message.artifacts).prefix(20))) { artifact in
                    ArtifactCard(artifact: artifact, machine: machine, cwd: cwd)
                }
            }
                .padding(.horizontal, message.fromUser ? 16 : 0).padding(.vertical, message.fromUser ? 12 : 0)
                .background(message.fromUser ? OrbTheme.raised : .clear, in: RoundedRectangle(cornerRadius: 17))
                .frame(maxWidth: message.fromUser ? nil : .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: message.fromUser ? .trailing : .leading)
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
