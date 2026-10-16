import XCTest
@testable import HerdrOrb

final class DeviceConnectionTests: XCTestCase {
    func testPeerPresenceDoesNotDependOnHerdrOrSSH() throws {
        let status = try JSONDecoder().decode(TailnetSnapshot.self, from: Data(#"{"BackendState":"Running","Self":{"Online":true},"Peer":{"a":{"DNSName":"grogu.example.ts.net.","HostName":"grogu","TailscaleIPs":["100.1.2.3"],"Online":true},"b":{"DNSName":"mini.example.ts.net.","Online":false}}}"#.utf8))
        XCTAssertEqual(status.state(host: "grogu", local: false), .online)
        XCTAssertEqual(status.state(host: "GROGU.EXAMPLE.TS.NET.", local: false), .online)
        XCTAssertEqual(status.state(host: "100.1.2.3", local: false), .online)
        XCTAssertEqual(status.state(host: "mini", local: false), .offline)
        XCTAssertEqual(status.state(host: "missing", local: false), .unknown)
        XCTAssertEqual(status.state(host: nil, local: true), .online)
    }
    func testMissingOnlineAndStoppedBackendAreNotReportedConnected() throws {
        let status = try JSONDecoder().decode(TailnetSnapshot.self, from: Data(#"{"BackendState":"Running","Peer":{"a":{"HostName":"grogu"}}}"#.utf8))
        XCTAssertEqual(status.state(host: "grogu", local: false), .unknown)
        let stopped = try JSONDecoder().decode(TailnetSnapshot.self, from: Data(#"{"BackendState":"Stopped"}"#.utf8))
        XCTAssertEqual(stopped.state(host: nil, local: true), .unavailable)
    }
    func testDirectTerminalDoesNotInvokeHerdrAndAllowsInteractiveAuthentication() throws {
        let machine = Machine(id: "grogu", label: "Grogu", target: "andrew@grogu")
        let command = try DeviceTerminal.command(machine, startHerdr: false)
        XCTAssertTrue(command.contains("'andrew@grogu'"))
        XCTAssertTrue(command.contains("'-tt'"))
        XCTAssertFalse(command.contains("herdr"))
        XCTAssertFalse(command.contains("BatchMode"))
        XCTAssertFalse(command.contains("StrictHostKeyChecking"))
        XCTAssertThrowsError(try DeviceTerminal.command(Machine(id: "bad", label: "Bad", target: "-oProxyCommand=bad"), startHerdr: false))
        XCTAssertEqual(try DeviceTerminal.command(.local, startHerdr: false), "exec /bin/zsh -l")
    }
    func testHerdrLaunchPreservesConfiguredSessionAndExecutable() throws {
        let machine = Machine(id: "grogu", label: "Grogu", target: "user@grogu", session: "work", executablePath: "/opt/my tools/herdr")
        let command = try DeviceTerminal.command(machine, startHerdr: true)
        XCTAssertTrue(command.contains("/opt/my tools/herdr"))
        XCTAssertTrue(command.contains("--session"))
        XCTAssertTrue(command.contains("work"))
    }
}
