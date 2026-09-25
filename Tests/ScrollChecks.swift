import AppKit
import SwiftUI

@main struct ScrollChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        func content(_ count: Int, first: Int = 0) -> AnyView {
            AnyView(VStack(alignment: .leading, spacing: 16) {
                ForEach(first..<(first + count), id: \.self) { index in
                    Text("Message \(index): " + String(repeating: "A long wrapped response. ", count: 15))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true))
        }
        let scroll = ConversationScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 400))
        let host = NSHostingController(rootView: content(30)); host.sizingOptions = []
        scroll.documentView = host.view
        let coordinator = ConversationScroll<AnyView>.Coordinator()
        coordinator.host = host; coordinator.connect(scroll)
        defer { coordinator.disconnect() }
        coordinator.scheduleLayout()
        try await Task.sleep(nanoseconds: 100_000_000)
        let bottom = host.view.frame.height - scroll.contentSize.height
        assert(bottom > 1_000 && abs(scroll.contentView.bounds.minY - bottom) < 1)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        assert(!coordinator.follow)
        host.rootView = content(35); coordinator.scheduleLayout()
        try await Task.sleep(nanoseconds: 100_000_000)
        assert(abs(scroll.contentView.bounds.minY - 200) < 1, "New output must preserve the reader's offset")
        coordinator.follow = true; coordinator.scheduleLayout()
        try await Task.sleep(nanoseconds: 100_000_000)
        assert(abs(scroll.contentView.bounds.maxY - host.view.frame.height) < 1, "Follow must reach the actual latest row")
        coordinator.follow = false; coordinator.restored = false; coordinator.initialOffset = 320
        coordinator.scheduleLayout()
        try await Task.sleep(nanoseconds: 100_000_000)
        assert(abs(scroll.contentView.bounds.minY - 320) < 1, "Saved offsets must restore without a competing anchor")
        let measured = coordinator.measurementCount
        coordinator.scheduleLayout(measure: false)
        try await Task.sleep(nanoseconds: 30_000_000)
        assert(coordinator.measurementCount == measured, "A follow/offset change must not remeasure the conversation")

        var notifications = 0
        coordinator.changed = { _, _ in notifications += 1 }
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        for _ in 0..<100 {
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        }
        assert(notifications == 1, "Scrolling must not publish/save on every wheel or trackpad tick")
        var applied = 0
        coordinator.replaceContent { applied += 1; return content(36) }
        coordinator.replaceContent { applied += 1; return content(37) }
        coordinator.setFollow(true) // A stale SwiftUI update during the gesture.
        try await Task.sleep(nanoseconds: 30_000_000)
        assert(applied == 0 && coordinator.measurementCount == measured && !coordinator.follow,
               "Streaming updates must not rebuild/resize the document during a scroll gesture")
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        try await Task.sleep(nanoseconds: 30_000_000)
        assert(applied == 1 && notifications == 2, "Apply only the latest streamed content and save the final scroll position")
        assert(abs(scroll.contentView.bounds.minY - 320) < 1)

        coordinator.follow = true; coordinator.scheduleLayout(measure: false)
        try await Task.sleep(nanoseconds: 30_000_000)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: host.view.frame.height - scroll.contentSize.height - 12))
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        assert(!coordinator.follow, "A small upward scroll near the bottom must not reactivate auto-follow")
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: host.view.frame.height - scroll.contentSize.height))
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        assert(coordinator.follow, "Returning to the bottom resumes follow")
        coordinator.follow = false
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        let previousHeight = host.view.frame.height
        var savedOffset = 0.0
        coordinator.changed = { _, offset in savedOffset = offset }
        coordinator.replaceContent({ content(45, first: -8) }, preservingBottomDistance: true)
        try await Task.sleep(nanoseconds: 30_000_000)
        let expectedOffset = 100 + host.view.frame.height - previousHeight
        assert(abs(scroll.contentView.bounds.minY - expectedOffset) < 1, "Prepending older messages must preserve the visible message")
        assert(abs(savedOffset - expectedOffset) < 1, "Persist the adjusted offset after loading older messages")
        coordinator.restore(to: 50)
        coordinator.scheduleLayout(measure: false)
        try await Task.sleep(nanoseconds: 30_000_000)
        assert(abs(scroll.contentView.bounds.minY - 50) < 1, "Leaving search restores the saved reading position")
        print("Scroll performance: no remeasure on follow changes, coalesced persistence, deferred streaming, stale-follow protection and precise bottom detection passed")
        print("Native scrolling: wrapped history, follow to latest, no jump on new output, and saved offset restoration passed")
    }
}
