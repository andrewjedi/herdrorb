import SwiftUI

struct ConversationMarkdown: View {
    let text: String
    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(ConversationBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block.kind {
                case .paragraph:
                    if block.text.isEmpty { Color.clear.frame(height: 4) }
                    else { inline(block.text) }
                case .heading:
                    inline(block.text).font(.system(size: 15, weight: .semibold)).padding(.top, 5)
                case .item(let marker):
                    HStack(alignment: .top, spacing: 8) {
                        Text(marker).foregroundStyle(.secondary).frame(minWidth: 12, alignment: .trailing)
                        inline(block.text).frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .code:
                    Text(block.text).font(.system(size: 12, design: .monospaced))
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.black.opacity(0.23), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }.textSelection(.enabled)
    }
}
