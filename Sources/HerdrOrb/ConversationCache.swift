import Foundation
import CryptoKit

/// Disk work is isolated from the main actor. Each session is stored independently.
actor ConversationCache {
    struct Snapshot: Codable, Equatable {
        var text: String
        var updatedAt: Date
        var draft: String = ""
        var follow: Bool = true
        var scrollAnchor: String?
        var history: String = ""
        var scrollOffset: Double?
        var messages: [SessionMessage]? = nil
        var imageInstructionsSent: Bool? = nil
    }
    private let directory: URL
    nonisolated var directoryURL: URL { directory }
    private var enabled = true
    private var loaded: [String: Snapshot] = [:]
    private var pending: [String: Task<Void, Never>] = [:]
    private(set) var writes = 0
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("herdrorb", isDirectory: true)) {
        self.directory = directory
    }
    nonisolated static func key(for agent: Agent) -> String {
        var parts = [agent.machineID, agent.profileIdentity ?? "", agent.terminal_id, agent.pane_id]
        if let reference = agent.providerSession { parts += [reference.agent, reference.sessionID ?? reference.value] }
        return String(data: try! JSONEncoder().encode(parts), encoding: .utf8)!
    }
    private func file(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("sessions/\(hash).json")
    }
    func snapshot(for agent: Agent) -> Snapshot? {
        guard enabled else { return nil }
        let key = Self.key(for: agent)
        if let value = loaded[key] { return value }
        if let data = try? Data(contentsOf: file(key)), let value = try? JSONDecoder().decode(Snapshot.self, from: data) {
            loaded[key] = value; trimMemory(keeping: key); return value
        }
        // Read the previous cache format only when restoring an old session.
        let oldKey = String(data: try! JSONEncoder().encode([agent.machineID, agent.terminal_id, agent.pane_id, agent.agent ?? "", agent.cwd ?? ""]), encoding: .utf8)!
        struct Legacy: Decodable { let text: String; let updatedAt: Date }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("conversations.json")),
           let old = try? JSONDecoder().decode([String: Legacy].self, from: data)[oldKey] {
            let value = Snapshot(text: old.text, updatedAt: old.updatedAt)
            loaded[key] = value; trimMemory(keeping: key); return value
        }
        return nil
    }
    func store(_ value: Snapshot, for agent: Agent) {
        guard enabled else { return }
        let key = Self.key(for: agent)
        var value = value
        // Raw output is diagnostic only. Structured messages are never sliced.
        if value.text.count > 250_000 { value.text = "" }
        value.history = TerminalPresentation.retainedHistory(value.history, kind: agent.agent)
        if let old = loaded[key], old.text == value.text && old.history == value.history && old.draft == value.draft && old.follow == value.follow && old.scrollAnchor == value.scrollAnchor && old.scrollOffset == value.scrollOffset && old.messages == value.messages && old.imageInstructionsSent == value.imageInstructionsSent { return }
        loaded[key] = value
        pending[key]?.cancel()
        pending[key] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 400_000_000); try Task.checkCancellation() }
            catch { return }
            await self?.write(key)
        }
    }
    private func write(_ key: String) {
        guard enabled, let value = loaded[key] else { return }
        do {
            try FileManager.default.createDirectory(at: file(key).deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(value).write(to: file(key), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(key).path)
            writes += 1
            let files = (try? FileManager.default.contentsOfDirectory(at: file(key).deletingLastPathComponent(), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let sorted = files.sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            for expired in sorted.dropFirst(40) { try? FileManager.default.removeItem(at: expired) }
        } catch { Metrics.logger.error("Cache write failed") }
        pending[key] = nil
        trimMemory(keeping: key)
    }
    private func trimMemory(keeping key: String) {
        let candidates = loaded.keys.filter { $0 != key && pending[$0] == nil }
            .sorted { loaded[$0]!.updatedAt < loaded[$1]!.updatedAt }
        for expired in candidates.prefix(max(0, loaded.count - 4)) { loaded[expired] = nil }
    }
    func flush() { for key in Array(pending.keys) { pending[key]?.cancel(); write(key) } }
    func save(_ text: String, for agent: Agent) { store(Snapshot(text: text, updatedAt: Date()), for: agent) }
    func loadInventory() -> [MachineInventory] {
        guard enabled else { return [] }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("inventory.json")) else { return [] }
        return (try? JSONDecoder().decode([MachineInventory].self, from: data)) ?? []
    }
    func saveInventory(_ value: [MachineInventory]) {
        guard enabled else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(value), file = directory.appendingPathComponent("inventory.json")
            if (try? Data(contentsOf: file)) != data {
                try data.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        } catch { Metrics.logger.error("Inventory save failed") }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        if !value {
            for task in pending.values { task.cancel() }
            pending.removeAll(); loaded.removeAll()
        }
    }
    func clear() throws {
        for task in pending.values { task.cancel() }
        pending.removeAll(); loaded.removeAll()
        // Integration helpers live beside the cache and must survive clearing
        // chat history; otherwise Claude's chained status line would be broken.
        for name in ["sessions", "inventory.json", "conversations.json"] {
            let file = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        if (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true { try FileManager.default.removeItem(at: directory) }
    }
}
