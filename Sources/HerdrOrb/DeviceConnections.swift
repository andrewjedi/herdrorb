import AppKit
import SwiftUI
import Combine

/// Tailnet presence is observed locally, independently of Herdr and remote SSH.
struct TailnetSnapshot: Decodable {
    struct Node: Decodable {
        var DNSName: String?
        var HostName: String?
        var TailscaleIPs: [String]?
        var Online: Bool?
    }
    var BackendState: String
    var Peer: [String: Node]?
    var currentNode: Node?
    enum CodingKeys: String, CodingKey { case BackendState, Peer; case currentNode = "Self" }

    func state(host: String?, local: Bool) -> TailnetPresence {
        guard BackendState == "Running" else { return .unavailable }
        if local { return currentNode == nil ? .unknown : .online }
        guard let host else { return .unknown }
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[]"))
        let matches = (Peer ?? [:]).values.filter { node in
            let dns = (node.DNSName ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return node.TailscaleIPs?.contains(normalized) == true || dns == normalized ||
                (!normalized.contains(".") && (dns.split(separator: ".").first.map(String.init) == normalized || node.HostName?.lowercased() == normalized))
        }
        guard matches.count == 1, let online = matches.first?.Online else { return .unknown }
        return online ? .online : .offline
    }
}

enum TailnetPresence: String {
    case online = "Connected", offline = "Offline", unknown = "Not identified", unavailable = "Unavailable", checking = "Checking…"
    var color: Color { self == .online ? OrbTheme.online : self == .offline ? OrbTheme.warning : OrbTheme.secondary }
    var detail: String {
        switch self {
        case .online: return "Tailscale reports this device online. SSH access is checked when you connect."
        case .offline: return "Tailscale reports this device offline. It may be asleep or powered off."
        case .unknown: return "The saved SSH host could not be matched to one Tailscale device."
        case .unavailable: return "Local Tailscale status is unavailable. SSH may still work over another network."
        case .checking: return "Checking this Mac’s Tailscale network…"
        }
    }
}

@MainActor final class DeviceConnections: ObservableObject {
    @Published var presence: [String: TailnetPresence] = [:]
    func refresh(_ machines: [Machine], demo: Bool) async {
        if demo {
            for machine in machines { presence[machine.identity] = .online }
            return
        }
        let data = try? await DeviceInformationProbe.tailscale("status --json", on: .local)
        let snapshot = data.flatMap { try? JSONDecoder().decode(TailnetSnapshot.self, from: $0) }
        for machine in machines {
            guard !Task.isCancelled else { return }
            var host = machine.target?.split(separator: "@").last.map(String.init)
            if machine.id != "local", let target = try? ConnectionCommands.target(machine),
               let config = try? await ProcessRunner.run("/usr/bin/ssh", ["-G", target], timeout: 3) {
                host = String(decoding: config, as: UTF8.self).split(separator: "\n")
                    .first(where: { $0.hasPrefix("hostname ") }).map { String($0.dropFirst(9)) } ?? host
            }
            presence[machine.identity] = snapshot?.state(host: host, local: machine.id == "local") ?? .unavailable
        }
    }
}

/// Shell command used by the embedded terminal’s PTY.
enum DeviceTerminal {
    static func command(_ machine: Machine, startHerdr: Bool) throws -> String {
        if machine.id == "local" {
            guard startHerdr else { return "exec /bin/zsh -l" }
            var local = machine
            local.executablePath = try HerdrInstallation.resolve()
            return ConnectionCommands.herdr(local, arguments: [])
        }
        let args = ["/usr/bin/ssh", "-tt", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", try ConnectionCommands.target(machine)]
            + (startHerdr ? [ConnectionCommands.herdr(machine, arguments: [])] : [])
        return args.map(ConnectionCommands.quote).joined(separator: " ")
    }


}

struct DeviceConnectionDots: View {
    let herdr: ConnectionState
    let tailscale: TailnetPresence
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(herdr == .online ? OrbTheme.online : OrbTheme.warning)
                .help("Herdr: \(herdr.rawValue)")
            Circle().fill(tailscale.color).help("Tailscale: \(tailscale.rawValue). \(tailscale.detail)")
        }.frame(width: 18, height: 7)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Herdr: \(herdr.rawValue). Tailscale: \(tailscale.rawValue)")
    }
}

struct DeviceOverview: View {
    @ObservedObject var model: BubbleModel
    let machine: Machine
    let tailscale: TailnetPresence
    var newAgent: () -> Void
    var openTerminal: (Bool) -> Void
    var settings: () -> Void
    private var herdr: ConnectionState { model.connection[machine.id] ?? .connecting }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Image(systemName: machine.id == "local" ? "laptopcomputer" : "desktopcomputer")
                        .font(.system(size: 30, weight: .light)).foregroundStyle(OrbTheme.accent)
                        .frame(width: 58, height: 58).background(OrbTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(machine.label).font(.system(size: 23, weight: .semibold))
                        Text("Agents, terminals, and connections").font(.system(size: 12)).foregroundStyle(OrbTheme.secondary)
                    }
                    Spacer()
                    Button(action: settings) { Image(systemName: "gearshape").font(.system(size: 16)) }
                        .buttonStyle(.plain).help("Device settings").accessibilityLabel("Device settings")
                }
                HStack(spacing: 10) {
                    connection("Herdr", value: herdr == .online ? "Connected" : herdr.rawValue, color: herdr == .online ? OrbTheme.online : OrbTheme.warning)
                        .help(model.connectionDetails[machine.id] ?? "Manages your agent sessions.")
                    connection("Tailscale", value: tailscale.rawValue, color: tailscale.color).help(tailscale.detail)
                }
                VStack(spacing: 10) {
                    action("New agent", subtitle: "Start a Codex or Claude Code session in your chosen folder.", icon: "sparkles", enabled: herdr == .online && !model.launching, perform: newAgent)
                    action("Start a new Herdr session", subtitle: "Open Herdr in an embedded terminal on this device.", icon: "bubble.left.and.bubble.right", enabled: herdr == .online || herdr == .stopped) {
                        openTerminal(true)
                    }
                    action("Start a new terminal session", subtitle: machine.id == "local" ? "Open a local shell here in the app." : "Open an SSH terminal here. Herdr isn’t required.", icon: "terminal", enabled: machine.id == "local" || machine.target != nil) {
                        openTerminal(false)
                    }
                }
                if herdr != .online {
                    Text(model.connectionDetails[machine.id] ?? "Herdr is unavailable. You can still try a direct terminal connection.")
                        .font(.system(size: 12)).foregroundStyle(OrbTheme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text(machine.id == "local" ? "Terminal sessions stay open as you switch views. Closing a session or quitting the app ends its shell." : "SSH uses your saved host and credentials, including Tailscale when configured. The device must be awake and allow SSH.")
                    .font(.system(size: 11)).foregroundStyle(OrbTheme.secondary).fixedSize(horizontal: false, vertical: true)
                LaunchRecovery(model: model, machine: machine)
            }.padding(28).frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func connection(_ title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(OrbTheme.secondary)
            HStack(spacing: 7) { Circle().fill(color).frame(width: 7, height: 7); Text(value).font(.system(size: 12, weight: .medium)) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(15)
            .background(OrbTheme.raised, in: RoundedRectangle(cornerRadius: 12))
    }
    private func action(_ title: String, subtitle: String, icon: String, enabled: Bool, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 20, weight: .light)).foregroundStyle(OrbTheme.accent).frame(width: 28)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 14, weight: .medium))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(OrbTheme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(OrbTheme.secondary)
            }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
                .background(OrbTheme.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(OrbTheme.line, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.45)
    }
}
