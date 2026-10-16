import XCTest
@testable import HerdrOrb

final class DeviceInformationTests: XCTestCase {
    func testSystemDiscoveryIgnoresNoiseAndDeduplicatesInterfaces() {
        let data = Data("hostname\tstudio.local\nname\tStudio Mac\nos\tmacOS 15 · arm64\nlan\t192.168.1.4 (en0)\nlan\t192.168.1.4 (en0)\nnoise\nname\t\n".utf8)
        let info = DeviceInformation.system(data)
        XCTAssertEqual(info.hostname, "studio.local")
        XCTAssertEqual(info.systemName, "Studio Mac")
        XCTAssertEqual(info.lanAddresses, ["192.168.1.4 (en0)"])
    }

    func testTailscaleUsesSelfRatherThanPeerAddresses() throws {
        var info = DeviceInformation()
        try info.applyTailscale(Data(#"{"BackendState":"Running","Self":{"DNSName":"studio.example.ts.net.","TailscaleIPs":["100.80.10.42","fd7a::123"]},"Peer":{"other":{"DNSName":"other.ts.net","TailscaleIPs":["100.1.2.3"]}}}"#.utf8))
        XCTAssertEqual(info.tailscaleName, "studio.example.ts.net")
        XCTAssertEqual(info.tailscaleAddresses, ["100.80.10.42", "fd7a::123"])
        XCTAssertEqual(info.tailscaleState, "Running")
        XCTAssertTrue(info.publicURLs.isEmpty)
        XCTAssertThrowsError(try info.applyTailscale(Data("unavailable".utf8)))
    }

    func testFunnelRequiresExplicitPublicHTTPSListener() throws {
        var info = DeviceInformation()
        try info.applyFunnel(Data(#"{"AllowFunnel":{"public.example.ts.net:443":true,"private.example.ts.net:443":false,"tcp.example.ts.net:8443":true},"Web":{"public.example.ts.net:443":{},"private.example.ts.net:443":{},"tcp.example.ts.net:8443":{}},"TCP":{"443":{"HTTPS":true},"8443":{"TCPForward":"localhost:8080"}},"Foreground":{"session":{"AllowFunnel":{"temporary.example.ts.net:10000":true},"Web":{"temporary.example.ts.net:10000":{}},"TCP":{"10000":{"HTTPS":true}}}}}"#.utf8))
        XCTAssertEqual(info.publicURLs, ["https://public.example.ts.net", "https://temporary.example.ts.net:10000"])
        XCTAssertTrue(info.funnelChecked)
    }

    func testMissingAndMalformedFunnelStatus() throws {
        var info = DeviceInformation()
        XCTAssertFalse(info.funnelChecked)
        XCTAssertThrowsError(try info.applyFunnel(Data("null".utf8)))
        XCTAssertFalse(info.funnelChecked)
        try info.applyFunnel(Data("{}".utf8))
        XCTAssertTrue(info.funnelChecked)
        XCTAssertTrue(info.publicURLs.isEmpty)
    }

    func testSystemProbeLocally() async throws {
        let data = try await DeviceInformationProbe.run(DeviceInformationProbe.systemScript, on: .local)
        let info = DeviceInformation.system(data)
        XCTAssertFalse(info.hostname?.isEmpty ?? true)
        XCTAssertTrue(info.operatingSystem?.contains("macOS") ?? false)
    }
}
