import Foundation
import CryptoKit

/// Removes only recognizable Codex input chrome at the end of a snapshot.
/// Leave the original snapshot available in the UI for diagnostics.
enum TerminalPresentation {
    static func conversation(_ raw: String, kind: String?) -> String {
        guard kind == "codex" else { return raw }
        var lines = removingStartup(raw.components(separatedBy: "\n"))
        let placeholder = lines.lastIndex { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            return text == "›" || (text.hasPrefix("›") && text.contains("Ask Codex to do anything"))
        }
        if let placeholder {
            // A footer is recognizable by its model/status row or by being the final prompt.
            let tail = lines.dropFirst(placeholder + 1)
            // Cached history can contain an earlier footer followed by newer turns.
            // Never discard those turns just because a model row occurs somewhere later.
            if tail.allSatisfy({ decoration($0) || ($0.trimmingCharacters(in: .whitespaces).hasPrefix("gpt-") && $0.contains("·")) }) {
                lines = Array(lines.prefix(placeholder))
                while let last = lines.last, decoration(last) { lines.removeLast() }
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removingStartup(_ lines: [String]) -> [String] {
        // Only recognize the initial CLI welcome card, never matching prose later in a reply.
        guard let title = lines.prefix(12).firstIndex(where: { $0.contains("OpenAI Codex (v") }),
              !lines.prefix(title).contains(where: { $0.hasPrefix("› ") || $0.hasPrefix("• ") || $0.contains("```") }),
              let end = lines.indices.dropFirst(title + 1).prefix(12).first(where: { lines[$0].contains("╰") || lines[$0].contains("└") }) else { return lines }
        var remaining = Array(lines.dropFirst(end + 1))
        while let first = remaining.first {
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.unicodeScalars.allSatisfy({ (0x2500...0x257F).contains($0.value) || CharacterSet.whitespaces.contains($0) }) {
                remaining.removeFirst()
            } else if trimmed.hasPrefix("Tip:") {
                remaining.removeFirst()
                if remaining.first?.trimmingCharacters(in: .whitespaces).hasPrefix("https://chatgpt.com/codex") == true { remaining.removeFirst() }
            } else { break }
        }
        return remaining
    }

    static func activityNotice(_ raw: String, status: String) -> String? {
        guard status == "working" else { return nil }
        if raw.contains("request timed out") || raw.contains("Reconnecting") {
            return "Codex is retrying its network connection. Messages already delivered may take longer to answer."
        }
        if raw.contains("Messages to be submitted after next tool call") {
            return "Codex has queued your follow-up messages while it finishes the current response."
        }
        return nil
    }

    private static func decoration(_ line: String) -> Bool {
        line.unicodeScalars.allSatisfy {
            CharacterSet.whitespaces.contains($0) || (0x2800...0x28FF).contains($0.value) || [0x2E, 0xB7, 0x2022, 0x22C5].contains($0.value)
        }
    }
}

struct SessionMessage: Identifiable, Equatable, Sendable {
    var id: String
    var fromUser: Bool
    var text: String
    var parts: [MessagePart] = []
    var artifacts: [ArtifactReference] = []
}
struct MessagePart: Equatable, Sendable {
    var text: String
    var status: Bool
}
struct ArtifactReference: Identifiable, Equatable, Sendable {
    var path: String
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var isImage: Bool { ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff"].contains((path as NSString).pathExtension.lowercased()) }
}
extension TerminalPresentation {
    static func parts(_ text: String, fromUser: Bool) -> [MessagePart] {
        guard !fromUser else { return [MessagePart(text: text, status: false)] }
        var parts: [MessagePart] = [], body: [String] = [], fenced = false
        func flush() {
            let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { parts.append(MessagePart(text: text, status: false)) }; body = []
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { fenced.toggle() }
            let pattern = #"^(?:[Dd]one \d{1,2}:\d{2}(?:\s*[APap][Mm])?|Worked for \d[^\n]*(?:s|m|h)(?:\s*·\s*done \d{1,2}:\d{2}(?:\s*[APap][Mm])?)?)$"#
            if !fenced && trimmed.range(of: pattern, options: .regularExpression) != nil {
                flush(); parts.append(MessagePart(text: trimmed, status: true))
            } else { body.append(line) }
        }
        flush(); return parts
    }

    static func artifacts(_ text: String) -> [ArtifactReference] {
        let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "svg", "pdf", "txt", "md", "csv", "json", "docx", "xlsx", "pptx", "mp4", "mov", "mp3", "wav", "swift", "py", "js", "ts", "tsx", "jsx", "css", "html", "rs", "go"]
        var candidates: [String] = []
        // Explicit links and backticked paths retain spaces in filenames.
        for pattern in [#"!?\[[^\]\n]*\]\(([^)\n]+)\)"#, #"`((?:/|file:///)[^`\n]+)`"#, #"(file:///[^\s<>`]+|/(?:Users|tmp|private|var|Volumes)/[^\s<>`]+)"#] {
            let regex = try! NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) { candidates.append(String(text[range])) }
            }
        }
        // Plain parenthesized relative paths are common in Codex's rendered links.
        // Join only path-shaped continuation lines, never unrelated prose.
        let lines = text.components(separatedBy: "\n")
        let startPattern = #"(?:file:///|/(?:Users|tmp|private|var|Volumes)/|\.{1,2}/|\.[A-Za-z0-9_-]+/|\b[A-Za-z0-9_-]+/)[^\s<>`\"()]*"#
        let starts = try! NSRegularExpression(pattern: startPattern)
        var consumedLines = Set<Int>()
        for index in lines.indices {
            if consumedLines.contains(index) { continue }
            let line = lines[index]
            for match in starts.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                guard let range = Range(match.range, in: line) else { continue }
                // Do not mistake the path inside an https URL for a local artifact.
                let prefix = String(line[..<range.lowerBound])
                if prefix.range(of: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s]*$"#, options: .regularExpression) != nil { continue }
                // Preserve leading dots in hidden directories and ./ relative paths.
                var path = String(line[range])
                while path.last.map({ ".,;".contains($0) }) == true { path.removeLast() }
                var joined: [Int] = []
                for (offset, next) in lines.dropFirst(index + 1).prefix(6).enumerated() {
                    if extensions.contains((path as NSString).pathExtension.lowercased()) { break }
                    let continuation = next.trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: ").,;`>"))
                    guard !continuation.isEmpty, continuation.range(of: #"^[A-Za-z0-9_./%+-]+$"#, options: .regularExpression) != nil else { break }
                    path += continuation
                    joined.append(index + offset + 1)
                }
                if extensions.contains((path as NSString).pathExtension.lowercased()) { consumedLines.formUnion(joined) }
                candidates.append(path)
            }
        }
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            var path = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'"))
            while path.last.map({ ").,;".contains($0) }) == true { path.removeLast() }
            if path.hasPrefix("file://") {
                guard let url = URL(string: path), url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
                path = url.path
            } else { path = path.removingPercentEncoding ?? path }
            guard !path.contains("://"), !path.contains("\0"), extensions.contains((path as NSString).pathExtension.lowercased()), seen.insert(path).inserted else { return nil }
            return ArtifactReference(path: path)
        }
    }
    static func mergeHistory(_ history: String, live: String) -> String {
        if history.isEmpty { return live }
        if live.isEmpty || history.contains(live) { return history }
        if live.contains(history) { return live }
        let old = history.components(separatedBy: "\n"), new = live.components(separatedBy: "\n")
        for size in stride(from: min(old.count, new.count), through: 2, by: -1) {
            if Array(old.suffix(size)) == Array(new.prefix(size)) { return (old + new.dropFirst(size)).joined(separator: "\n") }
        }
        // Same viewport with an evolving final response: replace its matching suffix.
        let minimum = min(3, new.count)
        if minimum > 0 {
            for start in old.indices.reversed() {
                let available = min(old.count - start, new.count)
                if available >= minimum && Array(old[start..<(start + minimum)]) == Array(new.prefix(minimum)) {
                    return (Array(old.prefix(start)) + new).joined(separator: "\n")
                }
            }
        }
        // No trustworthy overlap: keep a visible boundary instead of inventing continuity.
        return history + "\n\n— Live terminal view —\n\n" + live
    }

    /// Terminal-derived grouping, not a claim of structured agent history.
    static func messages(_ raw: String, kind: String?) -> [SessionMessage] {
        let cleaned = conversation(raw, kind: kind)
        let lines = cleaned.components(separatedBy: "\n")
        let marker = kind == "codex" ? "› " : "❯ "
        var result: [SessionMessage] = []
        var buffer: [String] = []
        var user = false
        var anchor = "leading"
        var ordinal = 0
        var occurrences: [String: Int] = [:]
        func flush() {
            let text = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                if user {
                    let hash = String(SHA256.hash(data: Data(text.utf8)).description)
                    let count = occurrences[hash, default: 0]; occurrences[hash] = count + 1
                    anchor = "\(hash)-\(count)"; ordinal = 0
                }
                let identity = "\(anchor)-\(user ? "user" : "reply")-\(ordinal)"
                result.append(SessionMessage(id: identity, fromUser: user, text: text, parts: parts(text, fromUser: user), artifacts: user ? [] : artifacts(text))); ordinal += 1
            }
            buffer = []
        }
        var inCode = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle() }
            if line.hasPrefix(marker) && !inCode {
                flush(); user = true; buffer.append(String(line.dropFirst(marker.count)))
            } else if user && !inCode && (line.hasPrefix("• ") || line.hasPrefix("● ")) {
                flush(); user = false; buffer.append(line)
            } else {
                buffer.append(line)
            }
        }
        flush()
        return result
    }
}

/// Lightweight blocks preserve terminal line breaks while adding readable Markdown structure.
struct ConversationBlock: Equatable {
    enum Kind: Equatable { case paragraph, heading, item(String), code }
    var kind: Kind
    var text: String
    static func parse(_ text: String) -> [ConversationBlock] {
        var blocks: [ConversationBlock] = []
        var code: [String]? = nil
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let content = code { blocks.append(.init(kind: .code, text: content.joined(separator: "\n"))); code = nil }
                else { code = [] }
                continue
            }
            if code != nil { code?.append(line); continue }
            if trimmed.isEmpty { blocks.append(.init(kind: .paragraph, text: "")); continue }
            if let range = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                blocks.append(.init(kind: .heading, text: String(trimmed[range.upperBound...])))
            } else if let range = trimmed.range(of: #"^(?:[-*+•●]|[0-9]+[.)])\s+"#, options: .regularExpression) {
                let marker = String(trimmed[range]).trimmingCharacters(in: .whitespaces)
                blocks.append(.init(kind: .item(marker.count == 1 ? "•" : marker), text: String(trimmed[range.upperBound...])))
            } else if let last = blocks.last, !last.text.isEmpty, last.kind == .paragraph {
                blocks[blocks.count - 1].text += "\n" + line
            } else { blocks.append(.init(kind: .paragraph, text: line)) }
        }
        if let code { blocks.append(.init(kind: .code, text: code.joined(separator: "\n"))) }
        return blocks
    }
}
