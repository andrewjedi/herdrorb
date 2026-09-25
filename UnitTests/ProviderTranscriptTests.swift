import XCTest
@testable import HerdrOrb

final class ProviderTranscriptTests: XCTestCase {
    let sid = "abcdef12-3456-7890-abcd-ef1234567890"
    func record(_ value: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); data.append(10); return data
    }
    func codex(_ payload: [String: Any], ordinal: Int) throws -> Data {
        try record(["type": "response_item", "ordinal": ordinal, "payload": payload])
    }
    func chunk(_ data: Data, offset: UInt64 = 0, identity: String = "file1") -> TranscriptChunk {
        TranscriptChunk(path: "/fixture.jsonl", identity: identity, offset: offset, size: offset + UInt64(data.count), data: data)
    }
    func testCodexReadsRolesPhasesUsageAndIgnoresReasoningTools() throws {
        var data = try record(["type": "session_meta", "payload": ["id": sid]])
        data += try codex(["type": "message", "role": "developer", "content": [["type": "input_text", "text": "private instructions"]]], ordinal: 1)
        data += try codex(["type": "message", "role": "user", "content": [["type": "input_text", "text": "same request"]]], ordinal: 2)
        data += try codex(["type": "reasoning", "text": "private thoughts"], ordinal: 3)
        data += try codex(["type": "message", "role": "assistant", "phase": "commentary", "content": [["type": "output_text", "text": "Working"]]], ordinal: 4)
        data += try codex(["type": "message", "role": "assistant", "phase": "final_answer", "content": [["type": "output_text", "text": "## Original Markdown\n\n**kept**"]]], ordinal: 5)
        data += try record(["type": "event_msg", "payload": ["type": "token_count", "info": ["model_context_window": 100000, "last_token_usage": ["total_tokens": 56000], "total_token_usage": ["total_tokens": 8000000]]]])
        let result = try ProviderTranscriptDecoder.decode(chunk(data), reference: .init(agent: "codex", kind: "id", value: sid), previous: TranscriptCursor())
        XCTAssertEqual(result.messages.count, 3)
        XCTAssertEqual(result.messages.map { $0.1.id }, ["codex:record-2", "codex:record-4", "codex:record-5"])
        XCTAssertEqual(result.messages.last?.1.phase, "final_answer")
        XCTAssertEqual(result.messages.last?.1.text, "## Original Markdown\n\n**kept**")
        XCTAssertEqual(result.cursor.usage?.usedPercent, 50)
        XCTAssertEqual(result.cursor.usage?.tokens, 56000, "Use latest context, never cumulative usage")
    }
    func testClaudeExcludesSidechainsAndToolResults() throws {
        var data = try record(["type": "user", "sessionId": sid, "uuid": "user-1", "message": ["content": "Hello"]])
        data += try record(["type": "user", "sessionId": sid, "uuid": "tool-1", "message": ["content": [["type": "tool_result", "content": "not a user"]]]])
        data += try record(["type": "assistant", "sessionId": sid, "uuid": "side", "isSidechain": true, "message": ["content": [["type": "text", "text": "subagent"]]]])
        data += try record(["type": "assistant", "sessionId": sid, "uuid": "answer", "message": ["content": [["type": "thinking", "thinking": "private"], ["type": "text", "text": "Answer"]]]])
        let result = try ProviderTranscriptDecoder.decode(chunk(data), reference: .init(agent: "claude", kind: "id", value: sid), previous: TranscriptCursor())
        XCTAssertEqual(result.messages.map { $0.1.text }, ["Hello", "Answer"])
        XCTAssertEqual(result.messages.map { $0.1.fromUser }, [true, false])
    }
    func testPartialUTF8RecordDoesNotAdvanceCheckpoint() throws {
        let first = try record(["type": "session_meta", "payload": ["id": sid]])
        let next = try codex(["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "café 🌎"]]], ordinal: 1)
        let reference = ProviderSessionReference(agent: "codex", kind: "id", value: sid)
        let partial = try ProviderTranscriptDecoder.decode(chunk(first + next.prefix(next.count - 3)), reference: reference, previous: TranscriptCursor())
        XCTAssertEqual(partial.cursor.offset, UInt64(first.count))
        let complete = try ProviderTranscriptDecoder.decode(chunk(next, offset: UInt64(first.count)), reference: reference, previous: partial.cursor)
        XCTAssertEqual(complete.messages.first?.1.text, "café 🌎")
        XCTAssertEqual(complete.cursor.offset, UInt64(first.count + next.count))
    }
    func testSessionMismatchAndCorruptRecordNeverAdvance() throws {
        let reference = ProviderSessionReference(agent: "codex", kind: "id", value: sid)
        let wrong = try record(["type": "session_meta", "payload": ["id": UUID().uuidString]])
        XCTAssertThrowsError(try ProviderTranscriptDecoder.decode(chunk(wrong), reference: reference, previous: TranscriptCursor()))
        let bad = try record(["type": "session_meta", "payload": ["id": sid]]) + Data("broken JSON\n".utf8)
        XCTAssertThrowsError(try ProviderTranscriptDecoder.decode(chunk(bad), reference: reference, previous: TranscriptCursor()))
    }
    func testProviderIdentityIsPartOfCacheKey() {
        let original = Agent(terminal_id: "t", agent: "codex", agent_status: "idle", pane_id: "p")
        var first = original, second = original
        first.providerSession = .init(agent: "codex", kind: "id", value: sid)
        second.providerSession = .init(agent: "codex", kind: "id", value: UUID().uuidString)
        XCTAssertNotEqual(ConversationCache.key(for: first), ConversationCache.key(for: second))
        XCTAssertNotEqual(ConversationCache.key(for: original), ConversationCache.key(for: first))
    }
    func testFileAppendAndTruncationUseByteOffsets() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("hello\n".utf8).write(to: file)
        let first = try ProviderFiles.read(path: file, offset: 0, identity: "")
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data("next\n".utf8)); try handle.close()
        let next = try ProviderFiles.read(path: file, offset: 6, identity: first.identity)
        XCTAssertEqual(String(decoding: next.data, as: UTF8.self), "next\n")
        try Data("new\n".utf8).write(to: file)
        let reset = try ProviderFiles.read(path: file, offset: 11, identity: first.identity)
        XCTAssertEqual(reset.offset, 0)
        XCTAssertEqual(String(decoding: reset.data, as: UTF8.self), "new\n")
    }
    func testClaudeTelemetryIdentityCacheTokensAndCompaction() {
        var payload: [String: Any] = ["session_id": sid, "model": ["id": "test-model"], "context_window": ["context_window_size": 1000000, "current_usage": ["input_tokens": 10000, "cache_creation_input_tokens": 20000, "cache_read_input_tokens": 30000, "output_tokens": 90000]]]
        XCTAssertEqual(ContextUsage.claude(payload, sessionID: sid)?.usedPercent, 6)
        XCTAssertNil(ContextUsage.claude(payload, sessionID: UUID().uuidString))
        payload["context_window"] = ["context_window_size": 1000000, "current_usage": NSNull(), "used_percentage": NSNull()]
        XCTAssertNil(ContextUsage.claude(payload, sessionID: sid))
    }
    func testCompleteMessageIsNeverCutAtRetentionBoundary() {
        let giant = "```swift\n" + String(repeating: "line\n", count: 55000) + "```"
        let raw = "› old\n• earlier\n› large\n• " + giant
        let retained = TerminalPresentation.retainedHistory(raw, kind: "codex")
        XCTAssertTrue(retained.hasSuffix("```"))
        XCTAssertTrue(retained.contains(giant))
        let message = SessionMessage(id: "long", fromUser: false, text: giant)
        let preview = LongMessagePresentation.preview(message)
        XCTAssertLessThanOrEqual(preview.text.count, LongMessagePresentation.limit)
        XCTAssertEqual(message.text, giant)
    }
}

extension ProviderTranscriptTests {
    func testReaderReplaysMissedMessagesAndOnlyReadsAppendedRecords() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(sid + ".jsonl")
        var data = try record(["type": "session_meta", "payload": ["id": sid]])
        for index in 0..<100 {
            data += try codex(["type": "message", "role": index % 2 == 0 ? "user" : "assistant", "content": [["type": "output_text", "text": "Message \(index)"]]], ordinal: index + 1)
        }
        try data.write(to: file)
        let archive = ConversationArchive(directory: directory.appendingPathComponent("cache"))
        let reader = ProviderTranscriptReader(archive: archive)
        let agent = Agent(terminal_id: "t", agent: "codex", agent_status: "idle", pane_id: "p", providerSession: .init(agent: "codex", kind: "path", value: file.path))
        let first = try await reader.refresh(agent: agent, machine: .local)
        XCTAssertEqual(first.page?.total, 100)
        XCTAssertEqual(first.page?.messages.count, 40)
        XCTAssertEqual(first.page?.messages.first?.text, "Message 60")
        let next = try codex(["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Written while hidden"]]], ordinal: 101)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: next); try handle.close()
        // A newly created reader starts from the durable cursor, not a UI snapshot.
        let resumed = try await ProviderTranscriptReader(archive: archive).refresh(agent: agent, machine: .local)
        XCTAssertEqual(resumed.page?.total, 101)
        XCTAssertEqual(resumed.page?.messages.last?.text, "Written while hidden")
        let unchanged = try await reader.refresh(agent: agent, machine: .local)
        XCTAssertNil(unchanged.page, "Unchanged transcript must not decode/reload the message page")
        let key = ConversationCache.key(for: agent)
        let cursor = try await archive.cursor(for: key)
        XCTAssertEqual(cursor?.offset, UInt64(data.count + next.count))
    }
}
