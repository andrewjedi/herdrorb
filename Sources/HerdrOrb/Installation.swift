import Foundation

enum AppPreferences {
    static let bundleID = "io.github.andrewjedi.herdrorb"
    static let isDemo = CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains("--render-previews")
    static let isSetupPreview = CommandLine.arguments.contains("--setup-preview")
    private static let previewSuite = bundleID + ".preview." + UUID().uuidString
    static let current: UserDefaults = (isDemo || isSetupPreview)
        ? UserDefaults(suiteName: previewSuite)! : .standard

    static func prepare() {
        if isDemo || isSetupPreview { current.removePersistentDomain(forName: previewSuite) }
        if !isDemo && !isSetupPreview {
            migrate(into: current)
            migrateStorage()
        }
        current.register(defaults: ["saveConversations": true, "automaticImagePreviews": true,
                                    "showOrb": true, "orbHoverSound": true, "orbStatusDot": true])
    }
    static func cleanUpPreview() {
        guard isDemo || isSetupPreview else { return }
        current.removePersistentDomain(forName: previewSuite)
    }
    static func migrateStorage(fileManager: FileManager = .default) {
        for location: FileManager.SearchPathDirectory in [.applicationSupportDirectory, .cachesDirectory] {
            let marker = "migratedStorage.\(location.rawValue)"
            guard !current.bool(forKey: marker), let base = fileManager.urls(for: location, in: .userDomainMask).first else { continue }
            let old = base.appendingPathComponent("HerdrBubble"), new = base.appendingPathComponent("herdrorb")
            if fileManager.fileExists(atPath: old.path) && !fileManager.fileExists(atPath: new.path) {
                do { try fileManager.moveItem(at: old, to: new) }
                catch { Metrics.logger.error("Legacy data migration could not finish; original data was preserved"); continue }
            }
            current.set(true, forKey: marker)
        }
    }
    static func migrate(into preferences: UserDefaults, legacy: [String: Any]? = nil) {
        guard !preferences.bool(forKey: "publicPreferencesMigrationV1") else { return }
        let old = legacy ?? preferences.persistentDomain(forName: "local.andrew.HerdrBubble") ?? [:]
        let keys = ["showOrb", "orbHoverSound", "orbStatusDot", "orbStyle", "orbPosition", "glassPanelHeight",
                    "automaticallyScrollToNewMessages", "projectFolders", "lastMachine", "lastSession",
                    "sessionDisplayNames", "syncedSessionNames", "nextSessionNumber", "compactMenuItemV1"]
        for key in keys where preferences.object(forKey: key) == nil {
            if let value = old[key] { preferences.set(value, forKey: key) }
        }
        preferences.set(true, forKey: "publicPreferencesMigrationV1")
    }
}

enum ConnectionState: String, Codable {
    case connecting = "Connecting", reconnecting = "Reconnecting", online = "Online"
    case missing = "Herdr not found", stopped = "Herdr stopped", incompatible = "Incompatible"
    case authentication = "SSH access required", hostKey = "SSH host key needs attention"
    case offline = "Offline"
    static func failure(_ error: Error) -> ConnectionState {
        switch (error as? RPCError)?.code {
        case "missing", "executable": return .missing
        case "stopped": return .stopped
        case "incompatible": return .incompatible
        case "authentication": return .authentication
        case "host_key": return .hostKey
        default: return .offline
        }
    }
}

enum HerdrInstallation {
    static let supportedProtocol = 22
    static let testedVersion = "0.9.1"
    static let installURL = URL(string: "https://github.com/herdrdev/herdr#install")!
    static let compatibilityURL = URL(string: "https://github.com/andrewjedi/herdrorb/blob/main/docs/COMPATIBILITY.md")!

    static func resolve(override: String? = AppPreferences.current.string(forKey: "herdrExecutable"),
                        home: String = NSHomeDirectory(), path: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
                        executable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) throws -> String {
        if let override, !override.isEmpty {
            guard override.hasPrefix("/"), !override.contains("\0"), !override.contains("\n"), executable(override) else {
                throw RPCError(code: "executable", message: "The selected Herdr executable is unavailable. Locate Herdr again or use automatic discovery.")
            }
            return override
        }
        let candidates = ["/opt/homebrew/bin/herdr", "/usr/local/bin/herdr", home + "/.local/bin/herdr",
                          home + "/.cargo/bin/herdr", home + "/.local/share/mise/shims/herdr"]
            + path.split(separator: ":").filter { $0.hasPrefix("/") }.map { String($0) + "/herdr" }
        guard let found = candidates.first(where: executable) else {
            throw RPCError(code: "missing", message: "herdrorb requires Herdr. Please install Herdr and start it, then choose Check again.")
        }
        return found
    }

    struct Status: Decodable, Equatable {
        struct Client: Decodable, Equatable { var version: String?; var `protocol`: Int? }
        struct Server: Decodable, Equatable { var running: Bool; var version: String?; var `protocol`: Int?; var socket: String? }
        var client: Client?
        var server: Server
        static func decode(_ data: Data) throws -> Status {
            do { return try JSONDecoder().decode(Status.self, from: data) }
            catch { throw RPCError(code: "incompatible", message: "Herdr returned an unsupported status format. This release is tested with Herdr \(testedVersion), protocol \(supportedProtocol).") }
        }
        func socketPath(machine: String) throws -> String {
            guard server.running else { throw RPCError(code: "stopped", message: "Herdr is installed but its server is not running on \(machine). Start herdr in Terminal, then check again.") }
            if let clientProtocol = client?.protocol, clientProtocol != supportedProtocol {
                throw RPCError(code: "incompatible", message: "The Herdr CLI reports protocol \(clientProtocol). This release supports protocol \(supportedProtocol); use a compatible CLI and server.")
            }
            guard server.protocol == supportedProtocol else {
                throw RPCError(code: "incompatible", message: "Herdr on \(machine) reports protocol \(server.protocol.map(String.init) ?? "unknown"). This release supports protocol \(supportedProtocol) and is tested with Herdr \(testedVersion).")
            }
            guard let socket = server.socket, socket.hasPrefix("/"), !socket.contains("\0"), !socket.contains("\n") else {
                throw RPCError(code: "incompatible", message: "Herdr did not return a valid server socket.")
            }
            return socket
        }
    }
}

/// All remote commands enter a POSIX shell explicitly; values are positional arguments.
enum ConnectionCommands {
    static let sshOptions = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2"]
    static func target(_ machine: Machine) throws -> String {
        guard let target = machine.target, !target.isEmpty, !target.hasPrefix("-"),
              !target.contains(where: { $0.isWhitespace || $0 == "\0" }) else {
            throw RPCError(code: "profile", message: "This device has an invalid SSH target. Update its profile in Herdr.")
        }
        return target
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func shell(_ script: String, arguments: [String]) -> String {
        (["/bin/sh", "-c", script, "herdr-bubble"] + arguments).map(quote).joined(separator: " ")
    }
    static let searchPath = #"/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.local/share/mise/shims:${PATH:-/usr/bin:/bin}"#
    static func herdr(_ machine: Machine, arguments: [String]) -> String {
        let script = #"""
        candidate=$1; shift
        PATH="\#(searchPath)"; export PATH
        if [ -n "$candidate" ]; then
          case "$candidate" in /*) ;; *) echo 'HB_MISSING: Herdr path must be absolute' >&2; exit 127;; esac
          if [ ! -x "$candidate" ]; then echo 'HB_MISSING: Selected Herdr executable is unavailable' >&2; exit 127; fi
        else
          candidate=$(command -v herdr) || { echo 'HB_MISSING: Herdr is not installed; install it or configure its executable path' >&2; exit 127; }
        fi
        exec "$candidate" "$@"
        """#
        return shell(script, arguments: [machine.executablePath ?? "", "--session", machine.session ?? "default"] + arguments)
    }
    static func environment(_ source: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = source
        result["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.cargo/bin",
                          NSHomeDirectory() + "/.local/share/mise/shims", source["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
        return result
    }
}

struct AgentAvailability: Equatable {
    var codex: Bool
    var claude: Bool
    func contains(_ kind: String) -> Bool { kind == "codex" ? codex : kind == "claude" && claude }
    static func check(_ machine: Machine) async throws -> AgentAvailability {
        let script = #"""
        PATH="\#(ConnectionCommands.searchPath)"; export PATH
        for name in codex claude; do
          if command -v "$name" >/dev/null 2>&1; then printf '%s\n' "$name"; fi
        done
        """#
        let data: Data
        if machine.id == "local" { data = try await ProcessRunner.run("/bin/sh", ["-c", script]) }
        else { data = try await ProcessRunner.run("/usr/bin/ssh", ConnectionCommands.sshOptions + [try ConnectionCommands.target(machine), ConnectionCommands.shell(script, arguments: [])]) }
        let names = String(decoding: data, as: UTF8.self).split(separator: "\n")
        return AgentAvailability(codex: names.contains("codex"), claude: names.contains("claude"))
    }
}

enum Diagnostics {
    static func text(connections: [(ConnectionState, String?)], bundle: Bundle = .main) -> String {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let version = (bundle.object(forInfoDictionaryKey: "HerdrOrbReleaseVersion") ?? bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")) as? String ?? "development"
        var lines = ["herdrorb \(version)", "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)", "Architecture: \(architecture)",
                     "Supported Herdr protocol: \(HerdrInstallation.supportedProtocol)", "Tested Herdr: \(HerdrInstallation.testedVersion)"]
        for (index, item) in connections.enumerated() {
            // Only strictly numeric versions enter diagnostics; never copy server-controlled errors or labels.
            let version = item.1.flatMap { $0.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil ? $0 : nil } ?? "unknown"
            lines.append("Device \(index + 1): \(item.0.rawValue), Herdr \(version)")
        }
        lines.append("Names, paths, SSH targets, prompts and output omitted.")
        return lines.joined(separator: "\n")
    }
}
