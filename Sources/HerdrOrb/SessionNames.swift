import Foundation

/// Friendly names stay separate from Herdr's restricted internal agent identifiers.
final class SessionNames {
    private let defaults: UserDefaults
    private var names: [String: String]
    private var nextNumber: Int

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        names = defaults.dictionary(forKey: "sessionDisplayNames") as? [String: String] ?? [:]
        nextNumber = max(1, defaults.integer(forKey: "nextSessionNumber"))
    }
    private func key(_ agent: Agent) -> String {
        let parts = [agent.machineID, agent.terminal_id, agent.pane_id]
        return String(data: try! JSONEncoder().encode(parts), encoding: .utf8)!
    }
    func existingName(for agent: Agent) -> String? { names[key(agent)] }
    func reserveNumber() -> String {
        let name = String(nextNumber); nextNumber += 1; persist(); return name
    }
    func needsSync(_ agent: Agent) -> Bool {
        !(defaults.dictionary(forKey: "syncedSessionNames")?[key(agent)] as? Bool ?? false)
    }
    func markSynced(_ agent: Agent) {
        var synced = defaults.dictionary(forKey: "syncedSessionNames") ?? [:]
        synced[key(agent)] = true; defaults.set(synced, forKey: "syncedSessionNames")
    }
    func name(for agent: Agent) -> String {
        let id = key(agent)
        if let name = names[id] { return name }
        let name = String(nextNumber)
        nextNumber += 1
        names[id] = name
        persist()
        return name
    }
    func rename(_ agent: Agent, to value: String) {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        // Allocate its default before renaming so the sequence never goes backwards.
        _ = self.name(for: agent)
        names[key(agent)] = name
        persist()
    }
    private func persist() {
        defaults.set(names, forKey: "sessionDisplayNames")
        defaults.set(nextNumber, forKey: "nextSessionNumber")
    }
}
