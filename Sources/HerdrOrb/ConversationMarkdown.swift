import SwiftUI
import AppKit

struct ConversationMarkdown: View, Equatable {
    let text: String
    var documentStyle = false
    var body: some View {
        MarkdownBlocks(blocks: RichMarkdown.blocks(text), documentStyle: documentStyle)
            .textSelection(.enabled)
    }
}

struct MarkdownInlineText: View {
    let runs: [MarkdownRun]
    var size: CGFloat = 14
    var body: some View {
        Text(attributed).tint(OrbTheme.accent)
    }
    private var attributed: AttributedString {
        var result = AttributedString()
        for run in runs {
            var part = AttributedString(run.text)
            var font = Font.system(size: run.code ? size - 1 : size, weight: run.bold ? .semibold : .regular,
                                   design: run.code ? .monospaced : .default)
            if run.italic { font = font.italic() }
            part.font = font
            if run.strike { part.strikethroughStyle = .single }
            if run.code {
                part.foregroundColor = OrbTheme.accentLight
                part.backgroundColor = OrbTheme.raised.opacity(0.7)
            }
            if let destination = run.link, let url = URL(string: destination),
               url.scheme == nil || ["https", "http", "mailto", "file"].contains(url.scheme?.lowercased() ?? "") {
                part.link = url
                part.foregroundColor = OrbTheme.accentLight
            }
            result += part
        }
        return result
    }
}

struct MarkdownBlocks: View {
    let blocks: [RichMarkdownBlock]
    var documentStyle = false
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                blockView(block).padding(.top, spacing(before: index))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var bodySize: CGFloat { documentStyle ? 16 : compact ? 13 : 14.5 }
    private func spacing(before index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        let block = blocks[index], previous = blocks[index - 1]
        if block.kind == .listItem && previous.kind == .listItem { return compact ? 4 : 6 }
        if block.kind == .heading { return documentStyle ? 26 : 20 }
        if previous.kind == .heading { return 9 }
        return compact ? 8 : 12
    }
    @ViewBuilder private func blockView(_ block: RichMarkdownBlock) -> some View {
        switch block.kind {
        case .paragraph:
            MarkdownInlineText(runs: block.runs, size: bodySize).lineSpacing(compact ? 3 : 5)
                .fixedSize(horizontal: false, vertical: true)
        case .heading:
            let size: CGFloat = documentStyle ? (block.level == 1 ? 30 : block.level == 2 ? 23 : 19) : (block.level == 1 ? 22 : block.level == 2 ? 18 : 15)
            MarkdownInlineText(runs: block.runs.map { var run = $0; run.bold = true; return run }, size: size)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        case .code:
            ConversationCodeBlock(source: block.text, language: block.language)
        case .rule:
            Rectangle().fill(OrbTheme.line.opacity(0.65)).frame(height: 1).padding(.vertical, 4)
        case .quote:
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 1).fill(OrbTheme.accent.opacity(0.5)).frame(width: 2)
                AnyView(MarkdownBlocks(blocks: block.children, documentStyle: documentStyle, compact: compact))
                    .foregroundStyle(OrbTheme.secondary)
            }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 2)
        case .listItem:
            HStack(alignment: .top, spacing: 10) {
                Group {
                    if let checked = block.checked {
                        Image(systemName: checked ? "checkmark.square.fill" : "square")
                            .foregroundStyle(checked ? OrbTheme.accent : OrbTheme.muted)
                            .accessibilityLabel(checked ? "Completed" : "Not completed")
                    } else { Text(block.marker).foregroundStyle(OrbTheme.secondary) }
                }.font(.system(size: bodySize - 1)).frame(minWidth: 16, alignment: .trailing).padding(.top, 2)
                AnyView(MarkdownBlocks(blocks: block.children, documentStyle: documentStyle, compact: compact))
            }
        case .table:
            ConversationTable(block: block)
        }
    }
}

struct ConversationCodeBlock: View {
    let source: String
    var language = ""
    @State private var tokens: [CodeToken] = []
    @State private var wraps = false
    @State private var copied = false
    private var label: String { language.isEmpty ? "Code" : language }
    private var height: CGFloat { min(300, max(32, CGFloat(source.components(separatedBy: "\n").count) * 18 + 24)) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: SyntaxHighlight.normalizedLanguage(language) == "diff" ? "plus.forwardslash.minus" : "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(OrbTheme.muted)
                Text(label).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(OrbTheme.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Button { wraps.toggle() } label: { Image(systemName: "arrow.turn.down.left").foregroundStyle(wraps ? OrbTheme.accent : OrbTheme.secondary) }
                    .help(wraps ? "Scroll long lines" : "Wrap long lines").accessibilityLabel(wraps ? "Disable code wrapping" : "Wrap code")
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(source, forType: .string)
                    copied = true
                } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc").foregroundStyle(copied ? OrbTheme.online : OrbTheme.secondary) }
                    .help("Copy code").accessibilityLabel(copied ? "Code copied" : "Copy code")
            }.buttonStyle(.plain).font(.system(size: 11)).padding(.horizontal, 13).frame(height: 33)
                .background(OrbTheme.surface.opacity(0.7))
            Rectangle().fill(OrbTheme.line.opacity(0.55)).frame(height: 0.5)
            GeometryReader { geometry in
                let width = max(1, geometry.size.width - 28)
                ScrollView(wraps ? .vertical : [.horizontal, .vertical]) {
                    Text(highlighted).font(.system(size: 12.5, design: .monospaced)).lineSpacing(3)
                        .textSelection(.enabled).fixedSize(horizontal: !wraps, vertical: true)
                        .frame(minWidth: width, maxWidth: wraps ? width : nil, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                }
            }.frame(height: height)
        }.background(Color(hex: 0x14151A), in: RoundedRectangle(cornerRadius: 9))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(OrbTheme.line.opacity(0.75), lineWidth: 0.75))
            .task(id: language + "\0" + source) {
                let code = source, syntax = language
                let result = await Task.detached(priority: .userInitiated) { SyntaxHighlight.tokens(code, language: syntax) }.value
                guard !Task.isCancelled else { return }; tokens = result
            }
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }; copied = false
            }
    }
    private var highlighted: AttributedString {
        var result = AttributedString()
        for token in tokens.isEmpty ? [.init(text: source, scope: "")] : tokens {
            var part = AttributedString(token.text)
            let scope = token.scope
            if scope.contains("comment") || scope.contains("meta") { part.foregroundColor = Color(hex: 0x858B9C) }
            else if scope.contains("string") || scope.contains("addition") { part.foregroundColor = Color(hex: 0xA5CEAC) }
            else if scope.contains("deletion") { part.foregroundColor = Color(hex: 0xE99BA6) }
            else if scope.contains("keyword") || scope.contains("literal") { part.foregroundColor = Color(hex: 0xC8ACEC) }
            else if scope.contains("number") || scope.contains("attr") { part.foregroundColor = Color(hex: 0xE6BC8C) }
            else if scope.contains("title") || scope.contains("built_in") || scope.contains("type") { part.foregroundColor = Color(hex: 0x9FC7E8) }
            else { part.foregroundColor = OrbTheme.text }
            result += part
        }
        return result
    }
}

private struct ConversationTable: View {
    let block: RichMarkdownBlock
    @State private var copied = false
    private var columns: Int { block.rows.map(\.count).max() ?? 0 }
    private func width(_ column: Int) -> CGFloat {
        let longest = block.rows.compactMap { row -> CGFloat? in
            guard row.indices.contains(column) else { return nil }
            let text = row[column].map(\.text).joined() as NSString
            return text.size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width + 28
        }.max() ?? 100
        return min(250, max(110, longest))
    }
    private func alignment(_ column: Int) -> Alignment {
        guard block.alignments.indices.contains(column) else { return .leading }
        return block.alignments[column] == 1 ? .trailing : block.alignments[column] == 0 ? .center : .leading
    }
    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(Array(block.rows.enumerated()), id: \.offset) { index, row in
                        GridRow(alignment: .top) {
                            ForEach(0..<columns, id: \.self) { column in
                                MarkdownInlineText(runs: (row.indices.contains(column) ? row[column] : []).map {
                                    var run = $0; if index == 0 { run.bold = true }; return run
                                }, size: 13).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                                    .frame(minWidth: width(column) - 24, maxWidth: .infinity, alignment: alignment(column))
                                    .padding(.horizontal, 12).padding(.vertical, 10)
                            }
                        }.background(index == 0 ? OrbTheme.raised.opacity(0.55) : index % 2 == 0 ? OrbTheme.surface.opacity(0.3) : .clear)
                        if index < block.rows.count - 1 { Rectangle().fill(OrbTheme.line.opacity(0.6)).frame(height: 0.5).gridCellUnsizedAxes(.horizontal) }
                    }
                }.containerRelativeFrame(.horizontal) { available, _ in
                    max(available, (0..<columns).reduce(CGFloat(0)) { $0 + width($1) })
                }
            }.overlay(RoundedRectangle(cornerRadius: 7).stroke(OrbTheme.line.opacity(0.65), lineWidth: 0.75))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            Button {
                let text = block.rows.map { $0.map { $0.map(\.text).joined() }.joined(separator: "\t") }.joined(separator: "\n")
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); copied = true
            } label: { Label(copied ? "Copied" : "Copy table", systemImage: copied ? "checkmark" : "doc.on.doc") }
                .font(.system(size: 10)).foregroundStyle(OrbTheme.muted).buttonStyle(.plain)
        }.task(id: copied) {
            guard copied else { return }; try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }; copied = false
        }
    }
}
