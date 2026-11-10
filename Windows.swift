import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
private func AXWindowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

struct WindowItem {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let appName: String
    let frame: CGRect                 // Quartz coordinates, origin at top left
    let icon: NSImage?
    let ax: AXUIElement?
    let minimized: Bool
}

final class WindowTracker {
    var onChange: (() -> Void)?
    private(set) var windows: [CGWindowID: WindowItem] = [:]
    private(set) var ordered: [CGWindowID] = []
    private(set) var frontID: CGWindowID?
    private var topOnScreen: [String: CGWindowID] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private var pending = false
    private(set) var parked: [CGWindowID: CGRect] = [:]
    private var parkedPIDs: [CGWindowID: pid_t] = [:]
    private var focusArmed = Set<CGWindowID>()
    private var pendingUnpark = Set<CGWindowID>()
    private var everParked = Set<CGWindowID>()
    private var parkedBundles: [CGWindowID: String] = [:]
    /// Pre-park frames of windows that closed while parked, by app: the app saved the off-screen
    /// position and will reopen its next window there.
    private var orphanFrames: [String: CGRect] = [:]
    private let orphanKey = "orphanFrames"
    // A window we just brought forward; app activation lags, so trust it as the front for a moment.
    private var pendingFront: (id: CGWindowID, until: Date)?
    private let parkedKey = "parked"
    /// Windows the user pinned to a strip slot (0 is the top tile); the rest flow around them.
    private(set) var pinned: [CGWindowID: Int] = [:]
    private let pinnedKey = "pinned"
    private let systemOwners: Set<String> = ["Dock", "WindowServer", "Window Server", "Control Center", "Notification Center", "NotificationCenter", "SystemUIServer", "Spotlight", "StageStrip", "WindowManager"]

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            center.addObserver(self, selector: #selector(workspaceChanged), name: name, object: nil)
        }
        loadOrphans()
        restoreSavedWindows()
        loadPinned()
        refresh()
    }

    @objc private func workspaceChanged() { scheduleRefresh() }

    func scheduleRefresh() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.pending = false
            self?.refresh()
        }
    }

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }

    private func axWindows(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        return attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    private func isMinimized(_ window: AXUIElement) -> Bool {
        attribute(window, kAXMinimizedAttribute) as? Bool == true
    }

    private func axFrame(_ window: AXUIElement) -> CGRect? {
        guard let p = attribute(window, kAXPositionAttribute), let s = attribute(window, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private func setPosition(_ window: AXUIElement, _ point: CGPoint) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }

    private func windowID(_ window: AXUIElement, pid: pid_t) -> CGWindowID? {
        if let item = windows.values.first(where: { $0.pid == pid && $0.ax.map { CFEqual($0, window) } == true }) {
            return item.id
        }
        var id: CGWindowID = 0
        return AXWindowID(window, &id) == .success && id != 0 ? id : nil
    }

    private func saveParked() {
        let records: [[String: Double]] = parked.compactMap { id, frame in
            guard let pid = parkedPIDs[id] else { return nil }
            return ["pid": Double(pid), "windowID": Double(id), "x": Double(frame.minX),
                    "y": Double(frame.minY), "w": Double(frame.width), "h": Double(frame.height)]
        }
        UserDefaults.standard.set(records, forKey: parkedKey)
    }

    private func loadOrphans() {
        guard let records = UserDefaults.standard.dictionary(forKey: orphanKey) as? [String: [Double]] else { return }
        for (bundle, v) in records where v.count == 4 {
            orphanFrames[bundle] = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        }
    }

    private func saveOrphans() {
        let records = orphanFrames.mapValues { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] }
        if records.isEmpty { UserDefaults.standard.removeObject(forKey: orphanKey) }
        else { UserDefaults.standard.set(records, forKey: orphanKey) }
    }

    private func loadPinned() {
        guard let records = UserDefaults.standard.array(forKey: pinnedKey) as? [[String: Int]] else { return }
        for record in records {
            if let id = record["windowID"], let slot = record["slot"], id > 0, slot >= 0 { pinned[CGWindowID(id)] = slot }
        }
    }

    private func savePinned() {
        let records = pinned.map { ["windowID": Int($0.key), "slot": $0.value] }
        if records.isEmpty { UserDefaults.standard.removeObject(forKey: pinnedKey) }
        else { UserDefaults.standard.set(records, forKey: pinnedKey) }
    }

    func isPinned(_ id: CGWindowID) -> Bool { pinned[id] != nil }

    /// Pins the window to the slot its tile is in now, or lets it flow again.
    func togglePin(_ id: CGWindowID, slot: Int) {
        if pinned.removeValue(forKey: id) == nil {
            // Another window pinned to the same slot gives way.
            pinned = pinned.filter { $0.value != slot }
            pinned[id] = slot
        }
        savePinned()
        onChange?()
    }

    private func restoreSavedWindows() {
        guard AXIsProcessTrusted() else { return }
        guard let records = UserDefaults.standard.array(forKey: parkedKey) as? [[String: Double]] else { return }
        let live = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        let liveIDs = Set(live.compactMap { entry -> CGWindowID? in
            (entry[kCGWindowNumber as String] as? NSNumber).map { CGWindowID($0.uint32Value) }
        })
        var retry: [[String: Double]] = []
        for record in records {
            guard let p = record["pid"], let n = record["windowID"], let x = record["x"],
                  let y = record["y"], let w = record["w"], let h = record["h"],
                  let app = NSRunningApplication(processIdentifier: pid_t(p)), !app.isTerminated else { continue }
            let id = CGWindowID(n)
            if let ax = axWindows(pid: pid_t(p)).first(where: { candidate in
                var candidateID: CGWindowID = 0
                return AXWindowID(candidate, &candidateID) == .success && candidateID == id
            }) {
                if !setPosition(ax, CGPoint(x: x, y: y)) { retry.append(record) }
            } else if liveIDs.contains(id) {
                retry.append(record)
            }
            _ = (w, h) // The position is the only attribute changed by parking.
        }
        if retry.isEmpty { UserDefaults.standard.removeObject(forKey: parkedKey) }
        else { UserDefaults.standard.set(retry, forKey: parkedKey) }
    }

    func isParked(_ id: CGWindowID) -> Bool { parked[id] != nil }

    func park(_ window: AXUIElement, thumbnails: ThumbnailStore, zoom: ZoomOverlay,
              destination: @escaping (CGWindowID, NSScreen) -> CGRect?,
              perspective: @escaping (NSScreen) -> (pivot: CGPoint, angle: CGFloat)?,
              landed: @escaping (CGWindowID) -> Void) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success, pid != getpid(),
              let id = windowID(window, pid: pid), parked[id] == nil,
              let item = windows[id], item.pid == pid, let frame = axFrame(window) else { return }
        let mainTop = NSScreen.screens.first?.frame.height ?? 0
        // The window may have just been moved to another screen, so go by its live frame.
        let center = CGPoint(x: frame.midX, y: mainTop - frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? screen(for: item)
        else { return }
        let image = thumbnails.image(for: id)
        let start = CGRect(x: frame.minX, y: mainTop - frame.maxY,
                           width: frame.width, height: frame.height)
        parked[id] = frame
        parkedPIDs[id] = pid
        parkedBundles[id] = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        saveParked()
        ordered.removeAll { $0 == id }
        ordered.insert(id, at: 0)
        if frontID == id { frontID = nil }
        // Asked once before the strip rebuilds, so the new tile starts out hidden.
        _ = destination(id, screen)
        onChange?()
        let target = { destination(id, screen) ?? CGRect(x: screen.frame.minX + 8,
            y: screen.frame.midY - 40, width: 80, height: 80) }
        let quartzBottom = mainTop - screen.frame.minY
        // Park past the corner that has no neighbouring screen, so the window can't spill onto it.
        let rightTaken = NSScreen.screens.contains { $0 != screen && abs($0.frame.minX - screen.frame.maxX) < 2 }
        let offscreen = CGPoint(x: rightTaken ? screen.frame.minX - frame.width + 1 : screen.frame.maxX - 1,
                                y: quartzBottom - 1)
        zoom.zoom(image: image, icon: item.icon, title: item.title, from: start, to: target(),
                  tilt: StripPanel.tilt(for: DisplaySettings.side(for: screen)),
                  perspective: { perspective(screen) }, shown: { [weak self] in
            guard let self else { return }
            guard self.setPosition(window, offscreen) else {
                self.parked.removeValue(forKey: id)
                self.parkedPIDs.removeValue(forKey: id)
                self.parkedBundles.removeValue(forKey: id)
                self.saveParked()
                self.scheduleRefresh()
                return
            }
            self.everParked.insert(id)
            let successor = self.ordered.compactMap { self.windows[$0] }.first {
                $0.id != id && $0.pid == pid && !$0.minimized && self.parked[$0.id] == nil
            } ?? self.ordered.compactMap { self.windows[$0] }.first {
                $0.id != id && !$0.minimized && self.parked[$0.id] == nil && self.screen(for: $0) == screen
            }
            // Take the successor out of the strip now, so the tile is already where it will stay
            // when the image sets off; the slow focus change itself waits.
            if let successor {
                self.frontID = successor.id
                self.topOnScreen[DisplaySettings.key(for: screen)] = successor.id
                self.onChange?()
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let successor { self.activate(successor.id) }
                self.scheduleRefresh()
            }
        }, retarget: target, completion: { landed(id) })
    }

    func unpark(_ id: CGWindowID) {
        guard let frame = parked[id] else {
            pendingUnpark.remove(id)
            return
        }
        let ax = windows[id]?.ax ?? axWindows(pid: parkedPIDs[id] ?? 0).first { candidate in
            var candidateID: CGWindowID = 0
            return AXWindowID(candidate, &candidateID) == .success && candidateID == id
        }
        guard let ax, setPosition(ax, frame.origin) else {
            pendingUnpark.insert(id)
            return
        }
        pendingUnpark.remove(id)
        parked.removeValue(forKey: id)
        parkedPIDs.removeValue(forKey: id)
        parkedBundles.removeValue(forKey: id)
        focusArmed.remove(id)
        saveParked()
        scheduleRefresh()
    }

    func restoreAllParked() {
        for id in Array(parked.keys) { unpark(id) }
    }

    private func axMatch(pid: pid_t, id: CGWindowID, title: String, frame: CGRect,
                         cache: inout [pid_t: [AXUIElement]]) -> AXUIElement? {
        if cache[pid] == nil { cache[pid] = axWindows(pid: pid) }
        // The exact window number first: CGWindowList truncates long titles with "…"
        // (Chrome's DevTools), so a title comparison alone misses such windows.
        if let exact = cache[pid]?.first(where: { candidate in
            var candidateID: CGWindowID = 0
            return AXWindowID(candidate, &candidateID) == .success && candidateID == id
        }) { return exact }
        return cache[pid]?.min { a, b in score(a, title: title, frame: frame) < score(b, title: title, frame: frame) }
            .flatMap { score($0, title: title, frame: frame) < 120 ? $0 : nil }
    }

    private func score(_ element: AXUIElement, title: String, frame: CGRect) -> CGFloat {
        guard let f = axFrame(element) else { return .greatestFiniteMagnitude }
        let t = attribute(element, kAXTitleAttribute) as? String ?? ""
        let mismatch: CGFloat = !title.isEmpty && !t.isEmpty && title != t ? 500 : 0
        return abs(f.minX - frame.minX) + abs(f.minY - frame.minY)
            + abs(f.width - frame.width) + abs(f.height - frame.height) + mismatch
    }

    private func observe(pid: pid_t) {
        guard AXIsProcessTrusted(), observers[pid] == nil, pid != getpid() else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            let tracker = Unmanaged<WindowTracker>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { tracker.scheduleRefresh() }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let app = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()
        _ = AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, context)
        _ = AXObserverAddNotification(observer, app, kAXMainWindowChangedNotification as CFString, context)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    private func observeWindow(_ window: AXUIElement, pid: pid_t) {
        guard let observer = observers[pid] else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        _ = AXObserverAddNotification(observer, window, kAXWindowMiniaturizedNotification as CFString, context)
        _ = AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, context)
    }

    private func removeDeadObservers(activePIDs: Set<pid_t>) {
        for (pid, observer) in observers where !activePIDs.contains(pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            observers.removeValue(forKey: pid)
        }
    }

    func refresh() {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var found: [CGWindowID: WindowItem] = [:]
        var zOrder: [CGWindowID] = []
        var visibleParked: [CGWindowID] = []
        var axCache: [pid_t: [AXUIElement]] = [:]
        var activePIDs = Set<pid_t>()

        for entry in list {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pidNum = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  let idNum = entry[kCGWindowNumber as String] as? NSNumber,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= 100, rect.height >= 100 else { continue }
            let pid = pidNum.int32Value
            let id = CGWindowID(idNum.uint32Value)
            let owner = entry[kCGWindowOwnerName as String] as? String ?? ""
            let title = entry[kCGWindowName as String] as? String ?? ""
            guard pid != getpid(), !systemOwners.contains(owner), !(owner == "Finder" && title.isEmpty) else { continue }
            let app = NSRunningApplication(processIdentifier: pid)
            guard let app, !app.isHidden else { continue }
            activePIDs.insert(pid)
            observe(pid: pid)
            let ax = AXIsProcessTrusted() ? axMatch(pid: pid, id: id, title: title, frame: rect, cache: &axCache) : nil
            // Pop-ups such as Chrome's downloads bubble are layer 0 too; only their subrole gives them away.
            if let ax, parked[id] == nil, attribute(ax, kAXSubroleAttribute) as? String == "AXUnknown" { continue }
            if let ax { observeWindow(ax, pid: pid) }
            found[id] = WindowItem(id: id, pid: pid, title: title.isEmpty ? owner : title,
                                   appName: owner, frame: parked[id] ?? rect, icon: app.icon, ax: ax, minimized: false)
            if parked[id] == nil { zOrder.append(id) }
            else { visibleParked.append(id) }
        }

        // Minimized windows leave CGWindowList. Keep only live AX windows that are still minimized.
        var newlyMinimized: [CGWindowID] = []
        for (id, old) in windows where found[id] == nil && parked[id] == nil {
            guard let app = NSRunningApplication(processIdentifier: old.pid),
                  !app.isTerminated, !app.isHidden else { continue }
            if axCache[old.pid] == nil { axCache[old.pid] = axWindows(pid: old.pid) }
            guard let candidates = axCache[old.pid],
                  let ax = old.ax.flatMap({ previous in candidates.first { CFEqual($0, previous) } })
                    ?? axMatch(pid: old.pid, id: old.id, title: old.title, frame: old.frame, cache: &axCache),
                  isMinimized(ax) else { continue }
            observe(pid: old.pid)
            observeWindow(ax, pid: old.pid)
            found[id] = WindowItem(id: old.id, pid: old.pid, title: old.title, appName: old.appName,
                                   frame: old.frame, icon: old.icon, ax: ax, minimized: true)
            if !old.minimized { newlyMinimized.append(id) }
            activePIDs.insert(old.pid)
        }

        let allWindows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]
        let liveIDs = Set((allWindows ?? []).compactMap { entry -> CGWindowID? in
            (entry[kCGWindowNumber as String] as? NSNumber).map { CGWindowID($0.uint32Value) }
        })
        let closedParked = Array(parked.keys).filter { id in
            guard found[id] == nil else { return false }
            guard let pid = parkedPIDs[id], let app = NSRunningApplication(processIdentifier: pid),
                  !app.isTerminated else { return true }
            return allWindows != nil && !liveIDs.contains(id)
        }
        for id in closedParked {
            if let bundle = parkedBundles.removeValue(forKey: id), let frame = parked[id] {
                orphanFrames[bundle] = frame
            }
            parked.removeValue(forKey: id)
            parkedPIDs.removeValue(forKey: id)
            focusArmed.remove(id)
            pendingUnpark.remove(id)
            everParked.remove(id)
        }
        if !closedParked.isEmpty { saveParked(); saveOrphans() }
        let closedPinned = pinned.keys.filter { allWindows != nil && !liveIDs.contains($0) }
        for id in closedPinned { pinned.removeValue(forKey: id) }
        if !closedPinned.isEmpty { savePinned() }

        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        let onScreen = { (frame: CGRect) in
            NSScreen.screens.contains { $0.frame.contains(CGPoint(x: frame.midX, y: mainTop - frame.midY)) }
        }
        // Lost former parked windows, and new windows an app reopened where we once parked its window.
        for (id, item) in found where (everParked.contains(id) || windows[id] == nil)
            && parked[id] == nil && !item.minimized && !onScreen(item.frame) {
            guard let screen = NSScreen.screens.first, let ax = item.ax else { continue }
            let bundle = NSRunningApplication(processIdentifier: item.pid)?.bundleIdentifier
            let saved = bundle.flatMap { orphanFrames[$0] }.flatMap { onScreen($0) ? $0 : nil }
            let point = saved?.origin ?? CGPoint(x: screen.visibleFrame.minX + 40,
                                                 y: mainTop - screen.visibleFrame.maxY + 40)
            if setPosition(ax, point) {
                everParked.remove(id)
                if let bundle, orphanFrames.removeValue(forKey: bundle) != nil { saveOrphans() }
                scheduleRefresh()
            }
        }
        if allWindows != nil { everParked.formIntersection(liveIDs) }

        removeDeadObservers(activePIDs: activePIDs)
        let oldTopOnScreen = topOnScreen
        topOnScreen.removeAll()
        for id in zOrder {
            guard let item = found[id], let screen = screen(for: item) else { continue }
            let key = DisplaySettings.key(for: screen)
            if topOnScreen[key] == nil { topOnScreen[key] = id }
        }
        let oldOrder = ordered
        ordered.removeAll { found[$0] == nil }
        for id in zOrder.reversed() where !ordered.contains(id) { ordered.insert(id, at: 0) }
        for id in visibleParked.reversed() where !ordered.contains(id) { ordered.insert(id, at: 0) }

        let activePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var front = zOrder.first { found[$0]?.pid == activePID } ?? zOrder.first
        if let pending = pendingFront {
            if front == pending.id || pending.until < Date() || found[pending.id] == nil {
                pendingFront = nil
            } else {
                front = pending.id
            }
        }
        if front != frontID {
            frontID = front
        }
        if let front {
            ordered.removeAll { $0 == front }
            ordered.insert(front, at: 0)
        }
        for id in newlyMinimized {
            ordered.removeAll { $0 == id }
            ordered.insert(id, at: 0)
        }
        let changed = Set(found.keys) != Set(windows.keys) || oldOrder != ordered
            || oldTopOnScreen != topOnScreen
            || found.contains { (id, item) in windows[id]?.frame != item.frame || windows[id]?.minimized != item.minimized }
        windows = found
        if let activePID {
            let app = AXUIElementCreateApplication(activePID)
            let focused = (attribute(app, kAXFocusedWindowAttribute) ?? attribute(app, kAXMainWindowAttribute))
                .flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
            let focusedID = focused.flatMap { windowID($0, pid: activePID) }
            for id in parked.keys {
                if focusedID == id {
                    if focusArmed.contains(id) { unpark(id) }
                } else {
                    focusArmed.insert(id)
                }
            }
        }
        if changed { onChange?() }
        for id in Array(pendingUnpark) { unpark(id) }
    }

    func screen(for item: WindowItem) -> NSScreen? {
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        let point = CGPoint(x: item.frame.midX, y: mainTop - item.frame.midY)
        return NSScreen.screens.first { $0.frame.contains(point) }
    }

    func recent(on screen: NSScreen) -> [WindowItem] {
        let topID = topOnScreen[DisplaySettings.key(for: screen)]
        let shown = { (id: CGWindowID) -> WindowItem? in
            guard id != self.frontID, (id != topID || self.parked[id] != nil),
                  let item = self.windows[id], self.screen(for: item) == screen,
                  NSRunningApplication(processIdentifier: item.pid)?.isHidden != true else { return nil }
            return item
        }
        let maxTiles = StripPanel.maxTiles
        var items = ordered.filter { pinned[$0] == nil }.compactMap(shown)
        // Pinned tiles go into their slots top-down; the recent ones fill the gaps around them.
        let pinnedHere = pinned.compactMap { id, slot in shown(id).map { (item: $0, slot: slot) } }
            .sorted { $0.slot < $1.slot }
        for entry in pinnedHere {
            items.insert(entry.item, at: min(entry.slot, items.count, max(maxTiles - 1, 0)))
        }
        return Array(items.prefix(maxTiles))
    }

    func item(for id: CGWindowID) -> WindowItem? { windows[id] }

    /// True when some part of the window shows from under the windows above it.
    func isPartlyVisible(_ id: CGWindowID) -> Bool {
        guard let item = windows[id], !item.minimized, parked[id] == nil,
              NSRunningApplication(processIdentifier: item.pid)?.isHidden != true else { return false }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], id) as? [[String: Any]] ?? []
        let covers = list.compactMap { info -> CGRect? in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: bounds)
        }
        let screens = NSScreen.screens.map(\.frame)
        let mainTop = screens.first?.maxY ?? 0
        let steps = 12
        for i in 0...steps {
            for j in 0...steps {
                let point = CGPoint(x: item.frame.minX + item.frame.width * CGFloat(i) / CGFloat(steps),
                                    y: item.frame.minY + item.frame.height * CGFloat(j) / CGFloat(steps))
                let onScreen = screens.contains { $0.contains(CGPoint(x: point.x, y: mainTop - point.y)) }
                if onScreen && !covers.contains(where: { $0.contains(point) }) { return true }
            }
        }
        return false
    }

    func stripIsBlocked(on screen: NSScreen, side: StripSide) -> Bool {
        // `-debugNeverBlocked YES` at launch keeps the strip at rest over windows, for screenshots.
        guard side != .off, !UserDefaults.standard.bool(forKey: "debugNeverBlocked") else { return false }
        let edge = side == .left ? screen.frame.minX : screen.frame.maxX
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        return windows.values.contains { item in
            guard !item.minimized, parked[item.id] == nil,
                  let itemScreen = self.screen(for: item), itemScreen == screen else { return false }
            let frame = CGRect(x: item.frame.minX, y: mainTop - item.frame.maxY,
                               width: item.frame.width, height: item.frame.height)
            return side == .left ? frame.minX < edge + 180 : frame.maxX > edge - 180
        }
    }

    func isFullScreen(on screen: NSScreen) -> Bool {
        guard let frontID, parked[frontID] == nil, let item = windows[frontID],
              self.screen(for: item) == screen else { return false }
        let f = item.frame
        return f.width >= screen.frame.width - 4 && f.height >= screen.frame.height - 4
    }

    func activate(_ id: CGWindowID) {
        if parked[id] != nil {
            unpark(id)
            guard parked[id] == nil else { return }
        }
        guard let item = windows[id], let app = NSRunningApplication(processIdentifier: item.pid) else { return }
        if app.isHidden { app.unhide() }
        if item.minimized, let ax = item.ax {
            _ = AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        if let ax = item.ax { _ = AXUIElementPerformAction(ax, kAXRaiseAction as CFString) }
        app.activate(options: [])
        ordered.removeAll { $0 == id }
        ordered.insert(id, at: 0)
        frontID = id
        pendingFront = (id, Date().addingTimeInterval(1))
        scheduleRefresh()
        onChange?()
    }
}
