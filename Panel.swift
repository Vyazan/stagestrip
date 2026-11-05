import AppKit
import QuartzCore
import ScreenCaptureKit

private func averageBrightness(of image: CGImage, in rect: CGRect) -> UInt8? {
    guard let crop = image.cropping(to: rect),
          let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return context.data?.load(as: UInt8.self)
}

private final class StripItemView: NSView {
    let id: CGWindowID
    private let contentLayer = CALayer()
    private let thumbnailLayer = CALayer()
    private let iconLayer = CALayer()
    private let titleLayer = CATextLayer()
    private let captionLayer = CATextLayer()
    private var thumbnail: CGImage?
    private var backdropBrightness: UInt8?
    private let click: (CGWindowID) -> Void
    private var hovering = false
    private var side: StripSide
    private var transformApplied = false

    init(item: WindowItem, image: NSImage?, showsCaption: Bool, side: StripSide,
         click: @escaping (CGWindowID) -> Void) {
        id = item.id
        self.side = side
        self.click = click
        super.init(frame: .zero)
        wantsLayer = true
        contentLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        // The app icon overlaps the tile's corner, so only the thumbnail is clipped.
        contentLayer.masksToBounds = false
        thumbnailLayer.cornerRadius = 9
        thumbnailLayer.masksToBounds = true
        layer?.addSublayer(contentLayer)
        thumbnailLayer.contentsGravity = .resizeAspect
        contentLayer.addSublayer(thumbnailLayer)
        iconLayer.contentsGravity = .resizeAspect
        contentLayer.addSublayer(iconLayer)
        titleLayer.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        titleLayer.fontSize = 11
        titleLayer.foregroundColor = NSColor.white.cgColor
        titleLayer.alignmentMode = .center
        titleLayer.truncationMode = .end
        titleLayer.isWrapped = true
        contentLayer.addSublayer(titleLayer)
        captionLayer.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        captionLayer.fontSize = 11
        captionLayer.foregroundColor = NSColor.white.cgColor
        captionLayer.truncationMode = .end
        contentLayer.addSublayer(captionLayer)
        update(item: item, image: image, showsCaption: showsCaption)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        contentLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        thumbnailLayer.frame = contentLayer.bounds
        layoutIcon()
        layoutTitle()
        layoutCaption()
        updateCaptionColor()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        thumbnailLayer.contentsScale = scale
        iconLayer.contentsScale = scale
        titleLayer.contentsScale = scale
        captionLayer.contentsScale = scale
        CATransaction.commit()
        if !transformApplied { updateTransform(animated: false) }
    }

    func update(item: WindowItem, image: NSImage?, showsCaption: Bool) {
        thumbnail = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        thumbnailLayer.contents = thumbnail
        thumbnailLayer.minificationFilter = .trilinear
        iconLayer.contents = item.icon?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        iconLayer.isHidden = item.icon == nil
        // A window that can't be captured gets a plain frame with its title.
        let framed = image == nil
        titleLayer.string = framed ? (item.title.isEmpty ? item.appName : item.title) : ""
        titleLayer.isHidden = !framed
        contentLayer.cornerRadius = 9
        contentLayer.backgroundColor = framed ? NSColor(white: 0.12, alpha: 0.85).cgColor : nil
        contentLayer.borderColor = NSColor(white: 1, alpha: 0.45).cgColor
        contentLayer.borderWidth = framed ? 1 : 0
        layoutTitle()
        // A card already shows its title inside.
        let caption = showsCaption && !framed ? item.title : ""
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if captionLayer.string as? String != caption { captionLayer.string = caption }
        captionLayer.isHidden = caption.isEmpty
        layoutCaption()
        updateCaptionColor()
        CATransaction.commit()
    }

    private func layoutTitle() {
        // The text layer draws from its top edge, so the frame is fitted to the text to centre it.
        let width = max(0, bounds.width - 32)
        let text = (titleLayer.string as? String ?? "") as NSString
        let height = min(36, ceil(text.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).height))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        titleLayer.frame = CGRect(x: 16, y: (bounds.height - height) / 2, width: width, height: height)
        CATransaction.commit()
    }

    private func layoutCaption() {
        let height: CGFloat = 14
        switch DisplaySettings.captionPlace {
        case .aboveTile:
            let inset: CGFloat = 20
            captionLayer.alignmentMode = .center
            captionLayer.frame = CGRect(x: inset, y: bounds.height + 3,
                                        width: max(bounds.width - inset * 2, 40), height: height)
        case .besideIcon:
            // Level with the centre of the icon that overlaps the tile's corner.
            let iconInset: CGFloat = 28
            let width = max(bounds.width - iconInset - 6, 40)
            captionLayer.alignmentMode = side == .right ? .right : .left
            captionLayer.frame = CGRect(x: side == .right ? bounds.width - iconInset - width : iconInset,
                                        y: 7 - height / 2, width: width, height: height)
        }
    }

    /// The caption has no backing, so it takes dark or white depending on what lies under it:
    /// the thumbnail beside the icon, whatever is behind the strip above the tile.
    private func updateCaptionColor() {
        guard !captionLayer.isHidden, bounds.width > 0, bounds.height > 0 else { return }
        let brightness: UInt8?
        switch DisplaySettings.captionPlace {
        case .aboveTile:
            brightness = backdropBrightness
        case .besideIcon:
            let text = captionTextRect
            brightness = thumbnail.flatMap { thumbnail in
                let scaleX = CGFloat(thumbnail.width) / bounds.width
                let scaleY = CGFloat(thumbnail.height) / bounds.height
                // CGImage rows run from the top; the tile's coordinates from the bottom.
                return averageBrightness(of: thumbnail, in: CGRect(
                    x: text.minX * scaleX, y: (bounds.height - text.maxY) * scaleY,
                    width: text.width * scaleX, height: text.height * scaleY))
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        captionLayer.foregroundColor = ((brightness ?? 0) > 128 ? NSColor(white: 0, alpha: 0.82) : NSColor.white).cgColor
        CATransaction.commit()
    }

    /// Where the caption's text is, in the tile's coordinates; nil when there is no caption.
    var visibleCaptionRect: CGRect? { captionLayer.isHidden ? nil : captionTextRect }

    private var captionTextRect: CGRect {
        let box = captionLayer.frame
        let text = (captionLayer.string as? String ?? "") as NSString
        let width = min(box.width, text.size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width)
        let x: CGFloat
        switch captionLayer.alignmentMode {
        case .center: x = box.midX - width / 2
        case .right: x = box.maxX - width
        default: x = box.minX
        }
        return CGRect(x: x, y: box.minY, width: width, height: box.height)
    }

    func setBackdropBrightness(_ brightness: UInt8?) {
        backdropBrightness = brightness
        updateCaptionColor()
    }

    func setSide(_ side: StripSide) {
        guard self.side != side else { return }
        self.side = side
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutIcon()
        layoutCaption()
        updateCaptionColor()
        CATransaction.commit()
    }

    private func layoutIcon() {
        iconLayer.frame = CGRect(x: side == .right ? bounds.width - 24 : -10,
                                 y: -10, width: 34, height: 34)
    }

    private func updateTransform(animated: Bool) {
        let transform = hovering
            ? CATransform3DMakeScale(1.045, 1.045, 1) : CATransform3DIdentity
        if animated {
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = contentLayer.presentation()?.transform ?? contentLayer.transform
            animation.toValue = transform
            animation.duration = 0.25
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            contentLayer.add(animation, forKey: "stripTransform")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.transform = transform
        CATransaction.commit()
        transformApplied = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        updateTransform(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateTransform(animated: true)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { click(id) }
}

final class StripPanel: NSPanel {
    static var maxTiles: Int { DisplaySettings.maxTiles }
    /// How far the tiles turn towards the middle of the screen while the strip is at rest.
    static func tilt(for side: StripSide) -> CGFloat { side == .left ? 0.3 : -0.3 }
    private static let width: CGFloat = 220
    private static let stripWidth: CGFloat = 170
    private static let tileSize: CGFloat = 160
    private static let fallbackHeight: CGFloat = 88
    private static let rowGap: CGFloat = 26
    private let click: (CGWindowID) -> Void
    private let tilesView = NSView(frame: .zero)
    private var rows: [CGWindowID: StripItemView] = [:]
    private var screenRef: NSScreen
    private var side: StripSide
    private var shown = true
    private var currentItems: [WindowItem] = []
    private var stripHeight: CGFloat = 1
    private var panelHeight: CGFloat = 1
    private var rowTargets: [CGWindowID: CGRect] = [:]
    private var hiddenTiles: Set<CGWindowID> = []
    private var hideTokens: [CGWindowID: Int] = [:]
    private var restingFrame: CGRect = .zero
    private var frameTarget: CGRect?
    private var exposed = true
    private var transformApplied = false
    private var backdropRequested = false
    private var lastBackdropRequest = Date.distantPast

    init(screen: NSScreen, side: StripSide, onClick: @escaping (CGWindowID) -> Void) {
        screenRef = screen
        self.side = side
        click = onClick
        super.init(contentRect: CGRect(x: 0, y: 0, width: Self.width, height: 1),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        tilesView.wantsLayer = true
        tilesView.layer?.masksToBounds = false
        contentView?.addSubview(tilesView)
        setFrameForScreen(screen: screen, side: side, shown: true, animated: false)
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `sharedPIDs`: apps with several windows open, whose tiles are told apart by a caption.
    func update(items: [WindowItem], sharedPIDs: Set<pid_t>, thumbnails: ThumbnailStore,
                exposed: Bool, visible: Bool) {
        tilesView.alphaValue = 1 - CGFloat(DisplaySettings.transparency) / 100
        currentItems = Array(items.prefix(Self.maxTiles))
        let images = currentItems.map { thumbnails.image(for: $0.id) }
        let naturalSizes = images.map { image -> CGSize in
            guard let image, image.size.width > 0, image.size.height > 0 else {
                return CGSize(width: Self.tileSize, height: Self.fallbackHeight)
            }
            let scale = Self.tileSize / max(image.size.width, image.size.height)
            return CGSize(width: image.size.width * scale, height: image.size.height * scale)
        }
        let gaps = CGFloat(currentItems.count) * Self.rowGap + 6
        // Reserve space for the shared perspective and the hover scale.
        let available = max(1, (screenRef.visibleFrame.height - 12) / 1.16 - gaps)
        let scale = min(1, available / max(1, naturalSizes.reduce(CGFloat(0)) { $0 + $1.height }))
        let rowHeights = naturalSizes.map { $0.height * scale }
        stripHeight = rowHeights.reduce(0, +) + gaps
        // The panel spans the whole screen height and never resizes; only the strip inside
        // moves, so a change in the number of tiles glides instead of jumping.
        panelHeight = screenRef.visibleFrame.height
        layoutTilesView(animated: tilesView.frame.height > 1)
        let ids = Set(currentItems.map(\.id))
        for (id, row) in rows where !ids.contains(id) {
            row.removeFromSuperview()
            rows.removeValue(forKey: id)
            rowTargets.removeValue(forKey: id)
        }
        var top = stripHeight - 3
        for (index, item) in currentItems.enumerated() {
            let image = images[index]
            let row: StripItemView
            if let existing = rows[item.id] {
                row = existing
                row.update(item: item, image: image, showsCaption: sharedPIDs.contains(item.pid))
            } else {
                row = StripItemView(item: item, image: image, showsCaption: sharedPIDs.contains(item.pid),
                                    side: side, click: click)
                rows[item.id] = row
                tilesView.addSubview(row)
            }
            let rowHeight = rowHeights[index]
            top -= rowHeight
            let rowWidth = naturalSizes[index].width * scale
            let target = CGRect(x: side == .right ? Self.stripWidth - rowWidth : 0, y: top,
                                width: rowWidth, height: rowHeight)
            top -= Self.rowGap
            rowTargets[item.id] = target
            row.isHidden = hiddenTiles.contains(item.id)
            if row.frame != target {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = row.frame == .zero ? 0 : 0.25
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    row.animator().frame = target
                }
            }
        }
        setPresentation(exposed: exposed, visible: visible)
        if visible { refreshBackdrop() }
    }

    /// Captions above the tiles lie on whatever is behind the strip, so that gets sampled,
    /// at low resolution and without our own windows.
    private func refreshBackdrop() {
        guard DisplaySettings.captionPlace == .aboveTile, side != .off, !backdropRequested,
              Date().timeIntervalSince(lastBackdropRequest) >= 2,
              rows.values.contains(where: { $0.visibleCaptionRect != nil }),
              let number = screenRef.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return }
        backdropRequested = true
        lastBackdropRequest = Date()
        let area = restingFrame, screen = screenRef.frame
        Task { @MainActor [weak self] in
            defer { self?.backdropRequested = false }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let display = content.displays.first(where: { $0.displayID == number.uint32Value })
            else { return }
            let own = content.applications.filter { $0.processID == getpid() }
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = CGRect(x: area.minX - screen.minX, y: screen.maxY - area.maxY,
                                              width: area.width, height: area.height)
            configuration.width = max(1, Int(area.width))
            configuration.height = max(1, Int(area.height))
            configuration.showsCursor = false
            guard let image = try? await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingApplications: own, exceptingWindows: []),
                configuration: configuration), let self else { return }
            for (id, row) in self.rows {
                guard let caption = row.visibleCaptionRect, let target = self.rowTargets[id] else { continue }
                // Panel coordinates run from the bottom, the image's rows from the top.
                let inPanel = caption.offsetBy(dx: target.minX + self.tilesView.frame.minX,
                                               dy: target.minY + self.tilesView.frame.minY)
                let scaleX = CGFloat(image.width) / area.width, scaleY = CGFloat(image.height) / area.height
                row.setBackdropBrightness(averageBrightness(of: image, in: CGRect(
                    x: inPanel.minX * scaleX, y: (area.height - inPanel.maxY) * scaleY,
                    width: inPanel.width * scaleX, height: inPanel.height * scaleY)))
            }
        }
    }

    func setPresentation(exposed: Bool, visible: Bool) {
        self.exposed = exposed
        for row in rows.values { row.setSide(side) }
        updateStripTransform(animated: transformApplied)
        if visible && side != .off && !currentItems.isEmpty {
            orderFrontRegardless()
        } else {
            orderOut(nil)
        }
    }

    func setFrameForScreen(screen: NSScreen, side: StripSide, shown: Bool, animated: Bool) {
        screenRef = screen
        self.side = side
        self.shown = shown
        layoutTilesView()
        for row in rows.values { row.setSide(side) }
        updateStripTransform(animated: transformApplied)
        let height = panelHeight
        let bounds = screen.visibleFrame
        let y = max(bounds.minY, min(bounds.maxY - height, bounds.midY - height / 2))
        let x: CGFloat
        switch side {
        case .left: x = shown ? screen.frame.minX : screen.frame.minX - Self.width + 3
        case .right: x = shown ? screen.frame.maxX - Self.width : screen.frame.maxX - 3
        case .off: x = screen.frame.minX - Self.width
        }
        let rect = CGRect(x: x, y: y, width: Self.width, height: height)
        restingFrame = CGRect(x: side == .right ? screen.frame.maxX - Self.width : screen.frame.minX,
                              y: y, width: Self.width, height: height)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().setFrame(rect, display: true)
            }
        } else if rect != frameTarget {
            // The periodic forced layout must not snap a slide that is already heading here.
            setFrame(rect, display: true)
        }
        frameTarget = rect
    }

    func containsMouse(point: NSPoint) -> Bool {
        // Only around the tiles: the panel itself runs the full height of the screen.
        let strip = tilesView.frame.offsetBy(dx: frame.minX, dy: frame.minY)
        return CGRect(x: frame.minX, y: strip.minY - 40, width: frame.width, height: strip.height + 80)
            .contains(point)
    }

    /// Where the tile settles once the strip is out and the rows have finished moving.
    func screenRect(for id: CGWindowID) -> CGRect? {
        guard let target = rowTargets[id] else { return nil }
        let rectInWindow = tilesView.convert(target, to: nil)
        return rectInWindow.offsetBy(dx: restingFrame.minX, dy: restingFrame.minY)
    }

    /// The strip's perspective as it falls on a tile at `rect` (screen coordinates), expressed
    /// around the tile's own centre, so an image landing there looks exactly like the tile.
    func landingTransform(for rect: CGRect) -> CATransform3D {
        guard let layer = tilesView.layer else { return CATransform3DIdentity }
        let pivot = CGPoint(x: restingFrame.minX + tilesView.frame.minX + layer.anchorPoint.x * tilesView.frame.width,
                            y: restingFrame.minY + tilesView.frame.minY + layer.anchorPoint.y * tilesView.frame.height)
        let dx = pivot.x - rect.midX, dy = pivot.y - rect.midY
        return CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-dx, -dy, 0), layer.transform),
                                   CATransform3DMakeTranslation(dx, dy, 0))
    }

    /// The point on screen the strip turns about (and is seen from), and how far it is turned.
    func perspective() -> (pivot: CGPoint, angle: CGFloat) {
        let size = tilesView.frame.size
        let anchor = tilesView.layer?.anchorPoint ?? .zero
        let pivot = CGPoint(x: restingFrame.minX + tilesView.frame.minX + anchor.x * size.width
                                + (side == .left ? 0 : size.width),
                            y: restingFrame.minY + tilesView.frame.minY + anchor.y * size.height + size.height / 2)
        return (pivot, exposed ? 0 : Self.tilt(for: side))
    }

    /// Hides the tile and shows it again after `delay`, unless it has been hidden anew since:
    /// a timer left over from an earlier flight must not reveal it in the middle of a later one.
    func hideTile(_ id: CGWindowID, revealAfter delay: TimeInterval) {
        let token = (hideTokens[id] ?? 0) + 1
        hideTokens[id] = token
        setTileHidden(id, true)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.hideTokens[id] == token else { return }
            self.hideTokens.removeValue(forKey: id)
            self.setTileHidden(id, false)
        }
    }

    func setTileHidden(_ id: CGWindowID, _ hidden: Bool) {
        if hidden { hiddenTiles.insert(id) } else { hiddenTiles.remove(id) }
        rows[id]?.isHidden = hidden
    }

    private func layoutTilesView(animated: Bool = false) {
        let x: CGFloat = side == .left ? 22 : side == .right ? 14 : 25
        let target = CGRect(x: x, y: (panelHeight - stripHeight) / 2,
                            width: Self.stripWidth, height: stripHeight)
        guard tilesView.frame != target else { return }
        if animated {
            // Same timing as the rows, so the two motions add up to one smooth glide.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                tilesView.animator().frame = target
            }
        } else {
            tilesView.frame = target
        }
    }

    private func updateStripTransform(animated: Bool) {
        guard let layer = tilesView.layer else { return }
        var transform = CATransform3DIdentity
        if !exposed {
            // Turned about the strip's outer edge, with the horizon across its middle, as in the original.
            var turn = CATransform3DIdentity
            turn.m34 = -1 / 500
            turn = CATransform3DRotate(turn, Self.tilt(for: side), 0, 1, 0)
            let pivot = CGPoint(x: side == .left ? 0 : tilesView.frame.width, y: tilesView.frame.height / 2)
            transform = CATransform3DConcat(
                CATransform3DConcat(CATransform3DMakeTranslation(-pivot.x, -pivot.y, 0), turn),
                CATransform3DMakeTranslation(pivot.x, pivot.y, 0))
        }
        guard !transformApplied || !CATransform3DEqualToTransform(layer.transform, transform) else {
            return
        }
        if animated {
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = layer.presentation()?.transform ?? layer.transform
            animation.toValue = transform
            animation.duration = 0.25
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(animation, forKey: "stripTransform")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = transform
        CATransaction.commit()
        transformApplied = true
    }
}
