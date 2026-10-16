import Foundation

struct ConversationActivity: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case command, read, search, edit, web, agent, plan, tool }
    struct Step: Codable, Equatable, Sendable { var title: String; var status: String }
    enum Status: String, Codable, Sendable { case running, completed, failed }
    var kind: Kind
    var title: String
    var input: String
    var output: String? = nil
    var status: Status = .running
    var file: String? = nil
    var diff: String? = nil
    var exitCode: Int? = nil
    var startedAt: Date? = nil
    var completedAt: Date? = nil
    var language: String? = nil
    var steps: [Step]? = nil
    var symbol: String {
        switch kind {
        case .command: return "terminal"
        case .read: return "doc.text"
        case .search: return "magnifyingglass"
        case .edit: return "pencil.line"
        case .web: return "globe"
        case .agent: return "person.crop.circle.badge.clock"
        case .plan: return "checklist"
        case .tool: return "wrench.and.screwdriver"
        }
    }
    var additions: Int? { diff.map { $0.components(separatedBy: "\n").filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count } }
    var deletions: Int? { diff.map { $0.components(separatedBy: "\n").filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count } }
}

/// Normalization stays at the provider boundary; views consume display intent.
enum ConversationToolPresentation {
    static func activity(name: String, arguments: Any?, at date: Date?) -> ConversationActivity {
        let raw: String
        if let text = arguments as? String { raw = text }
        else if let args = arguments, JSONSerialization.isValidJSONObject(args), let data = try? JSONSerialization.data(withJSONObject: args, options: [.prettyPrinted, .sortedKeys]) {
            raw = String(decoding: data, as: UTF8.self)
        } else { raw = "" }
        let values = (arguments as? [String: Any]) ?? (raw.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        let tool = name.components(separatedBy: ".").last?.lowercased() ?? name.lowercased()
        let file = ["file_path", "path", "file", "target_file"].compactMap { values[$0] as? String }.first
        let target = file.map { URL(fileURLWithPath: $0).lastPathComponent }
        let command = ["command", "cmd"].compactMap { values[$0] as? String }.first
        var result = ConversationActivity(kind: .tool, title: name, input: String(raw.prefix(32_000)), startedAt: date)
        result.file = file
        if tool == "exec" {
            result.title = "Run tools"; result.language = "javascript"
            result.input = String(((values["code"] as? String) ?? raw).prefix(32_000))
        } else if ["update_plan", "todowrite", "todo_write"].contains(tool) {
            result.kind = .plan; result.title = "Update plan"
            let entries = (values["plan"] ?? values["todos"]) as? [[String: Any]] ?? []
            result.steps = entries.compactMap { value in
                guard let title = (value["step"] ?? value["content"]) as? String else { return nil }
                return .init(title: title, status: value["status"] as? String ?? "pending")
            }
        } else if ["write_stdin", "wait"].contains(tool) {
            result.kind = .command; result.title = "Check running command"
        } else if ["bash", "shell", "shell_command", "exec_command", "run_command", "terminal"].contains(tool) {
            result.kind = .command
            result.input = String((command ?? raw).prefix(32_000))
            result.title = String((command ?? "Run command").components(separatedBy: "\n").first?.prefix(100) ?? "Run command")
        } else if ["read", "read_file", "readfile", "view", "view_file"].contains(tool) {
            result.kind = .read; result.title = target.map { "Read " + $0 } ?? "Read file"
        } else if ["grep", "glob", "search", "search_code", "find", "file_search"].contains(tool) {
            result.kind = .search; result.title = (values["pattern"] as? String).map { "Search “" + String($0.prefix(70)) + "”" } ?? "Search files"
        } else if ["edit", "write", "write_file", "apply_patch", "multiedit", "str_replace_editor"].contains(tool) {
            result.kind = .edit; result.title = target.map { "Edit " + $0 } ?? "Update files"
            if let old = values["old_string"] as? String, let new = values["new_string"] as? String {
                result.diff = "--- " + (file ?? "before") + "\n+++ " + (file ?? "after") + "\n" + old.components(separatedBy: "\n").map { "-" + $0 }.joined(separator: "\n") + "\n" + new.components(separatedBy: "\n").map { "+" + $0 }.joined(separator: "\n")
            } else if tool == "apply_patch" {
                let patch = (values["patch"] as? String) ?? (values["input"] as? String) ?? raw
                result.diff = String(patch.prefix(64_000))
                let files = patch.components(separatedBy: "\n").compactMap { line -> String? in
                    for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(prefix) { return String(line.dropFirst(prefix.count)) }
                    return nil
                }
                if files.count == 1 { result.file = files[0]; result.title = "Edit " + URL(fileURLWithPath: files[0]).lastPathComponent }
                else if !files.isEmpty { result.title = "Update \(files.count) files" }
            }
        } else if tool.contains("web") || tool.contains("fetch") || tool.contains("browse") {
            result.kind = .web; result.title = (values["url"] as? String).flatMap { URL(string: $0)?.host }.map { "Browse " + $0 } ?? "Search the web"
        } else if ["agent", "task", "spawn_agent"].contains(tool) {
            result.kind = .agent; result.title = (values["description"] as? String) ?? "Delegate to an agent"
        }
        return result
    }
    static func output(_ value: Any?) -> String {
        if let text = value as? String { return bounded(text) }
        if let blocks = value as? [[String: Any]] {
            let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !text.isEmpty { return bounded(text) }
        }
        if let value, JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            return bounded(String(decoding: data, as: UTF8.self))
        }
        return ""
    }
    static func finish(_ activity: ConversationActivity, output: Any?, failed: Bool, at date: Date?) -> ConversationActivity {
        var activity = activity
        activity.output = self.output(output)
        activity.completedAt = date
        activity.exitCode = (output as? [String: Any])?["exit_code"] as? Int
        if activity.exitCode == nil, let text = activity.output,
           let range = text.range(of: #"(?:Process exited with code|Exit code:)\s*(-?\d+)"#, options: .regularExpression) {
            activity.exitCode = text[range].split(whereSeparator: { !$0.isNumber && $0 != "-" }).last.flatMap { Int($0) }
        }
        activity.status = failed || activity.exitCode.map { $0 != 0 } == true ? .failed : .completed
        return activity
    }
    private static func bounded(_ text: String) -> String {
        text.count <= 64_000 ? text : String(text.prefix(32_000)) + "\n… Output shortened …\n" + String(text.suffix(32_000))
    }
}
