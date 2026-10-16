import Foundation

/// Claude's protocol is independent of Codex. Only the confirmed values share a view model.
enum ClaudeSettingsScreen {
    static func prompt(_ text: String) -> String? {
        let lines = text.replacingOccurrences(of: "\u{00a0}", with: " ").components(separatedBy: .newlines)
        guard let index = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("❯") }),
              index > 0, lines[index - 1].trimmingCharacters(in: .whitespaces).hasPrefix("────"),
              index + 1 < lines.count, lines[index + 1].trimmingCharacters(in: .whitespaces).hasPrefix("────") else { return nil }
        let value = String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("Try \"") && value.hasSuffix("\"") { return "" }
        return value
    }
    static func mode(_ text: String) -> String? {
        guard prompt(text) != nil, let boundary = text.range(of: "❯", options: .backwards) else { return nil }
        let footer = String(text[boundary.upperBound...])
        for (label, id) in [("manual mode on", "manual"), ("accept edits on", "acceptEdits"), ("plan mode on", "plan"), ("auto mode on", "claudeAuto"), ("bypass permissions on", "bypassPermissions"), ("don't ask on", "dontAsk")] {
            if footer.contains(label) { return id }
        }
        return "manual"
    }
    struct Model: Equatable {
        let label: String
        let highlighted: Bool
        let current: Bool
    }
    static func models(_ text: String) -> [Model] {
        guard text.contains("Select model"), (text.contains("Esc to cancel") || text.contains("Esc to exit")) else { return [] }
        let regex = try! NSRegularExpression(pattern: #"^\s*(❯)?\s*\d+\.\s+(.+?)(?:\s*✔|\s{2,}|$)"#)
        return text.components(separatedBy: .newlines).compactMap { line in
            guard let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let r = Range(m.range(at: 2), in: line) else { return nil }
            return Model(label: String(line[r]).trimmingCharacters(in: .whitespaces), highlighted: m.range(at: 1).location != NSNotFound, current: line.contains("✔"))
        }
    }
    static func effort(_ text: String) -> (values: [String], selected: String?) {
        if !models(text).isEmpty, text.contains("←"), text.contains("→"),
           let range = text.range(of: #"(?i)\b(low|medium|high) effort\b"#, options: .regularExpression) {
            return (["low", "medium", "high"], text[range].split(separator: " ").first.map { $0.lowercased() })
        }
        let lines = text.components(separatedBy: .newlines)
        guard lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "Effort" }), (text.contains("Esc to cancel") || text.contains("Esc to exit")),
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
        !models(text).isEmpty || !effort(text).values.isEmpty || (text.contains("Fast mode (research preview)") && (text.contains("Esc to cancel") || text.contains("Esc to exit")))
    }
}

struct ClaudeSettingsBridge {
    let connection: any HerdrConnection
    let paneID: String
    private let owned = ClaudeSettingsOwnership()

    /// Exit only an idle, empty prompt and resume the exact provider conversation.
    /// Never type a launch command into a pane that may still belong to Claude.
    func restart(machine: Machine, sessionID: String, bypass: Bool) async throws {
        guard UUID(uuidString: sessionID) != nil else { throw failure("Connect saved history before restarting Claude.") }
        func pane() async throws -> Agent {
            let inventory = try HerdrClient.inventory(await connection.call("session.snapshot"), machine: machine)
            guard let pane = inventory.first(where: { $0.pane_id == paneID }) else { throw failure("The terminal is no longer available.") }
            return pane
        }
        let original = try await pane()
        let originalScreen = try await screen()
        guard original.agent == "claude", !["working", "blocked"].contains(original.agent_status),
              original.providerSession?.sessionID == sessionID.lowercased(),
              ClaudeSettingsScreen.prompt(originalScreen) == "" else {
            throw failure("Wait for Claude to finish and clear its terminal draft before restarting.")
        }
        _ = try await connection.call("pane.send_text", ["pane_id": paneID, "text": "/exit"])
        _ = try await wait { ClaudeSettingsScreen.prompt($0) == "/exit" }
        try await keys(["enter"])
        var exited = false
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if try await pane().isShell { exited = true; break }
        }
        guard exited else { throw failure("Claude has not exited. Check Terminal before trying again; your saved chat is preserved.") }
        let mode = bypass ? "bypassPermissions" : ClaudeSettingsScreen.mode(originalScreen) ?? "manual"
        let cliMode = mode == "manual" ? "default" : mode == "claudeAuto" ? "auto" : mode
        var args = ["--resume", sessionID, "--permission-mode", cliMode]
        if mode == "bypassPermissions" { args.append("--allow-dangerously-skip-permissions") }
        let parameters: [String: Any] = ["name": HerdrClient.sessionName(kind: "claude"), "kind": "claude", "pane_id": paneID, "args": args, "timeout_ms": 30_000]
        for attempt in 0..<20 {
            do {
                _ = try await connection.call("agent.start", parameters, timeout: 35)
                return
            } catch let error as RPCError where error.code == "agent_not_ready" {
                // The process started and is awaiting a user-owned setup choice.
                return
            } catch let error as RPCError where error.code == "agent_pane_busy" && attempt < 19 {
                // This rejection guarantees no command was sent. Shell process
                // detection can settle later than the session snapshot.
                try await Task.sleep(nanoseconds: 250_000_000)
                guard try await pane().isShell else { throw error }
            }
        }
    }

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
                        try await keys([menu.contains("s to use this session only") ? "s" : "enter"])
                        _ = try await wait { ClaudeSettingsScreen.prompt($0) == "" }
                        owned.menu = false
                        break
                    }
                    try await keys(Array(repeating: target > selected ? "down" : "up", count: abs(target - selected)))
                    let previous = rows
                    menu = try await wait { ClaudeSettingsScreen.models($0) != previous }
                }
            case "effort":
                var menu = try await openEffort()
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
                let menu = try await openEffort()
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
        var initial = try await screen()
        // Recover a model menu left open by an earlier bridge/version without
        // applying its highlighted value. The native popover owns this interaction.
        if ClaudeSettingsScreen.menu(initial) {
            owned.menu = true
            try await dismiss()
            initial = try await screen()
        }
        guard ClaudeSettingsScreen.prompt(initial) == "" else { throw failure("Finish or clear the existing Terminal input first.") }
        var result = SessionComposerSettings()
        result.access = ClaudeSettingsScreen.mode(initial)
        if let mode = result.access {
            result.accessOptions = mode == "dontAsk" ? [] : ["manual", "acceptEdits", "plan"]
            if ["claudeAuto", "bypassPermissions"].contains(mode) { result.accessOptions.append(mode) }
        }
        let modelMenu = try await open("/model")
        let rows = ClaudeSettingsScreen.models(modelMenu)
        result.models = rows.map(\.label)
        result.model = rows.first(where: \.current)?.label
        let inlineEffort = ClaudeSettingsScreen.effort(modelMenu)
        try await dismiss()
        if !inlineEffort.values.isEmpty {
            result.availableEfforts = inlineEffort.values
            result.effort = inlineEffort.selected
        } else {
            // Newer Claude releases have a dedicated effort screen.
            do {
                let effortMenu = try await open("/effort")
                let parsed = ClaudeSettingsScreen.effort(effortMenu)
                result.availableEfforts = parsed.values
                result.effort = parsed.selected
                try await dismiss()
            } catch is CancellationError { throw CancellationError() }
            catch { await cleanup() }
        }
        return result
    }
    private func openEffort() async throws -> String {
        let menu = try await open("/model")
        if !ClaudeSettingsScreen.effort(menu).values.isEmpty { return menu }
        try await dismiss()
        return try await open("/effort")
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
