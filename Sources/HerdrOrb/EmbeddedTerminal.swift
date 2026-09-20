import AppKit
import SwiftUI
import SwiftTerm

/// The PTY runs an attach client only. Detaching never terminates the remote shell/agent.
struct EmbeddedTerminal: NSViewRepresentable {
    var agent: Agent
    var machine: Machine
    var initialInput = ""
    var onReady: () -> Void = {}
    var onExit: () -> Void = {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> InteractiveTerminalView {
        let view = InteractiveTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.appearance = NSAppearance(named: .darkAqua)
        view.nativeBackgroundColor = NSColor(srgbRed: 0.065, green: 0.075, blue: 0.10, alpha: 1)
        view.nativeForegroundColor = NSColor(srgbRed: 0.92, green: 0.93, blue: 0.96, alpha: 1)
        view.caretColor = NSColor(srgbRed: 0.72, green: 0.66, blue: 1, alpha: 1)
        view.inputBuffer = TerminalInputBuffer(initial: initialInput)
        view.ready = onReady
        view.setAccessibilityLabel("\(agent.kind) interactive terminal")
        context.coordinator.onExit = onExit
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.processDelegate = context.coordinator
        let args = ["terminal", "attach", agent.terminal_id]
        var environment = ConnectionCommands.environment()
        environment["TERM"] = "xterm-256color"
        environment["COLORFGBG"] = "15;0"
        do {
            if machine.id == "local" {
                view.startProcess(executable: try HerdrInstallation.resolve(), args: args, environment: environment.map { "\($0.key)=\($0.value)" })
            } else {
                let target = try ConnectionCommands.target(machine)
                view.startProcess(executable: "/usr/bin/ssh", args: ConnectionCommands.sshOptions.filter { $0 != "-T" } + ["-tt", target, MachineTransport.remoteCommand(machine, arguments: args)], environment: environment.map { "\($0.key)=\($0.value)" })
            }
        } catch {
            view.feed(text: error.localizedDescription)
            DispatchQueue.main.async { onExit() }
        }
        return view
    }
    func updateNSView(_ view: InteractiveTerminalView, context: Context) {
        view.inputBuffer.replaceInitial(initialInput)
        view.ready = onReady
        context.coordinator.onExit = onExit
    }
    static func dismantleNSView(_ view: InteractiveTerminalView, coordinator: Coordinator) {
        coordinator.onExit = {}; view.ready = {}; view.terminate()
    }
    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var onExit: () -> Void = {}
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) { source.feed(text: "\r\nDisconnected. Your session continues in Herdr.\r\n"); onExit() }
    }
}

/// Preserve fast typing while the attach client connects. Terminal-generated
/// protocol replies pass through immediately so geometry negotiation can finish.
final class InteractiveTerminalView: LocalProcessTerminalView {
    var inputBuffer = TerminalInputBuffer()
    var ready: () -> Void = {}
    private var themeFilter = TerminalThemeFilter()
    private var receivingOutput = false
    private var focused = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !focused else { return }; focused = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeFirstResponder(self)
        }
    }
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if receivingOutput { super.send(source: source, data: data); return }
        let bytes = inputBuffer.input(data)
        if !bytes.isEmpty { super.send(source: source, data: bytes[...]) }
    }
    override func dataReceived(slice: ArraySlice<UInt8>) {
        let buffered = inputBuffer.output(slice)
        let themed = themeFilter.process(slice)
        receivingOutput = true; super.dataReceived(slice: themed[...]); receivingOutput = false
        if let buffered {
            if !buffered.isEmpty { super.send(source: self, data: buffered[...]) }
            ready()
        }
    }
}
