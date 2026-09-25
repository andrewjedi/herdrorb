import AppKit
import SwiftUI

struct ConversationContentVersion: Equatable {
    let messages: Int
    let pending: [PendingMessage]
    let filter: String
    let raw: String?
    let status: String
    let loading: Bool
    var disclosures: Set<String> = []
    var cached = false
    var historyStart: String?
    var prepend = 0
    var searchLimit = 40
}

/// AppKit owns the scroll offset. Streaming updates never write a SwiftUI scroll
/// binding, and exact document heights avoid LazyVStack's changing estimates.
struct ConversationScroll<Content: View>: NSViewRepresentable {
    let follow: Bool
    let offset: Double?
    let version: ConversationContentVersion
    let changed: (Bool, Double) -> Void
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> ConversationScrollView {
        let scroll = ConversationScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
        let host = NSHostingController(rootView: content())
        host.sizingOptions = []
        scroll.documentView = host.view
        context.coordinator.host = host
        context.coordinator.connect(scroll)
        scroll.resized = { [weak coordinator = context.coordinator] in coordinator?.scheduleLayout() }
        return scroll
    }
    func updateNSView(_ scroll: ConversationScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.changed = changed
        let followChanged = coordinator.setFollow(follow)
        if !coordinator.restored { coordinator.initialOffset = version.filter.isEmpty ? offset ?? 0 : 0 }
        if coordinator.version != version {
            if let old = coordinator.version, old.filter != version.filter {
                coordinator.restore(to: version.filter.isEmpty ? offset ?? 0 : 0)
            }
            let prepend = coordinator.version.map { $0.prepend != version.prepend && $0.filter == version.filter } ?? false
            coordinator.version = version
            coordinator.replaceContent(content, preservingBottomDistance: prepend)
        } else if followChanged || !coordinator.restored { coordinator.scheduleLayout(measure: false) }
    }
    static func dismantleNSView(_ view: ConversationScrollView, coordinator: Coordinator) { coordinator.disconnect() }

    final class Coordinator {
        weak var scroll: ConversationScrollView?
        var host: NSHostingController<Content>?
        var rowDocument: ConversationRowDocument?
        private var pendingRows: [ConversationRowEntry]?
        var changed: ((Bool, Double) -> Void)?
        var follow = true
        var restored = false
        var initialOffset = 0.0
        var version: ConversationContentVersion?
        private var userScrolling = false
        private var queued = false
        private var needsMeasurement = true
        private var measuredHeight: CGFloat = 0
        private var measuredSize = NSSize.zero
        private var pendingContent: (() -> Content)?
        private var scrollSettled: DispatchWorkItem?
        private var gestureStartOffset: CGFloat = 0
        private var preserveBottomDistance = false
        private(set) var measurementCount = 0
        private var observers: [NSObjectProtocol] = []
        func restore(to offset: Double) {
            initialOffset = offset
            restored = false
            preserveBottomDistance = false
        }
        @discardableResult func setFollow(_ value: Bool) -> Bool {
            // SwiftUI can still be delivering a pre-gesture update. Never let
            // that stale value override direct scroll input.
            guard !userScrolling else { return false }
            let changed = follow != value
            follow = value
            return changed
        }
        func replaceContent(_ content: @escaping () -> Content, preservingBottomDistance: Bool = false) {
            // Retain only the newest update while the reader is scrolling.
            // Changing the hosted tree mid-gesture can resize the document and
            // fight AppKit's momentum even if we don't call scroll(to:).
            pendingContent = content
            preserveBottomDistance = preserveBottomDistance || preservingBottomDistance
            scheduleLayout()
        }
        func replaceRows(_ rows: [ConversationRowEntry], preservingBottomDistance: Bool = false) {
            pendingRows = rows
            preserveBottomDistance = preserveBottomDistance || preservingBottomDistance
            scheduleLayout()
        }
        func connect(_ scroll: ConversationScrollView) {
            self.scroll = scroll
            scroll.willScroll = { [weak self] in self?.beginScrolling() }
            scroll.didScroll = { [weak self] in self?.scheduleScrollEnd() }
            for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: scroll, queue: .main) { [weak self] notification in
                    guard let self else { return }
                    if notification.name == NSScrollView.didEndLiveScrollNotification {
                        self.endScrolling()
                    } else {
                        self.beginScrolling()
                    }
                })
            }
        }
        private func beginScrolling() {
            scrollSettled?.cancel()
            guard !userScrolling, let scroll else { return }
            gestureStartOffset = scroll.contentView.bounds.minY
            userScrolling = true
            follow = false
            // One immediate notification disables follow before a pending
            // streaming update can snap the reader back to the bottom.
            changed?(false, gestureStartOffset)
        }
        private func scheduleScrollEnd() {
            scrollSettled?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.endScrolling() }
            scrollSettled = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: item)
        }
        private func endScrolling() {
            scrollSettled?.cancel(); scrollSettled = nil
            guard userScrolling, let scroll, let document = scroll.documentView else { return }
            userScrolling = false
            let offset = scroll.contentView.bounds.minY
            // Scrolling upward by even a few pixels means "let me read".
            // Resume only after returning down to the actual bottom.
            follow = offset >= gestureStartOffset && document.frame.height - scroll.contentView.bounds.maxY <= 2
            changed?(follow, max(0, offset))
            scheduleLayout(measure: false)
        }
        func scheduleLayout(measure: Bool = true) {
            needsMeasurement = needsMeasurement || measure
            guard !queued else { return }; queued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.queued = false; self.layout()
            }
        }
        private func layout() {
            guard !userScrolling, let scroll, let document = scroll.documentView, scroll.contentSize.width > 1 else { return }
            let oldOffset = scroll.contentView.bounds.minY
            let oldHeight = document.frame.height
            let newWidth = scroll.contentSize.width
            if let rows = pendingRows {
                pendingRows = nil
                rowDocument?.update(rows)
                needsMeasurement = true
            }
            if let content = pendingContent, let host {
                pendingContent = nil
                host.rootView = content()
                needsMeasurement = true
            }
            // Measure with the viewport's exact width, not the hosting view's ideal
            // fitting width (which underestimates wrapped text height).
            if needsMeasurement || measuredSize != scroll.contentSize {
                measuredHeight = rowDocument?.measure(width: newWidth) ?? host?.sizeThatFits(in: scroll.contentSize).height ?? 0
                measuredSize = scroll.contentSize
                needsMeasurement = false
                measurementCount += 1
            }
            let height = max(scroll.contentSize.height, measuredHeight)
            let frame = NSRect(x: 0, y: 0, width: newWidth, height: height)
            if document.frame != frame { document.frame = frame }
            rowDocument?.attachVisibleRows()
            let maximum = max(0, height - scroll.contentSize.height)
            let preservedOffset = restored ? oldOffset + (preserveBottomDistance ? height - oldHeight : 0) : initialOffset
            let target = follow && !userScrolling ? maximum : min(maximum, max(0, preservedOffset))
            let prepended = preserveBottomDistance
            preserveBottomDistance = false
            restored = true
            if abs(scroll.contentView.bounds.minY - target) > 0.5 {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            if prepended { changed?(follow, target) }
        }
        func disconnect() {
            scrollSettled?.cancel(); scrollSettled = nil
            if let scroll, restored { changed?(follow, max(0, scroll.contentView.bounds.minY)) }
            pendingContent = nil
            pendingRows = nil
            rowDocument?.disconnect()
            observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
            scroll?.resized = nil; scroll?.willScroll = nil; scroll?.didScroll = nil; scroll = nil
        }
        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    }
}

final class ConversationScrollView: NSScrollView {
    var resized: (() -> Void)?
    var willScroll: (() -> Void)?
    var didScroll: (() -> Void)?
    private var lastSize = NSSize.zero
    override func layout() {
        super.layout()
        if contentSize != lastSize { lastSize = contentSize; resized?() }
    }
    override func scrollWheel(with event: NSEvent) {
        // Live-scroll notifications alone miss conventional mouse wheels.
        willScroll?()
        super.scrollWheel(with: event)
        didScroll?()
    }
}

/// Each row has independent layout. Scrolling only changes native visibility;
/// it never evaluates a transcript-wide SwiftUI body or remeasures messages.
struct ConversationRowEntry {
    let id: String
    var message: SessionMessage? = nil
    var state = ""
    let content: () -> AnyView
    func matches(_ other: Self) -> Bool { id == other.id && message == other.message && state == other.state }
}

struct ConversationRows: NSViewRepresentable {
    let follow: Bool
    let offset: Double?
    let version: ConversationContentVersion
    let changed: (Bool, Double) -> Void
    let rows: [ConversationRowEntry]
    func makeCoordinator() -> ConversationScroll<AnyView>.Coordinator { .init() }
    func makeNSView(context: Context) -> ConversationScrollView {
        let scroll = ConversationScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
        let document = ConversationRowDocument()
        scroll.documentView = document
        document.connect(scroll)
        context.coordinator.rowDocument = document
        context.coordinator.connect(scroll)
        scroll.resized = { [weak coordinator = context.coordinator] in coordinator?.scheduleLayout() }
        return scroll
    }
    func updateNSView(_ scroll: ConversationScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.changed = changed
        let followChanged = coordinator.setFollow(follow)
        if !coordinator.restored { coordinator.initialOffset = version.filter.isEmpty ? offset ?? 0 : 0 }
        if coordinator.version != version {
            if let old = coordinator.version, old.filter != version.filter {
                coordinator.restore(to: version.filter.isEmpty ? offset ?? 0 : 0)
            }
            let prepending = coordinator.version.map { $0.prepend != version.prepend && $0.filter == version.filter } ?? false
            if let old = coordinator.version, old.historyStart != version.historyStart && old.messages != version.messages && !follow { coordinator.restore(to: offset ?? 0) }
            coordinator.version = version
            coordinator.replaceRows(rows, preservingBottomDistance: prepending)
        } else if followChanged || !coordinator.restored { coordinator.scheduleLayout(measure: false) }
    }
    static func dismantleNSView(_ view: ConversationScrollView, coordinator: ConversationScroll<AnyView>.Coordinator) { coordinator.disconnect() }
}

final class ConversationRowDocument: NSView {
    private final class Cell {
        var entry: ConversationRowEntry
        var host: NSHostingController<AnyView>?
        var height: CGFloat = 0
        var width: CGFloat = -1
        var rect = NSRect.zero
        var lastVisible: UInt64 = 0
        init(_ entry: ConversationRowEntry) {
            self.entry = entry
        }
        func hosting() -> NSHostingController<AnyView> {
            if let host { return host }
            let result = NSHostingController(rootView: entry.content())
            result.sizingOptions = []
            host = result
            return result
        }
    }
    override var isFlipped: Bool { true }
    private var cells: [Cell] = []
    private var visibilityClock: UInt64 = 0
    private weak var scroll: NSScrollView?
    private var observer: NSObjectProtocol?
    private(set) var measurementCount = 0
    var attachedRowCount: Int { subviews.count }
    var visibleRowCount: Int { subviews.filter { !$0.isHidden }.count }
    func connect(_ scroll: NSScrollView) {
        self.scroll = scroll
        wantsLayer = true
        scroll.contentView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            self?.attachVisibleRows()
        }
    }
    func update(_ entries: [ConversationRowEntry]) {
        var previous = Dictionary(cells.map { ($0.entry.id, $0) }, uniquingKeysWith: { first, _ in first })
        cells = entries.map { entry in
            guard let cell = previous.removeValue(forKey: entry.id) else { return Cell(entry) }
            if !cell.entry.matches(entry) {
                cell.host?.rootView = entry.content()
                cell.width = -1
            }
            cell.entry = entry
            return cell
        }
        for cell in previous.values { cell.host?.view.removeFromSuperview() }
    }
    func measure(width: CGFloat) -> CGFloat {
        let rowWidth = max(1, min(780, width - 56))
        var y: CGFloat = 14
        for cell in cells {
            if cell.width != rowWidth {
                cell.height = ceil(cell.hosting().sizeThatFits(in: NSSize(width: rowWidth, height: 600)).height)
                cell.width = rowWidth
                measurementCount += 1
            }
            cell.rect = NSRect(x: (width - rowWidth) / 2, y: y, width: rowWidth, height: cell.height)
            if let host = cell.host, host.view.frame != cell.rect { host.view.frame = cell.rect }
            y += cell.height + 16
        }
        pruneHosts()
        return y + 8
    }
    func attachVisibleRows() {
        guard let scroll else { return }
        visibilityClock += 1
        let visible = scroll.contentView.bounds.insetBy(dx: 0, dy: -scroll.contentSize.height)
        for cell in cells {
            let needed = cell.rect.intersects(visible) || isFocused(cell)
            if needed {
                cell.lastVisible = visibilityClock
                let host = cell.hosting()
                if host.view.frame != cell.rect { host.view.frame = cell.rect }
                host.view.isHidden = false
                if host.view.superview !== self { addSubview(host.view) }
            } else if let host = cell.host {
                host.view.isHidden = true
                if host.view.superview !== self { addSubview(host.view) }
            }
        }
        pruneHosts()
    }
    private func pruneHosts() {
        let visible = scroll?.contentView.bounds.insetBy(dx: 0, dy: -(scroll?.contentSize.height ?? 0)) ?? .zero
        let optional = cells.enumerated().filter { $0.element.host != nil && !$0.element.rect.intersects(visible) && !isFocused($0.element) }
            .sorted { $0.element.lastVisible == $1.element.lastVisible ? $0.offset > $1.offset : $0.element.lastVisible < $1.element.lastVisible }
        let excess = max(0, retainedHostCount - 24)
        for candidate in optional.prefix(excess) {
            candidate.element.host?.view.removeFromSuperview()
            candidate.element.host = nil
        }
    }
    private func isFocused(_ cell: Cell) -> Bool {
        guard let host = cell.host, let view = window?.firstResponder as? NSView else { return false }
        return view.isDescendant(of: host.view)
    }
    var retainedHostCount: Int { cells.filter { $0.host != nil }.count }

    func disconnect() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        scroll = nil
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}
