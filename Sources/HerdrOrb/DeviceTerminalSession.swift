import AppKit
import SwiftUI
import SwiftTerm
import Combine

/// Owns the PTY independently of SwiftUI navigation. Only an explicit close ends it.
@MainActor final class DeviceTerminalSession: NSObject, ObservableObject, Identifiable, @preconcurrency LocalProcessTerminalViewDelegate {
    let id = UUID()
    let machine: Machine
    let startsHerdr: Bool
    let number: Int
    @Published private(set) var ended = false
    private(set) var terminal: InteractiveTerminalView?
    var title: String { "\(startsHerdr ? "Herdr" : "Terminal") \(number)" }

    init(machine: Machine, startsHerdr: Bool, number: Int) {
        self.machine = machine; self.startsHerdr = startsHerdr; self.number = number
    }

    func start(demo: Bool = false) -> InteractiveTerminalView {
        if let terminal { return terminal }
        let view = InteractiveTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        terminal = view
        view.appearance = NSAppearance(named: .darkAqua)
        view.nativeBackgroundColor = NSColor(srgbRed: 12/255, green: 13/255, blue: 16/255, alpha: 1)
        view.nativeForegroundColor = OrbTheme.nsText
        view.caretColor = OrbTheme.nsAccent
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.linkHighlightMode = .hover
        view.setAccessibilityLabel("\(title) on \(machine.label)")
        view.processDelegate = self
        if demo {
            view.feed(text: "Connected to \(machine.label)\r\n\r\n$ \(startsHerdr ? "herdr" : "")")
            return view
        }
        do {
            let command = try DeviceTerminal.command(machine, startHerdr: startsHerdr)
            var environment = ConnectionCommands.environment()
            environment["TERM"] = "xterm-256color"
            environment["COLORFGBG"] = "15;0"
            view.startProcess(executable: "/bin/sh", args: ["-c", command.hasPrefix("exec ") ? command : "exec " + command], environment: environment.map { "\($0.key)=\($0.value)" })
        } catch {
            view.feed(text: "\r\n\(error.localizedDescription)\r\n")
            ended = true
        }
        return view
    }
    func close() { terminal?.processDelegate = nil; terminal?.terminate(); terminal = nil; ended = true }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        source.feed(text: "\r\nSession ended\(exitCode.map { " (exit \($0))" } ?? "").\r\n")
        ended = true
    }
}

@MainActor final class DeviceTerminalStore: ObservableObject {
    static let shared = DeviceTerminalStore()
    @Published private(set) var sessions: [DeviceTerminalSession] = []
    @Published var selectedID: UUID?
    private var sequence = 0
    var selected: DeviceTerminalSession? { sessions.first { $0.id == selectedID } }
    @discardableResult func create(machine: Machine, startsHerdr: Bool) -> DeviceTerminalSession {
        sequence += 1
        let session = DeviceTerminalSession(machine: machine, startsHerdr: startsHerdr, number: sequence)
        sessions.append(session); selectedID = session.id
        return session
    }
    func closeAll() {
        for session in sessions { session.close() }
        sessions.removeAll(); selectedID = nil
    }
    func close(_ session: DeviceTerminalSession) {
        session.close(); sessions.removeAll { $0.id == session.id }
        if selectedID == session.id { selectedID = nil }
    }
}

struct DeviceTerminalSurface: NSViewRepresentable {
    let session: DeviceTerminalSession
    let demo: Bool
    func makeNSView(context: Context) -> InteractiveTerminalView {
        let view = session.start(demo: demo)
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
        return view
    }
    func updateNSView(_ view: InteractiveTerminalView, context: Context) {}
    // Navigation detaches the view, while the store retains its process and output.
    static func dismantleNSView(_ view: InteractiveTerminalView, coordinator: ()) {}
}

struct DeviceTerminalPane: View {
    @ObservedObject var session: DeviceTerminalSession
    let demo: Bool
    let close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal").foregroundStyle(OrbTheme.accent)
                Text(session.title).font(.system(size: 13, weight: .medium))
                Text(session.ended ? "Ended" : session.machine.id == "local" ? "Local terminal" : "SSH terminal")
                    .font(.system(size: 11)).foregroundStyle(OrbTheme.secondary)
                Spacer()
                Button(action: close) { Label("Close session", systemImage: "xmark") }
                    .buttonStyle(OrbButtonStyle(compact: true))
            }.padding(12)
            OrbRule()
            DeviceTerminalSurface(session: session, demo: demo).id(session.id)
        }
    }
}
