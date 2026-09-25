import Foundation
import CryptoKit

/// Presents terminal snapshots as conversation while keeping raw output available.
/// Leave the original snapshot available in the UI for diagnostics.
enum TerminalPresentation {
    static func conversation(_ raw: String, kind: String?) -> String {
        if kind == "claude" { return removingClaudeSettings(raw) }
        guard kind == "codex" else { return raw }
        var lines = removingStartup(removingStatusCards(raw.components(separatedBy: "\n")))
        var fence: String?
        lines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if fence == marker { fence = nil } else if fence == nil { fence = marker }
                return true
            }
            // Strip the changing CLI timer before merging snapshots. Otherwise
            // a timer tick can look like new transcript content or even a new turn.
            return fence != nil || !(trimmed.hasPrefix("Working (") && trimmed.hasSuffix("esc to interrupt)"))
        }
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

    private static func removingClaudeSettings(_ raw: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        var result: [String] = []
        var index = 0
        var fence: String?
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if fence == marker { fence = nil } else if fence == nil { fence = marker }
            }
            if fence == nil, ["❯ /model", "❯ /effort", "❯ /fast", "❯ /fast on", "❯ /fast off"].contains(trimmed), index + 1 < lines.count {
                let response = lines[index + 1].trimmingCharacters(in: .whitespaces)
                let commandResponse = response.hasPrefix("⎿") && ["Kept model as ", "Set model to ", "Cancelled", "Fast mode ON", "Fast mode OFF", "Set effort to ", "Effort set to "].contains { response.dropFirst().trimmingCharacters(in: .whitespaces).hasPrefix($0) }
                if commandResponse { index += 2; continue }
            }
            result.append(line)
            index += 1
        }
        return result.joined(separator: "\n")
    }

    /// The native settings controls ask the CLI for /status. Its boxed account and
    /// configuration report belongs in Terminal, not in the conversation transcript.
    private static func removingStatusCards(_ lines: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        var fence: String?
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if fence == marker { fence = nil } else if fence == nil { fence = marker }
                result.append(line); index += 1; continue
            }
            if fence == nil, trimmed.hasPrefix("╭") || trimmed.hasPrefix("┌"),
               let end = lines.indices.dropFirst(index + 1).prefix(80).first(where: {
                   let row = lines[$0].trimmingCharacters(in: .whitespaces)
                   return row.hasPrefix("╰") || row.hasPrefix("└")
               }) {
                let card = lines[index...end].joined(separator: "\n")
                let preceding = result.lastIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                let command = preceding.map { result[$0].trimmingCharacters(in: .whitespaces) }
                if card.contains("OpenAI Codex (v"), card.contains("Model:"), card.contains("Permissions:"),
                   command == "/status" || command == "› /status" || result.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    if let preceding, command == "/status" || command == "› /status" { result.removeSubrange(preceding...) }
                    index = end + 1
                    continue
                }
            }
            result.append(line); index += 1
        }
        return result
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

struct SessionMessage: Identifiable, Equatable, Sendable, Codable {
    var id: String
    var fromUser: Bool
    var text: String
    var parts: [MessagePart] = []
    var artifacts: [ArtifactReference] = []
    var phase: String? = nil
    var source: String? = nil
}
struct MessagePart: Equatable, Sendable, Codable {
    var text: String
    var status: Bool
}

/// Bound initial SwiftUI layout without discarding searchable/saved history.
/// Pin by message identity while reading so incoming replies cannot slide the
/// top of the document out from underneath the reader.
enum ConversationWindow {
    static let pageSize = 40
    static func start(in messages: [SessionMessage], anchor: String?) -> Int {
        if let anchor, let index = messages.firstIndex(where: { $0.id == anchor }) { return index }
        return max(0, messages.count - pageSize)
    }
    static func latestAnchor(in messages: [SessionMessage]) -> String? {
        guard !messages.isEmpty else { return nil }
        return messages[max(0, messages.count - pageSize)].id
    }
}

/// A reversible presentation of terminal cells. Raw messages remain untouched for
/// search, caching, and the activity disclosure; this is not structured reasoning.
struct ConversationResponse: Equatable {
    var answer: String
    var activity: String
    var duration: String?
    var artifacts: [ArtifactReference] { TerminalPresentation.artifacts(answer) }
}

/// A presentation contract sent with conversation prompts, including follow-up
/// edits such as “make it blue”. Generation remains in the existing CLI session.
enum ConversationImageInstructions {
    static let start = "<herdrorb-image-display>"
    static let end = "</herdrorb-image-display>"
    static func prompt(_ text: String, kind: String?) -> String {
        guard kind == "codex" else { return text }
        return text + "\n\n" + start + "\n" + """
        This conversation supports inline local images and clickable Mac previews. When the user requests image generation or editing, use your native image generation tool if available. After it succeeds, include each resulting image in your final answer as ![description](<absolute file path>), using the actual saved file on this machine. Do not return only an image attachment: this viewer needs the file path. Preserve the image for later viewing and follow-up edits. If generation is unavailable or fails, explain that honestly; do not silently switch to an API-key or external paid fallback. For other requests, respond normally.
        """ + "\n" + end
    }
    static func userText(_ text: String) -> String {
        // Only remove our complete trailing block; preserve quoted examples and
        // incomplete terminal snapshots until the end marker arrives.
        let lines = text.components(separatedBy: "\n")
        guard lines.last?.trimmingCharacters(in: .whitespaces) == end,
              let index = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == start }) else { return text }
        return lines.prefix(index).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension TerminalPresentation {
    static func response(_ message: SessionMessage, kind: String?, working: Bool) -> ConversationResponse {
        guard !message.fromUser, kind == "codex" else {
            return ConversationResponse(answer: message.text, activity: "")
        }
        struct Cell {
            var text: String
            var tool: Bool
        }
        var cells: [Cell] = []
        var buffer: [String] = []
        var tool = false
        var fenced = false
        var duration: String?
        var completedBoundary = false
        var boundaryIndex: Int?
        func flush() {
            let text = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { cells.append(Cell(text: text, tool: tool)) }
            buffer = []
            tool = false
        }
        for line in message.text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle() }
            if !fenced {
                let status = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "─━ "))
                if status.range(of: #"^Worked for \d[^\n]*"#, options: .regularExpression) != nil {
                    flush()
                    duration = status.components(separatedBy: " · ").first
                    completedBoundary = true
                    boundaryIndex = cells.count
                    continue
                }
                if status.range(of: #"^[Dd]one \d{1,2}:\d{2}(?:\s*[APap][Mm])?$"#, options: .regularExpression) != nil { continue }
                if trimmed == "— Live terminal view —" {
                    flush()
                    tool = true
                    continue
                }
                if status.range(of: #"^Working\s*\(.*esc to interrupt\)$"#, options: .regularExpression) != nil {
                    flush()
                    continue
                }
                let marked = line.hasPrefix("• ") || line.hasPrefix("● ")
                let approved = line.hasPrefix("✔ ") || line.hasPrefix("✓ ")
                if marked || approved {
                    flush()
                    let content = String(line.dropFirst(2))
                    tool = approved || content.range(of: #"^(?:(?:Ran|Running|Called|Calling|Edited|Added|Deleted|Read|Searched|Searching|Exploring)\s|Explored(?:\s|$)|Updated [Pp]lan|You approved\s)"#, options: .regularExpression) != nil
                    buffer.append(content)
                    continue
                }
            }
            buffer.append(line)
        }
        flush()
        // The final prose cell after tool output is the answer. Earlier prose is
        // progress commentary. Without tool evidence, preserve all idle prose.
        let lastTool = cells.lastIndex(where: \.tool)
        let answerStart: Int
        if working && !completedBoundary { answerStart = cells.count }
        else if let lastTool { answerStart = lastTool + 1 }
        else if let boundaryIndex, boundaryIndex < cells.count { answerStart = boundaryIndex }
        else { answerStart = 0 }
        return ConversationResponse(
            answer: cells.dropFirst(answerStart).map(\.text).joined(separator: "\n\n"),
            activity: cells.prefix(answerStart).map(\.text).joined(separator: "\n\n"),
            duration: duration
        )
    }
}
struct ArtifactReference: Identifiable, Equatable, Sendable, Codable {
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
    /// Retain complete terminal-derived messages, including a single oversized
    /// message. The archive owns older rows; never cut into a fenced block.
    static func retainedHistory(_ raw: String, kind: String?) -> String {
        guard raw.count > 250_000 else { return raw }
        let parsed = messages(raw, kind: kind)
        var kept: [SessionMessage] = []; var count = 0
        for message in parsed.reversed() {
            if !kept.isEmpty && count + message.text.count > 250_000 { break }
            kept.append(message); count += message.text.count
        }
        let marker = kind == "codex" ? "› " : "❯ "
        return kept.reversed().map { ($0.fromUser ? marker : "") + $0.text }.joined(separator: "\n")
    }
    static func mergeHistory(_ history: String, live: String) -> String {
        if history.isEmpty { return live }
        if live.isEmpty || history.contains(live) { return history }
        if live.contains(history) { return live }
        let old = history.components(separatedBy: "\n"), new = live.components(separatedBy: "\n")
        // KMP finds the longest suffix/prefix overlap in linear time. Repeated
        // terminal lines previously allocated and compared every candidate suffix.
        var prefix = [Int](repeating: 0, count: new.count)
        if new.count > 1 {
            for index in 1..<new.count {
                var matched = prefix[index - 1]
                while matched > 0 && new[index] != new[matched] { matched = prefix[matched - 1] }
                if new[index] == new[matched] { matched += 1 }
                prefix[index] = matched
            }
        }
        var overlap = 0
        for line in old {
            while overlap > 0 && (overlap == new.count || line != new[overlap]) { overlap = prefix[overlap - 1] }
            if line == new[overlap] { overlap += 1 }
        }
        if overlap >= 2 { return (old + new.dropFirst(overlap)).joined(separator: "\n") }
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
    static func messages(_ raw: String, kind: String?, previous: [SessionMessage] = []) -> [SessionMessage] {
        let cleaned = conversation(raw, kind: kind)
        let lines = cleaned.components(separatedBy: "\n")
        let marker = kind == "codex" ? "› " : "❯ "
        var result: [SessionMessage] = []
        var buffer: [String] = []
        var user = false
        var anchor = "leading"
        var ordinal = 0
        var occurrences: [String: Int] = [:]
        let existing = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        func flush() {
            var text = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if user && kind == "codex" { text = ConversationImageInstructions.userText(text) }
            if !text.isEmpty {
                if user {
                    let hash = String(SHA256.hash(data: Data(text.utf8)).description)
                    let count = occurrences[hash, default: 0]; occurrences[hash] = count + 1
                    anchor = "\(hash)-\(count)"; ordinal = 0
                }
                let identity = "\(anchor)-\(user ? "user" : "reply")-\(ordinal)"
                if let old = existing[identity], old.fromUser == user, old.text == text {
                    result.append(old)
                } else {
                    result.append(SessionMessage(id: identity, fromUser: user, text: text, parts: parts(text, fromUser: user), artifacts: user ? [] : artifacts(text)))
                }
                ordinal += 1
            }
            buffer = []
        }
        var inCode = false
        var skippingFooter = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if kind == "codex" && !inCode {
                // Empty CLI composers can occur anywhere in accumulated snapshots.
                // They are UI, never a sent user message.
                let emptyPrompt = trimmed == "›" || (trimmed.hasPrefix("›") && trimmed.contains("Ask Codex to do anything"))
                if emptyPrompt {
                    flush()
                    user = false
                    skippingFooter = true
                    continue
                }
                let boundary = trimmed == "— Live terminal view —"
                let cell = line.hasPrefix(marker) || line.hasPrefix("• ") || line.hasPrefix("● ") || line.hasPrefix("✔ ") || line.hasPrefix("✓ ")
                let status = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "─━ "))
                let completion = status.hasPrefix("Worked for ")
                if skippingFooter {
                    if boundary || cell || completion { skippingFooter = false }
                    else { continue }
                }
                let transient = status.range(of: #"^Working\s*\(.*esc to interrupt\)$"#, options: .regularExpression) != nil
                if boundary || completion || transient {
                    if user { flush(); user = false }
                }
                if transient { continue }
            }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle() }
            if line.hasPrefix(marker) && !inCode {
                flush(); user = true; buffer.append(String(line.dropFirst(marker.count)))
            } else if user && !inCode && (line.hasPrefix("• ") || line.hasPrefix("● ") || line.hasPrefix("✔ You approved") || line.hasPrefix("✓ You approved")) {
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
