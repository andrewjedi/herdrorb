import AppKit
import SwiftUI

@main struct ScrollChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        func content(_ count: Int) -> AnyView {
            AnyView(VStack(alignment: .leading, spacing: 16) {
                ForEach(0..<count, id: \.self) { index in
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
        print("Native scrolling: wrapped history, follow to latest, no jump on new output, and saved offset restoration passed")
    }
}
