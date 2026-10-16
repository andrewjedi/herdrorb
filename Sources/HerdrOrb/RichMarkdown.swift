import Foundation
import Markdown

/// A value-only projection of CommonMark/GFM. No HTML or JavaScript from a reply is executed.
struct MarkdownRun: Equatable, Sendable {
    var text: String
    var bold = false
    var italic = false
    var strike = false
    var code = false
    var link: String?
}

struct RichMarkdownBlock: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable { case paragraph, heading, code, listItem, quote, table, rule }
    var id: String
    var kind: Kind
    var runs: [MarkdownRun] = []
    var children: [RichMarkdownBlock] = []
    var text = ""
    var level = 0
    var marker = ""
    var checked: Bool?
    var language = ""
    var rows: [[[MarkdownRun]]] = []
    /// -1 left, 0 center, 1 right.
    var alignments: [Int] = []
}

enum RichMarkdown {
    private final class Entry {
        let blocks: [RichMarkdownBlock]
        init(_ blocks: [RichMarkdownBlock]) { self.blocks = blocks }
    }
    private static let cache: NSCache<NSString, Entry> = {
        let result = NSCache<NSString, Entry>()
        result.totalCostLimit = 8 * 1024 * 1024
        result.countLimit = 256
        return result
    }()
    static func blocks(_ source: String) -> [RichMarkdownBlock] {
        if let hit = cache.object(forKey: source as NSString) { return hit.blocks }
        let document = Document(parsing: source, options: [.disableSmartOpts])
        let blocks = document.children.enumerated().flatMap { convert($0.element, path: String($0.offset)) }
        cache.setObject(Entry(blocks), forKey: source as NSString, cost: source.utf8.count * 4 + blocks.count * 128)
        return blocks
    }
    private static func children(_ node: Markup, path: String) -> [RichMarkdownBlock] {
        node.children.enumerated().flatMap { convert($0.element, path: path + "." + String($0.offset)) }
    }
    private static func convert(_ node: Markup, path: String) -> [RichMarkdownBlock] {
        if let code = node as? CodeBlock {
            return [.init(id: path, kind: .code, text: code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code,
                          language: code.language ?? "")]
        }
        if let heading = node as? Heading {
            return [.init(id: path, kind: .heading, runs: inline(heading), level: heading.level)]
        }
        if node is Paragraph { return [.init(id: path, kind: .paragraph, runs: inline(node))] }
        if node is ThematicBreak { return [.init(id: path, kind: .rule)] }
        if node is BlockQuote { return [.init(id: path, kind: .quote, children: children(node, path: path))] }
        if node is UnorderedList || node is OrderedList {
            let start = (node as? OrderedList).map { Int($0.startIndex) } ?? 1
            return node.children.enumerated().compactMap { index, child in
                guard let item = child as? ListItem else { return nil }
                let id = path + "." + String(index)
                return RichMarkdownBlock(id: id, kind: .listItem, children: children(item, path: id),
                                         marker: node is OrderedList ? "\(start + index)." : "•",
                                         checked: item.checkbox.map { $0 == .checked })
            }
        }
        if let table = node as? Table {
            let head = table.head.children.map { inline($0) }
            let body = table.body.children.map { row in row.children.map { inline($0) } }
            return [.init(id: path, kind: .table, rows: [head] + body, alignments: table.columnAlignments.map {
                switch $0 { case .center: return 0; case .right: return 1; default: return -1 }
            })]
        }
        // Raw HTML is visible inert text. Unsupported containers preserve their contents.
        if let html = node as? HTMLBlock { return [.init(id: path, kind: .paragraph, runs: [.init(text: html.rawHTML)])] }
        return children(node, path: path)
    }
    private static func inline(_ node: Markup, style: MarkdownRun = .init(text: "")) -> [MarkdownRun] {
        var run = style
        if node is Strong { run.bold = true }
        if node is Emphasis { run.italic = true }
        if node is Strikethrough { run.strike = true }
        if let link = node as? Markdown.Link { run.link = link.destination }
        if let text = node as? Markdown.Text { run.text = text.string; return [run] }
        if let code = node as? InlineCode { run.text = code.code; run.code = true; return [run] }
        if node is SoftBreak { run.text = " "; return [run] }
        if node is LineBreak { run.text = "\n"; return [run] }
        if let html = node as? InlineHTML { run.text = html.rawHTML; return [run] }
        if let image = node as? Markdown.Image {
            // Existing ArtifactCard owns local/remote image loading, access, and previews.
            run.text = image.plainText.isEmpty ? "Image" : image.plainText
            return [run]
        }
        return node.children.flatMap { inline($0, style: run) }
    }
}
