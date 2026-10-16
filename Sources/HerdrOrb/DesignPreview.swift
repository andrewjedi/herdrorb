import AppKit
import SwiftUI
import SwiftTerm

/// Isolated, deterministic UI fixtures. These never attach to a terminal, discover
/// machine profiles, or read project folders. They use the same production views.
enum DesignPreviewScreen: String, CaseIterable {
    case claudeApproval = "31-claude-approval"
    case codeConversation = "25-conversation-code"
    case tableConversation = "26-conversation-table"
    case workDetails = "27-conversation-work"
    case claudeWorkDetails = "28-claude-work"
    case draftConversation = "29-conversation-draft"
    case commandConversation = "30-conversation-commands"
    case imageConversation = "18-image-conversation"
    case structuredCodex = "19-structured-codex"
    case structuredClaude = "20-structured-claude"
    case claudeLogin = "21-claude-login"
    case claudeLoginChoices = "22-claude-login-choices"
    case conversation = "01-conversation"
    case terminal = "02-terminal"
    case newSession = "03-new-session"
    case setup = "04-setup"
    case settings = "05-settings-orb"
    case privacy = "06-settings-privacy"
    case connection = "07-device-connection"
    case projects = "08-project-defaults"
    case folders = "09-folder-browser"
    case empty = "10-empty-state"
    case deviceOffline = "23-device-overview"
    case deviceTerminal = "24-device-terminal"
    case recovery = "11-launch-recovery"
    case dialogs = "12-dialogs-and-states"
    case orb = "13-orb-and-preview"
    case thinking = "14-conversation-thinking"
    case approval = "15-conversation-approval"
    case composer = "16-composer-controls"
    case claudeComposer = "17-claude-composer"
    static var requested: Self? {
        guard AppPreferences.isDemo, let index = CommandLine.arguments.firstIndex(of: "--screen"), CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return Self(rawValue: CommandLine.arguments[index + 1])
    }
}

struct DemoTerminal: NSViewRepresentable {
    func makeNSView(context: Context) -> TerminalView {
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 430))
        terminal.appearance = NSAppearance(named: .darkAqua)
        terminal.nativeBackgroundColor = NSColor(srgbRed: 12/255, green: 13/255, blue: 16/255, alpha: 1)
        terminal.nativeForegroundColor = OrbTheme.nsText
        terminal.caretColor = OrbTheme.nsText
        terminal.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        terminal.feed(text: "\u{1b}[38;2;181;168;228m$\u{1b}[0m codex\r\nProject: ~/Projects/herdrorb\r\n\r\n> Help me prepare this project for release.\r\n\r\nReading README.md\r\nChecking release checklist\r\n\r\n\u{1b}[38;2;99;206;119mReady to share\u{1b}[0m\r\n  Installation instructions\r\n  Connection recovery\r\n  Private local settings\r\n\r\n> ")
        terminal.setAccessibilityLabel("Fictional demo terminal. No terminal is attached.")
        return terminal
    }
    func updateNSView(_ view: TerminalView, context: Context) { }
}

@MainActor enum DesignPreview {
    static let artifactText = "# Release notes\n\n## Ready to share\n\n- Installation instructions\n- Connection recovery\n- Private local settings\n\nReview the documentation before publishing.\n"
    static func artifactFixtureURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("herdrorb-visual-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("release-notes.md")
        try artifactText.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
    static func showArtifactFixtureIfRequested() {
        if AppPreferences.isDemo, CommandLine.arguments.contains("--preview-image-window") {
            ArtifactPreview.shared.show(imageFixtureURL, source: "This Mac")
            return
        }
        guard AppPreferences.isDemo, CommandLine.arguments.contains("--preview-artifact") else { return }
        do { ArtifactPreview.shared.show(try artifactFixtureURL(), source: "This Mac") }
        catch { fputs("Artifact fixture failed: \(error)\n", stderr) }
    }
    static var outputDirectory: String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--render-previews"), CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }
    static var panelSize: NSSize {
        guard let index = CommandLine.arguments.firstIndex(of: "--preview-size"), CommandLine.arguments.indices.contains(index + 1) else {
            return NSSize(width: OrbTheme.panelWidth, height: OrbTheme.panelHeight)
        }
        let parts = CommandLine.arguments[index + 1].split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return NSSize(width: OrbTheme.panelWidth, height: OrbTheme.panelHeight) }
        return NSSize(width: max(700, parts[0]), height: max(460, parts[1]))
    }
    static func prepare(_ screen: DesignPreviewScreen, model: BubbleModel) async {
        // Populate synchronously without inventory workers. A screenshot must not
        // race discovery, selection restoration, or live terminal reads.
        model.panelVisible = false
        model.suspendLive()
        model.showingSetup = false
        model.machines = [.local, Machine(id: "demo-studio", label: "Studio Mac")]
        model.agents = model.machines.map { machine in
            Agent(terminal_id: "demo-terminal", agent: machine.id == "local" ? "codex" : "claude",
                  agent_status: screen == .thinking ? "working" : (screen == .approval || screen == .claudeApproval) ? "blocked" : "idle", pane_id: "demo-pane", cwd: "~/Projects/herdrorb", machineID: machine.id,
                  tabLabel: machine.id == "local" ? "Release checklist" : "Documentation", profileIdentity: machine.identity)
        }
        for machine in model.machines {
            model.connection[machine.id] = .online
            model.herdrVersions[machine.id] = "0.9.1"
            model.availability[machine.id] = AgentAvailability(codex: true, claude: true)
        }
        for agent in model.agents {
            let state = model.state(agent)
            let output = screen == .thinking || screen == .approval ? DemoFixtures.activity : DemoFixtures.output
            state.output = output
            state.history = output
            state.messages = TerminalPresentation.messages(output, kind: "codex")
            state.messageRevision = 1
            state.cached = false
            state.contextUsage = ContextUsage.footer(in: agent.agent == "codex" ? "›\n72% context left" : "❯\nContext: 63% used", provider: agent.agent)
            state.restored = true
            state.terminalConnected = true
            state.codexSettings = .preview
            state.claudeSettings = SessionComposerSettings(access: "manual", model: "claude-sonnet-5", effort: "medium", speed: "standard",
                models: ["claude-sonnet-5", "claude-opus-5-5"], availableEfforts: ["low", "medium", "high"], accessOptions: ["manual", "acceptEdits", "plan"], speeds: ["standard"])
            state.settingsLoadAttempted = true; state.claudeSettingsLoadAttempted = true
        }
        model.selected = model.agents.first
        model.selectedMachineID = "local"
        for key in ["showOrb", "orbStatusDot", "automaticallyScrollToNewMessages", "automaticImagePreviews"] {
            model.preferences.set(true, forKey: key)
        }
        model.preferences.set(false, forKey: "orbHoverSound")
        model.preferences.set(OrbStyle.nebula.rawValue, forKey: "orbStyle")
        switch screen {
        case .claudeLogin, .claudeLoginChoices:
            model.selected = model.agents[1]
            model.selectedMachineID = model.selected!.machineID
            model.current.output = screen == .claudeLogin
                ? "Browser didn't open?\nhttps://claude.ai/oauth/authorize?state=fictional-preview\n\nPaste code here if prompted >"
                : "Select login method:\n❯ 1. Claude account with subscription\n  2. Anthropic Console account\n  3. Third-party platform"
        case .conversation, .structuredCodex, .structuredClaude, .codeConversation, .tableConversation, .workDetails, .claudeWorkDetails, .draftConversation, .commandConversation:
            let provider = screen == .structuredClaude || screen == .claudeWorkDetails ? "claude" : "codex"
            model.selected = model.agents[provider == "claude" ? 1 : 0]
            model.selectedMachineID = model.selected!.machineID
            model.current.messages = ConversationPreview.messages(provider: provider, screen: screen)
            model.current.structuredHistory = true
            model.current.contextUsage = ContextUsage(usedPercent: provider == "codex" ? 28 : 43, source: "Fictional preview", sessionID: "fictional-demo", model: provider, capacity: 200000, observedAt: Date())
            model.current.follow = false; model.current.scrollOffset = 0
            if screen == .draftConversation { model.current.draft = "Make the conversation feel calm and readable for both Codex and Claude. Keep code easy to copy, tuck completed work into a small summary, and preserve my reading position as new messages arrive." }
            if screen == .commandConversation { model.current.draft = "/" }
            model.current.messageRevision += 1
        case .approval, .claudeApproval:
            let provider = screen == .claudeApproval ? "claude" : "codex"
            model.selected = model.agents[provider == "claude" ? 1 : 0]
            model.selectedMachineID = model.selected!.machineID
            model.current.messages = Array(ConversationPreview.messages(provider: provider, screen: .conversation).prefix(2))
            model.current.structuredHistory = true
            let marker = provider == "claude" ? "❯" : "›"
            model.current.approval = ConversationApproval.parse("Bash command\nswift test\nDo you want to proceed?\n\(marker) 1. Yes, run once\n  2. Yes, and don’t ask again for this command\n  3. No, cancel\nPress Enter to confirm · Esc to cancel", provider: provider)
            model.current.messageRevision += 1
        case .imageConversation:
            let file = imageFixtureURL
            let prompt = ConversationImageInstructions.prompt("Generate an illustration of a planet in space.", kind: "codex")
            let output = "› \(prompt)\n• Generating your image.\n• Called image_gen.imagegen\n─ Worked for 18s ───\n• Here’s your image.\n\n![Planet in space](<\(file.path)>)"
            model.agents[0].tabLabel = "Image generation"
            model.selected = model.agents[0]
            model.current.output = output
            model.current.history = output
            model.current.messages = TerminalPresentation.messages(output, kind: "codex")
            model.current.messageRevision += 1
        case .setup:
            model.machines = [.local]; model.selected = nil; model.agents = []
            model.connection = ["local": .missing]
            model.connectionDetails = ["local": "Install Herdr and start it, then check again."]
            model.herdrVersions = [:]; model.showingSetup = true
        case .terminal: model.current.terminal = true
        case .deviceTerminal:
            model.selected = nil
            model.selectedMachineID = "demo-studio"
            DeviceTerminalStore.shared.closeAll()
            DeviceTerminalStore.shared.create(machine: model.machines[1], startsHerdr: false)
        case .deviceOffline:
            model.selected = nil
            model.selectedMachineID = "demo-studio"
            model.machines[1].target = "andrew@studio-mac"
            model.connection["demo-studio"] = .stopped
            model.connectionDetails["demo-studio"] = "Herdr is stopped. Start it to reconnect your agent sessions, or open a terminal directly."
        case .empty: model.selected = nil; model.agents = []
        case .recovery: model.failedLaunches["local"] = FailedLaunch(paneID: "demo-pane", kind: "codex", detail: "Codex requires sign-in on This Mac.")
        case .privacy: model.savingConversations = true
        default: break
        }
    }
    static var imageFixtureURL: URL {
        if AppPreferences.isDemo, let index = CommandLine.arguments.firstIndex(of: "--preview-image"), CommandLine.arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: CommandLine.arguments[index + 1])
        }
        return Bundle.module.url(forResource: "ObservatoryBackground", withExtension: "png")!
    }
    static func view(_ screen: DesignPreviewScreen, model: BubbleModel) -> (AnyView, NSSize, Bool) {
        let placement = PopoverPlacement(); placement.showPointer = false
        let local = model.machines.first ?? .local
        let remote = model.machines.first(where: { $0.id != "local" }) ?? local
        switch screen {
        case .connection: return (AnyView(DeviceConnectionSettings(model: model, machine: remote)), NSSize(width: 580, height: 680), false)
        case .projects: return (AnyView(DeviceProjectSettings(model: model, machine: local)), NSSize(width: 610, height: 360), false)
        case .folders: return (AnyView(FolderBrowser(machine: local, initialPath: "~/Projects", demo: true, select: { _ in })), NSSize(width: 650, height: 538), false)
        case .dialogs: return (AnyView(PreviewStateBoard()), NSSize(width: 1012, height: 790), false)
        case .claudeComposer: return (AnyView(ComposerControlsPreviewBoard(provider: "claude")), NSSize(width: 820, height: 1300), false)
        case .composer: return (AnyView(ComposerControlsPreviewBoard()), NSSize(width: 820, height: 1100), false)
        case .orb: return (AnyView(PreviewOrbAndArtifact(model: model)), NSSize(width: 900, height: 613), false)
        default: return (AnyView(PanelView(model: model, placement: placement, close: {}, resize: { _ in }, preview: screen)), panelSize, true)
        }
    }
    static func renderAll(to directory: String) async throws {
        let target = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let requested = DesignPreviewScreen.requested.map { [$0] } ?? DesignPreviewScreen.allCases
        for screen in requested {
            let model = AppModel.make()
            await prepare(screen, model: model)
            let (view, size, panel) = view(screen, model: model)
            let root = view.environment(\.orbSnapshotTime, 0).defaultAppStorage(model.preferences).preferredColorScheme(.dark).tint(OrbTheme.accent)
            let host = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = OrbTheme.nsCanvas
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            window.setFrameOrigin(NSPoint(x: 40, y: 60))
            window.orderFrontRegardless()
            try await Task.sleep(nanoseconds: 450_000_000)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let bounds = panel ? host.bounds.insetBy(dx: 14, dy: 0) : host.bounds
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: bounds) else { throw BridgeError.message("Could not create preview bitmap") }
            host.cacheDisplay(in: bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw BridgeError.message("Could not encode preview") }
            try data.write(to: target.appendingPathComponent(screen.rawValue + ".png"))
            print("Rendered \(screen.rawValue): \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
            window.orderOut(nil)
            await model.stop()
        }
    }
}

private struct PreviewStateBoard: View {
    @State private var name = "Release checklist"
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("herdrorb").foregroundStyle(OrbTheme.accent)
                Spacer()
                Text("Confirmations & states").foregroundStyle(OrbTheme.secondary)
            }.font(.system(size: 14)).padding(.horizontal, 4).padding(.bottom, -4)
            HStack(alignment: .top, spacing: 20) {
                SessionRenameSheet(name: $name, cancel: {}, rename: {})
                SessionDeleteSheet(name: "Release checklist", cancel: {}, delete: {})
            }
            HStack(alignment: .top, spacing: 20) {
                OrbConfirmation(title: "Clear saved conversations?", detail: "Removes saved conversation history and drafts from disk. Live Herdr sessions and current in-memory drafts stay open. New activity can be saved again while saving is enabled.", actionTitle: "Clear saved data", cancel: {}, confirm: {})
                OrbSheet(width: 470, inset: 22) {
                    PendingMessageView(text: "Please review the release notes.", state: "Sending…")
                }
            }
            HStack(alignment: .top, spacing: 20) {
                OrbSheet(width: 470, inset: 22) {
                    VStack(alignment: .leading, spacing: 20) {
                        OrbSkeleton()
                        OrbRule()
                        CachedConversationNotice()
                    }
                }
                OrbSheet(width: 470, inset: 22) {
                    VStack(alignment: .leading, spacing: 20) {
                        ArtifactErrorView(title: "Couldn’t load image", detail: "The preview could not be loaded. Try again.", action: {})
                        OrbRule()
                        ArtifactErrorView(title: "Couldn’t preview this file", detail: "The file could not be opened.", symbol: "doc", actionTitle: "OK", inlineAction: true, action: {})
                    }
                }
            }
        }.padding(26).background(OrbTheme.canvas).foregroundStyle(OrbTheme.text)
    }
}

private struct PreviewOrbAndArtifact: View {
    @ObservedObject var model: BubbleModel
    @State private var artifactURL: URL?
    var body: some View {
        HStack(spacing: 30) {
            VStack(spacing: 8) {
                FloatingOrb(model: model).frame(width: 110, height: 110)
                Text("herdrorb").font(.system(size: 13))
                OrbStatus(text: "Online", color: OrbTheme.online)
                VStack(alignment: .leading, spacing: 12) {
                    Label("Hide orb", systemImage: "eye.slash")
                    OrbRule()
                    Label("Quit herdrorb", systemImage: "power")
                }.font(.system(size: 12)).padding(12).background(OrbTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 6)
                Spacer()
            }.frame(width: 200).padding(.top, 30)
            VStack(alignment: .leading, spacing: 8) {
                VStack(spacing: 0) {
                    Text("release-notes.md · This Mac").font(.system(size: 14))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                    OrbRule()
                    MarkdownArtifactDocument(text: DesignPreview.artifactText)
                }.background(OrbTheme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 13))
                    .clipShape(RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(OrbTheme.line, lineWidth: 0.8))
                if let artifactURL {
                    ArtifactCard(artifact: ArtifactReference(path: artifactURL.path), machine: .local, cwd: nil)
                        .frame(maxWidth: 480)
                }
            }
        }.padding(25).background(OrbTheme.canvas).foregroundStyle(OrbTheme.text).font(OrbTheme.bodyFont)
            .task { artifactURL = try? DesignPreview.artifactFixtureURL() }
    }
}

private enum ConversationPreview {
    static func messages(provider: String, screen: DesignPreviewScreen) -> [SessionMessage] {
        let start = Date(timeIntervalSince1970: 1_792_102_800)
        var result = [SessionMessage(id: "preview-user", fromUser: true, text: "Review the release changes and run the checks.",
                                     source: provider, turnID: "preview-turn", createdAt: start)]
        result.append(SessionMessage(id: "preview-progress", fromUser: false, text: "I’ll review the changed files and run the test suite.",
                                     phase: provider == "codex" ? "commentary" : nil, source: provider, turnID: "preview-turn", createdAt: start.addingTimeInterval(2)))
        let activities: [ConversationActivity] = [
            .init(kind: .read, title: "Read README.md", input: "{\"file_path\": \"README.md\"}", output: "Installation and release checklist reviewed.", status: .completed, file: "README.md", startedAt: start.addingTimeInterval(3), completedAt: start.addingTimeInterval(4)),
            .init(kind: .edit, title: "Edit ConnectionSetup.swift", input: "ConnectionSetup.swift", output: "File updated.", status: .completed, file: "ConnectionSetup.swift",
                  diff: "--- ConnectionSetup.swift\n+++ ConnectionSetup.swift\n@@ -24,3 +24,4 @@\n-    connect()\n+    await connect()\n+    restoreConversation()", startedAt: start.addingTimeInterval(6), completedAt: start.addingTimeInterval(9)),
            .init(kind: .command, title: "swift test", input: "swift test", output: "Build complete!\nExecuted 93 tests, with 0 failures.\nProcess exited with code 0", status: .completed, exitCode: 0, startedAt: start.addingTimeInterval(10), completedAt: start.addingTimeInterval(24))
        ]
        for (index, activity) in activities.enumerated() {
            result.append(SessionMessage(id: "preview-tool-\(index)", fromUser: false, text: activity.title + "\n" + activity.input + "\n" + (activity.output ?? ""),
                                         phase: "activity", source: provider, turnID: "preview-turn", createdAt: activity.startedAt, activity: activity))
        }
        let answer: String
        switch screen {
        case .codeConversation:
            answer = """
            ## One conversation, both agents

            The response stays readable while completed work folds above it.

            ```swift
            struct ConversationTurn {
                let provider: AgentProvider
                let items: [ConversationItem]

                var isComplete: Bool {
                    items.allSatisfy { $0.isComplete }
                }
            }
            ```

            Code keeps its language, formatting, and copy controls.
            """
        case .tableConversation:
            answer = """
            ## Release verification

            Both agents share the same conversation surface.

            | Check | Codex | Claude |
            | :--- | :--- | :--- |
            | Formatted replies | Ready | Ready |
            | Commands & edits | Ready | Ready |
            | Saved history | Connected | Connected |

            - [x] Test suite passes
            - [x] Original conversations preserved
            - [ ] Review the release notes
            """
        case .workDetails, .claudeWorkDetails:
            answer = "All release checks passed. The updated files are ready to review."
        default:
            answer = """
            The release checks passed.

            - **Codex and Claude** share the same conversation layout.
            - Completed work stays together, with details a click away.
            - Your draft and reading position stay with each session.

            The updated files are ready to review.
            """
        }
        result.append(SessionMessage(id: "preview-answer", fromUser: false, text: answer,
                                     artifacts: [], phase: "final_answer", source: provider, turnID: "preview-turn", createdAt: start.addingTimeInterval(25)))
        return result
    }
}
