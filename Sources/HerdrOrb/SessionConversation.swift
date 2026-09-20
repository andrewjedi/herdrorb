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
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 3) {
                    if !agent.isShell { modeButton("Conversation", icon: "bubble.left.and.bubble.right", terminal: false) }
                    modeButton("Terminal", icon: "terminal", terminal: true)
                }
                .padding(3)
                .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.09), lineWidth: 1))
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
            }.buttonStyle(.plain).font(.system(size: 12)).padding(.horizontal, 20).padding(.vertical, 8)
                .alert("Delete this session?", isPresented: $confirmingDelete) {
                    Button("Cancel", role: .cancel) { }
                    Button("Delete session", role: .destructive) { Task { await model.deleteSession(agent) } }
                } message: {
                    Text("This closes the terminal for \(model.sessionLabel(agent)) and ends any running command.")
                }
            if session.terminal && model.isDemo {
                Text("Demo mode does not attach to real terminals.").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.terminal {
                EmbeddedTerminal(agent: agent, machine: machine, initialInput: session.terminalSeed ?? "",
                                 onReady: { model.terminalAttached(agent) }, onExit: { model.terminalExited(agent) }).id(agent.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if session.commandMode {
                    Text("↑ ↓ Navigate  ·  Return Select  ·  Esc Dismiss")
                        .font(.system(size: 10)).foregroundStyle(.secondary).padding(.vertical, 6)
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
                                   version: ConversationContentVersion(messages: session.messageRevision, pending: session.pending, filter: find, raw: nil, status: agent.agent_status, loading: session.reading), changed: { follow, offset in
                    if session.follow != follow { session.follow = follow }
                    session.scrollOffset = offset
                    model.persist(agent)
                }) {
                    VStack(alignment: .leading, spacing: 16) {
                        if session.output.isEmpty && session.reading { ProgressView("Loading conversation…").controlSize(.small) }
                        ForEach(session.messages.filter { find.isEmpty || $0.text.localizedCaseInsensitiveContains(find) }) { message in
                            row(message)
                        }
                        ForEach(session.pending) { pending in
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(pending.text).textSelection(.enabled)
                                Text(pending.state).font(.system(size: 10)).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        Text(agent.isShell ? "Shell session · open Terminal to interact" : agent.agent_status == "blocked" ? "Needs your attention · open Terminal to respond" : agent.agent_status == "working" ? "\(agent.kind) is working…" : "Ready")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                if !agent.isShell {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Message \(agent.kind) on \(machine.label)")
                            Spacer()
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                        HStack(alignment: .bottom, spacing: 12) {
                            ZStack(alignment: .topLeading) {
                                if session.draft.isEmpty { Text("Message \(agent.kind)…").font(.system(size: 13)).foregroundStyle(.tertiary).padding(.leading, 5).padding(.top, 5).allowsHitTesting(false) }
                                MessageComposer(text: Binding(get: { session.draft }, set: { model.composerChanged(agent, text: $0) }), placeholder: "Message \(agent.kind)") { Task { await model.send(to: agent) } }
                                    .id(agent.id).frame(height: 52)
                            }
                            Button { Task { await model.send(to: agent) } } label: {
                                Image(systemName: session.busy ? "hourglass" : "arrow.up").frame(width: 32, height: 32)
                                    .background(Color.purple.opacity(0.6), in: Circle())
                            }.buttonStyle(.plain).disabled(session.busy || !model.canInteract(agent) || session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }.padding(10).background(.black.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.26)))
                        Text("Return to send · Shift-Return for a new line").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }.padding(.horizontal, 24).padding(.top, 12)
                }
            }
        }.onDisappear { model.persist(agent) }
    }
    private func modeButton(_ title: String, icon: String, terminal: Bool) -> some View {
        let selected = session.terminal == terminal
        return Button {
            guard !selected else { return }
            if terminal {
                session.terminalConnected = false
                session.terminal = true
                model.resumeLive()
            } else { model.closeTerminal(agent) }
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .padding(.horizontal, 12).frame(height: 28)
                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.72))
                .background(selected ? Color(red: 0.64, green: 0.58, blue: 1).opacity(0.28) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(selected ? 0.16 : 0), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(terminal ? "Interact with the live terminal" : "Read the formatted conversation")
    }
    private func row(_ message: SessionMessage) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if message.fromUser { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(message.parts.enumerated()), id: \.offset) { _, part in
                    Group {
                        if message.fromUser || part.status { Text(part.text) }
                        else { ConversationMarkdown(text: part.text) }
                    }
                        .font(.system(size: part.status ? 10 : 13))
                        .foregroundStyle(part.status ? Color.white.opacity(0.45) : Color.white.opacity(0.92))
                        .lineSpacing(part.status ? 1 : 4).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(message.artifacts) { artifact in
                    ArtifactCard(artifact: artifact, machine: machine, cwd: agent.cwd)
                }
            }
                .padding(.horizontal, message.fromUser ? 12 : 0).padding(.vertical, message.fromUser ? 9 : 3)
                .background(message.fromUser ? Color.purple.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 14))
                .frame(maxWidth: message.fromUser ? nil : .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: message.fromUser ? .trailing : .leading)
    }
}
