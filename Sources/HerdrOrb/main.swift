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
    var dragTo: ((NSPoint) -> Void)?
    var showOptions: (() -> Void)?
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
        if model.preferences.bool(forKey: "orbHoverSound") && value && Date().timeIntervalSince(lastChime) > 1 {
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
    override func rightMouseDown(with event: NSEvent) { showOptions?() }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { showOptions?(); return }
        startMouse = NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
        dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - startMouse.x, dy = mouse.y - startMouse.y
        if hypot(dx, dy) > 4 { dragging = true }
        if dragging {
            let origin = NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy)
            if let dragTo { dragTo(origin) } else { window?.setFrameOrigin(origin) }
        }
    }
    override func mouseUp(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return }
        if dragging { moved?() } else { clicked?() }
    }
}

final class FloatingPanel: NSPanel {
    var dismiss: (() -> Void)?
    override func cancelOperation(_ sender: Any?) {
        if attachedSheet == nil, let dismiss { dismiss() } else { super.cancelOperation(sender) }
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel.make()
    let placement = PopoverPlacement()
    var anchoredToOrb = true
    var bubble: FloatingPanel!
    var panel: FloatingPanel!
    var menuItem: NSStatusItem!
    var optionsMenu: NSMenu!
    var orbMenuItem: NSMenuItem!
    private let orbPopover = NSPopover()
    private var attentionObserver: AnyCancellable?
    private var preferencesObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    let preferences = AppPreferences.current
    private lazy var panelEffect = OrbPanelEffect()
    private let openingSound = OrbChime.make(opening: true)
    private let closingSound = OrbChime.make(opening: false)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let directory = DesignPreview.outputDirectory {
            Task {
                do { try await DesignPreview.renderAll(to: directory); AppPreferences.cleanUpPreview(); exit(0) }
                catch { fputs("Preview export failed: \(error)\n", stderr); AppPreferences.cleanUpPreview(); exit(1) }
            }
            return
        }
        if model.isDemo && CommandLine.arguments.contains("--benchmark-orb-effect") {
            Task {
                await DesignPreview.prepare(.conversation, model: model)
                await OrbEffectPreview.benchmark(model: model)
                AppPreferences.cleanUpPreview(); exit(0)
            }
            return
        }
        if model.isDemo, let index = CommandLine.arguments.firstIndex(of: "--render-orb-effect"), CommandLine.arguments.indices.contains(index + 1) {
            Task {
                do {
                    await DesignPreview.prepare(.conversation, model: model)
                    try OrbEffectPreview.render(model: model, directory: CommandLine.arguments[index + 1])
                    AppPreferences.cleanUpPreview(); exit(0)
                } catch { fputs("Effect preview failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        installMainMenu()
        preferences.register(defaults: ["showOrb": true, "orbHoverSound": true, "orbStatusDot": false, "panelGalaxySound": true])
        if model.isDemo && CommandLine.arguments.contains("--panel-only") { preferences.set(false, forKey: "showOrb") }
        bubble = makePanel(size: NSSize(width: 152, height: 152))
        bubble.hasShadow = false
        let orb = OrbControl(frame: NSRect(x: 0, y: 0, width: 152, height: 152), model: model)
        orb.showOptions = { [weak self, weak orb] in
            guard let self, let orb else { return }
            self.showOrbMenu(relativeTo: orb)
        }
        orb.clicked = { [weak self] in self?.toggleFromOrb() }
        orb.dragTo = { [weak self] origin in
            guard let self else { return }
            self.panelEffect.move(orb: self.bubble, panel: self.panel, to: origin, connected: self.anchoredToOrb)
        }
        orb.moved = { [weak self] in self?.savePosition() }
        bubble.contentView = orb
        panel = makePanel(size: model.isDemo ? DesignPreview.panelSize : NSSize(width: OrbTheme.panelWidth, height: OrbTheme.panelHeight), nativeWindow: true)
        panel.delegate = self
        panel.dismiss = { [weak self] in self?.closePanel() }
        panel.title = "herdrorb"
        if model.isDemo { panel.title = "herdrorb · Fictional demo" }
        panel.contentView = NSHostingView(rootView: PanelView(model: model, placement: placement, close: { [weak self] in self?.closePanel() }, resize: { [weak self] delta in self?.resizePanel(delta) }, preview: DesignPreviewScreen.requested, nativeWindow: true).defaultAppStorage(preferences))
        let savedWidth = max(700, preferences.double(forKey: "glassPanelWidth"))
        let savedHeight = preferences.double(forKey: "glassPanelHeight")
        if savedHeight >= 460 { panel.setContentSize(NSSize(width: preferences.object(forKey: "glassPanelWidth") == nil ? OrbTheme.panelWidth : savedWidth, height: min(savedHeight, NSScreen.main?.visibleFrame.height ?? 800))) }
        if let screen = NSScreen.main {
            var origin = NSPoint(x: screen.visibleFrame.maxX - 152, y: screen.visibleFrame.midY - 76)
            if let saved = preferences.string(forKey: "orbPosition") {
                var candidate = NSPointFromString(saved)
                if !preferences.bool(forKey: "orbExpandedGlowV1") { candidate.x -= 20; candidate.y -= 20 }
                if NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSPoint(x: candidate.x + 76, y: candidate.y + 76)) }) { origin = candidate }
            }
            bubble.setFrameOrigin(origin)
            preferences.set(NSStringFromPoint(origin), forKey: "orbPosition")
            preferences.set(true, forKey: "orbExpandedGlowV1")
        }
        // Migrate the old wide text item to a compact, consistently named item.
        // A right-edge starting position avoids restoring it behind a crowded notch.
        if !preferences.bool(forKey: "compactMenuItemV1") {
            preferences.set(0, forKey: "NSStatusItem Preferred Position HerdrAgentsMenu")
            preferences.set(true, forKey: "compactMenuItemV1")
        }
        menuItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menuItem.autosaveName = "HerdrAgentsMenu"
        menuItem.isVisible = true
        menuItem.button?.title = " Herd"
        let statusImage = NSImage(systemSymbolName: "circle.hexagongrid.fill", accessibilityDescription: "Herdr")
        statusImage?.isTemplate = true
        menuItem.button?.image = statusImage
        menuItem.button?.imagePosition = .imageLeading
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
        if !model.isDemo || CommandLine.arguments.contains("--enable-demo-hotkey") {
            PanelHotKey.shared.action = { [weak self] in
                guard let self else { return }
                self.toggle(byOrb: self.bubble.isVisible)
            }
            PanelHotKey.shared.configure(preferences)
        }
        preferencesObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: preferences, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateOrbVisibility(); PanelHotKey.shared.refresh() }
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
            if let screen = DesignPreviewScreen.requested {
                await DesignPreview.prepare(screen, model: model)
                model.panelVisible = true
                return
            }
            await model.start()
            if model.isDemo {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if let first = model.activeSessions.first { await model.choose(first) }
                DesignPreview.showArtifactFixtureIfRequested()
            }
            if !model.panelVisible { panelEffect.prepareSnapshot(panel: panel) }
        }
    }

    private func installMainMenu() {
        let bar = NSMenu()
        let application = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About herdrorb", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Close panel", action: #selector(closePanel), keyEquivalent: "w").target = self
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
    @objc func closePanel() {
        guard model.panelVisible else { return }
        model.panelVisible = false; model.suspendLive(); model.persistCurrent()
        playPanelSound(opening: false)
        panelEffect.animate(open: false, panel: panel, orb: bubble.frame, connected: anchoredToOrb && bubble.isVisible) { }
    }
    private func playPanelSound(opening: Bool) {
        openingSound?.stop(); closingSound?.stop()
        if preferences.bool(forKey: "panelGalaxySound") { (opening ? openingSound : closingSound)?.play() }
    }
    private func showPanel(byOrb: Bool) {
        positionPanel(byOrb: byOrb)
        resumePanel()
        playPanelSound(opening: true)
        panelEffect.animate(open: true, panel: panel, orb: bubble.frame, connected: byOrb && bubble.isVisible) { [weak self] in
            guard let self, self.model.panelVisible else { return }
            self.panel.makeKeyAndOrderFront(nil)
            self.panelEffect.showConnection(orb: self.bubble.frame, panel: self.panel, connected: self.anchoredToOrb && self.bubble.isVisible)
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await model.stop(); AppPreferences.cleanUpPreview(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func makePanel(size: NSSize, nativeWindow: Bool = false) -> FloatingPanel {
        let style: NSWindow.StyleMask = nativeWindow ? [.borderless, .resizable, .nonactivatingPanel] : [.borderless, .nonactivatingPanel]
        let window = FloatingPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        if nativeWindow {
            window.contentMinSize = NSSize(width: 700, height: 460)
            window.isMovable = false
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
        }
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.level = nativeWindow ? OrbWindowLevels.panel : OrbWindowLevels.orb
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
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closePanel()
        return false
    }
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        let size = window.contentRect(forFrameRect: window.frame).size
        preferences.set(size.width, forKey: "glassPanelWidth")
        preferences.set(size.height, forKey: "glassPanelHeight")
        if model.panelVisible { panelEffect.update(orb: bubble.frame, panel: panel, connected: anchoredToOrb && bubble.isVisible) }
    }
    func windowDidMiniaturize(_ notification: Notification) {
        model.panelVisible = false
        model.suspendLive()
        model.persistCurrent()
    }
    func windowDidDeminiaturize(_ notification: Notification) { resumePanel() }
    func savePosition() { preferences.set(NSStringFromPoint(bubble.frame.origin), forKey: "orbPosition") }
    func updateOrbVisibility() {
        let visible = preferences.bool(forKey: "showOrb")
        menuItem.isVisible = true
        orbMenuItem.state = visible ? .on : .off
        orbMenuItem.title = visible ? "Hide orb" : "Show orb"
        if visible { bubble.orderFrontRegardless() } else { bubble.orderOut(nil) }
        if model.panelVisible { panelEffect.update(orb: bubble.frame, panel: panel, connected: anchoredToOrb && visible) }
    }
    @objc func toggleOrb() {
        preferences.set(!preferences.bool(forKey: "showOrb"), forKey: "showOrb")
        updateOrbVisibility()
    }
    func showOrbMenu(relativeTo view: NSView) {
        if orbPopover.isShown { orbPopover.performClose(nil); return }
        orbPopover.behavior = .transient
        orbPopover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        orbPopover.contentViewController = NSHostingController(rootView: OrbMenu(model: model, toggle: { [weak self] in
            self?.orbPopover.performClose(nil)
            self?.toggleOrb()
        }, open: { [weak self] in
            self?.orbPopover.performClose(nil)
            self?.openFromMenu()
        }, quit: { [weak self] in self?.quit() }).defaultAppStorage(preferences))
        orbPopover.show(relativeTo: view.bounds, of: view, preferredEdge: view === menuItem.button ? .minY : .minX)
    }
    @objc func statusClicked() {
        guard let button = menuItem.button else { return }
        showOrbMenu(relativeTo: button)
    }
    @objc func openFromMenu() {
        if model.panelVisible { panel.makeKeyAndOrderFront(nil); return }
        showPanel(byOrb: bubble.isVisible)
    }
    private func resumePanel() {
        model.panelVisible = true; model.resumeLive()
        Task { await model.refresh() }
    }
    func toggleFromOrb() { toggle(byOrb: true) }
    func toggle(byOrb: Bool) {
        if panel.isMiniaturized { panel.deminiaturize(nil); panel.makeKeyAndOrderFront(nil); return }
        if model.panelVisible { closePanel(); return }
        showPanel(byOrb: byOrb)
    }
    func positionPanel(byOrb: Bool, animated: Bool = false) {
        anchoredToOrb = byOrb
        let anchor = byOrb ? bubble.frame : (menuItem.button?.window?.frame ?? bubble.frame)
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let width = min(panel.frame.width, frame.width - 16)
        let height = min(panel.frame.height, frame.height - 24)
        let rightFits = anchor.midX + 142 + width < frame.maxX
        let desiredX = byOrb ? (rightFits ? anchor.midX + 142 : anchor.midX - 142 - width) : anchor.maxX - width
        let x = max(frame.minX + 8, min(desiredX, frame.maxX - width - 8))
        let desiredY = byOrb ? anchor.midY - height * 0.4 : frame.maxY - height - 8
        let y = max(frame.minY + 8, min(desiredY, frame.maxY - height - 8))
        let target = NSRect(x: x, y: y, width: width, height: height)
        let shouldAnimate = animated && panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = 0.28
        let updatePlacement = {
            self.placement.left = rightFits
            self.placement.showPointer = false
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
        if model.panelVisible { panelEffect.update(orb: bubble.frame, panel: panel, connected: byOrb && bubble.isVisible) }
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
