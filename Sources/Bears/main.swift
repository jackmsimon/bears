import AppKit
import Carbon
import ServiceManagement
import WebKit

private struct Camera {
    let name: String
    let videoID: String
    let pageURL: URL
}

/// A borderless floating panel that can take key without activating the app,
/// so clicking the camera never pulls focus away from what you are working on.
private final class CameraPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Draws the panel's border band and turns drags on it into window moves and
/// resizes. The panel is borderless so it keeps the chrome-free look of the
/// popover it replaced, which means the window server gives it no title bar or
/// resize control of its own.
///
/// - top band: moves the panel, standing in for a title bar
/// - left, right and bottom bands: resize the panel
/// - Command-drag: moves the panel from anywhere, including over the video
@MainActor
private final class PanelChromeView: NSView {
    struct Handles: OptionSet {
        let rawValue: Int

        static let left = Handles(rawValue: 1 << 0)
        static let right = Handles(rawValue: 1 << 1)
        static let bottom = Handles(rawValue: 1 << 2)
        static let move = Handles(rawValue: 1 << 3)
    }

    var minimumSize = NSSize(width: 320, height: 180)
    var onFrameChanged: ((NSRect) -> Void)?

    private let grabMargin: CGFloat = 10
    private let content: NSView
    private var dragHandles: Handles = []
    private var dragStartLocation: NSPoint = .zero
    private var dragStartFrame: NSRect = .zero
    private var showingCustomCursor = false

    init(content: NSView, size: NSSize) {
        self.content = content
        super.init(frame: NSRect(origin: .zero, size: size))
        addSubview(content)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layoutContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContent()
    }

    override func layout() {
        super.layout()
        layoutContent()
    }

    private func layoutContent() {
        content.frame = bounds.insetBy(dx: grabMargin, dy: grabMargin)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        // A grip on the top band so the drag handle is visible.
        let grip = NSRect(x: bounds.midX - 16, y: bounds.maxY - grabMargin / 2 - 1.5, width: 32, height: 3)
        NSColor.secondaryLabelColor.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: grip, xRadius: 1.5, yRadius: 1.5).fill()
    }

    private func handles(at point: NSPoint) -> Handles {
        guard bounds.contains(point) else { return [] }

        var handles: Handles = []
        if point.x <= bounds.minX + grabMargin { handles.insert(.left) }
        if point.x >= bounds.maxX - grabMargin { handles.insert(.right) }
        if point.y <= bounds.minY + grabMargin { handles.insert(.bottom) }
        // The top band is the drag handle, so it never resizes. Corners stay
        // with the side they touch.
        if handles.isEmpty, point.y >= bounds.maxY - grabMargin { return .move }
        return handles
    }

    private func cursor(for handles: Handles, dragging: Bool) -> NSCursor? {
        if handles.contains(.move) { return dragging ? .closedHand : .openHand }

        let horizontal = handles.contains(.left) || handles.contains(.right)
        switch (horizontal, handles.contains(.bottom)) {
        case (true, true): return .crosshair
        case (true, false): return .resizeLeftRight
        case (false, true): return .resizeUpDown
        case (false, false): return nil
        }
    }

    /// Only claim clicks on the band, so the web view keeps everything else.
    /// Command is the exception: it makes the whole panel a drag handle.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        guard bounds.contains(local) else { return super.hitTest(point) }
        if NSEvent.modifierFlags.contains(.command) { return self }
        return handles(at: local).isEmpty ? super.hitTest(point) : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        guard dragHandles.isEmpty else { return }

        let at = handles(at: convert(event.locationInWindow, from: nil))
        if let cursor = cursor(for: at, dragging: false) {
            cursor.set()
            showingCustomCursor = true
        } else if showingCustomCursor {
            NSCursor.arrow.set()
            showingCustomCursor = false
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard dragHandles.isEmpty, showingCustomCursor else { return }
        NSCursor.arrow.set()
        showingCustomCursor = false
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        dragHandles = NSEvent.modifierFlags.contains(.command) ? .move : handles(at: local)
        guard !dragHandles.isEmpty, let window else {
            super.mouseDown(with: event)
            return
        }

        dragStartLocation = NSEvent.mouseLocation
        dragStartFrame = window.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragHandles.isEmpty, let window else {
            super.mouseDragged(with: event)
            return
        }

        cursor(for: dragHandles, dragging: true)?.set()
        window.setFrame(proposedFrame(forPointerAt: NSEvent.mouseLocation), display: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard !dragHandles.isEmpty, let window else {
            super.mouseUp(with: event)
            return
        }

        let frame = proposedFrame(forPointerAt: NSEvent.mouseLocation)
        window.setFrame(frame, display: true)
        dragHandles = []
        showingCustomCursor = false
        NSCursor.arrow.set()
        onFrameChanged?(frame)
    }

    private func proposedFrame(forPointerAt location: NSPoint) -> NSRect {
        let deltaX = location.x - dragStartLocation.x
        let deltaY = location.y - dragStartLocation.y
        var frame = dragStartFrame

        if dragHandles.contains(.move) {
            frame.origin.x += deltaX
            frame.origin.y += deltaY
            return frame
        }

        // Each edge keeps the opposite edge pinned, so the panel grows in the
        // direction of the drag rather than around its centre.
        if dragHandles.contains(.right) {
            frame.size.width = max(dragStartFrame.width + deltaX, minimumSize.width)
        }
        if dragHandles.contains(.left) {
            frame.size.width = max(dragStartFrame.width - deltaX, minimumSize.width)
            frame.origin.x = dragStartFrame.maxX - frame.size.width
        }
        if dragHandles.contains(.bottom) {
            frame.size.height = max(dragStartFrame.height - deltaY, minimumSize.height)
            frame.origin.y = dragStartFrame.maxY - frame.size.height
        }
        return frame
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let largeViewDefaultsKey = "LargeView"
    private let minimizeOnUnfocusDefaultsKey = "MinimizeOnUnfocus"
    private let customWidthDefaultsKey = "CustomWidth"
    private let customHeightDefaultsKey = "CustomHeight"
    private let originXDefaultsKey = "PanelOriginX"
    private let originYDefaultsKey = "PanelOriginY"
    private let hasStoredOriginDefaultsKey = "HasPanelOrigin"
    private let minimumPanelSize = NSSize(width: 320, height: 180)
    private let cameras = [
        Camera(
            name: "Brooks Falls",
            videoID: "J7ZrIDvqlic",
            pageURL: URL(string: "https://explore.org/livecams/brown-bears/brown-bear-salmon-cam-brooks-falls")!
        ),
        Camera(
            name: "Brooks Falls Low",
            videoID: "EwTH5yY7Mks",
            pageURL: URL(string: "https://explore.org/livecams/brown-bears/brooks-falls-brown-bears-low")!
        ),
        Camera(
            name: "The Riffles",
            videoID: "z7_GhJeFxQI",
            pageURL: URL(string: "https://explore.org/livecams/brown-bears/brown-bear-salmon-cam-the-riffles")!
        ),
    ]

    private var currentCameraIndex = -1
    private var statusItem: NSStatusItem!
    private var panel: CameraPanel!
    private var chrome: PanelChromeView!
    private var webView: WKWebView!
    private var hotKeys: [EventHotKeyRef] = []
    private var hotKeyHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [minimizeOnUnfocusDefaultsKey: true])
        createStatusItem()
        createPanel()
        registerHotKey()
        requestLaunchAtLoginOnce()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if panel.isVisible {
            storePanelFrame(panel.frame)
        }
        for hotKey in hotKeys {
            UnregisterEventHotKey(hotKey)
        }
        if let hotKeyHandler {
            RemoveEventHandler(hotKeyHandler)
        }
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }

        button.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Bears")
        button.image?.isTemplate = true
        button.toolTip = "Bears: click to cycle cameras"
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func createPanel() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        webView = WKWebView(frame: .zero, configuration: configuration)

        let size = clamped(panelSize)
        chrome = PanelChromeView(content: webView, size: size)
        chrome.minimumSize = minimumPanelSize
        chrome.onFrameChanged = { [weak self] frame in
            self?.storePanelFrame(frame)
        }

        panel = CameraPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = chrome
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    private func registerHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == 0x42656172 else { return status }

                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                let id = hotKeyID.id
                DispatchQueue.main.async {
                    if id == 1 {
                        delegate.showCurrentCamera()
                    } else if id == 2 {
                        delegate.showNextCamera()
                    }
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandler
        )
        guard handlerStatus == noErr else {
            showHotKeyError(shortcut: "keyboard shortcuts", status: handlerStatus)
            return
        }

        registerHotKey(keyCode: UInt32(kVK_ANSI_B), id: 1, shortcut: "Control-Option-B")
        registerHotKey(keyCode: UInt32(kVK_ANSI_N), id: 2, shortcut: "Control-Option-N")
    }

    private func registerHotKey(keyCode: UInt32, id: UInt32, shortcut: String) {
        let hotKeyID = EventHotKeyID(signature: 0x42656172, id: id)
        var hotKey: EventHotKeyRef?
        let registrationStatus = RegisterEventHotKey(
            keyCode,
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        if registrationStatus != noErr {
            showHotKeyError(shortcut: shortcut, status: registrationStatus)
        } else if let hotKey {
            hotKeys.append(hotKey)
        }
    }

    private func showHotKeyError(shortcut: String, status: OSStatus) {
        let alert = NSAlert()
        alert.messageText = "Could not register \(shortcut)"
        alert.informativeText = "Another app may already be using this shortcut. Error \(status)."
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = makeMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }

        showNextCamera()
    }

    fileprivate func showNextCamera() {
        showCamera(at: (currentCameraIndex + 1) % cameras.count)
    }

    fileprivate func showCurrentCamera() {
        if panel.isVisible {
            hidePanel()
            return
        }
        showCamera(at: max(currentCameraIndex, 0))
    }

    private func showCamera(at index: Int) {
        currentCameraIndex = index
        load(cameras[index])
        guard !panel.isVisible else { return }

        panel.setFrame(startingFrame(), display: false)
        panel.makeKeyAndOrderFront(nil)
    }

    private func hidePanel() {
        guard panel.isVisible else { return }
        storePanelFrame(panel.frame)
        panel.orderOut(nil)
        webView.loadHTMLString("", baseURL: nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard UserDefaults.standard.bool(forKey: minimizeOnUnfocusDefaultsKey) else { return }
        hidePanel()
    }

    private func load(_ camera: Camera) {
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            html, body, iframe { width: 100%; height: 100%; margin: 0; border: 0; overflow: hidden; background: #000; }
          </style>
        </head>
        <body>
          <iframe
            src="https://www.youtube.com/embed/\(camera.videoID)?rel=0&amp;autoplay=1&amp;playsinline=1"
            allow="autoplay; encrypted-media; picture-in-picture"
            allowfullscreen>
          </iframe>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: camera.pageURL)
    }

    /// A size the user dragged out wins until Large View is toggled again.
    private var panelSize: NSSize {
        let defaults = UserDefaults.standard
        let custom = NSSize(
            width: defaults.double(forKey: customWidthDefaultsKey),
            height: defaults.double(forKey: customHeightDefaultsKey)
        )
        if custom.width >= minimumPanelSize.width, custom.height >= minimumPanelSize.height {
            return clamped(custom)
        }
        if defaults.bool(forKey: largeViewDefaultsKey) {
            return NSSize(width: 960, height: 540)
        }
        return NSSize(width: 640, height: 360)
    }

    private func clamped(_ size: NSSize) -> NSSize {
        var maximum = NSSize(width: 1920, height: 1080)
        if let screen = statusItem?.button?.window?.screen ?? NSScreen.main {
            maximum = NSSize(
                width: max(screen.visibleFrame.width, minimumPanelSize.width),
                height: max(screen.visibleFrame.height, minimumPanelSize.height)
            )
        }
        return NSSize(
            width: min(max(size.width, minimumPanelSize.width), maximum.width),
            height: min(max(size.height, minimumPanelSize.height), maximum.height)
        )
    }

    private func startingFrame() -> NSRect {
        let size = clamped(panelSize)
        guard let origin = storedOrigin() else {
            return NSRect(origin: defaultOrigin(for: size), size: size)
        }
        return rescuedIfOffscreen(NSRect(origin: origin, size: size))
    }

    /// Under the paw, the way the popover used to sit.
    private func defaultOrigin(for size: NSSize) -> NSPoint {
        guard let button = statusItem?.button, let buttonWindow = button.window else {
            let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            return NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
        let rect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        return NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 6)
    }

    /// A stored position can outlive the display it was on. Only step in when
    /// the panel would come back mostly out of reach.
    private func rescuedIfOffscreen(_ frame: NSRect) -> NSRect {
        let reachable = NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(frame)
            guard !overlap.isNull else { return false }
            return overlap.width * overlap.height >= 0.4 * frame.width * frame.height
        }
        return reachable ? frame : NSRect(origin: defaultOrigin(for: frame.size), size: frame.size)
    }

    private func storedOrigin() -> NSPoint? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: hasStoredOriginDefaultsKey) else { return nil }
        return NSPoint(
            x: defaults.double(forKey: originXDefaultsKey),
            y: defaults.double(forKey: originYDefaultsKey)
        )
    }

    private func storePanelFrame(_ frame: NSRect) {
        let defaults = UserDefaults.standard
        defaults.set(Double(frame.origin.x), forKey: originXDefaultsKey)
        defaults.set(Double(frame.origin.y), forKey: originYDefaultsKey)
        defaults.set(true, forKey: hasStoredOriginDefaultsKey)
        defaults.set(Double(frame.width), forKey: customWidthDefaultsKey)
        defaults.set(Double(frame.height), forKey: customHeightDefaultsKey)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let showItem = NSMenuItem(
            title: panel.isVisible ? "Hide Bears" : "Show Bears",
            action: #selector(showCurrentCameraFromMenu),
            keyEquivalent: "b"
        )
        showItem.target = self
        showItem.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(showItem)

        let nextItem = NSMenuItem(title: "Next Camera", action: #selector(nextCameraFromMenu), keyEquivalent: "n")
        nextItem.target = self
        nextItem.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(nextItem)
        menu.addItem(.separator())

        for (index, camera) in cameras.enumerated() {
            let item = NSMenuItem(title: camera.name, action: #selector(selectCamera(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == currentCameraIndex ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let exploreItem = NSMenuItem(title: "Open on Explore.org", action: #selector(openExplore), keyEquivalent: "")
        exploreItem.target = self
        exploreItem.isEnabled = currentCameraIndex >= 0
        menu.addItem(exploreItem)

        let largeViewItem = NSMenuItem(title: "Large View", action: #selector(toggleLargeView), keyEquivalent: "")
        largeViewItem.target = self
        largeViewItem.state = UserDefaults.standard.bool(forKey: largeViewDefaultsKey) ? .on : .off
        menu.addItem(largeViewItem)

        let resetItem = NSMenuItem(title: "Reset Position", action: #selector(resetPosition), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        let minimizeItem = NSMenuItem(
            title: "Minimize on un-focus",
            action: #selector(toggleMinimizeOnUnfocus),
            keyEquivalent: ""
        )
        minimizeItem.target = self
        minimizeItem.state = UserDefaults.standard.bool(forKey: minimizeOnUnfocusDefaultsKey) ? .on : .off
        menu.addItem(minimizeItem)

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Bears", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    @objc private func nextCameraFromMenu() {
        showNextCamera()
    }

    @objc private func showCurrentCameraFromMenu() {
        showCurrentCamera()
    }

    @objc private func selectCamera(_ sender: NSMenuItem) {
        showCamera(at: sender.tag)
    }

    @objc private func openExplore() {
        guard currentCameraIndex >= 0 else { return }
        NSWorkspace.shared.open(cameras[currentCameraIndex].pageURL)
    }

    @objc private func toggleLargeView() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: largeViewDefaultsKey), forKey: largeViewDefaultsKey)
        // The presets are the way back to a known size after dragging.
        defaults.removeObject(forKey: customWidthDefaultsKey)
        defaults.removeObject(forKey: customHeightDefaultsKey)
        resizePanelKeepingTopLeft(to: clamped(panelSize))
    }

    /// Grow from the top-left, so the corner the user parked stays put.
    private func resizePanelKeepingTopLeft(to size: NSSize) {
        let current = panel.frame
        let frame = NSRect(
            origin: NSPoint(x: current.minX, y: current.maxY - size.height),
            size: size
        )
        panel.setFrame(rescuedIfOffscreen(frame), display: true)
        if panel.isVisible {
            storePanelFrame(panel.frame)
        }
    }

    @objc private func resetPosition() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: hasStoredOriginDefaultsKey)
        defaults.removeObject(forKey: originXDefaultsKey)
        defaults.removeObject(forKey: originYDefaultsKey)
        guard panel.isVisible else { return }

        let size = clamped(panelSize)
        panel.setFrame(NSRect(origin: defaultOrigin(for: size), size: size), display: true)
    }

    @objc private func toggleMinimizeOnUnfocus() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: minimizeOnUnfocusDefaultsKey), forKey: minimizeOnUnfocusDefaultsKey)
    }

    private func requestLaunchAtLoginOnce() {
        let defaultsKey = "DidRequestLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: defaultsKey) else { return }

        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: defaultsKey)
        } catch {
            showLoginItemError(error)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: "DidRequestLaunchAtLogin")
            }
        } catch {
            showLoginItemError(error)
        }
    }

    private func showLoginItemError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not update Launch at Login"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

@main
private struct BearsApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
