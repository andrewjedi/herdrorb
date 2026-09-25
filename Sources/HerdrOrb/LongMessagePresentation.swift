import AppKit
import Foundation

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
    static func show(_ text: String) {
        windows.removeAll { !$0.isVisible }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Complete message"
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        let view = NSTextView(frame: scroll.bounds)
        view.isEditable = false
        view.isSelectable = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 20, height: 20)
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.layoutManager?.allowsNonContiguousLayout = true
        view.string = text
        scroll.documentView = view
        window.contentView = scroll
        window.center(); window.makeKeyAndOrderFront(nil)
        windows.append(window)
        // Bound preview windows as well as the conversation's hosting controllers.
        if windows.count > 4 { windows.removeFirst().close() }
    }
}
