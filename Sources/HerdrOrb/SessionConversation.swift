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
                if session.terminal && !session.terminalConnected {
                    ProgressView().controlSize(.small).help("Connecting terminal…")
                } else if !session.terminal && session.cached {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                        .help("Showing saved conversation while reconnecting")
                }
                if !session.terminal {
                    Button {
                        searching.toggle()
                        if searching { searchFocused = true } else { find = "" }
                    } label: {
                        Image(systemName: "magnifyingglass").frame(width: 28, height: 28)
                            .background(searching ? Color.white.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }.help("Find in conversation").accessibilityLabel("Find in conversation")
                }
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Image(systemName: "trash").frame(width: 28, height: 28)
                }.help("Delete session").accessibilityLabel("Delete session")
                    .disabled(!model.canInteract(agent))
            }.buttonStyle(.plain).font(.system(size: 15)).padding(.horizontal, 24).padding(.vertical, 14)
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
                if let notice = TerminalPresentation.activityNotice(session.output, status: agent.agent_status) {
                    Text(notice).font(.system(size: 11)).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 8)
                }
                ConversationScroll(follow: automaticallyScroll && session.follow, offset: session.scrollOffset,
                                   version: ConversationContentVersion(messages: session.messageRevision, pending: session.pending, filter: find, raw: nil, status: agent.agent_status, loading: session.reading, disclosures: expandedActivity), changed: { follow, offset in
                    if session.follow != follow { session.follow = follow }
                    session.scrollOffset = offset
                    model.persist(agent)
                }) {
                    VStack(alignment: .leading, spacing: 24) {
                        if session.output.isEmpty && session.reading { OrbSkeleton() }
                        if session.cached { CachedConversationNotice() }
                        ForEach(session.messages.filter { find.isEmpty || $0.text.localizedCaseInsensitiveContains(find) }) { message in
                            row(message)
                        }
                        ForEach(session.pending) { pending in
                            PendingMessageView(text: pending.text, state: pending.state)
                        }
                        if find.isEmpty && agent.agent_status == "working" && (session.messages.last?.fromUser != false || !session.pending.isEmpty || agent.agent != "codex") {
                            ConversationActivityLabel(title: "Thinking…", working: true)
                        }
                    }.padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 28).frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                if !agent.isShell && model.needsTerminalResponse(agent) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Terminal response needed", systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(OrbTheme.warning)
                        Text("This session is waiting for an approval or another terminal response. Open Terminal, choose an option, and press Return.")
                            .font(.system(size: 13)).foregroundStyle(OrbTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button { model.respondInTerminal(agent) } label: {
                            Label("Respond in Terminal", systemImage: "terminal")
                        }.buttonStyle(OrbButtonStyle(kind: .primary)).disabled(!model.canInteract(agent))
                        if !session.draft.isEmpty {
                            Text("Your chat draft is saved. It will not be sent to the terminal.")
                                .font(.system(size: 12)).foregroundStyle(OrbTheme.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24).padding(.vertical, 16)
                } else if !agent.isShell {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .bottom, spacing: 12) {
                            ZStack(alignment: .topLeading) {
                                if session.draft.isEmpty { Text("Message \(agent.kind)…").font(.system(size: 15)).foregroundStyle(OrbTheme.muted).padding(.leading, 5).padding(.top, 5).allowsHitTesting(false) }
                                MessageComposer(text: Binding(get: { session.draft }, set: { model.composerChanged(agent, text: $0) }), placeholder: "Message \(agent.kind)") { Task { await model.send(to: agent) } }
                                    .id(agent.id).frame(height: 30)
                            }
                            Button { Task { await model.send(to: agent) } } label: {
                                Image(systemName: session.busy ? "hourglass" : "arrow.up").font(.system(size: 19, weight: .medium)).foregroundStyle(OrbTheme.canvas).frame(width: 32, height: 32)
                                    .background(OrbTheme.accentLight, in: Circle())
                            }.buttonStyle(.plain).accessibilityLabel(session.busy ? "Sending message" : "Send message")
                                .disabled(session.busy || !model.canInteract(agent) || session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }.padding(12).background(OrbTheme.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 13))
                            .overlay(RoundedRectangle(cornerRadius: 13).stroke(OrbTheme.controlEdge, lineWidth: 0.85))
                        Text("Return to send · Shift-Return for a new line").font(.system(size: 11)).foregroundStyle(OrbTheme.muted)
                            .frame(maxWidth: .infinity)
                    }.padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 14)
                }
            }
        }.onDisappear { model.persist(agent) }
    }
    private func modePicker(compact: Bool) -> some View {
        HStack(spacing: 3) {
            if !agent.isShell { modeButton("Conversation", icon: "bubble.left.and.bubble.right", terminal: false, compact: compact) }
            modeButton("Terminal", icon: "terminal", terminal: true, compact: compact)
        }
    }
    private func modeButton(_ title: String, icon: String, terminal: Bool, compact: Bool) -> some View {
        OrbSegment(title: title, symbol: icon, selected: session.terminal == terminal, compact: compact) {
            guard session.terminal != terminal else { return }
            if terminal {
                session.terminalConnected = model.isDemo
                session.terminal = true
                model.resumeLive()
            } else { model.closeTerminal(agent) }
        }.help(terminal ? "Interact with the live terminal" : "Read the formatted conversation")
    }
    private func row(_ message: SessionMessage) -> some View {
        let working = agent.agent_status == "working" && session.pending.isEmpty && message.id == session.messages.last?.id
        let blocked = agent.agent_status == "blocked" && message.id == session.messages.last?.id
        let response = TerminalPresentation.response(message, kind: agent.agent, working: working || blocked)
        let searchActivity = !find.isEmpty && response.activity.localizedCaseInsensitiveContains(find)
        let expanded = expandedActivity.contains(message.id) || searchActivity
        let codex = !message.fromUser && agent.agent == "codex"
        return HStack(alignment: .top, spacing: 0) {
            if message.fromUser { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 16) {
                if codex && (!response.activity.isEmpty || working || response.duration != nil) {
                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            session.follow = false
                            if expanded { expandedActivity.remove(message.id) }
                            else { expandedActivity.insert(message.id) }
                        } label: {
                            HStack(spacing: 7) {
                                ConversationActivityLabel(title: working ? "Thinking…" : blocked ? "Waiting for your response" : response.duration ?? "Activity", working: working)
                                if !response.activity.isEmpty {
                                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 10, weight: .medium)).foregroundStyle(OrbTheme.muted)
                                }
                            }.frame(minHeight: 26).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(response.activity.isEmpty || searchActivity)
                            .accessibilityLabel(working ? "Thinking" : blocked ? "Waiting for your response" : response.duration ?? "Activity")
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
                        ConversationMarkdown(text: response.answer)
                            .font(.system(size: 15)).foregroundStyle(OrbTheme.text).lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    ForEach(Array(message.parts.enumerated()), id: \.offset) { partIndex, part in
                        Group {
                            if message.fromUser || part.status { Text(part.text) }
                            else { ConversationMarkdown(text: partIndex == 0 && (part.text.hasPrefix("• ") || part.text.hasPrefix("● ")) ? String(part.text.dropFirst(2)) : part.text) }
                        }
                        .font(.system(size: part.status ? 12 : 15)).foregroundStyle(part.status ? OrbTheme.secondary : OrbTheme.text)
                        .lineSpacing(part.status ? 1 : 4).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(codex ? response.artifacts : message.artifacts) { artifact in
                    ArtifactCard(artifact: artifact, machine: machine, cwd: agent.cwd)
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
