import SwiftUI
import AppKit

struct ConversationMarkdown: View, Equatable {
    let text: String
    var documentStyle = false
    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
    }
    private func code(_ source: String) -> Text {
        var attributed = AttributedString(source)
        if let expression = try? NSRegularExpression(pattern: #"\b(let|var|func|return|if|else|struct|class|import|const|function)\b"#) {
            for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                if let range = Range(match.range, in: source), let start = AttributedString.Index(range.lowerBound, within: attributed), let end = AttributedString.Index(range.upperBound, within: attributed) {
                    attributed[start..<end].foregroundColor = Color(hex: 0xA3B3EF)
                }
            }
        }
        return Text(attributed)
    }
    private func gap(before index: Int, blocks: [ConversationBlock]) -> CGFloat {
        guard index > 0 else { return 0 }
        let previous = blocks[index - 1].kind, current = blocks[index].kind
        if case .item = previous, case .item = current { return documentStyle ? 12 : 7 }
        if case .heading = current { return documentStyle ? 28 : 16 }
        if case .heading = previous { return documentStyle ? 18 : 10 }
        if case .item = previous { return documentStyle ? 40 : 19 }
        return 12
    }
    var body: some View {
        // Parse once per changed message, not twice for every block's spacing.
        let blocks = MarkdownBlockCache.blocks(text)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, index: index).padding(.top, gap(before: index, blocks: blocks))
                if documentStyle, index == 0, case .heading = block.kind {
                    OrbRule().padding(.top, 18).padding(.bottom, 8)
                }
            }
        }.textSelection(.enabled)
    }
    @ViewBuilder private func blockView(_ block: ConversationBlock, index: Int) -> some View {
        switch block.kind {
        case .paragraph: inline(block.text)
        case .heading: inline(block.text).font(.system(size: documentStyle ? (index == 0 ? 40 : 26) : 20, weight: .semibold))
        case .item(let marker):
            HStack(alignment: .top, spacing: 16) {
                if documentStyle {
                    Text(marker).foregroundStyle(OrbTheme.secondary).frame(minWidth: 16)
                } else { Text(marker).foregroundStyle(OrbTheme.secondary).frame(minWidth: 10) }
                inline(block.text).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .code:
            HStack(alignment: .top, spacing: 10) {
                code(block.text).font(.system(size: 14, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(block.text, forType: .string) } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 14)).foregroundStyle(OrbTheme.secondary)
                }.buttonStyle(.plain).help("Copy code").accessibilityLabel("Copy code")
            }.padding(.horizontal, 14).padding(.vertical, 10)
                .background(OrbTheme.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(OrbTheme.line, lineWidth: 0.8))
        }
    }
}

/// Bounded immutable parse cache shared by recycled row hosts. Changes to a tail
/// do not evict/reparse every completed message. NSCache controls memory pressure.
private enum MarkdownBlockCache {
    final class Value {
        let blocks: [ConversationBlock]
        init(_ blocks: [ConversationBlock]) { self.blocks = blocks }
    }
    static let cache: NSCache<NSString, Value> = {
        let cache = NSCache<NSString, Value>()
        cache.totalCostLimit = 8 * 1024 * 1024
        cache.countLimit = 256
        return cache
    }()
    static func blocks(_ text: String) -> [ConversationBlock] {
        let key = text as NSString
        if let value = cache.object(forKey: key) { return value.blocks }
        let blocks = ConversationBlock.parse(text).filter { !$0.text.isEmpty }
        cache.setObject(Value(blocks), forKey: key, cost: text.utf8.count * 3 + blocks.count * 64)
        return blocks
    }
}
