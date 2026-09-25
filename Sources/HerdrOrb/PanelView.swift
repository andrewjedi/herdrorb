import AppKit
import SwiftUI

final class PopoverPlacement: ObservableObject {
    @Published var left = true
    @Published var pointerY: CGFloat = 230
    @Published var showPointer = true
}
struct PopoverShape: Shape {
    var pointerSide: CGFloat
    var pointerY: CGFloat
    var showPointer: Bool
    var nativeWindow: Bool = false

    init(left: Bool, pointerY: CGFloat, showPointer: Bool) {
        pointerSide = left ? -1 : 1
        self.pointerY = pointerY
        self.showPointer = showPointer
    }
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(pointerY, pointerSide) }
        set { pointerY = newValue.first; pointerSide = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        let body = rect.insetBy(dx: nativeWindow ? 0 : 14, dy: 0)
        var path = Path(roundedRect: body, cornerRadius: 20)
        if showPointer {
            let y = min(rect.height - 35, max(35, pointerY))
            // Retract the old pointer and extend the new one when changing sides.
            for side: CGFloat in [-1, 1] {
                let amount = max(0, min(1, pointerSide * side))
                let x = side < 0 ? body.minX : body.maxX
                path.move(to: CGPoint(x: x, y: y - 14 * amount))
                path.addLine(to: CGPoint(x: x + side * 14 * amount, y: y))
                path.addLine(to: CGPoint(x: x, y: y + 14 * amount))
                path.closeSubpath()
            }
        }
        return path
    }
}

struct GlassMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow; view.blendingMode = .behindWindow; view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}


struct ObservatorySidebar: View {
    private static let image: NSImage? = {
        let packaged = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("HerdrOrb_HerdrOrb.bundle")) }
        guard let url = (packaged ?? Bundle.module).url(forResource: "ObservatorySidebar", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                OrbTheme.sidebar
                if let image = Self.image {
                    Image(nsImage: image).resizable().frame(width: geometry.size.width, height: geometry.size.height)
                    OrbTheme.canvas.opacity(0.32)
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

// Retained as a source-compatible alias for existing callers.
struct GlassButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { OrbButtonStyle().makeBody(configuration: configuration) }
}

struct PanelView: View {
    @ObservedObject var model: BubbleModel
    @ObservedObject var placement: PopoverPlacement
    var close: () -> Void
    var resize: (CGFloat) -> Void
    var preview: DesignPreviewScreen? = nil
    var nativeWindow = false
    @State private var resizeTranslation: CGFloat = 0
    @State private var machineID = "local"
    @State private var choosingMachine = false
    @State private var expansionOverrides: [String: Bool] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var creating = false
    @State private var kind = "codex"
    @State private var directory = ""
    @FocusState private var focusedDeviceSettings: String?
    @State private var hoveredMachine: String?
    @State private var hoveredSession: String?
    @State private var renaming: Agent?
    @State private var renamedSession = ""
    @State private var showingRename = false
    @State private var settingsMachine: Machine?
    @State private var showingGeneralSettings = false
    @State private var deletingSession: Agent?
    @State private var checkingFolder = false
    var displayedMachineID: String { model.selected?.machineID ?? model.selectedMachineID }
    var machinesWithSessions: Set<String> { Set(model.activeSessions.map(\.machineID)) }
    var machineName: String { model.machines.first { $0.id == displayedMachineID }?.label ?? "Your devices" }
    private var isCreating: Bool { creating || preview == .newSession || preview == .recovery }
    private var hasFailedLaunch: Bool { model.failedLaunches[machineID] != nil }
    private var isSettings: Bool { showingGeneralSettings || preview == .settings || preview == .privacy }
    private func beginSession(on id: String) {
        machineID = id
        directory = model.isDemo ? "~/Projects/herdrorb" : model.machines.first(where: { $0.id == id }).map { model.projectFolder(for: $0) } ?? ""
        showingGeneralSettings = false
        creating = true
    }
    private var panelShape: PopoverShape {
        var shape = PopoverShape(left: placement.left, pointerY: placement.pointerY, showPointer: nativeWindow ? false : placement.showPointer)
        shape.nativeWindow = nativeWindow
        return shape
    }
    var body: some View {
        let shape = panelShape
        HStack(spacing: 0) {
            sidebar.frame(width: OrbTheme.sidebarWidth)
            Rectangle().fill(OrbTheme.line).frame(width: 1)
            VStack(spacing: 0) {
                if isSettings && !model.showingSetup { settingsHeader } else { header }
                OrbRule()
                if model.showingSetup { ConnectionSetup(model: model) }
                else if isSettings { GeneralSettings(model: model, showPrivacyFirst: preview == .privacy) }
                else if isCreating { newSession }
                else if let agent = model.selected { conversation(agent) }
                else { emptyState }
                if let notice = model.notice {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.circle")
                        Text(notice).font(.system(size: 12)).lineLimit(4).textSelection(.enabled)
                        Spacer()
                        Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss notice")
                    }.foregroundStyle(OrbTheme.warning).padding(12).background(OrbTheme.warning.opacity(0.07))
                }
                if !nativeWindow {
                Capsule().fill(OrbTheme.muted.opacity(0.65)).frame(width: 42, height: 4)
                    .frame(maxWidth: .infinity).frame(height: 16).contentShape(Rectangle())
                    .help("Drag to resize height")
                    .gesture(DragGesture(coordinateSpace: .global).onChanged { value in
                        resize(value.translation.height - resizeTranslation); resizeTranslation = value.translation.height
                    }.onEnded { _ in resizeTranslation = 0 })
                }
            }.background(OrbTheme.canvas)
        }
        .padding(.horizontal, nativeWindow ? 0 : 14)
        .frame(minWidth: 700, maxWidth: .infinity, minHeight: 460, maxHeight: .infinity)
        .background(OrbTheme.canvas, in: shape).clipShape(shape)
        .overlay(shape.stroke(LinearGradient(colors: [OrbTheme.accentLight, OrbTheme.accent.opacity(0.45), OrbTheme.accentLight.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
        .foregroundStyle(OrbTheme.text).font(OrbTheme.bodyFont).tint(OrbTheme.accent).preferredColorScheme(.dark)
        .onChange(of: machinesWithSessions) { old, new in
            for id in old.symmetricDifference(new) { expansionOverrides.removeValue(forKey: id) }
        }
        .onChange(of: model.selected?.id) { _, _ in
            if let agent = model.selected, !agent.isShell { expansionOverrides[agent.machineID] = true }
            if model.launching && model.selected != nil { creating = false }
        }
        .onChange(of: machineID) { _, id in
            if isCreating { directory = model.isDemo ? "~/Projects/herdrorb" : model.machines.first(where: { $0.id == id }).map { model.projectFolder(for: $0) } ?? "" }
        }
        .onAppear { if preview != nil { directory = "~/Projects/herdrorb" } }
        .sheet(item: $settingsMachine) { machine in DeviceConnectionSettings(model: model, machine: machine) }
        .sheet(isPresented: $showingRename) {
            SessionRenameSheet(name: $renamedSession, cancel: { showingRename = false; renaming = nil }) {
                if let agent = renaming { model.rename(agent, to: renamedSession) }
                showingRename = false; renaming = nil
            }
        }
        .sheet(item: $deletingSession) { agent in
            SessionDeleteSheet(name: model.sessionLabel(agent), cancel: { deletingSession = nil }) {
                Task { await model.deleteSession(agent) }; deletingSession = nil
            }
        }
    }

    private var settingsHeader: some View {
        HStack(spacing: 12) {
            Button { showingGeneralSettings = false } label: {
                Label("Back", systemImage: "chevron.left").font(.system(size: 13)).frame(height: 32)
            }.buttonStyle(.plain).foregroundStyle(OrbTheme.secondary).help("Back").accessibilityLabel("Back")
                .padding(.trailing, 12)
            Text("Settings").font(OrbTheme.titleFont)
            Spacer()
        }.padding(.horizontal, OrbTheme.inset).frame(height: 58)
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your devices").font(.system(size: 17, weight: .semibold))
                Spacer(minLength: 4)
                Text("\(model.connection.values.filter { $0 == .online }.count) connected")
                    .font(.system(size: 11)).foregroundStyle(OrbTheme.secondary)
            }.padding(.top, 22)
            OrbRule().padding(.top, 15).padding(.bottom, 9)
            ScrollView {
                VStack(spacing: 10) { ForEach(model.machines) { machine in machineRow(machine) } }
            }.scrollIndicators(.hidden)
            Spacer(minLength: 14)
            HStack(spacing: 10) {
                Button { beginSession(on: displayedMachineID) } label: {
                    Label("New session", systemImage: "plus").font(.system(size: 12)).fixedSize()
                }.buttonStyle(OrbButtonStyle(kind: isCreating ? .selected : .secondary, compact: true))
                    .disabled(model.showingSetup || !model.connection.values.contains(.online))
                Spacer(minLength: 0)
                Button { model.showingSetup = false; showingGeneralSettings = true } label: {
                    Label("Settings", systemImage: "gearshape").font(.system(size: 12)).fixedSize()
                        .padding(.vertical, 8)
                }.buttonStyle(.plain).help("General settings")
                    .foregroundStyle(isSettings ? OrbTheme.text : OrbTheme.secondary)
            }
        }.padding(.horizontal, 17).padding(.bottom, 20).background(ObservatorySidebar())
    }
    func machineRow(_ machine: Machine) -> some View {
        let selected = (isCreating ? machineID : displayedMachineID) == machine.id
        let sessions = model.activeSessions.filter { $0.machineID == machine.id }
        let expanded = expansionOverrides[machine.id] ?? !sessions.isEmpty
        let attention = sessions.filter { $0.agent_status == "blocked" || model.state($0).unread }.count
        let online = model.connection[machine.id] == .online
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Button {
                    machineID = machine.id
                    if sessions.isEmpty { creating = false; model.showMachine(machine.id) }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { expansionOverrides[machine.id] = !expanded }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: machine.id == "local" ? "laptopcomputer" : "desktopcomputer").font(.system(size: 15, weight: .regular)).frame(width: 18)
                        Circle().fill(online ? OrbTheme.online : OrbTheme.warning).frame(width: 7, height: 7).accessibilityHidden(true)
                        Text(machine.label).font(.system(size: 14)).lineLimit(1)
                        Spacer(minLength: 0)
                        if attention > 0 { Text("\(attention)").font(.system(size: 11, weight: .semibold)).foregroundStyle(OrbTheme.warning) }
                    }.frame(height: 35).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(machine.label)
                    .accessibilityValue("\(online ? "Online" : "Unavailable"), \(expanded ? "Expanded" : "Collapsed")")
                    .help(expanded ? "Collapse sessions" : "Expand sessions")
                Button { settingsMachine = machine } label: {
                    Image(systemName: "gearshape").font(.system(size: 12)).foregroundStyle(OrbTheme.secondary).frame(width: 24, height: 30)
                }.buttonStyle(.plain).focused($focusedDeviceSettings, equals: machine.id)
                    .opacity(hoveredMachine == machine.id || focusedDeviceSettings == machine.id ? 1 : 0)
                    .help("Settings for \(machine.label)").accessibilityLabel("Settings for \(machine.label)")
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { expansionOverrides[machine.id] = !expanded }
                } label: {
                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(OrbTheme.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 18, height: 30)
                }.buttonStyle(.plain).accessibilityLabel(expanded ? "Collapse \(machine.label)" : "Expand \(machine.label)")
            }.padding(.horizontal, 3)
                .background((sessions.isEmpty && selected && !isSettings && !isCreating) ? OrbTheme.selection : hoveredMachine == machine.id ? OrbTheme.raised.opacity(0.65) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .onHover { hoveredMachine = $0 ? machine.id : nil }
            if expanded {
                ForEach(sessions) { agent in
                    Button { showingGeneralSettings = false; creating = false; Task { await model.choose(agent) } } label: {
                        HStack(spacing: 10) {
                            Circle().fill(agent.agent_status == "working" ? OrbTheme.online : agent.agent_status == "blocked" ? OrbTheme.warning : OrbTheme.online.opacity(0.8))
                                .frame(width: 6, height: 6).accessibilityHidden(true)
                            ProviderLogo(provider: agent.agent).frame(width: 16, height: 16)
                            Text(model.sessionLabel(agent)).font(.system(size: 14)).lineLimit(1)
                            Spacer(minLength: 0)
                            if agent.agent_status == "blocked" || model.state(agent).unread { Image(systemName: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(OrbTheme.warning) }
                        }.foregroundStyle(model.selected?.id == agent.id && !isSettings && !isCreating ? OrbTheme.text : OrbTheme.secondary)
                            .padding(.horizontal, 9).frame(height: 34)
                            .background(model.selected?.id == agent.id && !isSettings && !isCreating ? OrbTheme.selection : hoveredSession == agent.id ? OrbTheme.raised : .clear, in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(model.sessionLabel(agent)), \(agent.kind), \(statusLabel(agent.agent_status))")
                        .accessibilityAddTraits(model.selected?.id == agent.id ? .isSelected : [])
                        .help("\(agent.workspaceLabel ?? "Workspace") · \(agent.kind) · \(agent.cwd ?? "")")
                        .contextMenu {
                            Button("Rename…") { renaming = agent; renamedSession = model.sessionLabel(agent); showingRename = true }
                            Button("Delete session…", role: .destructive) { deletingSession = agent }.disabled(!model.canInteract(agent))
                        }
                        .onHover { hoveredSession = $0 ? agent.id : nil }
                }
                if sessions.isEmpty && !online { Text("Machine unavailable").font(OrbTheme.smallFont).foregroundStyle(OrbTheme.secondary) }
            }
        }
    }
    var header: some View {
        HStack(spacing: 16) {
            Text(isCreating ? "New session" : machineName).font(.system(size: 18, weight: .semibold)).lineLimit(1)
            if let agent = model.selected, !isCreating && !model.showingSetup {
                HStack(spacing: 6) {
                    ProviderLogo(provider: agent.agent).frame(width: 14, height: 14)
                    Text(agent.kind).font(.system(size: 12)).foregroundStyle(OrbTheme.secondary)
                }
            }
            if !isCreating && !model.showingSetup {
                OrbStatus(text: (model.connection[displayedMachineID] ?? .connecting).rawValue,
                    color: model.connection[displayedMachineID] == .online ? OrbTheme.online : OrbTheme.warning)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 18).frame(height: 52)
    }
    func conversation(_ agent: Agent) -> some View {
        SessionConversation(model: model, agent: agent, machine: model.machines.first { $0.id == agent.machineID } ?? .local, session: model.state(agent)).id(agent.id)
    }

    var emptyState: some View {
        VStack(spacing: 15) {
            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 46, weight: .ultraLight)).foregroundStyle(OrbTheme.secondary).padding(.bottom, 5)
            Text("Start a conversation on \(machineName). ").font(.system(size: 19, weight: .semibold)).multilineTextAlignment(.center)
            Text("Choose an agent and a project to begin.").font(.system(size: 15)).foregroundStyle(OrbTheme.secondary)
            Button { beginSession(on: displayedMachineID) } label: { Label("New session", systemImage: "plus") }
                .buttonStyle(OrbButtonStyle(kind: .primary)).disabled(model.connection[displayedMachineID] != .online || model.launching)
            if let machine = model.machines.first(where: { $0.id == displayedMachineID }) {
                LaunchRecovery(model: model, machine: machine)
                if model.connection[machine.id] != .online, let detail = model.connectionDetails[machine.id] {
                    Text(detail).font(.callout).foregroundStyle(OrbTheme.warning)
                    Button("Connection settings…") { settingsMachine = machine }.buttonStyle(OrbButtonStyle())
                }
            }
        }.padding(.bottom, model.failedLaunches[displayedMachineID] == nil && model.connection[displayedMachineID] == .online ? 64 : 0)
            .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    var newSession: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: hasFailedLaunch ? 14 : 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Mac").font(.system(size: 13))
                        if hasFailedLaunch { Text("Run the session on a connected Mac.").font(.system(size: 12)).foregroundStyle(OrbTheme.secondary) }
                        Button { choosingMachine = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: machineID == "local" ? "laptopcomputer" : "desktopcomputer").font(.system(size: 22, weight: .light))
                                Text(model.machines.first(where: { $0.id == machineID })?.label ?? "This Mac")
                                Spacer(); Image(systemName: "chevron.down").font(.system(size: 12)).foregroundStyle(OrbTheme.secondary)
                            }.padding(.horizontal, 14).frame(height: 36).background(OrbTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(OrbTheme.controlEdge, lineWidth: 0.75))
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).accessibilityLabel("Mac")
                            .accessibilityValue(model.machines.first(where: { $0.id == machineID })?.label ?? "This Mac")
                            .popover(isPresented: $choosingMachine, arrowEdge: .bottom) {
                                VStack(spacing: 4) {
                                    ForEach(model.machines) { machine in
                                        Button { machineID = machine.id; choosingMachine = false } label: {
                                            HStack(spacing: 12) {
                                                Image(systemName: machine.id == "local" ? "laptopcomputer" : "desktopcomputer")
                                                Text(machine.label)
                                                Spacer()
                                                if machine.id == machineID { Image(systemName: "checkmark").foregroundStyle(OrbTheme.accent) }
                                            }.padding(10).frame(width: 260, alignment: .leading)
                                                .background(machine.id == machineID ? OrbTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                                        }.buttonStyle(.plain)
                                    }
                                }.padding(8).background(OrbTheme.canvas).foregroundStyle(OrbTheme.text)
                            }

                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Agent").font(.system(size: 13))
                        if hasFailedLaunch { Text("Choose which agent to use for this session.").font(.system(size: 12)).foregroundStyle(OrbTheme.secondary) }
                        HStack(spacing: 3) {
                            OrbSegment(title: "Codex", symbol: "terminal", selected: kind == "codex", fillsWidth: true) { kind = "codex" }
                            OrbSegment(title: "Claude Code", symbol: "asterisk", selected: kind == "claude", fillsWidth: true) { kind = "claude" }
                        }.padding(3).background(OrbTheme.surface, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(OrbTheme.line))
                    }
                    if let machine = model.machines.first(where: { $0.id == machineID }) {
                        SessionProjectChooser(machine: machine, basePath: model.isDemo ? "~/Projects" : model.projectFolder(for: machine), directory: $directory, demo: model.isDemo, showProjects: !hasFailedLaunch).id(machine.identity)
                        LaunchRecovery(model: model, machine: machine)
                        if model.checkingAgents.contains(machine.id) { ProgressView("Checking installed agents…").controlSize(.small) }
                        else if let available = model.availability[machine.id], !available.contains(kind) {
                            Text("Install \(kind == "claude" ? "Claude Code" : "Codex") on this Mac, then sign in from Terminal.").foregroundStyle(OrbTheme.warning).font(.callout)
                        }
                        if let error = model.availabilityErrors[machine.id] { Text(error).font(.caption).foregroundStyle(OrbTheme.warning) }
                        if !hasFailedLaunch { VStack(alignment: .leading, spacing: 8) {
                            Button("Check installed agents") { Task { await model.checkAgents(machine) } }.buttonStyle(.link).foregroundStyle(OrbTheme.accent)
                            Text("Agent sign-in is completed in Terminal. Your existing agent accounts are used.").font(.system(size: 12)).foregroundStyle(OrbTheme.secondary)
                        } }
                    }
                }.padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 12)
            }
            OrbRule().padding(.horizontal, 24)
            HStack {
                Button { creating = false } label: { Text("Cancel").frame(width: 76) }.buttonStyle(OrbButtonStyle())
                Spacer()
                Button {
                    guard let machine = model.machines.first(where: { $0.id == machineID }) else { return }
                    if model.isDemo {
                        let sample = Agent(terminal_id: UUID().uuidString, agent: kind, agent_status: "idle",
                                           pane_id: "demo-pane", cwd: directory, machineID: machine.id,
                                           tabLabel: "New conversation", profileIdentity: machine.identity)
                        model.agents.append(sample)
                        model.state(sample).cached = false
                        creating = false
                        Task { await model.choose(sample) }
                        return
                    }
                    let chosenDirectory = directory
                    checkingFolder = true
                    Task {
                        do {
                            let path = try await ProjectFolders.list(on: machine, path: chosenDirectory).path
                            await model.launch(kind: kind, machine: machine, directory: path)
                            if model.selected != nil { creating = false }
                        } catch { model.globalNotice = error.localizedDescription }
                        checkingFolder = false
                    }
                } label: { Text(checkingFolder ? "Checking folder…" : model.launching ? "Starting…" : "Start session").frame(minWidth: 106) }
                    .buttonStyle(OrbButtonStyle(kind: .primary)).disabled(hasFailedLaunch || model.launching || checkingFolder || model.connection[machineID] != .online || model.checkingAgents.contains(machineID) || model.availability[machineID]?.contains(kind) == false)
            }.padding(.horizontal, 24).padding(.top, 15).padding(.bottom, 14)
        }.disabled(model.launching || checkingFolder)
            .task(id: machineID) { if let machine = model.machines.first(where: { $0.id == machineID }) { await model.checkAgents(machine) } }
    }
}
