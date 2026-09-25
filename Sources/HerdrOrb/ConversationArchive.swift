import Foundation
import SQLite3

/// Incremental, indexed message storage. All SQLite and encoding work is off the UI actor.
actor ConversationArchive {
    struct Page: Sendable {
        var messages: [SessionMessage]
        var total: Int
        var earlier: Int = 0
        var hasEarlier: Bool { earlier > 0 }
    }
    private var db: OpaquePointer?
    private let directory: URL
    private var persistent = true
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("herdrorb")) { self.directory = directory }
    deinit { sqlite3_close(db) }

    private func open() throws {
        if db != nil { return }
        let path: String
        if persistent {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            path = directory.appendingPathComponent("messages.sqlite").path
        } else { path = ":memory:" }
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw failure() }
        if persistent { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }
        try execute("PRAGMA journal_mode=DELETE")
        try execute("CREATE TABLE IF NOT EXISTS messages (session TEXT NOT NULL, id TEXT NOT NULL, position INTEGER NOT NULL, body BLOB NOT NULL, text TEXT NOT NULL, PRIMARY KEY(session,id))")
        try execute("CREATE INDEX IF NOT EXISTS message_order ON messages(session,position)")
        try execute("CREATE TABLE IF NOT EXISTS cursors (session TEXT PRIMARY KEY, body BLOB NOT NULL)")
    }
    private func failure() -> Error { BridgeError.message("Conversation archive: " + (db.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open storage")) }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else { throw failure() }
        return result
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) { sqlite3_bind_text(statement, index, value, -1, transient) }
    private func bind(_ value: Data, to statement: OpaquePointer, at index: Int32) {
        _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), transient) }
    }
    private func data(_ statement: OpaquePointer, column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
    func cursor(for session: String) throws -> TranscriptCursor? {
        try open()
        let query = try statement("SELECT body FROM cursors WHERE session=?"); defer { sqlite3_finalize(query) }
        bind(session, to: query, at: 1)
        guard sqlite3_step(query) == SQLITE_ROW else { return nil }
        return try JSONDecoder().decode(TranscriptCursor.self, from: data(query, column: 0))
    }
    /// Commit messages and the byte checkpoint together: a crash can replay, never skip.
    func apply(_ messages: [(Int64, SessionMessage)], session: String, cursor: TranscriptCursor? = nil) throws {
        try open(); try execute("BEGIN IMMEDIATE")
        do {
            let insert = try statement("INSERT INTO messages(session,id,position,body,text) VALUES(?,?,?,?,?) ON CONFLICT(session,id) DO UPDATE SET body=excluded.body,text=excluded.text WHERE messages.body != excluded.body")
            defer { sqlite3_finalize(insert) }
            for (position, message) in messages {
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                bind(session, to: insert, at: 1); bind(message.id, to: insert, at: 2)
                sqlite3_bind_int64(insert, 3, position)
                bind(try JSONEncoder().encode(message), to: insert, at: 4); bind(message.text, to: insert, at: 5)
                guard sqlite3_step(insert) == SQLITE_DONE else { throw failure() }
            }
            if let cursor {
                let save = try statement("INSERT OR REPLACE INTO cursors(session,body) VALUES(?,?)"); defer { sqlite3_finalize(save) }
                bind(session, to: save, at: 1); bind(try JSONEncoder().encode(cursor), to: save, at: 2)
                guard sqlite3_step(save) == SQLITE_DONE else { throw failure() }
            }
            if !persistent {
                // With saving disabled, a growing transcript cannot become an
                // unbounded RAM archive. Evict whole oldest rows, never slices.
                while true {
                    let size = try statement("SELECT count(*),coalesce(sum(length(body)),0) FROM messages")
                    let status = sqlite3_step(size)
                    let count = sqlite3_column_int64(size, 0), bytes = sqlite3_column_int64(size, 1)
                    sqlite3_finalize(size)
                    guard status == SQLITE_ROW else { throw failure() }
                    if count <= 1 || (count <= 1000 && bytes <= 16_777_216) { break }
                    try execute("DELETE FROM messages WHERE rowid=(SELECT min(rowid) FROM messages)")
                }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func page(session: String, limit: Int = 40, before: String? = nil, search: String = "") throws -> Page {
        try open()
        let condition = search.isEmpty ? "session=?" : "session=? AND instr(lower(text),lower(?))>0"
        let count = try statement("SELECT count(*) FROM messages WHERE " + condition); defer { sqlite3_finalize(count) }
        bind(session, to: count, at: 1); if !search.isEmpty { bind(search, to: count, at: 2) }
        guard sqlite3_step(count) == SQLITE_ROW else { throw failure() }
        let total = Int(sqlite3_column_int64(count, 0))
        let boundary = before == nil ? "" : " AND position < (SELECT position FROM messages WHERE session=? AND id=?)"
        let query = try statement("SELECT body FROM messages WHERE " + condition + boundary + " ORDER BY position DESC, id DESC LIMIT ?")
        defer { sqlite3_finalize(query) }
        var index: Int32 = 1
        bind(session, to: query, at: index); index += 1
        if !search.isEmpty { bind(search, to: query, at: index); index += 1 }
        if let before { bind(session, to: query, at: index); index += 1; bind(before, to: query, at: index); index += 1 }
        sqlite3_bind_int(query, index, Int32(min(max(limit, 1), 200)))
        var messages: [SessionMessage] = []
        var decodedBytes = 0
        while true {
            let result = sqlite3_step(query)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw failure() }
            let body = data(query, column: 0)
            // Count is not a memory bound when individual replies are enormous.
            // Always allow one complete message, then cap each page at 2 MB.
            if !messages.isEmpty && decodedBytes + body.count > 2_097_152 { break }
            messages.append(try JSONDecoder().decode(SessionMessage.self, from: body))
            decodedBytes += body.count
        }
        var earlier = 0
        if let first = messages.last {
            let older = try statement("SELECT count(*) FROM messages WHERE session=? AND position < (SELECT position FROM messages WHERE session=? AND id=?)")
            defer { sqlite3_finalize(older) }
            bind(session, to: older, at: 1); bind(session, to: older, at: 2); bind(first.id, to: older, at: 3)
            if sqlite3_step(older) == SQLITE_ROW { earlier = Int(sqlite3_column_int64(older, 0)) }
        }
        return Page(messages: messages.reversed(), total: total, earlier: earlier)
    }
    func replaceFallback(_ messages: [SessionMessage], session: String) throws {
        try open()
        let query = try statement("SELECT coalesce(max(position),0) FROM messages WHERE session=?")
        bind(session, to: query, at: 1)
        guard sqlite3_step(query) == SQLITE_ROW else { sqlite3_finalize(query); throw failure() }
        var position = sqlite3_column_int64(query, 0)
        sqlite3_finalize(query)
        // Existing IDs retain their original ordering; only genuinely new rows append.
        try apply(messages.map { message in position += 1; return (position, message) }, session: session)
    }
    func setPersistent(_ enabled: Bool) throws {
        guard enabled != persistent else { return }
        sqlite3_close(db); db = nil
        persistent = enabled
        // Turning saving off must also remove archive content, not just the legacy cache.
        if !enabled { try removeFiles() }
    }
    func clear() throws {
        sqlite3_close(db); db = nil
        try removeFiles()
    }
    private func removeFiles() throws {
        for suffix in ["", "-journal", "-wal", "-shm"] {
            let file = directory.appendingPathComponent("messages.sqlite" + suffix)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }
}
