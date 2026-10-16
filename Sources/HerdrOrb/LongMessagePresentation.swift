import AppKit
import Foundation
import SwiftUI

/// Huge messages keep their original data in the archive. The chat lays out a
/// bounded excerpt; the complete text uses AppKit's scrolling text view on demand.
enum LongMessagePresentation {
    static let limit = 12_000
    static func preview(_ message: SessionMessage) -> SessionMessage {
        guard message.text.utf8.count > limit, message.text.count > limit else { return message }
        var result = message
        let prefix = String(message.text.prefix(limit))
        result.text = prefix.lastIndex(of: "\n").map { String(prefix[..<$0]) } ?? prefix
        result.parts = [MessagePart(text: result.text, status: message.phase == "commentary")]
        return result
    }
}

@MainActor enum FullMessageWindow {
    private static var windows: [NSWindow] = []
    static func show(_ text: String, plainText: Bool = false) {
        windows.removeAll { !$0.isVisible }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = plainText ? "Complete output" : "Complete message"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 360)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = OrbTheme.nsCanvas
        window.contentViewController = NSHostingController(rootView: FullMessageReader(text: text, plainText: plainText).preferredColorScheme(.dark))
        window.center(); window.makeKeyAndOrderFront(nil)
        windows.append(window)
        // Bound preview windows as well as the conversation's hosting controllers.
        if windows.count > 4 { windows.removeFirst().close() }
    }
}


private struct FullMessageReader: View {
    let text: String
    let plainText: Bool
    @State private var blocks: [RichMarkdownBlock] = []
    @State private var ready = false
    @State private var limit = 32
    @State private var copied = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(plainText ? "Output" : "Message").font(.system(size: 13, weight: .medium))
                Text("\(text.count.formatted()) characters").font(.system(size: 11)).foregroundStyle(OrbTheme.muted)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); copied = true
                } label: { Label(copied ? "Copied" : "Copy all", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(OrbButtonStyle(kind: .quiet, compact: true))
            }.padding(.horizontal, 20).padding(.vertical, 10)
            OrbRule()
            if !ready { ProgressView("Preparing message…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(blocks.prefix(limit))) { block in
                            MarkdownBlocks(blocks: [block]).textSelection(.enabled)
                        }
                        if blocks.count > limit {
                            Button("Show more") { limit += 32 }.buttonStyle(OrbButtonStyle(compact: true))
                        }
                    }.frame(maxWidth: 740, alignment: .leading).padding(28).frame(maxWidth: .infinity)
                }
            }
        }.background(OrbTheme.canvas).foregroundStyle(OrbTheme.text)
            .task {
                let source = text, plain = plainText
                let result = await Task.detached(priority: .userInitiated) {
                    let parsed = plain ? [RichMarkdownBlock(id: "output", kind: .code, text: source, language: "text")] : RichMarkdown.blocks(source)
                    return parsed.flatMap { Self.bounded($0) }
                }.value
                guard !Task.isCancelled else { return }; blocks = result; ready = true
            }
            .task(id: copied) {
                guard copied else { return }; try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }; copied = false
            }
    }
    /// Page large blocks too: a single code fence or paragraph can be megabytes.
    nonisolated private static func bounded(_ block: RichMarkdownBlock) -> [RichMarkdownBlock] {
        if block.kind == .code && block.text.count > 8_000 {
            var rest = block.text[...], result: [RichMarkdownBlock] = []
            while !rest.isEmpty {
                let prefix = rest.prefix(8_000)
                let end = prefix.lastIndex(of: "\n").map { rest.index(after: $0) } ?? prefix.endIndex
                var next = block; next.id += ":\(result.count)"; next.text = String(rest[..<end])
                result.append(next); rest = rest[end...]
            }
            return result
        }
        if block.kind == .paragraph && block.runs.reduce(0, { $0 + $1.text.count }) > 8_000 {
            var result: [RichMarkdownBlock] = [], runs: [MarkdownRun] = [], count = 0
            for run in block.runs {
                var rest = run.text[...]
                while !rest.isEmpty {
                    let prefix = rest.prefix(8_000 - count)
                    var part = run; part.text = String(prefix); runs.append(part)
                    count += prefix.count; rest = rest[prefix.endIndex...]
                    if count >= 8_000 {
                        var next = block; next.id += ":\(result.count)"; next.runs = runs
                        result.append(next); runs = []; count = 0
                    }
                }
            }
            if !runs.isEmpty { var next = block; next.id += ":\(result.count)"; next.runs = runs; result.append(next) }
            return result
        }
        var result = block
        result.children = block.children.flatMap { bounded($0) }
        return [result]
    }
}
