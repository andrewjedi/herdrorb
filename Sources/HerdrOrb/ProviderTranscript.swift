import Foundation
import Darwin

struct ProviderSessionReference: Codable, Hashable, Sendable {
    var agent: String
    var kind: String
    var value: String
    var source: String = "herdr"
    var sessionID: String? {
        if kind == "id", UUID(uuidString: value) != nil { return value.lowercased() }
        if kind == "path" {
            let name = URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent
            if UUID(uuidString: name) != nil { return name.lowercased() }
            if let match = name.range(of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, options: .regularExpression) { return String(name[match]).lowercased() }
        }
        return nil
    }
}
struct TranscriptCursor: Codable, Sendable {
    var path = ""
    var identity = ""
    var offset: UInt64 = 0
    var validated = false
    var model: String?
    var turnID: String?
    var usage: ContextUsage?
    var compactedAt: Date? = nil
    var presentationVersion: Int? = nil
    var pendingTools: [String: SessionMessage]? = nil
    var conversationTurnID: String? = nil
}
struct TranscriptChunk: Codable, Sendable {
    var path: String
    var identity: String
    var offset: UInt64
    var size: UInt64
    var data: Data
}

/// Reads only the exact provider session reported by Herdr; never guesses by cwd/mtime.
enum ProviderFiles {
    static func resolve(_ reference: ProviderSessionReference, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        if reference.kind == "path", reference.value.hasPrefix("/"), reference.value.hasSuffix(".jsonl") {
            return URL(fileURLWithPath: reference.value)
        }
        guard let id = reference.sessionID else { throw BridgeError.message("Herdr has not reported a valid provider session ID.") }
        let root: URL
        if reference.agent == "codex" {
            root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? home.appendingPathComponent(".codex").path).appendingPathComponent("sessions")
        } else {
            root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? home.appendingPathComponent(".claude").path).appendingPathComponent("projects")
        }
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        var matches: [URL] = []
        while let file = files?.nextObject() as? URL {
            if file.lastPathComponent.lowercased() == id + ".jsonl" || (reference.agent == "codex" && file.lastPathComponent.lowercased().hasSuffix("-" + id + ".jsonl")) { matches.append(file) }
        }
        guard matches.count == 1, let match = matches.first else { throw BridgeError.message(matches.isEmpty ? "The provider session file is not available yet." : "Multiple files claim this provider session; refusing to guess.") }
        return match
    }
    static func read(path: URL, offset: UInt64, identity: String, maximum: Int = 1_048_576) throws -> TranscriptChunk {
        let handle = try FileHandle(forReadingFrom: path); defer { try? handle.close() }
        var attributes = stat()
        guard fstat(handle.fileDescriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG else { throw BridgeError.message("Provider transcript is not a regular file.") }
        let size = UInt64(max(0, attributes.st_size))
        let current = "\(attributes.st_dev):\(attributes.st_ino)"
        let start = identity == current && offset <= size ? offset : 0
        try handle.seek(toOffset: start)
        let data = try handle.read(upToCount: maximum) ?? Data()
        return TranscriptChunk(path: path.path, identity: current, offset: start, size: size, data: data)
    }
}

/// Converts complete JSONL records to UI messages. No terminal-marker parsing or
/// raw reasoning is used. Byte checkpoints make replay independent of UI visibility.
enum ProviderTranscriptDecoder {
    static let presentationVersion = 2
    struct Batch {
        var messages: [(Int64, SessionMessage)] = []
        var cursor: TranscriptCursor
    }
    static func decode(_ chunk: TranscriptChunk, reference: ProviderSessionReference, previous: TranscriptCursor) throws -> Batch {
        var cursor = chunk.offset == previous.offset && chunk.identity == previous.identity ? previous : TranscriptCursor()
        cursor.path = chunk.path; cursor.identity = chunk.identity; cursor.offset = chunk.offset
        cursor.presentationVersion = presentationVersion
        var batch = Batch(cursor: cursor)
        var start = chunk.data.startIndex
        for end in chunk.data.indices where chunk.data[end] == 10 {
            let line = chunk.data[start..<end]
            let position = chunk.offset + UInt64(start)
            start = end + 1
            if line.isEmpty { batch.cursor.offset = chunk.offset + UInt64(start); continue }
            guard let record = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { throw BridgeError.message("Invalid provider transcript record.") }
            let payload = record["payload"] as? [String: Any] ?? [:]
            if reference.agent == "codex", record["type"] as? String == "session_meta" {
                let reported = (payload["id"] as? String ?? payload["session_id"] as? String)?.lowercased()
                guard reported != nil, reference.sessionID == nil || reported == reference.sessionID else { throw BridgeError.message("Provider transcript belongs to another session.") }
                batch.cursor.validated = true
            } else if reference.agent == "claude", let reported = record["sessionId"] as? String {
                guard reference.sessionID == nil || reported.lowercased() == reference.sessionID else { throw BridgeError.message("Provider transcript belongs to another session.") }
                batch.cursor.validated = true
            }
            guard batch.cursor.validated else {
                // Metadata may precede Claude's first session-scoped record.
                batch.cursor.offset = chunk.offset + UInt64(start); continue
            }
            let recordedAt = (record["timestamp"] as? String).flatMap(parseDate)
            let timestamp = recordedAt ?? Date()
            if reference.agent == "codex" {
                if record["type"] as? String == "turn_context" {
                    batch.cursor.model = payload["model"] as? String
                    batch.cursor.turnID = payload["turn_id"] as? String
                }
                if record["type"] as? String == "compacted" || payload["type"] as? String == "context_compacted" { batch.cursor.usage = nil; batch.cursor.compactedAt = timestamp }
                if record["type"] as? String == "event_msg", payload["type"] as? String == "token_count" {
                    batch.cursor.usage = ContextUsage.codex(info: payload["info"] as? [String: Any], sessionID: reference.sessionID, model: batch.cursor.model, observedAt: timestamp)
                }
                if record["type"] as? String == "response_item", payload["type"] as? String == "message",
                   let role = payload["role"] as? String, ["user", "assistant"].contains(role) {
                    let content = payload["content"] as? [[String: Any]] ?? []
                    let text = content.compactMap { part -> String? in
                        guard ["input_text", "output_text", "text"].contains(part["type"] as? String ?? "") else { return nil }
                        return part["text"] as? String
                    }.joined(separator: "\n")
                    let id = payload["id"] as? String ?? "record-\(record["ordinal"] as? Int ?? Int(position))"
                    if role == "user" { batch.cursor.conversationTurnID = id }
                    if !text.isEmpty { batch.messages.append((Int64(position) * 1024, message(id: id, text: text, user: role == "user", phase: payload["phase"] as? String, provider: "codex", turnID: batch.cursor.conversationTurnID ?? batch.cursor.turnID, at: recordedAt))) }
                }
                if record["type"] as? String == "response_item", let type = payload["type"] as? String,
                   ["function_call", "custom_tool_call"].contains(type), let call = payload["call_id"] as? String {
                    beginTool(call, name: payload["name"] as? String ?? "Tool", input: payload["arguments"] ?? payload["input"], provider: "codex", at: recordedAt, position: position, batch: &batch)
                }
                if record["type"] as? String == "response_item", let type = payload["type"] as? String,
                   ["function_call_output", "custom_tool_call_output"].contains(type), let call = payload["call_id"] as? String {
                    finishTool(call, output: payload["output"], failed: payload["is_error"] as? Bool == true, provider: "codex", at: recordedAt, position: position, batch: &batch)
                }
            } else if reference.agent == "claude" {
                if record["type"] as? String == "system", record["subtype"] as? String == "compact_boundary" { batch.cursor.usage = nil; batch.cursor.compactedAt = timestamp }
                if record["isSidechain"] as? Bool != true, record["isMeta"] as? Bool != true,
                   let role = record["type"] as? String, ["user", "assistant"].contains(role),
                   let body = record["message"] as? [String: Any], let id = record["uuid"] as? String {
                    batch.cursor.model = body["model"] as? String ?? batch.cursor.model
                    let content = body["content"]
                    let text = content as? String ?? (content as? [[String: Any]] ?? []).compactMap { part -> String? in
                        guard part["type"] as? String == "text" else { return nil }; return part["text"] as? String
                    }.joined(separator: "\n")
                    // Tool results (role=user) are not user messages. Thinking blocks stay private.
                    let localCommand = role == "user" && ["<command-name>", "<local-command-stdout>", "<local-command-stderr>", "<local-command-caveat>"].contains { text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix($0) }
                    if role == "user", !text.isEmpty && !localCommand { batch.cursor.conversationTurnID = id }
                    if let plain = content as? String, !plain.isEmpty && !localCommand {
                        batch.messages.append((Int64(position) * 1024, message(id: id, text: plain, user: role == "user", phase: nil, provider: "claude", turnID: batch.cursor.conversationTurnID ?? batch.cursor.turnID, at: recordedAt)))
                    }
                    var textIndex = 0
                    for (index, part) in (content as? [[String: Any]] ?? []).enumerated() {
                        if part["type"] as? String == "text", let prose = part["text"] as? String, !prose.isEmpty && !localCommand {
                            let proseID = textIndex == 0 ? id : id + ":text:\(textIndex)"
                            batch.messages.append((Int64(position) * 1024 + Int64(index), message(id: proseID, text: prose, user: role == "user", phase: nil, provider: "claude", turnID: batch.cursor.conversationTurnID ?? batch.cursor.turnID, at: recordedAt)))
                            textIndex += 1
                        }
                        if part["type"] as? String == "tool_use", let call = part["id"] as? String {
                            beginTool(call, name: part["name"] as? String ?? "Tool", input: part["input"], provider: "claude", at: recordedAt, position: position, subposition: index + 1, batch: &batch)
                        }
                        if part["type"] as? String == "tool_result", let call = part["tool_use_id"] as? String {
                            finishTool(call, output: part["content"], failed: part["is_error"] as? Bool == true, provider: "claude", at: recordedAt, position: position, batch: &batch)
                        }
                    }
                }
            }
            batch.cursor.offset = chunk.offset + UInt64(start)
        }
        return batch
    }
    static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    private static func message(id: String, text: String, user: Bool, phase: String?, provider: String, turnID: String?, at date: Date?) -> SessionMessage {
        let text = user && provider == "codex" ? ConversationImageInstructions.userText(text) : text
        return SessionMessage(id: provider + ":" + id, fromUser: user, text: text, parts: [MessagePart(text: text, status: phase == "commentary")], artifacts: user ? [] : TerminalPresentation.artifacts(text), phase: phase, source: provider, turnID: turnID, createdAt: date)
    }
    private static func beginTool(_ call: String, name: String, input: Any?, provider: String, at date: Date?, position: UInt64, subposition: Int = 0, batch: inout Batch) {
        let activity = ConversationToolPresentation.activity(name: name, arguments: input, at: date)
        let item = SessionMessage(id: provider + ":tool:" + call, fromUser: false, text: activity.title + "\n" + activity.input,
                                  phase: "activity", source: provider, turnID: batch.cursor.conversationTurnID ?? batch.cursor.turnID, createdAt: date, activity: activity)
        batch.messages.append((Int64(position) * 1024 + Int64(subposition), item))
        var pending = batch.cursor.pendingTools ?? [:]
        pending[call] = item
        if pending.count > 64, let oldest = pending.keys.filter({ $0 != call }).sorted(by: { (pending[$0]?.createdAt ?? .distantPast) < (pending[$1]?.createdAt ?? .distantPast) }).first { pending.removeValue(forKey: oldest) }
        batch.cursor.pendingTools = pending
    }
    private static func finishTool(_ call: String, output: Any?, failed: Bool, provider: String, at date: Date?, position: UInt64, batch: inout Batch) {
        guard var item = batch.cursor.pendingTools?[call], let activity = item.activity else { return }
        item.activity = ConversationToolPresentation.finish(activity, output: output, failed: failed, at: date)
        item.text = activity.title + "\n" + activity.input + "\n" + (item.activity?.output ?? "")
        batch.messages.append((Int64(position) * 1024, item))
        batch.cursor.pendingTools?.removeValue(forKey: call)
    }
}

actor ProviderTranscriptReader {
    struct Update: Sendable {
        var page: ConversationArchive.Page?
        var usage: ContextUsage?
        var catchingUp: Bool
    }
    let archive: ConversationArchive
    init(archive: ConversationArchive) { self.archive = archive }
    func refresh(agent: Agent, machine: Machine) async throws -> Update {
        guard let reference = agent.providerSession, reference.agent == agent.agent else { throw BridgeError.message("Herdr has not linked this terminal to a provider transcript.") }
        let key = ConversationCache.key(for: agent)
        let saved = try await archive.cursor(for: key)
        let reindex = saved?.presentationVersion != ProviderTranscriptDecoder.presentationVersion || saved?.validated != true
        let previous = reindex ? TranscriptCursor() : saved ?? TranscriptCursor()
        var chunk: TranscriptChunk
        if machine.id == "local" {
            let path = previous.path.isEmpty ? try ProviderFiles.resolve(reference) : URL(fileURLWithPath: previous.path)
            chunk = try ProviderFiles.read(path: path, offset: previous.offset, identity: previous.identity)
            // Allow a large single JSON record without holding the full transcript in memory.
            if !chunk.data.isEmpty && !chunk.data.contains(10) {
                chunk = try ProviderFiles.read(path: path, offset: previous.offset, identity: previous.identity, maximum: 8_388_608)
            }
        } else {
            chunk = try await ProviderBridge.read(reference: reference, cursor: previous, machine: machine)
        }
        if chunk.data.count >= 8_388_608 && !chunk.data.contains(10) { throw BridgeError.message("A provider record exceeds the 8 MB read limit; use Terminal for this output.") }
        let batch = try ProviderTranscriptDecoder.decode(chunk, reference: reference, previous: previous)
        if !batch.cursor.validated && batch.cursor.offset >= chunk.size && chunk.size > 0 { throw BridgeError.message("Provider transcript has no matching session metadata.") }
        if batch.cursor.offset != previous.offset || chunk.identity != previous.identity {
            try await archive.apply(batch.messages, session: key, cursor: batch.cursor, reset: reindex && batch.cursor.validated)
        }
        var usage = batch.cursor.usage
        if reference.agent == "claude" {
            usage = try await ProviderBridge.claudeUsage(reference: reference, machine: machine)
            if let compacted = batch.cursor.compactedAt, usage?.observedAt.map({ $0 < compacted }) != false { usage = nil }
        }
        let page = batch.messages.isEmpty && previous.validated ? nil : try await archive.page(session: key)
        return Update(page: page, usage: usage, catchingUp: !batch.cursor.validated || (batch.cursor.offset < chunk.size && chunk.data.last == 10))
    }
}
