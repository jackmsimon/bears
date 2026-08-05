import AppKit
import Carbon
import ServiceManagement
import WebKit

private struct Camera {
    let name: String
    let videoID: String
    let pageURL: URL
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    private let largeViewDefaultsKey = "LargeView"
    private let minimizeOnUnfocusDefaultsKey = "MinimizeOnUnfocus"
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
    private var popover: NSPopover!
    private var webView: WKWebView!
    private var hotKeys: [EventHotKeyRef] = []
    private var hotKeyHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [minimizeOnUnfocusDefaultsKey: true])
        createStatusItem()
        createPopover()
        registerHotKey()
        requestLaunchAtLoginOnce()
    }

    func applicationWillTerminate(_ notification: Notification) {
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

    private func createPopover() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        webView = WKWebView(frame: .zero, configuration: configuration)

        let viewController = NSViewController()
        viewController.view = webView

        popover = NSPopover()
        popover.contentSize = popoverSize
        popover.contentViewController = viewController
        popover.behavior = popoverBehavior
        popover.delegate = self
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
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        showCamera(at: max(currentCameraIndex, 0))
    }

    private func showCamera(at index: Int) {
        currentCameraIndex = index
        let camera = cameras[index]
        load(camera)
        guard let button = statusItem.button else { return }
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
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

    func popoverDidClose(_ notification: Notification) {
        webView.loadHTMLString("", baseURL: nil)
    }

    private var popoverSize: NSSize {
        if UserDefaults.standard.bool(forKey: largeViewDefaultsKey) {
            return NSSize(width: 960, height: 540)
        }
        return NSSize(width: 640, height: 360)
    }

    private var popoverBehavior: NSPopover.Behavior {
        UserDefaults.standard.bool(forKey: minimizeOnUnfocusDefaultsKey) ? .transient : .applicationDefined
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let showItem = NSMenuItem(
            title: popover.isShown ? "Hide Bears" : "Show Bears",
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
        popover.contentSize = popoverSize
    }

    @objc private func toggleMinimizeOnUnfocus() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: minimizeOnUnfocusDefaultsKey), forKey: minimizeOnUnfocusDefaultsKey)
        popover.behavior = popoverBehavior
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
