import Foundation

/// A recognized, currently selected CLI permission menu. Unknown menus stay in Terminal.
struct ConversationApproval: Equatable, Sendable {
    struct Choice: Identifiable, Equatable, Sendable { var id: Int; var title: String }
    var title: String
    var context: String
    var choices: [Choice]
    var selected: Int
    var snapshot: String
    static func parse(_ text: String, provider: String?) -> Self? {
        guard provider == nil || ["codex", "claude"].contains(provider) else { return nil }
        let lines = text.components(separatedBy: .newlines)
        let questions = ["Do you want to proceed?", "Do you want to make this edit?", "Would you like to run the following command?", "Would you like to make the following edits?"]
        guard let question = lines.lastIndex(where: { questions.contains($0.trimmingCharacters(in: .whitespaces)) }),
              lines.count - question < 90 else { return nil }
        // A quoted example or an old menu followed by a fresh prompt is not actionable.
        var fenced = false
        for line in lines.prefix(question + 1) {
            let clean = line.trimmingCharacters(in: .whitespaces)
            if clean.hasPrefix("```") || clean.hasPrefix("~~~") { fenced.toggle() }
        }
        guard !fenced, let last = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?.lowercased(),
              last.contains("esc") && (last.contains("cancel") || last.contains("confirm") || last.contains("amend")) else { return nil }
        let pattern = #"^\s*([❯›>]?)\s*([1-9])[.)]\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        var choices: [Choice] = [], selected: Int?
        var firstChoice: Int?
        for (index, line) in lines.enumerated() where index > question {
            if let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let numberRange = Range(match.range(at: 2), in: line), let number = Int(line[numberRange]),
               let titleRange = Range(match.range(at: 3), in: line), let selection = Range(match.range(at: 1), in: line) {
                choices.append(.init(id: number, title: String(line[titleRange])))
                if !line[selection].isEmpty { selected = number }
                if firstChoice == nil { firstChoice = index }
            } else if !choices.isEmpty {
                let clean = line.trimmingCharacters(in: .whitespaces)
                if clean.isEmpty || clean.lowercased().contains("esc") || clean.lowercased().contains("enter to") { continue }
                // Indented continuation lines belong to the full permission label.
                guard line.hasPrefix("  ") else { return nil }
                choices[choices.count - 1].title += " " + clean
            }
        }
        guard (2...5).contains(choices.count), Set(choices.map(\.id)).count == choices.count,
              choices.map(\.id) == Array(1...choices.count), let selected, let firstChoice else { return nil }
        // Claude prints the command before its question. Preserve that context too.
        let start = max(0, question - 16)
        let context = lines[start..<firstChoice].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(title: lines[question].trimmingCharacters(in: .whitespaces), context: context,
                     choices: choices, selected: selected, snapshot: text)
    }
    func keys(for choice: Int) -> [String]? {
        guard choices.contains(where: { $0.id == choice }) else { return nil }
        return Array(repeating: choice > selected ? "down" : "up", count: abs(choice - selected)) + ["enter"]
    }
}
