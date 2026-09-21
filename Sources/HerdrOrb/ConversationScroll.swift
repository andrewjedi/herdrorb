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
        let followChanged = coordinator.follow != follow
        coordinator.follow = follow
        if !coordinator.restored { coordinator.initialOffset = offset ?? 0 }
        if coordinator.version != version {
            coordinator.version = version
            coordinator.host?.rootView = content()
            coordinator.scheduleLayout()
        } else if followChanged || !coordinator.restored { coordinator.scheduleLayout() }
    }
    static func dismantleNSView(_ view: ConversationScrollView, coordinator: Coordinator) { coordinator.disconnect() }

    final class Coordinator {
        weak var scroll: ConversationScrollView?
        var host: NSHostingController<Content>?
        var changed: ((Bool, Double) -> Void)?
        var follow = true
        var restored = false
        var initialOffset = 0.0
        var version: ConversationContentVersion?
        private var userScrolling = false
        private var queued = false
        private var observers: [NSObjectProtocol] = []
        func connect(_ scroll: ConversationScrollView) {
            self.scroll = scroll
            for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: scroll, queue: .main) { [weak self] notification in
                    guard let self, let scroll = self.scroll, let document = scroll.documentView else { return }
                    let offset = scroll.contentView.bounds.minY
                    if notification.name == NSScrollView.didEndLiveScrollNotification {
                        self.userScrolling = false
                        self.follow = document.frame.height - scroll.contentView.bounds.maxY < 48
                    } else {
                        self.userScrolling = true
                        self.follow = false
                    }
                    self.changed?(self.follow, offset)
                })
            }
        }
        func scheduleLayout() {
            guard !queued else { return }; queued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.queued = false; self.layout()
            }
        }
        private func layout() {
            guard let scroll, let host, scroll.contentSize.width > 1 else { return }
            let oldOffset = scroll.contentView.bounds.minY
            let newWidth = scroll.contentSize.width
            // Measure with the viewport's exact width, not the hosting view's ideal
            // fitting width (which underestimates wrapped text height).
            let height = max(scroll.contentSize.height, host.sizeThatFits(in: NSSize(width: newWidth, height: scroll.contentSize.height)).height)
            host.view.frame = NSRect(x: 0, y: 0, width: newWidth, height: height)
            host.view.layoutSubtreeIfNeeded()
            let maximum = max(0, height - scroll.contentSize.height)
            let target = follow && !userScrolling ? maximum : min(maximum, max(0, restored ? oldOffset : initialOffset))
            restored = true
            if abs(scroll.contentView.bounds.minY - target) > 0.5 {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        func disconnect() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
            scroll?.resized = nil; scroll = nil
        }
        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    }
}

final class ConversationScrollView: NSScrollView {
    var resized: (() -> Void)?
    private var lastSize = NSSize.zero
    override func layout() {
        super.layout()
        if contentSize != lastSize { lastSize = contentSize; resized?() }
    }
}
