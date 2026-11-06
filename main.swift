import AppKit
import ApplicationServices
import ServiceManagement
import Darwin

private struct PanelState {
    var panel: StripPanel
    var shown = false
    var exposed = false
    var leaveDeadline: Date?
    var items: [WindowItem] = []
    var blocked = false
    var fullScreen = false
}

final class StageStripApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let tracker = WindowTracker()
    private let thumbnails = ThumbnailStore()
    private let zoomOverlay = ZoomOverlay()
    private let minimizeInterceptor = MinimizeInterceptor()
    private var termSource: DispatchSourceSignal?
    private var panels: [String: PanelState] = [:]
    private var timer: Timer?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var lastScan = Date.distantPast
    /// Where Notification Center (with its widgets) is open, if it is; the strip keeps out of its way.
    private var notificationCenterFrame: CGRect?
    /// Hot corners that open Notification Center, as (right, top) pairs.
    private var notificationCorners: [(right: Bool, top: Bool)] = []
    private var inNotificationCorner = false
    /// A click on the wallpaper has swept the windows aside.
    private var desktopRevealed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "StageStrip")
        statusItem.button?.toolTip = "StageStrip"
        statusItem.menu = NSMenu()
        // Remembers the visibility between launches; also lets Cmd-drag take the icon off the menu bar.
        statusItem.autosaveName = "StageStrip"
        statusItem.behavior = .removalAllowed
        rebuildMenu()

        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        tracker.onChange = { [weak self] in self?.updatePanels() }
        thumbnails.onChange = { [weak self] in self?.updatePanels() }
        rebuildPanels()
        minimizeInterceptor.onPark = { [weak self] window in
            guard let self else { return }
            self.tracker.park(window, thumbnails: self.thumbnails, zoom: self.zoomOverlay) { [weak self] id, screen in
                let key = DisplaySettings.key(for: screen)
                if let panel = self?.panels[key]?.panel {
                    // Hidden even before the tile exists, so it never shows ahead of the image.
                    // An interrupted flight never lands, so don't leave the tile hidden for good.
                    panel.hideTile(id, revealAfter: 1.5)
                    if let rect = panel.screenRect(for: id) { return rect }
                }
                let side = DisplaySettings.side(for: screen)
                let x = side == .right ? screen.frame.maxX - 90 : screen.frame.minX + 10
                return CGRect(x: x, y: screen.frame.midY - 40, width: 80, height: 80)
            } perspective: { [weak self] screen in
                self?.panels[DisplaySettings.key(for: screen)]?.panel.perspective()
            } landed: { [weak self] id in
                self?.panels.values.forEach { $0.panel.setTileHidden(id, false) }
            }
        }
        minimizeInterceptor.start()
        signal(SIGTERM, SIG_IGN)
        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource.setEventHandler { [weak self] in
            self?.tracker.restoreAllParked()
            NSApp.terminate(nil)
        }
        termSource.resume()
        self.termSource = termSource

        let mouseEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            self?.updateInteraction()
            guard event.type == .leftMouseUp else { return }
            // The click may have revealed the desktop; don't wait for the timer to notice.
            for delay in [0.05, 0.3] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.updateNotificationCenter() }
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            self?.updateInteraction()
            return event
        }

        // A low-frequency timer catches window movement and Space switches.
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Picks up Accessibility granted after launch; does nothing once the tap exists.
            self.minimizeInterceptor.start()
            if Date().timeIntervalSince(self.lastScan) >= 2 {
                self.lastScan = Date()
                self.tracker.refresh()
            }
            self.updateNotificationCenter()
            self.updatePanels()
        }
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
    }

    @objc private func screenChanged() {
        rebuildPanels()
        rebuildMenu()
    }

    private func rebuildPanels() {
        let current = Set(NSScreen.screens.map { DisplaySettings.key(for: $0) })
        for key in panels.keys where !current.contains(key) {
            panels[key]?.panel.close()
            panels.removeValue(forKey: key)
        }
        for screen in NSScreen.screens {
            let key = DisplaySettings.key(for: screen)
            if panels[key] == nil {
                let panel = StripPanel(screen: screen, side: DisplaySettings.side(for: screen)) { [weak self] id in
                    guard let self else { return }
                    if (self.tracker.isParked(id) || !self.tracker.isPartlyVisible(id)),
                       let startRect = self.panels[key]?.panel.screenRect(for: id),
                       let item = self.tracker.item(for: id),
                       let mainScreenHeight = NSScreen.screens.first?.frame.height {
                        let frame = item.frame
                        let endRect = CGRect(x: frame.minX, y: mainScreenHeight - frame.maxY,
                                             width: frame.width, height: frame.height)
                        let icon = NSRunningApplication(processIdentifier: item.pid)?.icon
                        let panel = self.panels[key]?.panel
                        // The tile itself opens up into the window: the image starts in the
                        // tile's perspective and the tile is gone while it flies.
                        self.zoomOverlay.zoom(image: self.thumbnails.image(for: id), icon: icon, title: item.title,
                                              from: startRect, to: endRect,
                                              startTransform: panel?.landingTransform(for: startRect)) { [weak self] in
                            self?.tracker.activate(id)
                        }
                        // The strip drops the tile once the window is in front, which can lag the
                        // landing; bring it back only if that never happens (e.g. an interrupted flight).
                        panel?.hideTile(id, revealAfter: 2)
                    } else {
                        self.tracker.activate(id)
                    }
                }
                panel.onPin = { [weak self] id, slot in self?.tracker.togglePin(id, slot: slot) }
                panel.setFrameForScreen(screen: screen, side: DisplaySettings.side(for: screen), shown: false, animated: false)
                panels[key] = PanelState(panel: panel)
            }
        }
        updatePanels()
    }

    private func updatePanels() {
        let sharedPIDs = Set(Dictionary(grouping: tracker.windows.values, by: \.pid)
            .filter { $0.value.count > 1 }.keys)
        for screen in NSScreen.screens {
            let key = DisplaySettings.key(for: screen)
            guard var state = panels[key] else { continue }
            let side = DisplaySettings.side(for: screen)
            state.items = tracker.recent(on: screen)
            state.blocked = tracker.stripIsBlocked(on: screen, side: side)
            state.fullScreen = tracker.isFullScreen(on: screen)
            state.panel.update(items: state.items, sharedPIDs: sharedPIDs, pinned: Set(tracker.pinned.keys),
                               thumbnails: thumbnails, exposed: state.exposed,
                               visible: side != .off && !state.fullScreen && !state.items.isEmpty)
            panels[key] = state
        }
        updateInteraction(forceLayout: true)

        var visibleItems: [WindowItem] = []
        for state in panels.values where state.shown {
            visibleItems.append(contentsOf: state.items)
        }
        if let frontID = tracker.frontID, let front = tracker.windows[frontID], !front.minimized {
            visibleItems.append(front)
        }
        thumbnails.refresh(items: visibleItems.filter { !tracker.isParked($0.id) })
    }

    /// Notification Center shows as a full-screen window of its own process while it is open.
    /// So does the revealed desktop: WindowManager covers the screen until the windows come back.
    private func updateNotificationCenter() {
        let dock = UserDefaults(suiteName: "com.apple.dock")
        notificationCorners = [("tl", false, true), ("tr", true, true), ("bl", false, false), ("br", true, false)]
            .filter { dock?.integer(forKey: "wvous-\($0.0)-corner") == 12 }
            .map { (right: $0.1, top: $0.2) }
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let revealed = list.contains { info in
            info[kCGWindowOwnerName as String] as? String == "WindowManager"
                && (info[kCGWindowLayer as String] as? Int ?? 0) > 0
        }
        let frame = list.lazy.compactMap { info -> CGRect? in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.notificationcenterui",
                  (info[kCGWindowLayer as String] as? Int ?? 0) > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width >= 300, rect.height >= 300
            else { return nil }
            return CGRect(x: rect.minX, y: mainTop - rect.maxY, width: rect.width, height: rect.height)
        }.first
        guard frame != notificationCenterFrame || revealed != desktopRevealed else { return }
        notificationCenterFrame = frame
        desktopRevealed = revealed
        updateInteraction()
    }

    private func updateInteraction(forceLayout: Bool = false) {
        let mouse = NSEvent.mouseLocation
        let leftDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
        // Reaching a hot corner for Notification Center: get out of the way at once, before it opens,
        // and look again shortly for the window it opens.
        let corner = NSScreen.screens.first { screen in
            notificationCorners.contains { corner in
                abs(mouse.x - (corner.right ? screen.frame.maxX : screen.frame.minX)) <= 3
                    && abs(mouse.y - (corner.top ? screen.frame.maxY : screen.frame.minY)) <= 3
            }
        }
        if corner != nil, !inNotificationCorner {
            for delay in [0.3, 0.8] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.updateNotificationCenter() }
            }
        }

        inNotificationCorner = corner != nil
        for screen in NSScreen.screens {
            let key = DisplaySettings.key(for: screen)
            guard var state = panels[key] else { continue }
            let side = DisplaySettings.side(for: screen)
            let edge = side == .left ? screen.frame.minX : screen.frame.maxX
            let atEdge = side != .off
                && mouse.y >= screen.frame.minY && mouse.y <= screen.frame.maxY
                && mouse.x >= screen.frame.minX && mouse.x <= screen.frame.maxX
                && abs(mouse.x - edge) <= 2
            let hovering = state.panel.containsMouse(point: mouse)
            if hovering { state.leaveDeadline = nil }
            else if state.exposed && state.leaveDeadline == nil { state.leaveDeadline = Date().addingTimeInterval(0.3) }
            let hold = state.leaveDeadline.map { Date() < $0 } ?? false
            let covered = corner == screen || notificationCenterFrame?.intersects(screen.frame) == true
                || desktopRevealed
            let expose = state.blocked && !leftDown && !covered && (atEdge || hovering || hold)
            let shown = side != .off && !state.fullScreen && !state.items.isEmpty && !covered
                && (!state.blocked || expose)

            if forceLayout || shown != state.shown || expose != state.exposed {
                state.panel.setFrameForScreen(screen: screen, side: side, shown: shown,
                                          animated: shown != state.shown || expose != state.exposed)
                state.panel.setPresentation(exposed: expose,
                    visible: side != .off && !state.fullScreen && !state.items.isEmpty)
            }
            state.shown = shown
            state.exposed = expose
            panels[key] = state
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        for (index, screen) in NSScreen.screens.enumerated() {
            let label = "Экран \(index + 1) (\(Int(screen.frame.width))×\(Int(screen.frame.height)))"
            let parent = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let side = DisplaySettings.side(for: screen)
            for (title, choice) in [("Слева", StripSide.left), ("Справа", .right), ("Выключить на этом экране", .off)] {
                let item = NSMenuItem(title: title, action: #selector(chooseSide(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ["key": DisplaySettings.key(for: screen), "side": choice.rawValue]
                item.state = side == choice ? .on : .off
                sub.addItem(item)
            }
            parent.submenu = sub
            menu.addItem(parent)
        }
        menu.addItem(.separator())
        menu.addItem(choiceMenu(title: "Количество плиток", choices: DisplaySettings.tileCountChoices,
                                current: DisplaySettings.maxTiles, label: { "\($0)" },
                                action: #selector(chooseTileCount(_:))))
        menu.addItem(choiceMenu(title: "Прозрачность плиток", choices: DisplaySettings.transparencyChoices,
                                current: DisplaySettings.transparency, label: { $0 == 0 ? "Нет" : "\($0)%" },
                                action: #selector(chooseTransparency(_:))))
        menu.addItem(choiceMenu(title: "Подпись при нескольких окнах приложения", choices: CaptionPlace.allCases.map(\.rawValue),
                                current: DisplaySettings.captionPlace.rawValue,
                                label: { CaptionPlace(rawValue: $0)?.title ?? "" },
                                action: #selector(chooseCaptionPlace(_:))))
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Запускать при входе", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let hide = NSMenuItem(title: "Скрыть значок (вернуть — открыть StageStrip снова)",
                              action: #selector(hideIcon), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выйти", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func choiceMenu(title: String, choices: [Int], current: Int,
                            label: (Int) -> String, action: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for choice in choices {
            let item = NSMenuItem(title: label(choice), action: action, keyEquivalent: "")
            item.target = self
            item.tag = choice
            item.state = choice == current ? .on : .off
            sub.addItem(item)
        }
        parent.submenu = sub
        return parent
    }

    @objc private func chooseTileCount(_ sender: NSMenuItem) {
        DisplaySettings.maxTiles = sender.tag
        updatePanels()
        rebuildMenu()
    }

    @objc private func chooseTransparency(_ sender: NSMenuItem) {
        DisplaySettings.transparency = sender.tag
        updatePanels()
        rebuildMenu()
    }

    @objc private func chooseCaptionPlace(_ sender: NSMenuItem) {
        DisplaySettings.captionPlace = CaptionPlace(rawValue: sender.tag) ?? .aboveTile
        updatePanels()
        rebuildMenu()
    }

    @objc private func chooseSide(_ sender: NSMenuItem) {
        guard let data = sender.representedObject as? [String: String],
              let screen = NSScreen.screens.first(where: { DisplaySettings.key(for: $0) == data["key"] }),
              let side = data["side"].flatMap(StripSide.init(rawValue:)) else { return }
        DisplaySettings.setSide(side, for: screen)
        updatePanels()
        rebuildMenu()
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не удалось изменить автозапуск"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        rebuildMenu()
    }

    @objc private func hideIcon() { statusItem.isVisible = false }

    @objc private func quitApp() { NSApp.terminate(nil) }

    /// With the icon hidden, opening the running app again is the way back to the menu.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem.isVisible = true
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        tracker.restoreAllParked()
    }
}

let app = NSApplication.shared
let delegate = StageStripApp()
app.delegate = delegate
app.run()
