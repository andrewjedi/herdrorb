import Foundation

typealias CodexSessionSettings = SessionComposerSettings

/// Values confirmed by the connected CLI. An absent value is deliberately not a default.
struct SessionComposerSettings: Equatable {
    var providerSessionID: String?
    var access: String?
    var model: String?
    var effort: String?
    var speed: String?
    var defaultEffort: String?
    var models: [String] = []
    var availableEfforts: [String] = []
    var accessOptions: [String] = []
    var speeds: [String] = []
    var efforts: [String] { availableEfforts }

    static let preview = Self(access: "full", model: "gpt-6-astra", effort: "low", speed: "fast", defaultEffort: "low",
        models: ["gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"],
        availableEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"], accessOptions: ["ask", "auto", "full"], speeds: ["standard", "fast"])

    func merging(_ other: Self) -> Self {
        var result = self
        result.providerSessionID = other.providerSessionID ?? providerSessionID
        result.access = other.access ?? access
        result.model = other.model ?? model
        result.effort = other.effort ?? effort
        result.speed = other.speed ?? speed
        result.defaultEffort = other.defaultEffort ?? defaultEffort
        if !other.models.isEmpty { result.models = other.models }
        if !other.availableEfforts.isEmpty { result.availableEfforts = other.availableEfforts }
        if !other.accessOptions.isEmpty { result.accessOptions = other.accessOptions }
        if !other.speeds.isEmpty { result.speeds = other.speeds }
        return result
    }

    static func modelID(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: " ", with: "-")
    }

    static func effortID(_ label: String) -> String? {
        let value = label.lowercased().trimmingCharacters(in: .whitespaces)
        return ["none": "none", "minimal": "minimal", "low": "low", "light": "low",
                "medium": "medium", "high": "high", "extra high": "xhigh", "xhigh": "xhigh",
                "max": "max", "ultra": "ultra", "persistent": "persistent"][value]
    }

    static func accessID(_ label: String) -> String? {
        let value = label.lowercased()
        if value.contains("full access") || value.contains("danger-full-access") { return "full" }
        if value.contains("approve for me") { return "auto" }
        if value.contains("ask for approval") { return "ask" }
        return nil
    }

    static func observed(in text: String) -> Self {
        var result = Self()
        // Only the current composer footer is authoritative; earlier answers may quote settings.
        let lines = text.components(separatedBy: .newlines)
        if let prompt = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("›") }) {
            let footer = lines.dropFirst(prompt + 1).joined(separator: "\n")
            if let match = captures(#"(?im)^\s*(gpt-[a-z0-9. -]+?)\s+(none|minimal|low|medium|high|xhigh|max|ultra|persistent|default)(?:\s+(fast))?\s*[·•]"#, in: footer) {
                result.model = modelID(match[0])
                result.effort = effortID(match[1])
                result.speed = match.count > 2 && match[2] == "fast" ? "fast" : "standard"
                if result.speed == "fast" { result.speeds = ["standard", "fast"] }
            }
        }
        return result
    }

    static func status(in text: String) -> Self {
        var result = observed(in: text)
        // `/status` is issued by the bridge immediately before reading this block.
        if let match = captures(#"(?i)Model:\s+([a-z0-9_.-]+)(?:\s+\(reasoning\s+([a-z]+))?"#, in: text, last: true) {
            result.model = result.model ?? modelID(match[0])
            if match.count > 1 { result.effort = result.effort ?? effortID(match[1]) }
        }
        if let match = captures(#"(?im)Permissions:\s+([^│\n]+)"#, in: text, last: true) {
            result.access = accessID(match[0])
        }
        if let match = captures(#"(?im)^\s*[│|]?\s*Session(?: ID)?:\s*([0-9a-f-]{36})\b"#, in: text, last: true), UUID(uuidString: match[0]) != nil {
            result.providerSessionID = match[0].lowercased()
        }
        return result
    }

    fileprivate static func captures(_ pattern: String, in text: String, last: Bool = false) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let match = last ? matches.last : matches.first else { return nil }
        return (1..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: text) else { return "" }
            return String(text[range])
        }
    }
}

/// A bounded adapter for the installed CLI's own menus. It never submits prose or guesses a
/// menu index. Model/effort choices use the CLI's session-only action when it is available.
struct CodexSettingsBridge {
    let connection: any HerdrConnection
    let paneID: String
    private let interaction = CodexSettingsInteraction()

    func identifySession() async throws -> String? {
        do { return try await readStatus().providerSessionID }
        catch { await cleanUpOwnedMenus(); throw error }
    }
    func read() async throws -> CodexSessionSettings {
        do {
            var settings = try await readStatus()
            var menu = try await openMenu("/permissions", kind: .permissions)
            settings.accessOptions = menu.items.compactMap { CodexSessionSettings.accessID($0.label) }
            if let current = menu.items.first(where: \.current) {
                settings.access = CodexSessionSettings.accessID(current.label) ?? settings.access
            }
            try await dismissMenus()
            menu = try await openModelMenu()
            settings.models = menu.items.compactMap { item in
                item.label.lowercased().hasPrefix("gpt-") ? CodexSessionSettings.modelID(item.label) : nil
            }
            if let current = menu.items.first(where: \.current), current.label.lowercased().hasPrefix("gpt-") {
                settings.model = CodexSessionSettings.modelID(current.label)
            }
            if let model = settings.model,
               let current = menu.items.first(where: { CodexSessionSettings.modelID($0.label) == model }),
               !menu.sessionAction {
                // A model row with a session shortcut applies directly. Do not select it just to read.
                let next = try await select(current.label, in: menu)
                if let effortMenu = CodexSettingsMenu.parse(next), effortMenu.kind == .effort {
                    settings.availableEfforts = effortMenu.efforts
                    settings.defaultEffort = effortMenu.items.first(where: \.isDefault).flatMap { CodexSessionSettings.effortID($0.label) }
                    if let current = effortMenu.items.first(where: \.current) {
                        settings.effort = CodexSessionSettings.effortID(current.label) ?? settings.effort
                    }
                    if let more = effortMenu.items.first(where: { $0.label.hasPrefix("More reasoning") }) {
                        let advancedText = try await select(more.label, in: effortMenu)
                        if let advanced = CodexSettingsMenu.parse(advancedText), advanced.kind == .advanced {
                            settings.availableEfforts = Array(Set(settings.availableEfforts + advanced.efforts)).sorted { Self.effortOrder($0) < Self.effortOrder($1) }
                            if let current = advanced.items.first(where: \.current) {
                                settings.effort = CodexSessionSettings.effortID(current.label) ?? settings.effort
                            }
                        } else { throw unavailable("Codex's reasoning menu changed.") }
                    }
                } else { throw unavailable("Codex did not open its reasoning menu.") }
            }
            try await dismissMenus()
            settings.speeds = try await discoverSpeeds()
            return settings
        } catch {
            await cleanUpOwnedMenus()
            throw error
        }
    }

    func refresh() async throws -> CodexSessionSettings { try await read() }

    func update(key: String, value: String, current: CodexSessionSettings) async throws -> CodexSessionSettings {
        guard ["access", "model", "effort", "speed"].contains(key) else { throw unavailable("Unknown setting.") }
        do {
            let before = try await screen()
            guard Self.isEmptyComposer(before), CodexSettingsMenu.parse(before) == nil else {
                throw unavailable("Finish or clear the existing Terminal input before changing settings.")
            }
            var result = current.merging(CodexSessionSettings.observed(in: before))
            if (key == "effort" && result.model == nil) || (key == "speed" && CodexSessionSettings.observed(in: before).speed == nil) {
                result = result.merging(try await readStatus())
            }
            switch key {
            case "access":
                guard ["ask", "auto", "full"].contains(value) else { throw unavailable("Unknown access mode.") }
                let menu = try await openMenu("/permissions", kind: .permissions)
                guard let item = menu.items.first(where: { CodexSessionSettings.accessID($0.label) == value }) else {
                    throw unavailable("This Codex session does not offer that access mode.")
                }
                let next = try await select(item.label, in: menu)
                if value == "full", let confirm = CodexSettingsMenu.parse(next), confirm.kind == .fullAccess {
                    guard let yes = confirm.items.first(where: { $0.label.hasPrefix("Yes, continue") }) else {
                        throw unavailable("Review Codex's full access confirmation in Terminal.")
                    }
                    _ = try await select(yes.label, in: confirm)
                }
            case "model", "effort":
                let targetModel = key == "model" ? value : result.model
                guard let targetModel else { throw unavailable("The current model could not be read.") }
                let models = try await openModelMenu()
                guard let item = models.items.first(where: { CodexSessionSettings.modelID($0.label) == targetModel }) else {
                    throw unavailable("This Codex session does not offer that model.")
                }
                let next = try await select(item.label, in: models, sessionOnly: true)
                if var menu = CodexSettingsMenu.parse(next), menu.kind == .effort {
                    result.availableEfforts = menu.efforts
                    let defaultChoice = menu.items.first(where: \.isDefault)
                    result.defaultEffort = defaultChoice.flatMap { CodexSessionSettings.effortID($0.label) }
                    let targetEffort = key == "effort" ? value : result.effort
                    var choice = menu.items.first(where: { CodexSessionSettings.effortID($0.label) == targetEffort })
                    if choice == nil, let targetEffort, ["max", "ultra"].contains(targetEffort),
                       let more = menu.items.first(where: { $0.label.hasPrefix("More reasoning") }) {
                        let advancedText = try await select(more.label, in: menu)
                        guard let advanced = CodexSettingsMenu.parse(advancedText), advanced.kind == .advanced else {
                            throw unavailable("Codex's advanced reasoning menu changed.")
                        }
                        menu = advanced
                        result.availableEfforts = Array(Set(result.availableEfforts + advanced.efforts)).sorted { Self.effortOrder($0) < Self.effortOrder($1) }
                        choice = advanced.items.first(where: { CodexSessionSettings.effortID($0.label) == targetEffort })
                    }
                    if choice == nil && key == "model" {
                        if menu.kind == .advanced {
                            try await keys(["escape"])
                            let base = try await waitFor { CodexSettingsMenu.parse($0)?.kind == .effort }
                            guard let restored = CodexSettingsMenu.parse(base) else { throw unavailable("Codex's reasoning menu changed.") }
                            menu = restored
                        }
                        choice = menu.items.first(where: { $0.label == defaultChoice?.label })
                    }
                    guard let choice else { throw unavailable("This model does not offer that effort level.") }
                    _ = try await select(choice.label, in: menu, sessionOnly: true)
                } else if key == "effort" { throw unavailable("This model does not offer an effort menu.") }
            case "speed":
                guard ["standard", "fast"].contains(value), let speed = result.speed else {
                    throw unavailable("Codex's current speed could not be confirmed.")
                }
                if speed != value { _ = try await command("/fast") }
            default: break
            }
            try await dismissMenus()
            var verified = CodexSessionSettings.observed(in: try await screen())
            // The fresh CLI footer confirms model, effort and speed without submitting /status.
            if key == "access" || (key == "model" && verified.model == nil) || (key == "effort" && verified.effort == nil) || (key == "speed" && verified.speed == nil) {
                verified = try await readStatus()
            }
            let actual: String?
            switch key {
            case "access": actual = verified.access
            case "model": actual = verified.model
            case "effort": actual = verified.effort
            default: actual = verified.speed
            }
            guard actual == value else { throw unavailable("The setting change was not confirmed by Codex.") }
            result = result.merging(verified)
            if key == "model" { result.speeds = try await discoverSpeeds() }
            return result
        } catch {
            await cleanUpOwnedMenus()
            throw error
        }
    }

    private func readStatus() async throws -> CodexSessionSettings {
        let text = try await command("/status")
        guard text.contains("Model:"), text.contains("Permissions:") else {
            throw unavailable("Codex's current settings could not be read.")
        }
        return CodexSessionSettings.status(in: text)
    }

    private static func effortOrder(_ effort: String) -> Int {
        ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra", "persistent"].firstIndex(of: effort) ?? 100
    }

    private func discoverSpeeds() async throws -> [String] {
        let typed = try await prepareCommand("/fast")
        let supported = Self.offersCommand("/fast", in: typed)
        try await clearOwnedCommand()
        return supported ? ["standard", "fast"] : ["standard"]
    }

    private func openModelMenu() async throws -> CodexSettingsMenu {
        let menu = try await openMenu("/model", kind: .model)
        if let all = menu.items.first(where: { $0.label == "All models" }) {
            let next = try await select(all.label, in: menu)
            guard let full = CodexSettingsMenu.parse(next), full.kind == .model else {
                throw unavailable("Codex's model menu changed.")
            }
            return full
        }
        return menu
    }

    private func openMenu(_ slash: String, kind: CodexSettingsMenu.Kind) async throws -> CodexSettingsMenu {
        let text = try await command(slash)
        guard let menu = CodexSettingsMenu.parse(text), menu.kind == kind, !menu.items.isEmpty else {
            throw unavailable("This Codex version did not open the expected settings menu.")
        }
        return menu
    }

    private func command(_ text: String) async throws -> String {
        let typed = try await prepareCommand(text)
        if text == "/fast", !Self.offersCommand(text, in: typed) {
            throw unavailable("Fast mode is not offered by the current model.")
        }
        if text == "/model" || text == "/permissions" { interaction.ownsMenu = true }
        try await keys(["enter"])
        let output = try await waitFor { output in
            guard output != typed else { return false }
            if text == "/status" { return Self.isEmptyComposer(output) && output.contains("Model:") && output.contains("Permissions:") }
            if text == "/fast" { return Self.isEmptyComposer(output) }
            return CodexSettingsMenu.parse(output) != nil
        }
        interaction.ownedCommand = nil
        return output
    }

    private func prepareCommand(_ text: String) async throws -> String {
        let before = try await screen()
        guard CodexSettingsMenu.parse(before) == nil, Self.isEmptyComposer(before) else {
            throw unavailable("Finish or clear the existing Terminal input before changing settings.")
        }
        interaction.ownedCommand = text
        _ = try await connection.call("pane.send_text", ["pane_id": paneID, "text": text])
        let typed = try await waitFor { Self.composerText($0) == text }
        guard Self.composerText(typed) == text else {
            throw unavailable("The settings command could not be prepared safely.")
        }
        return typed
    }

    private static func offersCommand(_ command: String, in text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { line in
            let candidate = line.trimmingCharacters(in: .whitespaces)
            return candidate.hasPrefix(command + " ") || candidate.hasPrefix(command + "\t")
        }
    }

    private func select(_ label: String, in expected: CodexSettingsMenu, sessionOnly: Bool = false) async throws -> String {
        var seen: Set<String> = []
        for _ in 0..<24 {
            let text = try await screen()
            guard let menu = CodexSettingsMenu.parse(text), menu.kind == expected.kind,
                  let highlighted = menu.items.first(where: \.highlighted),
                  let target = menu.items.first(where: { $0.label == label }) else {
                throw unavailable("Codex's menu changed before the selection could be applied.")
            }
            if highlighted.label == label {
                if sessionOnly && menu.sessionAction { try await keys(["s"]) }
                else { try await keys(["enter"]) }
                return try await waitFor { next in
                    guard let nextMenu = CodexSettingsMenu.parse(next) else { return Self.isEmptyComposer(next) }
                    return nextMenu.kind != menu.kind || (nextMenu != menu && nextMenu.items.contains(where: { $0.label == label && $0.current }))
                }
            }
            let marker = "\(highlighted.number):\(highlighted.label)"
            guard seen.insert(marker).inserted else { throw unavailable("Codex did not move to the requested setting.") }
            guard let from = menu.items.firstIndex(of: highlighted), let to = menu.items.firstIndex(of: target) else {
                throw unavailable("Codex's menu changed before navigation.")
            }
            // Deliver navigation together; still verify the highlighted row before selecting it.
            try await keys(Array(repeating: from < to ? "down" : "up", count: abs(to - from)))
            _ = try await waitFor { next in
                guard let nextMenu = CodexSettingsMenu.parse(next), nextMenu.kind == menu.kind else { return true }
                return nextMenu.items.first(where: \.highlighted)?.label != highlighted.label
            }
        }
        throw unavailable("The settings menu could not be navigated.")
    }

    private func dismissMenus() async throws {
        guard interaction.ownsMenu else { return }
        for _ in 0..<5 {
            let text = try await screen()
            guard let menu = CodexSettingsMenu.parse(text) else { interaction.ownsMenu = false; return }
            // Only close the menus this adapter understands; never answer unrelated approvals.
            try await keys(["escape"])
            _ = try await waitFor { next in CodexSettingsMenu.parse(next)?.kind != menu.kind || Self.isEmptyComposer(next) }
        }
        throw unavailable("Close Codex's settings menu in Terminal to continue.")
    }

    private func cleanUpOwnedMenus() async {
        guard interaction.ownsMenu || interaction.ownedCommand != nil else { return }
        // Cancellation must still release only menus opened by this operation.
        let cleanup = Task.detached {
            try? await dismissMenus()
            try? await clearOwnedCommand()
        }
        await cleanup.value
    }

    private func clearOwnedCommand() async throws {
        guard let command = interaction.ownedCommand else { return }
        let text = try await screen()
        guard CodexSettingsMenu.parse(text) == nil, Self.composerText(text) == command else {
            interaction.ownedCommand = nil
            return
        }
        try await keys(["ctrl+u"])
        _ = try await waitFor { Self.isEmptyComposer($0) }
        interaction.ownedCommand = nil
    }

    private func screen() async throws -> String {
        try Task.checkCancellation()
        let response = try await connection.call("pane.read", ["pane_id": paneID, "source": "visible", "format": "text", "strip_ansi": true])
        guard let read = response["read"] as? [String: Any], let text = read["text"] as? String else {
            throw unavailable("The terminal did not return its current screen.")
        }
        return text
    }

    private func keys(_ keys: [String]) async throws {
        _ = try await connection.call("pane.send_keys", ["pane_id": paneID, "keys": keys])
    }

    private func waitFor(_ predicate: (String) -> Bool) async throws -> String {
        for _ in 0..<25 {
            try await Task.sleep(nanoseconds: 80_000_000)
            let text = try await screen()
            if predicate(text) { return text }
        }
        throw unavailable("Codex did not finish updating its settings menu.")
    }

    static func composerText(_ text: String) -> String? {
        text.components(separatedBy: .newlines).reversed().compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("›") else { return nil }
            return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        }.first
    }

    static func isEmptyComposer(_ text: String) -> Bool {
        guard CodexSettingsMenu.parse(text) == nil, let draft = composerText(text) else { return false }
        guard draft.isEmpty || draft == "Ask Codex to do anything" else { return false }
        let lines = text.components(separatedBy: .newlines)
        guard let prompt = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("›") }) else { return false }
        let following = lines.dropFirst(prompt + 1).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // An empty first line of a multiline native draft is not an empty composer.
        guard let first = following.first else { return true }
        return first.lowercased().hasPrefix("gpt-") || first == "? for shortcuts"
    }

    private func unavailable(_ detail: String) -> BridgeError {
        .message(detail + " Open Terminal to finish there. Your conversation draft is saved.")
    }
}

private final class CodexSettingsInteraction: @unchecked Sendable {
    var ownsMenu = false
    var ownedCommand: String?
}

struct CodexSettingsMenu: Equatable {
    enum Kind: String { case model, effort, advanced, permissions, fullAccess }
    struct Item: Equatable {
        let number: Int
        let label: String
        let highlighted: Bool
        let current: Bool
        let isDefault: Bool
        let details: String
    }
    let kind: Kind
    let items: [Item]
    let sessionAction: Bool
    var efforts: [String] {
        var result = items.compactMap { CodexSessionSettings.effortID($0.label) }
        if let more = items.first(where: { $0.label.hasPrefix("More reasoning") }) {
            for (word, value) in [("Max", "max"), ("Ultra", "ultra")] where more.details.contains(word) {
                if !result.contains(value) { result.append(value) }
            }
        }
        return result
    }

    static func parse(_ text: String) -> Self? {
        let lines = text.components(separatedBy: .newlines)
        let headers: [(String, Kind)] = [("Select Model and Effort", .model), ("Select Model", .model),
            ("Select Reasoning Level for ", .effort), ("Advanced Reasoning", .advanced),
            ("Update Model Permissions", .permissions), ("Enable full access?", .fullAccess)]
        var found: (Int, Kind)?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let header = headers.first(where: { trimmed.hasPrefix($0.0) }) { found = (index, header.1) }
        }
        guard let (start, kind) = found else { return nil }
        let body = lines.dropFirst(start + 1)
        guard body.contains(where: { $0.contains("esc back") || $0.contains("esc to") || $0.contains("esc cancel") }) else { return nil }
        let items = body.compactMap { line -> Item? in
            guard let parts = CodexSessionSettings.captures(#"^\s*(›|>)?\s*(\d+)\.\s+(.+?)\s*$"#, in: line),
                  let number = Int(parts[1]) else { return nil }
            let remainder = parts[2]
            let rawLabel = remainder.components(separatedBy: "  ").first ?? remainder
            guard !rawLabel.contains("(disabled)") else { return nil }
            let label = rawLabel.replacingOccurrences(of: " (current)", with: "")
                .replacingOccurrences(of: " (default)", with: "").trimmingCharacters(in: .whitespaces)
            return Item(number: number, label: label, highlighted: !parts[0].isEmpty,
                        current: rawLabel.contains("(current)"), isDefault: rawLabel.contains("(default)"), details: remainder)
        }
        return Self(kind: kind, items: items, sessionAction: body.contains(where: { $0.contains("s session") }))
    }
}
