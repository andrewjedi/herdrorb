import Foundation

/// A provider-reported terminal footer reading, never an estimate from chat length.
struct ContextUsage: Equatable, Sendable, Codable {
    let usedPercent: Double
    var source: String = "Terminal footer"
    var sessionID: String? = nil
    var model: String? = nil
    var capacity: Int? = nil
    var tokens: Int? = nil
    var observedAt: Date? = nil

    static func codex(info: [String: Any]?, sessionID: String?, model: String?, observedAt: Date) -> Self? {
        guard let info, let capacity = info["model_context_window"] as? Int, capacity > 0,
              let last = info["last_token_usage"] as? [String: Any], let total = last["total_tokens"] as? Int, total >= 0 else { return nil }
        // Same baseline normalization as Codex's own context-remaining indicator.
        let effective = capacity - 12_000
        let remaining = effective > 0 ? (Double(max(0, effective - max(0, total - 12_000))) / Double(effective) * 100).rounded() : 0
        return Self(usedPercent: min(100, max(0, 100 - remaining)), source: "Codex session usage", sessionID: sessionID, model: model, capacity: capacity, tokens: total, observedAt: observedAt)
    }
    static func claude(_ json: [String: Any], sessionID: String) -> Self? {
        guard (json["session_id"] as? String)?.lowercased() == sessionID.lowercased(),
              let window = json["context_window"] as? [String: Any],
              let usage = window["current_usage"] as? [String: Any],
              let capacity = window["context_window_size"] as? Int, capacity > 0 else { return nil }
        let input = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].compactMap { usage[$0] as? Int }
        guard input.count == 3, input.allSatisfy({ $0 >= 0 }) else { return nil }
        var tokens = 0
        for value in input {
            let sum = tokens.addingReportingOverflow(value)
            guard !sum.overflow else { return nil }
            tokens = sum.partialValue
        }
        let percent = window["used_percentage"] as? Double ?? Double(tokens) / Double(capacity) * 100
        guard percent.isFinite, (0...100).contains(percent) else { return nil }
        return Self(usedPercent: percent, source: "Claude status-line telemetry", sessionID: sessionID,
            model: (json["model"] as? [String: Any])?["id"] as? String, capacity: capacity, tokens: tokens,
            observedAt: (json["herdrorb_observed_at"] as? Double).map { Date(timeIntervalSince1970: $0) })
    }

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
