import SwiftUI
import AppKit

enum SetupActions {
    @MainActor static func locate(_ model: BubbleModel, selected: ((String) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Locate the herdr executable"
        panel.message = "Select the herdr command-line executable you installed."
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            selected?(url.path)
            Task { await model.setExecutable(url.path) }
        }
    }
    @MainActor static func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}

struct ConnectionSetup: View {
    @ObservedObject var model: BubbleModel
    @State private var selectedDevice: Machine?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 10) {
                    Image(systemName: "circle.hexagongrid.fill").font(.system(size: 43, weight: .light)).foregroundStyle(OrbTheme.accent)
                    Text("Welcome to herdrorb").font(.system(size: 25, weight: .semibold))
                    Text("Your Herdr sessions, a click away.").font(.system(size: 17)).foregroundStyle(OrbTheme.secondary)
                }.frame(maxWidth: .infinity).padding(.top, 0).padding(.bottom, 4)
                ForEach(model.machines.isEmpty ? [.local] : model.machines) { machine in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 13) {
                            Image(systemName: machine.id == "local" ? "laptopcomputer" : "desktopcomputer").font(.system(size: 24, weight: .light))
                            Text(machine.label)
                            Spacer()
                            OrbStatus(text: (model.connection[machine.id] ?? .connecting).rawValue, color: model.connection[machine.id] == .online ? OrbTheme.online : OrbTheme.warning)
                        }.padding(15).background(OrbTheme.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(OrbTheme.line, lineWidth: 0.8))
                        if let detail = model.connectionDetails[machine.id] { Text(detail).font(.system(size: 12)).foregroundStyle(OrbTheme.secondary).textSelection(.enabled) }
                        if let version = model.herdrVersions[machine.id] { Text("Herdr \(version)").font(.system(size: 11)).foregroundStyle(OrbTheme.secondary) }
                        Button { selectedDevice = machine } label: { Label("Connection settings…", systemImage: "gearshape") }
                            .buttonStyle(.plain).foregroundStyle(OrbTheme.accent).font(.system(size: 14))
                    }
                }.frame(maxWidth: 464).frame(maxWidth: .infinity)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { setupActions }.fixedSize(horizontal: true, vertical: false)
                    VStack(spacing: 10) { setupActions }
                }.frame(maxWidth: .infinity).padding(.bottom, 2)
                OrbRule()
                VStack(alignment: .leading, spacing: 7) {
                    Text("Start command").font(.system(size: 12)).foregroundStyle(OrbTheme.secondary)
                    HStack {
                        Text("herdr").font(.system(size: 15, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button { SetupActions.copy((try? HerdrInstallation.resolve()).map(ConnectionCommands.quote) ?? "herdr") } label: { Label("Copy start command", systemImage: "doc.on.doc") }.buttonStyle(OrbButtonStyle(compact: true))
                    }.padding(10).background(OrbTheme.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(OrbTheme.line))
                    Text("Agent CLIs must be installed and signed in on the Mac where they run.").font(.system(size: 12)).foregroundStyle(OrbTheme.secondary)
                }
                HStack {
                    Link("Compatibility", destination: HerdrInstallation.compatibilityURL).foregroundStyle(OrbTheme.accent)
                    Spacer()
                    Button("Continue") { model.completeSetup() }.buttonStyle(OrbButtonStyle(kind: .primary)).disabled(!model.connection.values.contains(.online))
                }.padding(.vertical, 4)
                OrbRule()
                Text("herdrorb is an independent open-source companion for Herdr.").font(.system(size: 11)).foregroundStyle(OrbTheme.muted)
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $selectedDevice) { DeviceConnectionSettings(model: model, machine: $0) }
        .task {
            while !Task.isCancelled && model.showingSetup {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                guard model.panelVisible, !model.isDemo, !AppPreferences.isSetupPreview else { continue }
                await model.refresh()
            }
        }
    }
    @ViewBuilder private var setupActions: some View {
        Link(destination: HerdrInstallation.installURL) {
            Label("Install Herdr", systemImage: "arrow.down.to.line").frame(minWidth: 114)
        }.buttonStyle(OrbButtonStyle(kind: .primary))
        Button { SetupActions.locate(model) } label: {
            Label("Locate Herdr…", systemImage: "magnifyingglass").frame(minWidth: 114)
        }.buttonStyle(OrbButtonStyle())
        Button { Task { await model.refresh() } } label: {
            Text(model.refreshing ? "Checking…" : "Check again").frame(minWidth: 114)
        }.buttonStyle(OrbButtonStyle()).disabled(model.refreshing)
    }

}

struct DeviceConnectionSettings: View {
    @ObservedObject var model: BubbleModel
    let machine: Machine
    @Environment(\.dismiss) private var dismiss
    @State private var executable = ""
    @State private var projects = false
    @State private var testing = false
    @State private var error: String?
    var body: some View {
        OrbSheet(width: 580) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 18) {
                    Image(systemName: machine.id == "local" ? "laptopcomputer" : "desktopcomputer").font(.system(size: 27, weight: .light))
                        .frame(width: 57, height: 57).background(OrbTheme.surface, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(OrbTheme.controlEdge, lineWidth: 0.75))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(machine.label).font(.system(size: 24, weight: .semibold))
                        OrbStatus(text: (model.connection[machine.id] ?? .connecting).rawValue, color: model.connection[machine.id] == .online ? OrbTheme.online : OrbTheme.warning)
                    }
                }
                OrbRule()
                if let detail = model.connectionDetails[machine.id], model.connection[machine.id] != .online { Text(detail).font(.system(size: 13)).foregroundStyle(OrbTheme.warning).textSelection(.enabled) }
                VStack(alignment: .leading, spacing: 10) {
                    Text(machine.id == "local" ? "Herdr executable on this Mac" : "Herdr executable on the remote Mac").foregroundStyle(OrbTheme.secondary)
                    OrbField(placeholder: "Automatic discovery", text: $executable, label: "Herdr executable path")
                    Text("Leave blank to search common installation locations and PATH. Custom paths must be absolute.").font(.system(size: 12)).foregroundStyle(OrbTheme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if machine.id == "local" { Button("Locate…") { SetupActions.locate(model) { executable = $0 } }.buttonStyle(OrbButtonStyle()) }
                    Button {
                        testing = true; error = nil
                        Task {
                            defer { testing = false }
                            if model.isDemo {
                                await model.checkAgents(machine)
                                return
                            }
                            let path = executable.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard path.isEmpty || (path.hasPrefix("/") && !path.contains("\0") && !path.contains("\n")) else {
                                error = "Enter an absolute executable path, or leave it blank."; return
                            }
                            if machine.id == "local" && !path.isEmpty {
                                do { _ = try HerdrInstallation.resolve(override: path) }
                                catch { self.error = error.localizedDescription; return }
                            }
                            await model.setExecutable(path, for: machine)
                            if let updated = model.machines.first(where: { $0.id == machine.id }) { await model.testConnection(updated) }
                        }
                    } label: { Text(testing ? "Checking…" : "Save and test connection").frame(maxWidth: .infinity) }
                        .buttonStyle(OrbButtonStyle(kind: .primary)).disabled(testing)
                }
                if let error { Text(error).foregroundStyle(OrbTheme.warning).font(.system(size: 13)) }
                OrbRule()
                if let installed = model.availability[machine.id] {
                    VStack(spacing: 8) {
                        availability("Codex", found: installed.codex)
                        availability("Claude Code", found: installed.claude)
                    }
                }
                if let detail = model.availabilityErrors[machine.id] { Text(detail).font(.system(size: 12)).foregroundStyle(OrbTheme.warning) }
                Text("Sign in to your agent from its terminal. Executable discovery does not verify authentication.").font(.system(size: 12)).foregroundStyle(OrbTheme.secondary)
                if machine.id != "local" {
                    OrbRule()
                    Text("Remote access uses your saved Herdr profile and SSH configuration. Connect successfully in Terminal first, including verifying the host key and unlocking your SSH key. herdrorb never disables host-key checks.").font(.system(size: 12)).foregroundStyle(OrbTheme.secondary).fixedSize(horizontal: false, vertical: true)
                    Link(destination: URL(string: "https://github.com/andrewjedi/herdrorb/blob/main/docs/TROUBLESHOOTING.md")!) {
                        Label("Remote setup guide ↗", systemImage: "book")
                    }.foregroundStyle(OrbTheme.accent)
                }
                OrbRule()
                HStack(spacing: 10) {
                    Button { projects = true } label: { Label("Project folders…", systemImage: "folder") }.buttonStyle(OrbButtonStyle())
                    Button { SetupActions.copy(model.diagnostics) } label: { Label("Copy diagnostics", systemImage: "doc") }.buttonStyle(OrbButtonStyle())
                    Spacer()
                    Button("Done") { dismiss() }.buttonStyle(OrbButtonStyle(kind: .primary)).keyboardShortcut(.cancelAction)
                }
            }
        }
        .onAppear { executable = machine.id == "local" ? model.preferences.string(forKey: "herdrExecutable") ?? "" : machine.executablePath ?? "" }
        .sheet(isPresented: $projects) { DeviceProjectSettings(model: model, machine: machine) }
    }
    private func availability(_ title: String, found: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "terminal").font(.system(size: 20, weight: .light)); Text(title)
            Spacer()
            Image(systemName: found ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(found ? OrbTheme.online : OrbTheme.warning)
            Text(found ? "Found" : "Not found").foregroundStyle(OrbTheme.secondary)
        }.padding(12).background(OrbTheme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(OrbTheme.line))
    }
}

struct LaunchRecovery: View {
    @ObservedObject var model: BubbleModel
    let machine: Machine
    var body: some View {
        if let failed = model.failedLaunches[machine.id] {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 23)).foregroundStyle(OrbTheme.warning)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Agent startup needs attention").font(.system(size: 15, weight: .semibold)).foregroundStyle(OrbTheme.warning)
                    Text(failed.detail).font(.system(size: 13)).textSelection(.enabled)
                    Text("Open the existing terminal to finish sign-in or inspect the error. Check it before retrying; the original request may have reached Herdr.").font(.system(size: 12)).foregroundStyle(OrbTheme.secondary).lineSpacing(2)
                    HStack {
                        Button("Open terminal") { Task { await model.openRecoveryTerminal(machine) } }.buttonStyle(OrbButtonStyle(kind: .primary, compact: true))
                        Button("Retry in this terminal") { Task { await model.retryLaunch(machine) } }.buttonStyle(OrbButtonStyle(compact: true)).disabled(model.launching)
                    }
                }
            }.padding(14).background(OrbTheme.warning.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(OrbTheme.warning.opacity(0.8), lineWidth: 0.8))
        }
    }
}
