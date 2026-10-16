import XCTest
import AppKit
@testable import HerdrOrb

final class DeviceTerminalSessionTests: XCTestCase {
    @MainActor func testSessionsSurviveSelectionChangesAndCloseIndependently() {
        _ = NSApplication.shared
        let store = DeviceTerminalStore()
        let shell = store.create(machine: .local, startsHerdr: false)
        let view = shell.start(demo: true)
        let herdr = store.create(machine: .local, startsHerdr: true)
        XCTAssertEqual(store.selectedID, herdr.id)
        store.selectedID = nil
        XCTAssertTrue(shell.start(demo: true) === view)
        XCTAssertEqual(store.sessions.count, 2)
        store.close(herdr)
        XCTAssertFalse(shell.ended)
        XCTAssertEqual(store.sessions.map(\.id), [shell.id])
        store.selectedID = shell.id
        XCTAssertTrue(store.selected === shell)
        store.closeAll()
        XCTAssertTrue(shell.ended)
        XCTAssertNil(shell.terminal)
        XCTAssertTrue(store.sessions.isEmpty)
    }

    @MainActor func testLocalEmbeddedShellAcceptsInputAndReportsExit() async throws {
        _ = NSApplication.shared
        let session = DeviceTerminalSession(machine: .local, startsHerdr: false, number: 1)
        let terminal = session.start()
        defer { session.close() }
        let input = Array("printf 'embedded_%s\\n' terminal_ok; exit\n".utf8)
        terminal.send(source: terminal, data: input[...])
        for _ in 0..<100 {
            if session.ended { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(session.ended, "The embedded shell should process input and exit")
        let output = String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self)
        XCTAssertTrue(output.contains("embedded_terminal_ok"), output)
        XCTAssertTrue(output.contains("Session ended"), output)
    }
}
