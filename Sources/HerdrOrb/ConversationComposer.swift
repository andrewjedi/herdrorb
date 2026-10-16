import SwiftUI

/// A draft stays local until Send. Dictation only edits that draft.
struct ConversationComposer: View {
    let model: BubbleModel
    let agent: Agent
    @ObservedObject var session: SessionState
    @StateObject private var dictation = VoiceDictation()
    @State private var acceptingDictationUpdates = false
    @State private var dictationPrefix = ""
    @State private var dictationDraft = ""
    @State private var dictationTask: Task<Void, Never>?
    @State private var editorHeight: CGFloat = 38
    @State private var editorFocused = false
    @State private var settingsRequest = 0
    @State private var accessRequest = 0

    private var settings: CodexSessionSettings { agent.agent == "claude" ? session.claudeSettings : session.codexSettings }
    private var settingsAttempted: Bool { agent.agent == "claude" ? session.claudeSettingsLoadAttempted : session.settingsLoadAttempted }
    private var canSend: Bool {
        !session.busy && !session.settingsBusy && !dictation.isPreparing && !dictation.isRecording && !dictation.isFinishing
            && model.canInteract(agent) && !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if BubbleModel.isSlashCommand(session.draft) { commandMenu }
            VStack(alignment: .leading, spacing: 5) {
                ZStack(alignment: .topLeading) {
                    if session.draft.isEmpty {
                        Text(dictation.isRecording ? "Listening…" : "Ask \(agent.kind) to do anything…")
                            .font(.system(size: 14.5)).foregroundStyle(OrbTheme.muted)
                            .padding(.leading, 5).padding(.top, 5).allowsHitTesting(false)
                    }
                    MessageComposer(text: Binding(get: { session.draft }, set: { text in
                        if dictation.isRecording || dictation.isPreparing || dictation.isFinishing { endDictation() }
                        model.composerChanged(agent, text: text)
                    }), placeholder: "Message \(agent.kind)", onHeightChange: { height in
                        if abs(editorHeight - height) > 0.5 { editorHeight = height }
                    }, onFocusChange: { editorFocused = $0 }) { send() }
                        .id(agent.id)
                }.frame(height: editorHeight).padding(.horizontal, 11).padding(.top, 8)
                GeometryReader { geometry in
                    footer(compact: geometry.size.width < 540)
                }.frame(height: 30).padding(.horizontal, 9).padding(.bottom, 7)
            }
            .background(OrbTheme.surface, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(editorFocused ? OrbTheme.accent.opacity(0.6) : OrbTheme.controlEdge.opacity(0.65), lineWidth: 0.75))
            if let error = dictation.error {
                Text(error).font(.system(size: 12)).foregroundStyle(OrbTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if dictation.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: 0xFF986C)).frame(width: 6, height: 6)
                    Text("Listening · click Stop when you’re finished")
                    Spacer()
                    Button("Cancel") { session.draft = dictationPrefix; model.persist(agent); endDictation() }.buttonStyle(.plain)
                }.font(.system(size: 12)).foregroundStyle(OrbTheme.secondary)
            }
        }.frame(maxWidth: 780).padding(.horizontal, 28).frame(maxWidth: .infinity)
            .padding(.top, 8).padding(.bottom, 16)
            .onChange(of: agent.id) { _, _ in editorHeight = 38; editorFocused = false }
            .task(id: agent.id + (agent.agent ?? "")) { if ["codex", "claude"].contains(agent.agent), !settingsAttempted { await model.refreshAgentSettings(agent) } }
            .onChange(of: dictation.transcript) { _, text in
                guard acceptingDictationUpdates, !text.isEmpty else { return }
                // If the user edited while recognition was settling, preserve their edit.
                guard session.draft == dictationDraft else { endDictation(); return }
                let separator = dictationPrefix.isEmpty || dictationPrefix.last?.isWhitespace == true ? "" : " "
                dictationDraft = dictationPrefix + separator + text
                session.draft = dictationDraft
                model.persist(agent)
            }
            .onChange(of: agent.agent_status) { _, status in
                if !["working", "blocked"].contains(status), !settingsAttempted {
                    Task { await model.refreshAgentSettings(agent) }
                }
            }
            .onReceive(model.$panelVisible) { if !$0 { endDictation() } }
            .onDisappear { endDictation() }
    }
    private var working: Bool { agent.agent_status == "working" }
    private func footer(compact: Bool) -> some View {
        HStack(spacing: 4) {
            if ["codex", "claude"].contains(agent.agent) {
                controls(access: false, compact: compact).fixedSize()
                controls(access: true, compact: compact).fixedSize()
            }
            Spacer(minLength: 6)
            Button {
                if dictation.isPreparing { endDictation() }
                else if dictation.isRecording { dictation.stop() }
                else {
                    acceptingDictationUpdates = true; dictationPrefix = session.draft; dictationDraft = session.draft
                    dictationTask = Task { await dictation.start() }
                }
            } label: {
                ZStack {
                    if dictation.isPreparing || dictation.isFinishing { ProgressView().controlSize(.mini) }
                    else { Image(systemName: dictation.isRecording ? "stop.fill" : "mic").font(.system(size: 13)) }
                }.frame(width: 26, height: 28)
                    .foregroundStyle(dictation.isRecording ? OrbTheme.danger : OrbTheme.secondary)
            }.buttonStyle(.plain).disabled(dictation.isFinishing)
                .help(dictation.isRecording ? "Finish dictation" : "Dictate a message")
                .accessibilityLabel(dictation.isRecording ? "Finish dictation" : "Dictate a message")
            Button {
                if working { Task { await model.interrupt(to: agent) } }
                else { send() }
            } label: {
                Image(systemName: working ? "stop.fill" : session.busy ? "ellipsis" : "arrow.up")
                    .font(.system(size: working ? 10 : 13, weight: .semibold))
                    .foregroundStyle(working || canSend ? OrbTheme.canvas : OrbTheme.muted)
                    .frame(width: 28, height: 28)
                    .background(working || canSend ? OrbTheme.accent : OrbTheme.raised, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).disabled(working ? !model.canInteract(agent) || session.settingsBusy : !canSend)
                .help(working ? "Stop \(agent.kind)" : "Send message · Return")
                .accessibilityLabel(working ? "Stop response" : "Send message")
        }
    }
    private var commandMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach([("/model", "Model & effort", "slider.horizontal.3"),
                     ("/permissions", "Permissions", "shield"),
                     ("/compact", "Compact in Terminal", "arrow.down.right.and.arrow.up.left"),
                     ("/", "All commands in Terminal", "terminal")].filter {
                $0.0 == "/" || $0.0.hasPrefix(session.draft.lowercased())
            }, id: \.0) { command in
                Button { executeCommand(command.0) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: command.2).frame(width: 18)
                        Text(command.1)
                        Spacer()
                        Text(command.0).font(.system(size: 11, design: .monospaced)).foregroundStyle(OrbTheme.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(OrbButtonStyle(kind: .quiet, compact: true))
            }
        }.disabled(!model.canInteract(agent) || session.settingsBusy || working)
            .padding(7).background(OrbTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(OrbTheme.line, lineWidth: 0.75))
    }
    private func executeCommand(_ command: String) {
        switch command {
        case "/model", "/permissions":
            session.draft = ""; model.persist(agent)
            if command == "/model" { settingsRequest += 1 } else { accessRequest += 1 }
        default:
            model.openSlashCommands(agent, text: command == "/" ? session.draft : command, fromDraft: true, submit: command != "/")
        }
    }
    private func controls(access: Bool, compact: Bool) -> some View {
        ComposerControls(provider: agent.agent ?? "", showsAccess: access, showsModel: !access, compactOnly: compact,
            access: settings.access, model: settings.model, effort: settings.effort, speed: settings.speed,
            models: settings.models, efforts: settings.efforts, accessOptions: settings.accessOptions,
            speeds: settings.speeds, defaultEffort: settings.defaultEffort,
            enabled: (session.settingsBusy || model.canChangeAgentSettings(agent)) && !dictation.isRecording,
            applying: session.settingsBusy, onAccess: { change("access", $0) }, onModel: { change("model", $0) },
            onEffort: { change("effort", $0) }, onSpeed: { change("speed", $0) },
            onRefresh: { Task { await model.refreshAgentSettings(agent) } },
            onRestartClaude: agent.agent == "claude" ? { bypass in Task { await model.restartClaude(agent, bypass: bypass) } } : nil,
            settingsRequest: settingsRequest, accessRequest: accessRequest)
    }
    private func change(_ key: String, _ value: String) {
        Task { await model.updateAgentSetting(agent, key: key, value: value) }
    }
    private func endDictation() {
        acceptingDictationUpdates = false
        dictationTask?.cancel(); dictationTask = nil
        dictation.cancel()
    }
    private func send() {
        guard canSend else { return }
        endDictation()
        if ["/model", "/permissions"].contains(session.draft.lowercased()) { executeCommand(session.draft.lowercased()); return }
        Task { await model.send(to: agent) }
    }
}
