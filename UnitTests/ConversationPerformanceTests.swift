import AppKit
import SwiftUI
import XCTest
@testable import HerdrOrb

final class ConversationPerformanceTests: XCTestCase {
    static let answer = "## Findings\n\n" + (0..<16).map {
        "- **Finding \($0)**: A wrapped explanation of the change, its behavior, and the next step for the reader."
    }.joined(separator: "\n")
    static let history = (0..<100).map {
        "› Request \($0)\n• " + answer + "\n"
    }.joined(separator: "\n")

    func testHistoryParsingBenchmark() {
        let start = Date()
        let messages = TerminalPresentation.messages(Self.history, kind: "codex")
        XCTAssertEqual(messages.count, 200)
        print("PERF history parse (\(Self.history.count) characters): \(Date().timeIntervalSince(start) * 1000) ms")
        let incrementalStart = Date()
        let updated = TerminalPresentation.messages(Self.history + "\nMore detail.", kind: "codex", previous: messages)
        XCTAssertEqual(Array(updated.dropLast()), Array(messages.dropLast()))
        XCTAssertTrue(updated.last?.text.hasSuffix("More detail.") == true)
        print("PERF incremental history parse: \(Date().timeIntervalSince(incrementalStart) * 1000) ms")
    }

    @MainActor func testLongMarkdownLayoutBenchmark() {
        _ = NSApplication.shared
        let text = "## Findings\n\n" + (0..<160).map {
            "- **Finding \($0)**: A wrapped explanation of the change and its behavior."
        }.joined(separator: "\n")
        let host = NSHostingController(rootView: ConversationMarkdown(text: text).frame(maxWidth: .infinity, alignment: .leading))
        host.sizingOptions = []
        let start = Date()
        let size = host.sizeThatFits(in: NSSize(width: 600, height: 400))
        XCTAssertGreaterThan(size.height, 400)
        print("PERF 160-item Markdown layout: \(Date().timeIntervalSince(start) * 1000) ms")
    }

    @MainActor func testLongConversationStreamingLayoutBenchmark() {
        _ = NSApplication.shared
        let messages = TerminalPresentation.messages(Self.history, kind: "codex")
        let host = NSHostingController(rootView: PerformanceTranscript(messages: messages))
        host.sizingOptions = []
        let size = NSSize(width: 600, height: 400)
        let start = Date()
        let initial = host.sizeThatFits(in: size)
        XCTAssertGreaterThan(initial.height, 10_000)
        print("PERF 200-message initial layout: \(Date().timeIntervalSince(start) * 1000) ms")
        var samples: [Double] = []
        for index in 0..<6 {
            let updated = TerminalPresentation.messages(Self.history + "\nStreaming update \(index).", kind: "codex", previous: messages)
            let start = Date()
            host.rootView = PerformanceTranscript(messages: updated)
            _ = host.sizeThatFits(in: size)
            samples.append(Date().timeIntervalSince(start) * 1000)
        }
        print("PERF 200-message streaming layout, median: \(samples.sorted()[3]) ms; worst: \(samples.max()!) ms")
        let recent = Array(messages.suffix(ConversationWindow.pageSize))
        let recentHost = NSHostingController(rootView: PerformanceTranscript(messages: recent))
        recentHost.sizingOptions = []
        let recentStart = Date()
        XCTAssertGreaterThan(recentHost.sizeThatFits(in: size).height, 400)
        print("PERF recent-message initial layout: \(Date().timeIntervalSince(recentStart) * 1000) ms")
    }

    @MainActor func testScrollFrameCostBenchmark() {
        measureScrollFrames(useRows: false)
        measureScrollFrames(useRows: true)
    }
    @MainActor private func measureScrollFrames(useRows: Bool) {
        _ = NSApplication.shared
        let messages = Array(TerminalPresentation.messages(Self.history, kind: "codex").suffix(40))
        let scroll = ConversationScrollView(frame: NSRect(x: 0, y: 0, width: 780, height: 600))
        let host = NSHostingController(rootView: PerformanceTranscript(messages: messages))
        host.sizingOptions = []
        let document = ConversationRowDocument()
        if useRows {
            scroll.documentView = document
            document.connect(scroll)
            document.update(messages.map { message in
                ConversationRowEntry(id: message.id, message: message) {
                    AnyView(ConversationMessageRow(message: message, kind: "codex", machine: .local, cwd: nil,
                        working: false, blocked: false, disclosed: false, find: "", toggleDisclosure: {})
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true))
                }
            })
            document.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: document.measure(width: scroll.contentSize.width))
            document.attachVisibleRows()
        } else {
            scroll.documentView = host.view
            let size = host.sizeThatFits(in: scroll.contentSize)
            host.view.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: size.height)
        }
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        window.displayIfNeeded()
        var samples: [Double] = []
        for index in 0..<90 {
            let start = CACurrentMediaTime()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(index) * 42))
            scroll.reflectScrolledClipView(scroll.contentView)
            scroll.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            samples.append((CACurrentMediaTime() - start) * 1000)
        }
        print("PERF \(useRows ? "visible rows" : "whole transcript") scroll CPU frame median: \(samples.sorted()[45]) ms; p95: \(samples.sorted()[85]) ms; worst: \(samples.max()!) ms")
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        if useRows {
            XCTAssertEqual(document.attachedRowCount, messages.count)
            XCTAssertLessThan(document.visibleRowCount, 12)
            XCTAssertEqual(document.measurementCount, messages.count, "Scrolling must not remeasure rows")
            document.disconnect()
        }
    }

    @MainActor func testRowLayoutCacheAndScrollingUpdateIsolation() async throws {
        _ = NSApplication.shared
        func rows(_ count: Int, changed: Int? = nil, first: Int = 0) -> [ConversationRowEntry] {
            (first..<count).map { index in
                let text = "Message \(index) " + String(repeating: "Some wrapped content. ", count: index == changed ? 24 : 20)
                return ConversationRowEntry(id: String(index), state: text) {
                    AnyView(Text(text).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true))
                }
            }
        }
        let scroll = ConversationScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 400))
        let document = ConversationRowDocument()
        scroll.documentView = document
        document.connect(scroll)
        let coordinator = ConversationScroll<AnyView>.Coordinator()
        coordinator.rowDocument = document
        coordinator.connect(scroll)
        defer { coordinator.disconnect() }
        coordinator.replaceRows(rows(20))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(document.measurementCount, 20)
        coordinator.replaceRows(rows(20, changed: 19))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(document.measurementCount, 21, "Only a changed row needs text layout")
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        coordinator.replaceRows(rows(21, changed: 19))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(document.measurementCount, 21, "New replies must not interrupt scrolling")
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(document.measurementCount, 22)
        XCTAssertEqual(scroll.contentView.bounds.minY, 200, accuracy: 1)
        let oldHeight = document.frame.height
        coordinator.replaceRows(rows(21, changed: 19, first: -2), preservingBottomDistance: true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(document.measurementCount, 24)
        XCTAssertEqual(scroll.contentView.bounds.minY, 200 + document.frame.height - oldHeight, accuracy: 1)
        coordinator.follow = true
        coordinator.scheduleLayout(measure: false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(scroll.contentView.bounds.maxY, document.frame.height, accuracy: 1)
        XCTAssertEqual(document.measurementCount, 24, "Follow doesn't need any new row measurements")
    }

    func testPinnedHistoryWindowAndSpinnerOnlyUpdates() {
        let messages = TerminalPresentation.messages(Self.history, kind: "codex")
        let anchor = ConversationWindow.latestAnchor(in: messages)
        XCTAssertEqual(ConversationWindow.start(in: messages, anchor: anchor), 160)
        let appended = TerminalPresentation.messages(Self.history + "\n› One more request\n• A new answer", kind: "codex", previous: messages)
        XCTAssertEqual(ConversationWindow.start(in: appended, anchor: anchor), 160, "A reader's window must stay pinned when new replies arrive")
        XCTAssertEqual(ConversationWindow.start(in: appended, anchor: nil), 162)
        XCTAssertEqual(ConversationWindow.start(in: [], anchor: nil), 0)
        let old = TerminalPresentation.messages("› Do something\n• Working on it.\nWorking (1s • esc to interrupt)", kind: "codex")
        let new = TerminalPresentation.messages("› Do something\n• Working on it.\nWorking (2s • esc to interrupt)", kind: "codex", previous: old)
        XCTAssertEqual(old, new, "A terminal timer tick must not invalidate the conversation")
        let cleanOld = TerminalPresentation.conversation("› Do something\n• Working on it.\nWorking (1s • esc to interrupt)", kind: "codex")
        let cleanNew = TerminalPresentation.conversation("› Do something\n• Working on it.\nWorking (2s • esc to interrupt)", kind: "codex")
        XCTAssertEqual(TerminalPresentation.mergeHistory(cleanOld, live: cleanNew), cleanOld, "Timer ticks must not accumulate duplicate history")
        let quoted = TerminalPresentation.messages("› Explain\n• Example:\n```\nWorking (1s • esc to interrupt)\n```", kind: "codex")
        XCTAssertTrue(quoted.last?.text.contains("Working (1s") == true)
    }

    @MainActor func testRawTerminalRefreshDoesNotPublishViewChanges() {
        let state = SessionState(identity: "performance-fixture")
        var changes = 0
        let observation = state.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        for index in 0..<100 {
            state.output = "› Hello\n• Working on it.\nWorking (\(index)s • esc to interrupt)"
            state.history = "Raw history \(index)"
        }
        XCTAssertEqual(changes, 0, "Raw reads must not invalidate the entire conversation")
        state.output = "request timed out"
        XCTAssertEqual(changes, 1, "A real connection notice must still update the UI")
    }
}

private struct PerformanceTranscript: View {
    let messages: [SessionMessage]
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(messages) { message in
                ConversationMessageRow(message: message, kind: "codex", machine: .local, cwd: nil,
                    working: false, blocked: false, disclosed: false, find: "", toggleDisclosure: {}).equatable()
            }
        }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
}
