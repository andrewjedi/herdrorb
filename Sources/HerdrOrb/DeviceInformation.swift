import Foundation
import Combine

struct DeviceInformation: Equatable {
    var hostname: String?
    var systemName: String?
    var operatingSystem: String?
    var lanAddresses: [String] = []
    var tailscaleName: String?
    var tailscaleAddresses: [String] = []
    var tailscaleState = "Unavailable"
    var publicURLs: [String] = []
    var funnelChecked = false
    var updatedAt = Date()

    static func system(_ data: Data) -> DeviceInformation {
        var info = DeviceInformation()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            switch parts[0] {
            case "hostname": info.hostname = value
            case "name": info.systemName = value
            case "os": info.operatingSystem = value
            case "lan": if !info.lanAddresses.contains(value) { info.lanAddresses.append(value) }
            default: break
            }
        }
        return info
    }

    mutating func applyTailscale(_ data: Data) throws {
        struct Status: Decodable {
            struct Node: Decodable { var DNSName: String?; var TailscaleIPs: [String]? }
            var BackendState: String
            var currentNode: Node?
            enum CodingKeys: String, CodingKey { case BackendState; case currentNode = "Self" }
        }
        let status = try JSONDecoder().decode(Status.self, from: data)
        tailscaleState = status.BackendState
        tailscaleName = status.currentNode?.DNSName?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if tailscaleName == "" { tailscaleName = nil }
        tailscaleAddresses = status.currentNode?.TailscaleIPs ?? []
    }

    mutating func applyFunnel(_ data: Data) throws {
        guard let config = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RPCError(code: "format", message: "Unknown Funnel status format")
        }
        publicURLs = Self.funnelURLs(config)
        funnelChecked = true
    }

    // Only HTTPS web listeners explicitly enabled for Funnel are public URLs.
    // Private Serve listeners and raw TCP forwards are not website URLs.
    static func funnelURLs(_ config: [String: Any]) -> [String] {
        let allowed = config["AllowFunnel"] as? [String: Bool] ?? [:]
        let web = config["Web"] as? [String: Any] ?? [:]
        let tcp = config["TCP"] as? [String: [String: Any]] ?? [:]
        var urls: [String] = []
        for (hostPort, enabled) in allowed where enabled && web[hostPort] != nil {
            guard var url = URLComponents(string: "https://" + hostPort),
                  let host = url.host, host.hasSuffix(".ts.net"), let port = url.port,
                  tcp[String(port)]?["HTTPS"] as? Bool == true,
                  url.user == nil, url.password == nil, url.path.isEmpty,
                  url.query == nil, url.fragment == nil else { continue }
            if port == 443 { url.port = nil }
            if let value = url.string { urls.append(value) }
        }
        for child in (config["Foreground"] as? [String: [String: Any]] ?? [:]).values {
            urls += funnelURLs(child)
        }
        return Array(Set(urls)).sorted()
    }
}

enum DeviceInformationProbe {
    static let systemScript = #"""
    printf 'hostname\t%s\n' "$(hostname)"
    if command -v sw_vers >/dev/null 2>&1; then
      printf 'name\t%s\n' "$(scutil --get ComputerName 2>/dev/null)"
      printf 'os\t%s %s · %s\n' "$(sw_vers -productName)" "$(sw_vers -productVersion)" "$(uname -m)"
    else
      printf 'os\t%s\n' "$(uname -srm)"
    fi
    if command -v ip >/dev/null 2>&1; then
      ip -o -4 addr show scope global 2>/dev/null | awk '$2 !~ /^(lo|tailscale|tun|utun|docker|veth)/ {split($4,a,"/"); printf "lan\t%s (%s)\n", a[1], $2}'
    else
      /sbin/ifconfig 2>/dev/null | awk '/^[a-zA-Z0-9]/ {iface=$1; sub(/:$/, "", iface)} $1 == "inet" && iface !~ /^(lo|utun|tun|tailscale)/ && $2 !~ /^(127\.|169\.254\.)/ {printf "lan\t%s (%s)\n", $2, iface}'
    fi
    """#

    static func run(_ script: String, on machine: Machine) async throws -> Data {
        let script = "PATH=\"\(ConnectionCommands.searchPath):/usr/sbin:/sbin\"; export PATH\n" + script
        if machine.id == "local" { return try await ProcessRunner.run("/bin/sh", ["-c", script], timeout: 8) }
        return try await ProcessRunner.run("/usr/bin/ssh", ConnectionCommands.sshOptions + [try ConnectionCommands.target(machine), ConnectionCommands.shell(script, arguments: [])], timeout: 8)
    }

    static func tailscale(_ command: String, on machine: Machine) async throws -> Data {
        let script = #"""
        candidate=$(command -v tailscale)
        if [ -z "$candidate" ] && [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
          candidate=/Applications/Tailscale.app/Contents/MacOS/Tailscale
        fi
        [ -n "$candidate" ] || exit 127
        exec "$candidate" \#(command)
        """#
        return try await run(script, on: machine)
    }
}

@MainActor final class DeviceInformationStore: ObservableObject {
    @Published var values: [String: DeviceInformation] = [:]
    @Published var loading: Set<String> = []
    @Published var errors: [String: String] = [:]
    private var attempts: [String: Date] = [:]

    func refresh(_ machine: Machine, demo: Bool) async {
        let key = machine.identity
        guard !loading.contains(key), attempts[key].map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return }
        if demo {
            values[key] = DeviceInformation(hostname: "studio-mac.local", systemName: machine.label,
                operatingSystem: "macOS 15.0 · arm64", lanAddresses: ["192.168.1.42 (en0)"],
                tailscaleName: "studio-mac.example.ts.net", tailscaleAddresses: ["100.80.10.42"],
                tailscaleState: "Running", funnelChecked: true)
            return
        }
        attempts[key] = Date()
        loading.insert(key)
        defer { loading.remove(key) }
        do {
            var info = DeviceInformation.system(try await DeviceInformationProbe.run(DeviceInformationProbe.systemScript, on: machine))
            guard info.hostname != nil else { throw RPCError(code: "discovery", message: "Device details unavailable") }
            values[key] = info
            errors[key] = nil
            // Independent read-only probes have separate deadlines, so a missing or
            // unresponsive Tailscale installation cannot hide system information.
            async let status = try? DeviceInformationProbe.tailscale("status --json", on: machine)
            async let funnel = try? DeviceInformationProbe.tailscale("funnel status --json", on: machine)
            if let data = await status { try? info.applyTailscale(data) }
            if let data = await funnel { try? info.applyFunnel(data) }
            try Task.checkCancellation()
            info.updatedAt = Date()
            values[key] = info
        } catch is CancellationError {
            attempts[key] = nil
        } catch {
            errors[key] = "Couldn’t refresh device details. Cached information may be out of date."
        }
    }
}
