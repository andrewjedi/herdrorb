import SwiftUI
import AppKit

struct DeviceHoverDetails: ViewModifier {
    @ObservedObject var model: BubbleModel
    @ObservedObject var information: DeviceInformationStore
    let machine: Machine
    var tailscale: TailnetPresence = .checking
    @State private var presented = false
    @State private var overRow = false
    @State private var overCard = false
    @State private var opening: Task<Void, Never>?
    @State private var closing: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                overRow = inside
                opening?.cancel()
                if inside {
                    closing?.cancel()
                    opening = Task { @MainActor in
                        do { try await Task.sleep(for: .seconds(1.8)) } catch { return }
                        guard overRow else { return }
                        presented = true
                    }
                } else { scheduleClose() }
            }
            .accessibilityAction(named: Text("Show device information")) { presented = true }
            .contextMenu { Button("Device information") { presented = true } }
            .popover(isPresented: $presented, arrowEdge: .trailing) {
                DeviceHoverCard(model: model, information: information, machine: machine, tailscale: tailscale)
                    .onHover { inside in
                        overCard = inside
                        if inside { closing?.cancel() } else { scheduleClose() }
                    }
                    .task {
                        await information.refresh(machine, demo: model.isDemo)
                    }
            }
            .onChange(of: presented) { _, visible in if !visible { overCard = false } }
            .onDisappear { opening?.cancel(); closing?.cancel(); presented = false }
    }

    private func scheduleClose() {
        closing?.cancel()
        closing = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            if !overRow && !overCard { presented = false }
        }
    }
}

struct DeviceHoverCard: View {
    @ObservedObject var model: BubbleModel
    @ObservedObject var information: DeviceInformationStore
    let machine: Machine
    var tailscale: TailnetPresence = .checking
    private var info: DeviceInformation? { information.values[machine.identity] }
    private var loading: Bool { information.loading.contains(machine.identity) }
    private var sessions: [Agent] { model.activeSessions.filter { $0.machineID == machine.id } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: machine.id == "local" ? "laptopcomputer" : "desktopcomputer")
                        .font(.system(size: 23)).foregroundStyle(OrbTheme.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(machine.label).font(.system(size: 16, weight: .semibold))
                        Text((model.connection[machine.id] ?? .connecting).rawValue)
                            .foregroundStyle(model.connection[machine.id] == .online ? OrbTheme.online : OrbTheme.warning)
                    }
                    Spacer()
                    if loading { ProgressView().controlSize(.small).accessibilityLabel("Refreshing device information") }
                }
                if let detail = model.connectionDetails[machine.id], model.connection[machine.id] != .online {
                    Text(detail).font(.system(size: 11)).foregroundStyle(OrbTheme.warning).textSelection(.enabled)
                }
                Divider()
                field("System name", info?.systemName)
                field("Hostname", info?.hostname, copy: true)
                field("System", info?.operatingSystem)
                field("Connection", machine.id == "local" ? "Local device" : "SSH")
                if machine.id != "local" { field("SSH target", machine.target, copy: true) }
                Divider()
                field("LAN IPv4", joined(info?.lanAddresses), copy: true, copyValue: joined(info?.lanAddresses.map { String($0.prefix { !$0.isWhitespace }) }))
                field("Tailscale", tailscale.rawValue)
                Text(tailscale.detail).font(.system(size: 10)).foregroundStyle(OrbTheme.secondary)
                field("Private DNS", info?.tailscaleName, copy: true)
                field("Tailscale IP", joined(info?.tailscaleAddresses), copy: true)
                field("Public Funnel", joined(info?.publicURLs) ?? (info?.funnelChecked == true ? "Not configured" : nil), copy: !(info?.publicURLs.isEmpty ?? true))
                if !(info?.publicURLs.isEmpty ?? true) {
                    Text("Configured public URLs; reachability has not been tested.").font(.system(size: 10)).foregroundStyle(OrbTheme.secondary)
                }
                Divider()
                field("Sessions", "\(sessions.count) · \(sessions.filter { $0.agent_status == "blocked" || model.state($0).unread }.count) need attention")
                field("Herdr", model.herdrVersions[machine.id])
                if let agents = model.availability[machine.id] {
                    field("Codex", agents.codex ? "Installed" : "Not found")
                    field("Claude Code", agents.claude ? "Installed" : "Not found")
                } else {
                    field("Codex", nil)
                    field("Claude Code", nil)
                }
                if let error = information.errors[machine.identity] {
                    Text(error).font(.system(size: 11)).foregroundStyle(OrbTheme.warning)
                }
                if let updated = info?.updatedAt {
                    HStack(spacing: 3) {
                        Text("Details updated")
                        Text(updated, style: .relative)
                        Text("ago")
                    }.font(.system(size: 10)).foregroundStyle(OrbTheme.secondary)
                } else if !loading {
                    Text("Connect to this device to discover its details.").font(.system(size: 11)).foregroundStyle(OrbTheme.secondary)
                }
            }.padding(18)
        }
        .frame(width: 380, height: 490)
        .background(OrbTheme.canvas)
        .foregroundStyle(OrbTheme.text)
        .task { if model.connection[machine.id] == .online { await model.checkAgents(machine) } }
    }

    private func joined(_ values: [String]?) -> String? {
        guard let values, !values.isEmpty else { return nil }
        return values.joined(separator: "\n")
    }

    private func field(_ title: String, _ value: String?, copy: Bool = false, copyValue: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title).foregroundStyle(OrbTheme.secondary).frame(width: 92, alignment: .leading)
            Text(value ?? (loading ? "Checking…" : "Unavailable"))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if copy, let value {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyValue ?? value, forType: .string)
                } label: { Image(systemName: "doc.on.doc").foregroundStyle(OrbTheme.secondary) }
                    .buttonStyle(.plain).help("Copy \(title.lowercased())")
                    .accessibilityLabel("Copy \(title.lowercased())")
            }
        }.font(.system(size: 11))
    }
}
