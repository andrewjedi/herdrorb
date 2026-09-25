import Foundation

/// Claude's protocol is independent of Codex. Only the confirmed values share a view model.
enum ClaudeSettingsScreen {
    static func prompt(_ text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        guard let index = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("❯") }),
              index > 0, lines[index - 1].trimmingCharacters(in: .whitespaces).hasPrefix("────"),
              index + 1 < lines.count, lines[index + 1].trimmingCharacters(in: .whitespaces).hasPrefix("────") else { return nil }
        return String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)
    }
    static func mode(_ text: String) -> String? {
        guard prompt(text) != nil, let boundary = text.range(of: "❯", options: .backwards) else { return nil }
        let footer = String(text[boundary.upperBound...])
        for (label, id) in [("manual mode on", "manual"), ("accept edits on", "acceptEdits"), ("plan mode on", "plan"), ("auto mode on", "claudeAuto"), ("bypass permissions on", "bypassPermissions"), ("don't ask on", "dontAsk")] {
            if footer.contains(label) { return id }
        }
        return nil
    }
    struct Model: Equatable {
        let label: String
        let highlighted: Bool
        let current: Bool
    }
    static func models(_ text: String) -> [Model] {
        guard text.contains("Select model"), text.contains("Esc to cancel") else { return [] }
        let regex = try! NSRegularExpression(pattern: #"^\s*(❯)?\s*\d+\.\s+(.+?)(?:\s*✔|\s{2,}|$)"#)
        return text.components(separatedBy: .newlines).compactMap { line in
            guard let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let r = Range(m.range(at: 2), in: line) else { return nil }
            return Model(label: String(line[r]).trimmingCharacters(in: .whitespaces), highlighted: m.range(at: 1).location != NSNotFound, current: line.contains("✔"))
        }
    }
    static func effort(_ text: String) -> (values: [String], selected: String?) {
        let lines = text.components(separatedBy: .newlines)
        guard lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "Effort" }), text.contains("Esc to cancel"),
              let index = lines.firstIndex(where: { $0.contains("low") && $0.contains("medium") && $0.contains("high") }), index > 0 else { return ([], nil) }
        let regex = try! NSRegularExpression(pattern: #"\b(low|medium|high|xhigh|max|ultracode)\b"#)
        let matches = regex.matches(in: lines[index], range: NSRange(lines[index].startIndex..., in: lines[index]))
        let values = matches.map { (lines[index] as NSString).substring(with: $0.range) }
        guard let marker = lines[index - 1].firstIndex(of: "▲") else { return (values, nil) }
        let column = lines[index - 1].distance(from: lines[index - 1].startIndex, to: marker)
        let nearest = matches.enumerated().min { abs($0.element.range.location + $0.element.range.length / 2 - column) < abs($1.element.range.location + $1.element.range.length / 2 - column) }
        return (values, nearest.map { values[$0.offset] })
    }
    static func menu(_ text: String) -> Bool {
        !models(text).isEmpty || !effort(text).values.isEmpty || (text.contains("Fast mode (research preview)") && text.contains("Esc to cancel"))
    }
}

struct ClaudeSettingsBridge {
    let connection: any HerdrConnection
    let paneID: String
    private let owned = ClaudeSettingsOwnership()

    func refresh() async throws -> SessionComposerSettings {
        do { let result = try await readSettings(); await cleanup(); return result }
        catch { await cleanup(); throw error }
    }

    func update(key: String, value: String, current: SessionComposerSettings) async throws -> SessionComposerSettings {
        do {
            let initial = try await screen()
            guard ClaudeSettingsScreen.prompt(initial) == "" else { throw failure("Finish or clear the existing Terminal input first.") }
            switch key {
            case "access":
                guard current.accessOptions.contains(value), let original = ClaudeSettingsScreen.mode(initial), original != "dontAsk" else { throw failure("Use Claude's Terminal to change this permission mode.") }
                var mode = original
                var visited = Set<String>()
                while mode != value && visited.insert(mode).inserted && visited.count <= 6 {
                    try await keys(["shift+tab"])
                    let previous = mode
                    let next = try await wait { ClaudeSettingsScreen.mode($0).map { $0 != previous } ?? false }
                    guard let observed = ClaudeSettingsScreen.mode(next) else { throw failure("Couldn't confirm Claude's permission mode.") }
                    mode = observed
                }
                guard mode == value else { throw failure("That mode isn't enabled for this Claude session. Bypass permissions must be enabled when the session starts.") }
            case "model":
                var menu = try await open("/model")
                for _ in 0..<24 {
                    let rows = ClaudeSettingsScreen.models(menu)
                    guard let target = rows.firstIndex(where: { $0.label == value }), let selected = rows.firstIndex(where: \.highlighted) else { throw failure("Claude no longer offers that model.") }
                    if target == selected {
                        guard menu.contains("s to use this session only") else { throw failure("This Claude version does not offer a session-only model change. Use Terminal to choose its default.") }
                        try await keys(["s"])
                        _ = try await wait { ClaudeSettingsScreen.prompt($0) == "" }
                        owned.menu = false
                        break
                    }
                    try await keys(Array(repeating: target > selected ? "down" : "up", count: abs(target - selected)))
                    let previous = rows
                    menu = try await wait { ClaudeSettingsScreen.models($0) != previous }
                }
            case "effort":
                var menu = try await open("/effort")
                for _ in 0..<12 {
                    let parsed = ClaudeSettingsScreen.effort(menu)
                    guard let target = parsed.values.firstIndex(of: value), let selected = parsed.selected.flatMap({ parsed.values.firstIndex(of: $0) }) else { throw failure("Claude no longer offers that effort.") }
                    if target == selected {
                        try await keys(["enter"])
                        _ = try await wait { ClaudeSettingsScreen.prompt($0) == "" }
                        owned.menu = false
                        break
                    }
                    try await keys(Array(repeating: target > selected ? "right" : "left", count: abs(target - selected)))
                    let previous = parsed.selected
                    menu = try await wait { ClaudeSettingsScreen.effort($0).selected != previous }
                }
            case "speed":
                guard current.speeds.contains(value), ["standard", "fast"].contains(value) else { throw failure("Fast mode isn't offered by this Claude session.") }
                let command = value == "fast" ? "/fast on" : "/fast off"
                owned.command = command
                _ = try await connection.call("pane.send_text", ["pane_id": paneID, "text": command])
                _ = try await wait { ClaudeSettingsScreen.prompt($0) == command }
                try await keys(["enter"])
                _ = try await wait { ClaudeSettingsScreen.prompt($0) == "" && $0.contains(value == "fast" ? "Fast mode ON" : "Fast mode OFF") }
                owned.command = nil
            default: throw failure("Unsupported Claude setting.")
            }
            var confirmed = current
            if key == "access" {
                confirmed.access = ClaudeSettingsScreen.mode(try await screen())
            } else if key == "effort" {
                let menu = try await open("/effort")
                let parsed = ClaudeSettingsScreen.effort(menu)
                confirmed.availableEfforts = parsed.values
                confirmed.effort = parsed.selected
                try await dismiss()
            } else {
                // Models and Fast can affect each other, so recheck their capabilities together.
                confirmed = try await readSettings()
            }
            let actual = key == "model" ? confirmed.model : key == "effort" ? confirmed.effort : key == "speed" ? confirmed.speed : confirmed.access
            guard actual == value else { throw failure("Claude did not confirm the requested setting. Refresh its controls or check Terminal.") }
            await cleanup()
            return confirmed
        } catch { await cleanup(); throw error }
    }

    private func readSettings() async throws -> SessionComposerSettings {
        let initial = try await screen()
        guard ClaudeSettingsScreen.prompt(initial) == "" else { throw failure("Finish or clear the existing Terminal input first.") }
        var result = SessionComposerSettings()
        result.access = ClaudeSettingsScreen.mode(initial)
        if let mode = result.access {
            result.accessOptions = mode == "dontAsk" ? [] : ["manual", "acceptEdits", "plan", "claudeAuto", "bypassPermissions"]
        }
        let modelMenu = try await open("/model")
        let rows = ClaudeSettingsScreen.models(modelMenu)
        result.models = rows.map(\.label)
        result.model = rows.first(where: \.current)?.label
        try await dismiss()
        let effortMenu = try await open("/effort")
        let parsed = ClaudeSettingsScreen.effort(effortMenu)
        result.availableEfforts = parsed.values
        result.effort = parsed.selected
        try await dismiss()
        let fastMenu = try await open("/fast")
        try await dismiss()
        let after = try await screen()
        let lower = fastMenu.lowercased()
        let unavailable = ["disabled", "not available", "not eligible", "requires", "not logged in"].contains { lower.contains($0) }
        let statusLines = after.components(separatedBy: .newlines).filter { $0.contains("⎿") && $0.contains("Fast mode ") }
        if let status = statusLines.last {
            result.speed = status.contains("Fast mode ON") ? "fast" : status.contains("Fast mode OFF") ? "standard" : nil
        }
        if result.speed != nil { result.speeds = unavailable ? ["standard"] : ["standard", "fast"] }
        return result
    }

    private func open(_ command: String) async throws -> String {
        guard ClaudeSettingsScreen.prompt(try await screen()) == "" else { throw failure("Close the existing Terminal dialog or clear its draft first.") }
        owned.command = command
        _ = try await connection.call("pane.send_text", ["pane_id": paneID, "text": command])
        let typed = try await wait { ClaudeSettingsScreen.prompt($0) == command }
        guard typed.contains(command) else { throw failure("Couldn't prepare Claude's settings command.") }
        owned.menu = true
        try await keys(["enter"])
        let menu = try await wait { command == "/model" ? !ClaudeSettingsScreen.models($0).isEmpty : command == "/effort" ? !ClaudeSettingsScreen.effort($0).values.isEmpty : ClaudeSettingsScreen.menu($0) }
        owned.command = nil
        return menu
    }
    private func dismiss() async throws {
        guard owned.menu, ClaudeSettingsScreen.menu(try await screen()) else { return }
        try await keys(["escape"])
        _ = try await wait { ClaudeSettingsScreen.prompt($0) == "" }
        owned.menu = false
    }
    private func cleanup() async {
        await Task.detached {
            try? await dismiss()
            if let command = owned.command, let text = try? await screen(), ClaudeSettingsScreen.prompt(text) == command {
                try? await keys(["ctrl+u"])
            }
            owned.command = nil
        }.value
    }
    private func screen() async throws -> String {
        try Task.checkCancellation()
        let response = try await connection.call("pane.read", ["pane_id": paneID, "source": "visible", "format": "text", "strip_ansi": true])
        guard let read = response["read"] as? [String: Any], let text = read["text"] as? String else { throw failure("Claude's terminal did not return a screen.") }
        return text
    }
    private func keys(_ keys: [String]) async throws { _ = try await connection.call("pane.send_keys", ["pane_id": paneID, "keys": keys]) }
    private func wait(_ predicate: (String) -> Bool) async throws -> String {
        for _ in 0..<35 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let text = try await screen()
            if predicate(text) { return text }
        }
        throw failure("Claude didn't finish updating its settings menu. Check Terminal.")
    }
    private func failure(_ message: String) -> NSError { NSError(domain: "ClaudeSettings", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
private final class ClaudeSettingsOwnership: @unchecked Sendable {
    var menu = false
    var command: String?
}
