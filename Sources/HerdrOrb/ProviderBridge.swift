import Foundation

/// A small standard-library helper on the machine that owns the CLI. Local log
/// reads use FileHandle; only remote reads and explicit integration setup spawn tools.
enum ProviderBridge {
    static func script() throws -> String {
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "provider_bridge", withExtension: "py") { return try String(contentsOf: url, encoding: .utf8) }
        #endif
        // Used by the repository's standalone swiftc regression runner.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources/provider_bridge.py")
        return try String(contentsOf: url, encoding: .utf8)
    }
    private static func run(_ arguments: [String], machine: Machine) async throws -> Data {
        let source = try script()
        if machine.id == "local" {
            return try await ProcessRunner.run("/usr/bin/env", ["python3", "-c", source] + arguments)
        }
        return try await RemoteTranscriptConnections.shared.request(arguments, machine: machine, source: source)
    }
    static func read(reference: ProviderSessionReference, cursor: TranscriptCursor, machine: Machine) async throws -> TranscriptChunk {
        struct Request: Encodable { let reference: ProviderSessionReference; let cursor: TranscriptCursor }
        let encoded = try JSONEncoder().encode(Request(reference: reference, cursor: cursor)).base64EncodedString()
        return try JSONDecoder().decode(TranscriptChunk.self, from: await run(["read", encoded], machine: machine))
    }
    static func claudeUsage(reference: ProviderSessionReference, machine: Machine) async throws -> ContextUsage? {
        guard let id = reference.sessionID else { return nil }
        let data: Data
        if machine.id == "local" {
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/herdrorb/provider-bridge/usage/\(id).json")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            data = try Data(contentsOf: file)
        } else { data = try await run(["usage", id], machine: machine) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return ContextUsage.claude(json, sessionID: id)
    }
    /// Installs a versioned helper and chains Claude's existing status line. Called
    /// only from the explicit Connect history/context action, or for a new session.
    static func connectClaude(machine: Machine, cwd: String) async throws {
        let source = try script()
        let encoded = Data(source.utf8).base64EncodedString()
        let bootstrap = """
        import base64,os,sys,subprocess
        root=os.path.expanduser('~/Library/Application Support/herdrorb/provider-bridge')
        os.makedirs(root,mode=0o700,exist_ok=True)
        path=os.path.join(root,'provider_bridge.py')
        with open(path+'.tmp','wb') as f:f.write(base64.b64decode(sys.argv[1]))
        os.chmod(path+'.tmp',0o700)
        os.replace(path+'.tmp',path)
        subprocess.run([sys.executable,path,'install',os.path.expanduser(sys.argv[2])],check=True)
        """
        if machine.id == "local" {
            _ = try await ProcessRunner.run("/usr/bin/env", ["python3", "-c", bootstrap, encoded, cwd])
        } else {
            let command = ConnectionCommands.shell(#"PATH="\#(ConnectionCommands.searchPath)"; export PATH; script=$1; shift; exec python3 -c "$script" "$@""#, arguments: [bootstrap, encoded, cwd])
            _ = try await ProcessRunner.run("/usr/bin/ssh", ConnectionCommands.sshOptions + [try ConnectionCommands.target(machine), command])
        }
    }
    static func connectCodex(machine: Machine) async throws {
        if machine.id == "local" { _ = try await HerdrClient.run(["integration", "install", "codex"]) }
        else { _ = try await ProcessRunner.run("/usr/bin/ssh", ConnectionCommands.sshOptions + [try ConnectionCommands.target(machine), MachineTransport.remoteCommand(machine, arguments: ["integration", "install", "codex"])]) }
    }
}
