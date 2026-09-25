import XCTest
@testable import HerdrOrb

final class ConversationArchiveTests: XCTestCase {
    func testReplayPagingSearchAndCompleteLargeMessages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = ConversationArchive(directory: directory)
        var rows = (0..<105).map { (Int64($0), SessionMessage(id: "m\($0)", fromUser: $0 % 2 == 0, text: "Text \($0)")) }
        rows[104].1.text = "```\n" + String(repeating: "large\n", count: 50000) + "```"
        let cursor = TranscriptCursor(path: "/provider.jsonl", identity: "test", offset: 4096, validated: true)
        try await archive.apply(rows, session: "s", cursor: cursor)
        try await archive.apply(rows, session: "s", cursor: cursor)
        let page = try await archive.page(session: "s")
        XCTAssertEqual(page.total, 105, "Replay must not duplicate rows")
        XCTAssertEqual(page.messages.count, 40)
        XCTAssertEqual(page.earlier, 65)
        XCTAssertEqual(page.messages.last?.text, rows.last?.1.text)
        let older = try await archive.page(session: "s", before: page.messages.first?.id)
        XCTAssertEqual(older.messages.first?.id, "m25")
        XCTAssertEqual(older.earlier, 25)
        let oldest = try await archive.page(session: "s", before: older.messages.first?.id)
        XCTAssertEqual(oldest.messages.count, 25)
        XCTAssertFalse(oldest.hasEarlier)
        let search = try await archive.page(session: "s", search: "Text 3")
        XCTAssertEqual(search.total, 11)
        XCTAssertTrue(search.messages.contains { $0.id == "m3" })
        let reopened = ConversationArchive(directory: directory)
        let restored = try await reopened.cursor(for: "s")
        XCTAssertEqual(restored?.offset, 4096)
        var updated = rows[50]; updated.1.text = "edited"
        try await reopened.apply([updated], session: "s")
        let changed = try await reopened.page(session: "s", search: "edited")
        XCTAssertEqual(changed.messages.map(\.id), ["m50"])
        let isolated = try await reopened.page(session: "different")
        XCTAssertEqual(isolated.total, 0)
    }
    func testDisablingStorageRemovesPrivateArchiveAndUsesMemory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = ConversationArchive(directory: directory)
        try await archive.apply([(0, SessionMessage(id: "one", fromUser: true, text: "private"))], session: "s")
        let file = directory.appendingPathComponent("messages.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try await archive.setPersistent(false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try await archive.apply([(0, SessionMessage(id: "two", fromUser: true, text: "memory"))], session: "s")
        let memory = try await archive.page(session: "s")
        XCTAssertEqual(memory.messages.map(\.text), ["memory"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try await archive.clear()
        let empty = try await archive.page(session: "s")
        XCTAssertTrue(empty.messages.isEmpty)
    }
}

extension ConversationArchiveTests {
    @MainActor func testInactiveHistoryEvictionPreservesDraftsAndRestoresMessages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "herdrorb-eviction-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let model = BubbleModel(cache: ConversationCache(directory: directory), preferences: preferences, discover: { [] })
        let agents = (0..<8).map { Agent(terminal_id: "t\($0)", agent: "codex", agent_status: "idle", pane_id: "p\($0)") }
        model.agents = agents
        for (index, agent) in agents.enumerated() {
            await model.choose(agent)
            let state = model.state(agent)
            state.messages = [SessionMessage(id: "m\(index)", fromUser: false, text: "Complete message \(index)")]
            state.draft = "Draft \(index)"
            state.imageInstructionsSent = true
        }
        await model.evictInactiveHistories(keeping: model.current.identity)
        XCTAssertLessThanOrEqual(agents.filter { !model.state($0).messages.isEmpty }.count, 4)
        XCTAssertEqual(model.state(agents[0]).draft, "Draft 0")
        XCTAssertTrue(model.state(agents[0]).messages.isEmpty)
        await model.choose(agents[0])
        XCTAssertEqual(model.current.messages.first?.text, "Complete message 0")
        XCTAssertEqual(model.current.draft, "Draft 0")
        XCTAssertTrue(model.current.imageInstructionsSent)
        await model.stop()
    }
}

extension ConversationArchiveTests {
    func testMemoryArchiveEvictsWholeRowsAndPageByteBudgetKeepsOversizedMessage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = ConversationArchive(directory: directory)
        try await archive.setPersistent(false)
        let rows = (0..<1005).map { (Int64($0), SessionMessage(id: "\($0)", fromUser: false, text: "whole message \($0)")) }
        try await archive.apply(rows, session: "memory")
        let page = try await archive.page(session: "memory")
        XCTAssertEqual(page.total, 1000)
        let expired = try await archive.page(session: "memory", search: "whole message 0")
        XCTAssertEqual(expired.total, 0)
        let giant = String(repeating: "x", count: 2_200_000)
        try await archive.apply([(2000, SessionMessage(id: "giant", fromUser: false, text: giant))], session: "memory")
        let bounded = try await archive.page(session: "memory")
        XCTAssertEqual(bounded.messages.count, 1)
        XCTAssertEqual(bounded.messages.first?.text, giant, "The page budget must not slice an oversized message")
        XCTAssertTrue(bounded.hasEarlier)
    }
}

extension ConversationArchiveTests {
    func testClearingCachePreservesInstalledStatusLineHelper() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("provider-bridge/provider_bridge.py")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("helper".utf8).write(to: helper)
        let cache = ConversationCache(directory: directory)
        let agent = Agent(terminal_id: "t", agent_status: "idle", pane_id: "p")
        await cache.save("private chat", for: agent)
        await cache.flush()
        try await cache.clear()
        XCTAssertTrue(FileManager.default.fileExists(atPath: helper.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("sessions").path))
    }
}
