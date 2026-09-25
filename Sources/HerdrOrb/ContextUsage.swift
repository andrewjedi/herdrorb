import Foundation

/// A provider-reported terminal footer reading, never an estimate from chat length.
struct ContextUsage: Equatable, Sendable {
    let usedPercent: Double

    static func footer(in raw: String, provider: String?) -> ContextUsage? {
        guard provider == "codex" || provider == "claude" else { return nil }
        let prompt = provider == "codex" ? "›" : "❯"
        let lines = raw.components(separatedBy: "\n")
        var fence: String?
        var composer: Int?
        for (index, line) in lines.enumerated() {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("```") || text.hasPrefix("~~~") {
                let marker = String(text.prefix(3))
                if fence == marker { fence = nil } else if fence == nil { fence = marker }
            }
            if fence == nil && text == prompt { composer = index }
        }
        // Only inspect footer rows following an empty composer. Never mine replies,
        // old /status reports, account quotas, or an arbitrary custom status script.
        guard let composer, lines.count - composer <= 12 else { return nil }
        let pattern = provider == "codex"
            ? #"(?:^|[·│|])\s*(\d{1,3}(?:\.\d+)?)%\s+context\s+(left|remaining|used)\s*(?=$|[·│|])"#
            : #"(?:^|[·│|])\s*(?:Context:\s*)?(\d{1,3}(?:\.\d+)?)%\s+(?:context(?:\s+(used|remaining|left))?|(used|remaining|left))\s*(?=$|[·│|])"#
        let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        for line in lines.dropFirst(composer + 1).reversed() {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let digits = Range(match.range(at: 1), in: line),
                  let percent = Double(line[digits]), (0...100).contains(percent) else { continue }
            let direction = (2..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: line).map { String(line[$0]).lowercased() } }.first
            guard let matchedRange = Range(match.range, in: line),
                  provider == "codex" || line[matchedRange].lowercased().contains("context") else { continue }
            return ContextUsage(usedPercent: direction == "left" || direction == "remaining" ? 100 - percent : percent)
        }
        return nil
    }
}
