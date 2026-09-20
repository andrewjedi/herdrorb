import AppKit
import SwiftUI

private let lavender = Color(red: 0.64, green: 0.58, blue: 1)

final class PopoverPlacement: ObservableObject {
    @Published var left = true
    @Published var pointerY: CGFloat = 230
    @Published var showPointer = true
}
struct PopoverShape: Shape {
    var pointerSide: CGFloat
    var pointerY: CGFloat
    var showPointer: Bool

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
        let body = rect.insetBy(dx: 14, dy: 0)
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

private struct ObservatoryBackground: View {
    // Decode once; the image remains fixed behind every region of the panel.
    private static let image: NSImage? = {
        let packaged = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("HerdrOrb_HerdrOrb.bundle")) }
        guard let url = (packaged ?? Bundle.module).url(forResource: "ObservatoryBackground", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(red: 0.045, green: 0.055, blue: 0.09)
                if let image = Self.image {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
                Color(red: 0.035, green: 0.045, blue: 0.075).opacity(0.80)
                LinearGradient(colors: [.black.opacity(0.12), .clear, .black.opacity(0.18)], startPoint: .top, endPoint: .bottom)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
struct GlassButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 14).padding(.vertical, 11)
            .background(.white.opacity(configuration.isPressed ? 0.16 : 0.065), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.15)))
    }
}

struct PanelView: View {
    @ObservedObject var model: BubbleModel
    @ObservedObject var placement: PopoverPlacement
    var close: () -> Void
    var resize: (CGFloat) -> Void
    @State private var resizeTranslation: CGFloat = 0
    @State private var machineID = "local"
    @State private var expansionOverrides: [String: Bool] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var creating = false
    @State private var kind = "codex"
    @State private var directory = ""
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
    var machineName: String { model.machines.first { $0.id == displayedMachineID }?.label ?? "Your Macs" }
    private func beginSession(on id: String) {
        machineID = id
        directory = model.machines.first(where: { $0.id == id }).map { model.projectFolder(for: $0) } ?? ""
        showingGeneralSettings = false
        creating = true
    }
    var body: some View {
        let shape = PopoverShape(left: placement.left, pointerY: placement.pointerY, showPointer: placement.showPointer)
        HStack(spacing: 0) {
            sidebar.frame(width: 275)
            Rectangle().fill(.white.opacity(0.1)).frame(width: 1)
            VStack(spacing: 0) {
                if showingGeneralSettings && !model.showingSetup {
                    HStack {
                        Button { showingGeneralSettings = false } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(.plain)
                        Text("Settings").font(.system(size: 16, weight: .semibold))
                        Spacer()
                        Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).help("Close pop-out")
                    }.padding(.horizontal, 24).padding(.vertical, 18)
                } else { header }
                Divider().overlay(.white.opacity(0.04))
                if model.showingSetup { ConnectionSetup(model: model) }
                else if showingGeneralSettings { GeneralSettings(model: model) }
                else if creating { newSession }
                else if let agent = model.selected { conversation(agent) }
                else { emptyState }
                if let notice = model.notice {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.circle")
                        Text(notice).font(.system(size: 11)).lineLimit(4).textSelection(.enabled)
                        Spacer()
                        Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }.foregroundStyle(.orange).padding(12).background(.orange.opacity(0.08))
                }
                Capsule().fill(.white.opacity(0.3)).frame(width: 42, height: 4)
                    .frame(maxWidth: .infinity).frame(height: 18).contentShape(Rectangle())
                    .help("Drag to resize height")
                    .gesture(DragGesture(coordinateSpace: .global).onChanged { value in
                        resize(value.translation.height - resizeTranslation); resizeTranslation = value.translation.height
                    }.onEnded { _ in resizeTranslation = 0 })
            }
        }
        .padding(.horizontal, 14)
        .frame(minWidth: 700, maxWidth: .infinity, minHeight: 460, maxHeight: .infinity)
        .background {
            ObservatoryBackground().clipShape(shape)
        }
        .overlay(shape.stroke(.white.opacity(0.27), lineWidth: 0.8))
        .foregroundStyle(Color.white.opacity(0.92)).preferredColorScheme(.dark)
        .onChange(of: machinesWithSessions) { old, new in
            // Reapply the default when the first agent starts or the last one exits.
            for id in old.symmetricDifference(new) { expansionOverrides.removeValue(forKey: id) }
        }
        .onChange(of: model.selected?.id) { _, _ in
            if let agent = model.selected, !agent.isShell { expansionOverrides[agent.machineID] = true }
            if model.launching && model.selected != nil { creating = false }
        }
        .onChange(of: machineID) { _, id in
            if creating { directory = model.machines.first(where: { $0.id == id }).map { model.projectFolder(for: $0) } ?? "" }
        }
        .alert("Delete this session?", isPresented: Binding(get: { deletingSession != nil }, set: { if !$0 { deletingSession = nil } })) {
            Button("Cancel", role: .cancel) { deletingSession = nil }
            Button("Delete session", role: .destructive) {
                if let agent = deletingSession { Task { await model.deleteSession(agent) } }
                deletingSession = nil
            }
        } message: {
            Text("This closes the terminal for \(deletingSession.map { model.sessionLabel($0) } ?? "this session") and ends any running command.")
        }
        .sheet(item: $settingsMachine) { machine in DeviceConnectionSettings(model: model, machine: machine) }
        .alert("Rename session", isPresented: $showingRename) {
            TextField("Session name", text: $renamedSession)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let agent = renaming { model.rename(agent, to: renamedSession) }
                renaming = nil
            }.disabled(renamedSession.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.isDemo { Text("DEMO · Sample sessions").font(.system(size: 10, weight: .semibold)).foregroundStyle(.purple).padding(.top, 14) }
            Text("Your Macs").font(.system(size: 20, weight: .semibold)).padding(.top, model.isDemo ? 14 : 28)
            Text("\(model.connection.values.filter { $0 == .online }.count) connected")
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 5)
            Divider().padding(.vertical, 22)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.machines) { machine in machineRow(machine) }
                }
            }
            Spacer(minLength: 12)
            Button { beginSession(on: displayedMachineID) } label: {
                Label("New session", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(GlassButton()).disabled(model.showingSetup || !model.connection.values.contains(.online))
            HStack {
                Button { model.showingSetup = false; showingGeneralSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                    .help("General settings")
                Spacer()
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.refreshing).help("Refresh machines")
            }.font(.system(size: 11)).foregroundStyle(.secondary).buttonStyle(.plain).padding(.top, 14)
        }.padding(.horizontal, 20).padding(.bottom, 24)
    }
    func machineRow(_ machine: Machine) -> some View {
        let selected = (creating ? machineID : displayedMachineID) == machine.id
        let sessions = model.activeSessions.filter { $0.machineID == machine.id }
        let expanded = expansionOverrides[machine.id] ?? !sessions.isEmpty
        let attention = sessions.filter { $0.agent_status == "blocked" || model.state($0).unread }.count
        let online = model.connection[machine.id] == .online
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
            Button {
                machineID = machine.id
                if sessions.isEmpty { creating = false; model.showMachine(machine.id) }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    expansionOverrides[machine.id] = !expanded
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: machine.id == "local" ? "laptopcomputer" : "macmini.fill")
                        .font(.system(size: 22)).foregroundStyle(LinearGradient(colors: [.white, .gray], startPoint: .top, endPoint: .bottom)).frame(width: 30)
                    Circle().fill(online ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(machine.label).font(.system(size: 13)).lineLimit(1).minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                    if attention > 0 {
                        Text("\(attention)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange)
                            .help("Sessions needing attention")
                    }
                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }.padding(.vertical, 10).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(machine.label)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .help(expanded ? "Collapse sessions" : "Expand sessions")
            Button { settingsMachine = machine } label: {
                Image(systemName: "gearshape").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(width: 24, height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Settings for \(machine.label)").accessibilityLabel("Settings for \(machine.label)")
            }
            if expanded {
                ForEach(sessions) { agent in
                    HStack(spacing: 0) {
                    Button { showingGeneralSettings = false; creating = false; Task { await model.choose(agent) } } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "bubble.left").font(.system(size: 13))
                                .overlay(alignment: .bottomTrailing) {
                                    Circle().fill(agent.agent_status == "working" ? .green : agent.agent_status == "blocked" ? .orange : .yellow)
                                        .frame(width: 7, height: 7).overlay(Circle().stroke(.black.opacity(0.7), lineWidth: 1))
                                        .offset(x: 3, y: 2)
                                }
                                .accessibilityLabel(agent.agent_status == "working" ? "Working" : agent.agent_status == "blocked" ? "Needs attention" : "Idle")
                                .help(agent.agent_status == "working" ? "Agent is working" : agent.agent_status == "blocked" ? "Agent needs your attention" : "Agent is idle")
                            Text(model.sessionLabel(agent)).help("\(agent.workspaceLabel ?? "Workspace") · \(agent.kind) · \(agent.cwd ?? "")").font(.system(size: 12)).lineLimit(1)
                            Spacer(minLength: 0)
                            if agent.agent_status == "blocked" { Circle().fill(.orange).frame(width: 6, height: 6) }
                            else if model.state(agent).unread { Circle().fill(.cyan).frame(width: 6, height: 6) }
                        }.padding(11)
                            .background(model.selected?.id == agent.id ? lavender.opacity(hoveredSession == agent.id ? 0.5 : 0.36) : .white.opacity(hoveredSession == agent.id ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(hoveredSession == agent.id ? 0.22 : 0), lineWidth: 1))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .contextMenu {
                            Button("Rename…") {
                                renaming = agent
                                renamedSession = model.sessionLabel(agent)
                                showingRename = true
                            }
                            Button("Delete session…", role: .destructive) { deletingSession = agent }
                        }
                    Button(role: .destructive) { deletingSession = agent } label: {
                        Image(systemName: "trash").frame(width: 28, height: 32)
                    }.buttonStyle(.plain).help("Delete session \(model.sessionLabel(agent))")
                        .accessibilityLabel("Delete session \(model.sessionLabel(agent))")
                        .disabled(!model.canInteract(agent))
                        .opacity(hoveredSession == agent.id ? 1 : 0)
                        .allowsHitTesting(hoveredSession == agent.id)
                    }.contentShape(Rectangle())
                        .onHover { hovering in
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                                if hovering { hoveredSession = agent.id }
                                else if hoveredSession == agent.id { hoveredSession = nil }
                            }
                        }
                }
                if sessions.isEmpty {
                    Button { model.showMachine(machine.id); beginSession(on: machine.id) } label: {
                        Label("New Session", systemImage: "plus").font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(GlassButton()).disabled(!online || model.launching)
                    if !online { Text("Machine unavailable").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
            } else if let working = sessions.first {
                Text("\(working.kind) · \(working.agent_status)").font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 50).padding(.bottom, 8)
            }
        }.padding(.horizontal, 10).padding(.bottom, expanded ? 8 : 0)
            .background(hoveredMachine == machine.id ? lavender.opacity(0.27) : selected ? lavender.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(hoveredMachine == machine.id ? 0.2 : 0), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    if hovering { hoveredMachine = machine.id }
                    else if hoveredMachine == machine.id { hoveredMachine = nil }
                }
            }
    }
    var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(creating ? "New session" : machineName).font(.system(size: 16, weight: .semibold))
                HStack(spacing: 8) {
                    Text(creating ? "Choose where your agent will work" : model.selected.map { "\($0.kind) / \(model.sessionLabel($0))" } ?? (model.activeSessions.contains { $0.machineID == displayedMachineID } ? "Choose a session to start talking" : "No active sessions"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if !creating {
                        HStack(spacing: 6) {
                            Circle().fill(model.connection[displayedMachineID] == .online ? Color.green : .orange).frame(width: 8, height: 8)
                            Text((model.connection[displayedMachineID] ?? .connecting).rawValue)
                        }.font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button { moveSession(-1) } label: { Image(systemName: "chevron.up") }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option]).buttonStyle(.plain).help("Previous session")
            Button { moveSession(1) } label: { Image(systemName: "chevron.down") }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option]).buttonStyle(.plain).help("Next session")
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 12)).frame(width: 30, height: 30).background(.white.opacity(0.07), in: Circle()) }.buttonStyle(.plain).help("Close pop-out")
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }
    func conversation(_ agent: Agent) -> some View {
        SessionConversation(model: model, agent: agent, machine: model.machines.first { $0.id == agent.machineID } ?? .local, session: model.state(agent)).id(agent.id)
    }
    private func moveSession(_ direction: Int) {
        let sessions = model.activeSessions
        guard !sessions.isEmpty else { return }
        let index = sessions.firstIndex(where: { $0.id == model.selected?.id }) ?? (direction > 0 ? -1 : 0)
        let next = (index + direction + sessions.count) % sessions.count
        creating = false
        Task { await model.choose(sessions[next]) }
    }
    var emptyState: some View {
        VStack(spacing: 16) {
            Button { beginSession(on: displayedMachineID) } label: {
                Label("Start New Session", systemImage: "plus.circle.fill")
                    .font(.system(size: 21, weight: .medium)).padding(.horizontal, 22).padding(.vertical, 16)
            }.buttonStyle(GlassButton()).disabled(model.connection[displayedMachineID] != .online || model.launching)
            if let machine = model.machines.first(where: { $0.id == displayedMachineID }) {
                LaunchRecovery(model: model, machine: machine)
                if let detail = model.connectionDetails[machine.id] {
                    Text(detail).font(.callout).foregroundStyle(.orange)
                    Button("Connection settings…") { settingsMachine = machine }
                }
            }
            Text("Start a conversation on \(machineName).")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    var newSession: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Mac", selection: $machineID) { ForEach(model.machines) { Text($0.label).tag($0.id) } }
            Picker("Agent", selection: $kind) { Text("Codex").tag("codex"); Text("Claude Code").tag("claude") }.pickerStyle(.segmented)
            if let machine = model.machines.first(where: { $0.id == machineID }) {
                if !model.isDemo { SessionProjectChooser(machine: machine, basePath: model.projectFolder(for: machine), directory: $directory).id(machine.identity) }
                LaunchRecovery(model: model, machine: machine)
                if model.checkingAgents.contains(machine.id) { ProgressView("Checking installed agents…").controlSize(.small) }
                else if let available = model.availability[machine.id], !available.contains(kind) {
                    Text("Install \(kind == "claude" ? "Claude Code" : "Codex") on this Mac, then sign in from Terminal.").foregroundStyle(.orange).font(.callout)
                }
                if let error = model.availabilityErrors[machine.id] { Text(error).font(.caption).foregroundStyle(.orange) }
                Button("Check installed agents") { Task { await model.checkAgents(machine) } }.font(.caption)
                Text("Agent sign-in is completed in Terminal. Your existing agent accounts are used.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Button("Cancel") { creating = false }.buttonStyle(.plain)
                Spacer()
                Button(checkingFolder ? "Checking folder…" : model.launching ? "Starting…" : "Start session") {
                    guard let machine = model.machines.first(where: { $0.id == machineID }) else { return }
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
                }.buttonStyle(GlassButton()).disabled(model.isDemo || model.launching || checkingFolder || model.connection[machineID] != .online || model.checkingAgents.contains(machineID) || model.availability[machineID]?.contains(kind) == false)
            }
        }.padding(30).disabled(model.launching || checkingFolder)
            .task(id: machineID) { if let machine = model.machines.first(where: { $0.id == machineID }) { await model.checkAgents(machine) } }
        }
    }
}
