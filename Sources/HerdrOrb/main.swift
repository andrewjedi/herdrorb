import AppKit
import SwiftUI
import QuartzCore
import Combine

private let mint = Color(red: 0.65, green: 0.91, blue: 0.76)
private let ink = Color(red: 0.065, green: 0.085, blue: 0.08)

func statusColor(_ status: String) -> Color {
    switch status { case "working": return mint; case "blocked": return .orange; case "idle", "done": return .secondary; default: return .gray }
}
func statusLabel(_ status: String) -> String {
    status == "blocked" ? "Needs you" : status.capitalized
}

/// Native mouse tracking keeps a drag from also firing a click.
final class OrbControl: NSView {
    var clicked: (() -> Void)?
    var moved: (() -> Void)?
    private let model: BubbleModel
    private var startMouse = NSPoint.zero
    private var startOrigin = NSPoint.zero
    private var dragging = false
    private var art: NSHostingView<FloatingOrb>!
    private var hoverTracking: NSTrackingArea?
    private var hovering = false
    private var lastChime = Date.distantPast
    private let hoverSound = OrbChime.make()

    // Deliver the initial click even while another application owns focus.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }
    private func updateHover(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setHover(hypot(point.x - bounds.midX, point.y - bounds.midY) <= 43)
    }
    private func setHover(_ value: Bool) {
        guard value != hovering else { return }
        hovering = value
        art.rootView = FloatingOrb(model: model, hovered: value)
        if UserDefaults.standard.bool(forKey: "orbHoverSound") && value && Date().timeIntervalSince(lastChime) > 1 {
            lastChime = Date()
            hoverSound?.stop()
            hoverSound?.play()
        }
    }
    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { setHover(false) }


    init(frame: NSRect, model: BubbleModel) {
        self.model = model
        super.init(frame: frame)
        art = NSHostingView(rootView: FloatingOrb(model: model))
        art.frame = bounds
        art.autoresizingMask = [.width, .height]
        addSubview(art)
        toolTip = "Click to open agents · drag to move"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Open Herdr agents")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return hypot(local.x - bounds.midX, local.y - bounds.midY) <= 43 ? self : nil
    }
    override func accessibilityPerformPress() -> Bool { clicked?(); return true }
    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
        dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - startMouse.x, dy = mouse.y - startMouse.y
        if hypot(dx, dy) > 4 { dragging = true }
        if dragging { window?.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy)) }
    }
    override func mouseUp(with event: NSEvent) {
        if dragging { moved?() } else { clicked?() }
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel.make()
    let placement = PopoverPlacement()
    var anchoredToOrb = true
    var bubble: FloatingPanel!
    var panel: FloatingPanel!
    var menuItem: NSStatusItem!
    var optionsMenu: NSMenu!
    var orbMenuItem: NSMenuItem!
    private var attentionObserver: AnyCancellable?
    private var preferencesObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    let preferences = AppPreferences.current

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        preferences.register(defaults: ["showOrb": true, "orbHoverSound": true, "orbStatusDot": true])
        bubble = makePanel(size: NSSize(width: 112, height: 112))
        bubble.hasShadow = false
        let orb = OrbControl(frame: NSRect(x: 0, y: 0, width: 112, height: 112), model: model)
        orb.clicked = { [weak self] in self?.toggleFromOrb() }
        orb.moved = { [weak self] in self?.savePosition(); if self?.panel.isVisible == true { self?.positionPanel(byOrb: true, animated: true) } }
        bubble.contentView = orb
        panel = makePanel(size: NSSize(width: 900, height: 580))
        panel.contentView = NSHostingView(rootView: PanelView(model: model, placement: placement, close: { [weak self] in self?.closePanel() }, resize: { [weak self] delta in self?.resizePanel(delta) }).defaultAppStorage(preferences))
        let savedHeight = preferences.double(forKey: "glassPanelHeight")
        if savedHeight >= 460 { panel.setContentSize(NSSize(width: 900, height: min(savedHeight, NSScreen.main?.visibleFrame.height ?? 800))) }
        if let screen = NSScreen.main {
            var origin = NSPoint(x: screen.visibleFrame.maxX - 132, y: screen.visibleFrame.midY - 56)
            if let saved = preferences.string(forKey: "orbPosition") {
                let candidate = NSPointFromString(saved)
                if NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSPoint(x: candidate.x + 56, y: candidate.y + 56)) }) { origin = candidate }
            }
            bubble.setFrameOrigin(origin)
        }
        // Migrate the old wide text item to a compact, consistently named item.
        // A right-edge starting position avoids restoring it behind a crowded notch.
        if !preferences.bool(forKey: "compactMenuItemV1") {
            preferences.set(0, forKey: "NSStatusItem Preferred Position HerdrAgentsMenu")
            preferences.set(true, forKey: "compactMenuItemV1")
        }
        menuItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menuItem.autosaveName = "HerdrAgentsMenu"
        menuItem.isVisible = true
        menuItem.button?.title = ""
        let statusImage = NSImage(systemSymbolName: "circle.hexagongrid.fill", accessibilityDescription: "Herdr")
        statusImage?.isTemplate = true
        menuItem.button?.image = statusImage
        menuItem.button?.imagePosition = .imageOnly
        menuItem.button?.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        menuItem.button?.setAccessibilityLabel("HERD — Herdr agents")
        menuItem.button?.target = self
        menuItem.button?.action = #selector(statusClicked)
        menuItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        menuItem.button?.toolTip = "Herdr agents · right-click for floating circle options"
        optionsMenu = NSMenu()
        optionsMenu.addItem(withTitle: "Open agents", action: #selector(openFromMenu), keyEquivalent: "").target = self
        orbMenuItem = optionsMenu.addItem(withTitle: "Show floating circle", action: #selector(toggleOrb), keyEquivalent: "")
        orbMenuItem.target = self
        optionsMenu.addItem(.separator())
        optionsMenu.addItem(withTitle: "Quit herdrorb", action: #selector(quit), keyEquivalent: "q").target = self
        updateOrbVisibility()
        preferencesObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: preferences, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateOrbVisibility() }
        }
        attentionObserver = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let count = self.model.attention
                self.menuItem.button?.toolTip = count > 0 ? "Herdr · \(count) sessions need attention" : "Herdr · click to open agents"
                self.menuItem.button?.setAccessibilityLabel(count > 0 ? "Herdr, \(count) sessions need attention" : "Herdr agents")
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.model.refresh() }
        }
        if model.showingSetup || model.isDemo { openFromMenu() }
        Task {
            await model.start()
            if model.isDemo {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if let first = model.activeSessions.first { await model.choose(first) }
            }
        }
    }

    private func installMainMenu() {
        let bar = NSMenu()
        let application = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About herdrorb", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit herdrorb", action: #selector(quit), keyEquivalent: "q").target = self
        application.submenu = appMenu; bar.addItem(application)
        let edit = NSMenuItem(); edit.title = "Edit"; let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
        }
        let redo = NSMenuItem(title: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]; editMenu.insertItem(redo, at: 1)
        edit.submenu = editMenu; bar.addItem(edit); NSApp.mainMenu = bar
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard panel != nil, !model.isDemo, !AppPreferences.isSetupPreview else { return }
        Task { await model.refresh() }
    }
    @objc func showAbout() { NSApp.orderFrontStandardAboutPanel(nil); NSApp.activate(ignoringOtherApps: true) }
    func closePanel() { panel.orderOut(nil); model.panelVisible = false; model.suspendLive(); model.persistCurrent() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await model.stop(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func makePanel(size: NSSize) -> FloatingPanel {
        let window = FloatingPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return window
    }

    func resizePanel(_ delta: CGFloat) {
        let current = panel.frame
        let screen = panel.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let height = max(460, min(current.height + delta, current.maxY - screen.minY - 8))
        panel.setFrame(NSRect(x: current.minX, y: current.maxY - height, width: current.width, height: height), display: true)
        preferences.set(height, forKey: "glassPanelHeight")
        updatePointer()
    }
    func savePosition() { preferences.set(NSStringFromPoint(bubble.frame.origin), forKey: "orbPosition") }
    func updateOrbVisibility() {
        let visible = preferences.bool(forKey: "showOrb")
        orbMenuItem.state = visible ? .on : .off
        if visible { bubble.orderFrontRegardless() } else { bubble.orderOut(nil) }
    }
    @objc func toggleOrb() {
        preferences.set(!preferences.bool(forKey: "showOrb"), forKey: "showOrb")
        updateOrbVisibility()
    }
    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp, let button = menuItem.button {
            optionsMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        } else { toggle(byOrb: false) }
    }
    @objc func openFromMenu() { positionPanel(byOrb: false); panel.makeKeyAndOrderFront(nil); resumePanel() }
    private func resumePanel() {
        model.panelVisible = true; model.resumeLive()
        Task { await model.refresh() }
    }
    func toggleFromOrb() { toggle(byOrb: true) }
    func toggle(byOrb: Bool) {
        if panel.isVisible { closePanel(); return }
        positionPanel(byOrb: byOrb)
        panel.makeKeyAndOrderFront(nil)
        resumePanel()
    }
    func positionPanel(byOrb: Bool, animated: Bool = false) {
        anchoredToOrb = byOrb
        let anchor = byOrb ? bubble.frame : (menuItem.button?.window?.frame ?? bubble.frame)
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let width = min(900, frame.width - 100)
        let height = min(panel.frame.height, frame.height - 24)
        let rightFits = anchor.midX + 42 + width < frame.maxX
        let desiredX = byOrb ? (rightFits ? anchor.midX + 42 : anchor.midX - 42 - width) : anchor.maxX - width
        let x = max(frame.minX + 8, min(desiredX, frame.maxX - width - 8))
        let desiredY = byOrb ? anchor.midY - height * 0.4 : frame.maxY - height - 8
        let y = max(frame.minY + 8, min(desiredY, frame.maxY - height - 8))
        let target = NSRect(x: x, y: y, width: width, height: height)
        let shouldAnimate = animated && panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = 0.28
        let updatePlacement = {
            self.placement.left = rightFits
            self.placement.showPointer = byOrb
            // Use the destination frame so the pointer and window arrive together.
            self.placement.pointerY = min(target.height - 40, max(40, target.maxY - self.bubble.frame.midY))
        }
        if shouldAnimate {
            withAnimation(.timingCurve(0.42, 0, 0.58, 1, duration: duration)) {
                updatePlacement()
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            updatePlacement()
            panel.setFrame(target, display: true)
        }
    }
    func updatePointer() {
        placement.pointerY = min(panel.frame.height - 40, max(40, panel.frame.maxY - bubble.frame.midY))
    }
    @objc func quit() { NSApp.terminate(nil) }
}

MainActor.assumeIsolated {
    AppPreferences.prepare()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
