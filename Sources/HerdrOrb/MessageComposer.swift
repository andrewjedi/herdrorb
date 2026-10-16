import AppKit
import SwiftUI

class ComposerTextView: NSTextView {
    var send: (() -> Void)?
    var heightChanged: ((CGFloat) -> Void)?
    var focusChanged: ((Bool) -> Void)?
    private var measurementQueued = false
    private var reportedHeight: CGFloat?
    func measureContent() {
        guard !measurementQueued else { return }
        measurementQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.measurementQueued = false
            guard self.bounds.width > 20, let layout = self.layoutManager, let container = self.textContainer else { return }
            layout.ensureLayout(for: container)
            let height = ceil(layout.usedRect(for: container).height + self.textContainerInset.height * 2)
            let measured = min(132, max(38, height))
            if self.reportedHeight.map({ abs($0 - measured) > 0.5 }) ?? true {
                self.reportedHeight = measured
                self.heightChanged?(measured)
            }
        }
    }
    override func setFrameSize(_ size: NSSize) {
        let widthChanged = abs(size.width - frame.width) > 0.5
        super.setFrameSize(size)
        if widthChanged { measureContent() }
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        // Dictation tools target the active app; the floating launcher itself stays nonactivating.
        if accepted { NSApp.activate(ignoringOtherApps: true) }
        if accepted { focusChanged?(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { focusChanged?(false) }
        return accepted
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "v": pasteAsPlainText(nil)
        case "c": copy(nil)
        case "x": cut(nil)
        case "a": selectAll(nil)
        case "z":
            if event.modifierFlags.contains(.shift) { undoManager?.redo() }
            else { undoManager?.undo() }
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76), !hasMarkedText() {
            if event.modifierFlags.contains(.shift) { insertNewline(nil) }
            else { send?() }
            return
        }
        super.keyDown(with: event)
    }
}

struct MessageComposer: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onHeightChange: ((CGFloat) -> Void)? = nil
    var onFocusChange: ((Bool) -> Void)? = nil
    var send: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        editor.isRichText = false
        editor.allowsUndo = true
        editor.minSize = NSSize(width: 0, height: 28)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.drawsBackground = false
        editor.textColor = OrbTheme.nsText
        editor.insertionPointColor = OrbTheme.nsAccent
        editor.font = .systemFont(ofSize: 14.5)
        editor.textContainerInset = NSSize(width: 0, height: 5)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        editor.send = send
        editor.heightChanged = onHeightChange
        editor.focusChanged = onFocusChange
        editor.setAccessibilityLabel(placeholder)
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        if editor.string != text {
            let selection = editor.selectedRange()
            let wasAtEnd = selection.length == 0 && NSMaxRange(selection) == (editor.string as NSString).length
            editor.string = text
            let length = (text as NSString).length
            editor.setSelectedRange(NSRange(location: wasAtEnd ? length : min(selection.location, length), length: 0))
            if wasAtEnd { editor.scrollRangeToVisible(editor.selectedRange()) }
        }
        editor.send = send
        editor.heightChanged = onHeightChange
        editor.focusChanged = onFocusChange
        editor.setAccessibilityLabel(placeholder)
        editor.measureContent()
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MessageComposer
        init(_ parent: MessageComposer) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            (editor as? ComposerTextView)?.measureContent()
        }
    }
}
