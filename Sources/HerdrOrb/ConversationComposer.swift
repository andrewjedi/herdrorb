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

    private var settings: CodexSessionSettings { agent.agent == "claude" ? session.claudeSettings : session.codexSettings }
    private var settingsAttempted: Bool { agent.agent == "claude" ? session.claudeSettingsLoadAttempted : session.settingsLoadAttempted }
    private var canSend: Bool {
        !session.busy && !session.settingsBusy && !dictation.isPreparing && !dictation.isRecording && !dictation.isFinishing
            && model.canInteract(agent) && !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            GeometryReader { geometry in
                HStack(spacing: 7) {
                    if ["codex", "claude"].contains(agent.agent) {
                        controls(access: true, compact: geometry.size.width < 600).fixedSize()
                        Rectangle().fill(OrbTheme.controlEdge.opacity(0.6)).frame(width: 1, height: 24)
                    }
                    ZStack(alignment: .topLeading) {
                        if session.draft.isEmpty {
                            Text(dictation.isRecording ? "Listening…" : "Do anything")
                                .font(.system(size: 14)).foregroundStyle(OrbTheme.muted)
                                .padding(.leading, 5).padding(.top, 5).allowsHitTesting(false)
                        }
                        MessageComposer(text: Binding(get: { session.draft }, set: { text in
                            if dictation.isRecording || dictation.isPreparing || dictation.isFinishing { endDictation() }
                            model.composerChanged(agent, text: text)
                        }), placeholder: "Message \(agent.kind)") { send() }
                            .id(agent.id)
                    }.frame(minWidth: 80, maxWidth: .infinity).frame(height: editorHeight)
                    if ["codex", "claude"].contains(agent.agent) {
                        controls(access: false, compact: geometry.size.width < 600).fixedSize()
                    }
                    Button {
                        if dictation.isPreparing { endDictation() }
                        else if dictation.isRecording { dictation.stop() }
                        else {
                            acceptingDictationUpdates = true
                            dictationPrefix = session.draft
                            dictationDraft = session.draft
                            dictationTask = Task { await dictation.start() }
                        }
                    } label: {
                        ZStack {
                            if dictation.isPreparing || dictation.isFinishing { ProgressView().controlSize(.small) }
                            else { Image(systemName: dictation.isRecording ? "stop.fill" : "mic").font(.system(size: 14, weight: .medium)) }
                        }.frame(width: 26, height: 28)
                            .foregroundStyle(dictation.isRecording ? Color(hex: 0xFF986C) : OrbTheme.text)
                            .background(dictation.isRecording ? Color(hex: 0xFF986C).opacity(0.13) : .clear, in: Circle())
                    }.buttonStyle(.plain).disabled(dictation.isFinishing)
                        .help(dictation.isRecording ? "Finish dictation" : "Dictate a message")
                        .accessibilityLabel(dictation.isPreparing ? "Cancel microphone request" : dictation.isRecording ? "Finish dictation" : "Dictate a message")
                    Button(action: send) {
                        Image(systemName: session.busy ? "hourglass" : "arrow.up")
                            .font(.system(size: 14, weight: .medium)).foregroundStyle(OrbTheme.text)
                            .frame(width: 24, height: 24)
                            .background(OrbTheme.selectionEdge.opacity(canSend ? 1 : 0.55), in: Circle())
                    }.buttonStyle(.plain).disabled(!canSend)
                        .accessibilityLabel(session.busy ? "Sending message" : "Send message")
                }.padding(.horizontal, 10).padding(.vertical, 9)
            }.frame(height: editorHeight + 18)
                .background(OrbTheme.raised.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(OrbTheme.controlEdge.opacity(0.65), lineWidth: 0.75))
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
        }.frame(maxWidth: .infinity).padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 16)
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
    private var editorHeight: CGFloat {
        CGFloat(min(4, max(1, session.draft.components(separatedBy: .newlines).count))) * 20 + 8
    }
    private func controls(access: Bool, compact: Bool) -> some View {
        ComposerControls(provider: agent.agent ?? "", showsAccess: access, showsModel: !access, compactOnly: compact,
            access: settings.access, model: settings.model, effort: settings.effort, speed: settings.speed,
            models: settings.models, efforts: settings.efforts, accessOptions: settings.accessOptions,
            speeds: settings.speeds, defaultEffort: settings.defaultEffort,
            enabled: (session.settingsBusy || model.canChangeAgentSettings(agent)) && !dictation.isRecording,
            applying: session.settingsBusy, onAccess: { change("access", $0) }, onModel: { change("model", $0) },
            onEffort: { change("effort", $0) }, onSpeed: { change("speed", $0) },
            onRefresh: { Task { await model.refreshAgentSettings(agent) } })
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
        Task { await model.send(to: agent) }
    }
}
