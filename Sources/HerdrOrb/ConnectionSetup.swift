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
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "circle.hexagongrid.fill").font(.system(size: 34)).foregroundStyle(.purple)
                Text("Welcome to herdrorb").font(.system(size: 24, weight: .semibold))
                Text("Your Herdr sessions, a click away. Connect to Herdr on this Mac or one of your saved machines.")
                    .foregroundStyle(.secondary)
                ForEach(model.machines.isEmpty ? [.local] : model.machines) { machine in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(machine.label, systemImage: machine.id == "local" ? "desktopcomputer" : "network")
                            Spacer()
                            Text((model.connection[machine.id] ?? .connecting).rawValue)
                                .foregroundStyle(model.connection[machine.id] == .online ? Color.green : .orange)
                        }.font(.system(size: 13, weight: .medium))
                        if let detail = model.connectionDetails[machine.id] {
                            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if let version = model.herdrVersions[machine.id] {
                            Text("Herdr \(version)").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Button("Connection settings…") { selectedDevice = machine }.buttonStyle(.link)
                    }.padding(14).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                }
                HStack {
                    Link("Install Herdr", destination: HerdrInstallation.installURL)
                    Button("Locate Herdr…") { SetupActions.locate(model) }
                    Button(model.refreshing ? "Checking…" : "Check again") { Task { await model.refresh() } }
                        .disabled(model.refreshing)
                }.font(.system(size: 12))
                Text("To start Herdr, run herdr in Terminal. Its background server keeps sessions alive after you detach. Agent CLIs must be installed and signed in on the machine where they run.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                HStack {
                    Button("Copy start command") { SetupActions.copy((try? HerdrInstallation.resolve()).map(ConnectionCommands.quote) ?? "herdr") }
                    Link("Compatibility", destination: HerdrInstallation.compatibilityURL)
                    Spacer()
                    Button("Continue") { model.completeSetup() }
                        .buttonStyle(.borderedProminent).tint(.purple)
                        .disabled(!model.connection.values.contains(.online))
                }.font(.system(size: 12))
                Text("herdrorb is an independent open-source companion for Herdr.").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 16) {
            Text(machine.label).font(.title2.weight(.semibold))
            Label((model.connection[machine.id] ?? .connecting).rawValue,
                  systemImage: model.connection[machine.id] == .online ? "checkmark.circle" : "exclamationmark.circle")
            if let detail = model.connectionDetails[machine.id] { Text(detail).font(.callout).textSelection(.enabled) }
            Text(machine.id == "local" ? "Herdr executable on this Mac" : "Herdr executable on the remote Mac").font(.headline)
            TextField("Automatic discovery", text: $executable).textFieldStyle(.roundedBorder)
            Text("Leave blank to search common installation locations and PATH. Custom paths must be absolute.").font(.caption).foregroundStyle(.secondary)
            HStack {
                if machine.id == "local" { Button("Locate…") { SetupActions.locate(model) { executable = $0 } } }
                Button(testing ? "Checking…" : "Save and test connection") {
                    testing = true; error = nil
                    Task {
                        defer { testing = false }
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
                }.disabled(testing || model.isDemo)
            }
            if let error { Text(error).foregroundStyle(.orange).font(.callout) }
            if let installed = model.availability[machine.id] {
                Text("Codex: \(installed.codex ? "found" : "not found") · Claude Code: \(installed.claude ? "found" : "not found")").font(.callout)
            }
            if let detail = model.availabilityErrors[machine.id] { Text(detail).font(.caption).foregroundStyle(.orange) }
            Text("Sign in to your agent from its terminal. Executable discovery does not verify authentication.").font(.caption).foregroundStyle(.secondary)
            if machine.id != "local" {
                Text("Remote access uses your saved Herdr profile and SSH configuration. Connect successfully in Terminal first, including verifying the host key and unlocking your SSH key. herdrorb never disables host-key checks.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Remote setup guide", destination: URL(string: "https://github.com/andrewjedi/herdrorb/blob/main/docs/TROUBLESHOOTING.md")!)
            }
            Divider()
            HStack {
                Button("Project folders…") { projects = true }.disabled(model.isDemo)
                Button("Copy diagnostics") { SetupActions.copy(model.diagnostics) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 530)
        .onAppear {
            executable = machine.id == "local" ? model.preferences.string(forKey: "herdrExecutable") ?? "" : machine.executablePath ?? ""
        }
        .sheet(isPresented: $projects) { DeviceProjectSettings(model: model, machine: machine) }
    }
}

struct LaunchRecovery: View {
    @ObservedObject var model: BubbleModel
    let machine: Machine
    var body: some View {
        if let failed = model.failedLaunches[machine.id] {
            VStack(alignment: .leading, spacing: 8) {
                Text("Agent startup needs attention").font(.headline)
                Text(failed.detail).font(.callout).textSelection(.enabled)
                Text("Open the existing terminal to finish sign-in or inspect the error. Check it before retrying; the original request may have reached Herdr.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Open terminal") { Task { await model.openRecoveryTerminal(machine) } }
                    Button("Retry in this terminal") { Task { await model.retryLaunch(machine) } }.disabled(model.launching)
                }
            }.padding(14).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
