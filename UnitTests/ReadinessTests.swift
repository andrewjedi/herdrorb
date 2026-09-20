import XCTest
@testable import HerdrOrb

final class ReadinessTests: XCTestCase {
    func testExecutableResolutionAndExplicitOverride() throws {
        let installed: Set<String> = ["/custom/bin/herdr", "/home/test/.cargo/bin/herdr"]
        XCTAssertEqual(try HerdrInstallation.resolve(override: nil, home: "/home/test", path: "/custom/bin", executable: installed.contains), "/home/test/.cargo/bin/herdr")
        XCTAssertEqual(try HerdrInstallation.resolve(override: "/custom/bin/herdr", executable: installed.contains), "/custom/bin/herdr")
        XCTAssertThrowsError(try HerdrInstallation.resolve(override: "/missing", executable: installed.contains))
        XCTAssertThrowsError(try HerdrInstallation.resolve(override: nil, home: "/none", path: "relative::.", executable: { _ in false })) {
            XCTAssertEqual(($0 as? RPCError)?.code, "missing")
        }
        XCTAssertEqual(try HerdrInstallation.resolve(override: nil, home: "/none", path: "/custom/bin", executable: installed.contains), "/custom/bin/herdr")
        XCTAssertTrue(ConnectionCommands.environment(["PATH": "/custom/bin"])["PATH"]!.contains("/custom/bin"))
    }
    func testJSONStatusStates() throws {
        let running = Data(#"{"client":{"version":"0.9.1"},"server":{"running":true,"version":"0.9.1","protocol":22,"socket":"/tmp/herdr.sock"}}"#.utf8)
        XCTAssertEqual(try HerdrInstallation.Status.decode(running).socketPath(machine: "Test"), "/tmp/herdr.sock")
        for (json, code) in [
            (#"{"server":{"running":false,"protocol":null,"socket":"/tmp/test"}}"#, "stopped"),
            (#"{"server":{"running":true,"protocol":999,"socket":"/tmp/test"}}"#, "incompatible"),
            (#"{"server":{"running":true,"protocol":22,"socket":"relative.sock"}}"#, "incompatible"),
            (#"{"client":{"protocol":99},"server":{"running":true,"protocol":22,"socket":"/tmp/test"}}"#, "incompatible"),
            ("not JSON", "incompatible")
        ] {
            XCTAssertThrowsError(try HerdrInstallation.Status.decode(Data(json.utf8)).socketPath(machine: "Test")) {
                XCTAssertEqual(($0 as? RPCError)?.code, code)
            }
        }
    }
    func testRemoteCommandQuotingAndTargetValidation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("herdrorb-quote-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("herdr ' custom")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\"\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let machine = Machine(id: "remote", label: "Fixture", target: "sample", session: "a'b;$(exit 99)", executablePath: executable.path)
        let arguments = ["status", "--json", "value ' with spaces;$(exit 98)"]
        let output = try await ProcessRunner.run("/bin/sh", ["-c", ConnectionCommands.herdr(machine, arguments: arguments)])
        XCTAssertEqual(String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init), ["--session", machine.session!] + arguments)
        for target in ["-oProxyCommand=bad", "", "host\nother", "host with space"] {
            XCTAssertThrowsError(try ConnectionCommands.target(Machine(id: "r", label: "Test", target: target)))
        }
        XCTAssertEqual(try ConnectionCommands.target(machine), "sample")
    }
    func testDiagnosticsExcludeUntrustedValues() {
        let text = Diagnostics.text(connections: [(.online, "0.9.1"), (.authentication, "/Users/private-host/key-secret")])
        XCTAssertTrue(text.contains("0.9.1"))
        XCTAssertFalse(text.contains("private-host"))
        XCTAssertFalse(text.contains("key-secret"))
        XCTAssertEqual(ConnectionState.failure(RPCError(code: "host_key", message: "private detail")), .hostKey)
    }
    func testPreferenceMigrationPreservesNewSettings() {
        let suite = "herdrorb-tests-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: "showOrb")
        AppPreferences.migrate(into: preferences, legacy: ["showOrb": true, "orbStyle": "eclipse", "unrelated": "private"])
        XCTAssertFalse(preferences.bool(forKey: "showOrb"))
        XCTAssertEqual(preferences.string(forKey: "orbStyle"), "eclipse")
        XCTAssertNil(preferences.string(forKey: "unrelated"))
        AppPreferences.migrate(into: preferences, legacy: ["orbStyle": "pearl"])
        XCTAssertEqual(preferences.string(forKey: "orbStyle"), "eclipse")
    }
    func testDisablingCacheCancelsPendingWritesAndClearsLegacyData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("herdrorb-cache-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ConversationCache(directory: directory)
        let agent = Agent(terminal_id: "t", agent_status: "idle", pane_id: "p")
        await cache.save("private draft", for: agent)
        await cache.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        await cache.save("pending private update", for: agent)
        await cache.setEnabled(false)
        try await cache.clear()
        await cache.save("must not persist", for: agent)
        await cache.saveInventory([MachineInventory(machine: .local, agents: [agent])])
        await cache.flush()
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let snapshot = await cache.snapshot(for: agent)
        XCTAssertNil(snapshot)
        await cache.setEnabled(true)
        await cache.save("new opt-in data", for: agent)
        await cache.flush()
        let restored = await cache.snapshot(for: agent)
        XCTAssertEqual(restored?.text, "new opt-in data")
    }
    @MainActor func testMissingHerdrCanRecoverWithoutRestart() async throws {
        let suite = "herdrorb-setup-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: "saveConversations")
        var installed = false
        let model = BubbleModel(cache: ConversationCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), preferences: preferences,
                                discover: { if !installed { throw RPCError(code: "missing", message: "Install Herdr") }; return [.local] }, makeTransport: { DemoConnection($0) })
        await model.start()
        XCTAssertEqual(model.connection["local"], .missing)
        XCTAssertTrue(model.showingSetup)
        installed = true
        await model.refresh()
        for _ in 0..<50 where model.connection["local"] != .online { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.connection["local"], .online)
        XCTAssertNil(model.connectionDetails["local"])
        model.completeSetup()
        XCTAssertFalse(model.showingSetup)
        await model.stop()
    }
    func testClaudeAndCodexParserFixtures() {
        for kind in ["codex", "claude"] {
            let messages = TerminalPresentation.messages("› Please review this sample.\n\n• Here is a safe example response.", kind: kind)
            XCTAssertFalse(messages.isEmpty)
            XCTAssertTrue(messages.contains { $0.text.contains("safe example response") })
        }
    }
}
