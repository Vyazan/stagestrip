import AppKit
import QuartzCore

final class ZoomOverlay {
    private var activePanel: NSPanel?
    private var generation = 0

    func zoom(image: NSImage?, icon: NSImage?, title: String, from startRect: CGRect, to endRect: CGRect,
              tilt: CGFloat = 0, startTransform: CATransform3D? = nil, perspective: (() -> (pivot: CGPoint, angle: CGFloat)?)? = nil, shown: (() -> Void)? = nil, retarget: (() -> CGRect?)? = nil,
              completion: @escaping () -> Void) {
        generation += 1
        let currentGeneration = generation
        activePanel?.orderOut(nil)
        activePanel = nil

        // Animating a freshly created window's frame jumps straight to the end,
        // so the panel covers every screen and only its layer moves; that also lets
        // the target change after the panel is up.
        let area = NSScreen.screens.reduce(startRect.union(endRect)) { $0.union($1.frame) }
        let local = { (r: CGRect) in r.offsetBy(dx: -area.minX, dy: -area.minY) }
        let panel = NSPanel(contentRect: area,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        // Otherwise the system scales and blurs the overlay as it goes, a flash over the tile.
        panel.animationBehavior = .none
        panel.alphaValue = 1

        let imageLayer = CALayer()
        imageLayer.frame = CGRect(origin: .zero, size: startRect.size)
        // A window that can't be captured flies as the framed title its tile shows.
        let displayedImage = image ?? Self.titleImage(title, between: startRect.size, and: endRect.size)
        imageLayer.contents = displayedImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        imageLayer.contentsGravity = .resize
        if image == nil {
            imageLayer.backgroundColor = NSColor(white: 0.12, alpha: 0.85).cgColor
            imageLayer.borderColor = NSColor(white: 1, alpha: 0.45).cgColor
            imageLayer.borderWidth = 1
        }
        imageLayer.cornerRadius = 9
        imageLayer.masksToBounds = true

        let shadowLayer = CALayer()
        shadowLayer.frame = local(startRect)
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.25
        shadowLayer.shadowRadius = 12
        shadowLayer.shadowOffset = CGSize(width: 0, height: -4)
        shadowLayer.addSublayer(imageLayer)
        if let startTransform { shadowLayer.transform = startTransform }
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.addSublayer(shadowLayer)

        // Going into the strip, the app icon shows up under the middle of the window and slides
        // to its corner on the tile.
        let badgeSize: CGFloat = 34
        let badge: CALayer? = tilt == 0 ? nil : icon.map { icon in
            let layer = CALayer()
            layer.contents = icon.cgImage(forProposedRect: nil, context: nil, hints: nil)
            layer.contentsGravity = .resizeAspect
            layer.bounds = CGRect(x: 0, y: 0, width: badgeSize, height: badgeSize)
            layer.position = CGPoint(x: startRect.width / 2, y: 0)
            layer.opacity = 0
            shadowLayer.addSublayer(layer)
            return layer
        }
        // Same spot as the icon on a tile (StripItemView.iconLayer).
        let badgeCorner = { (size: CGSize) in
            CGPoint(x: tilt < 0 ? size.width - 24 + badgeSize / 2 : -10 + badgeSize / 2,
                    y: -10 + badgeSize / 2)
        }

        activePanel = panel
        panel.orderFrontRegardless()
        let finish = { [weak self, weak panel] in
            guard let self, let panel, self.generation == currentGeneration else { return }
            // The window comes up under the image only once the image has covered its place.
            completion()
            // Going into the strip the image (badge included) lies exactly over the tile, so it
            // goes as soon as the tile is drawn: a fade would show the two out of step, and
            // dropping the badge first would leave the tile's icon half covered by the image.
            // Coming out, the window needs a moment to come forward before the image fades.
            if tilt != 0 {
                DispatchQueue.main.async { [weak self, weak panel] in
                    guard let self, let panel, self.generation == currentGeneration else { return }
                    panel.orderOut(nil)
                    self.activePanel = nil
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak panel] in
                guard let self, let panel, self.generation == currentGeneration else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    panel.animator().alphaValue = 0
                } completionHandler: { [weak self, weak panel] in
                    guard let self, let panel, self.generation == currentGeneration else { return }
                    panel.orderOut(nil)
                    self.activePanel = nil
                }
            }
        }
        // Moves the image to `destination` over `duration`, starting from wherever it is now.
        let move = { (destination: CGRect, duration: CFTimeInterval, timing: CAMediaTimingFunction) in
            CATransaction.begin()
            // Setting the model values below must not add implicit animations: they would
            // replace the explicit ones under the same keys.
            CATransaction.setDisableActions(true)
            for (layer, rect) in [(shadowLayer, local(destination)),
                                  (imageLayer, CGRect(origin: .zero, size: destination.size))] {
                let current = layer.presentation() ?? layer
                let resize = CABasicAnimation(keyPath: "bounds")
                resize.fromValue = current.bounds
                resize.toValue = CGRect(origin: .zero, size: rect.size)
                let shift = CABasicAnimation(keyPath: "position")
                shift.fromValue = current.position
                shift.toValue = CGPoint(x: rect.midX, y: rect.midY)
                for anim in [resize, shift] {
                    anim.duration = duration
                    anim.timingFunction = timing
                }
                layer.add(resize, forKey: "bounds")
                layer.add(shift, forKey: "position")
                layer.bounds = CGRect(origin: .zero, size: rect.size)
                layer.position = CGPoint(x: rect.midX, y: rect.midY)
            }
            if let badge {
                let shift = CABasicAnimation(keyPath: "position")
                shift.fromValue = (badge.presentation() ?? badge).position
                shift.toValue = badgeCorner(destination.size)
                shift.duration = duration
                shift.timingFunction = timing
                badge.add(shift, forKey: "position")
                badge.position = badgeCorner(destination.size)
            }
            CATransaction.commit()
        }
        // With a tilt (going into the strip) the flight is slower, and the image swings into a
        // strong perspective early on, easing back to the tile's own tilt as it lands.
        let duration: CFTimeInterval = tilt == 0 ? 0.5 : 0.55
        let animate = {
            var destination = retarget?() ?? endRect
            move(destination, duration, CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1))
            if let startTransform {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                let flatten = CABasicAnimation(keyPath: "transform")
                flatten.fromValue = startTransform
                flatten.toValue = CATransform3DIdentity
                flatten.duration = duration * 0.6
                flatten.timingFunction = CAMediaTimingFunction(name: .easeOut)
                shadowLayer.add(flatten, forKey: "transform")
                shadowLayer.transform = CATransform3DIdentity
                CATransaction.commit()
            }
            let tilted = { (angle: CGFloat) -> CATransform3D in
                var transform = CATransform3DIdentity
                transform.m34 = -1 / 500
                return CATransform3DRotate(transform, angle, 0, 1, 0)
            }
            // Turned by `angle` about the point `offset` from the image's centre, seen from there too.
            let turned = { (angle: CGFloat, offset: CGPoint) -> CATransform3D in
                CATransform3DConcat(
                    CATransform3DConcat(CATransform3DMakeTranslation(-offset.x, -offset.y, 0), tilted(angle)),
                    CATransform3DMakeTranslation(offset.x, offset.y, 0))
            }
            // How far along its path the image is at `u` (the share of the flight gone), by the
            // same curve as `move` below: most of the way is covered early on.
            let progress = { (u: CGFloat) -> CGFloat in
                let bezier = { (t: CGFloat, p1: CGFloat, p2: CGFloat) in
                    3 * (1 - t) * (1 - t) * t * p1 + 3 * (1 - t) * t * t * p2 + t * t * t
                }
                var low: CGFloat = 0, high: CGFloat = 1
                for _ in 0..<30 {
                    let mid = (low + high) / 2
                    if bezier(mid, 0.2, 0.2) < u { low = mid } else { high = mid }
                }
                return bezier((low + high) / 2, 0.8, 1)
            }
            // Turns along with the flight and swings past the tile's tilt halfway; the swing is
            // gone by the time the image is in place, so it never keeps turning once it has stopped.
            let angle = { (u: CGFloat, final: CGFloat) -> CGFloat in
                let p = progress(u)
                return final * p + tilt * 1.3 * 16 * p * p * (1 - p) * (1 - p)
            }
            // The image turns about its own centre at first and about the strip's pivot by the end.
            var offset: (CGFloat) -> CGPoint = { _ in .zero }
            // Core Animation blends two transforms by pulling them apart into rotation, perspective
            // and so on, which warps the strip's off-centre perspective on the way and lets it snap
            // into place only at the end; sampled densely, every step is too short for that to show.
            let turn = { (u0: CGFloat) -> CATransform3D in
                let target = perspective?()
                let final = target?.angle ?? tilt
                let reach = target.map { CGPoint(x: $0.pivot.x - destination.midX, y: $0.pivot.y - destination.midY) }
                    ?? .zero
                let from = offset(u0)
                let path = { (u: CGFloat) -> CGPoint in
                    let k = (progress(u) - progress(u0)) / max(1 - progress(u0), 0.001)
                    return CGPoint(x: from.x + (reach.x - from.x) * k, y: from.y + (reach.y - from.y) * k)
                }
                offset = path
                let steps = 40
                let animation = CAKeyframeAnimation(keyPath: "transform")
                animation.values = (0...steps).map { step -> CATransform3D in
                    let u = u0 + (1 - u0) * CGFloat(step) / CGFloat(steps)
                    return turned(angle(u, final), path(u))
                }
                animation.duration = duration * CFTimeInterval(1 - u0)
                shadowLayer.add(animation, forKey: "transform")
                let landed = turned(final, reach)
                shadowLayer.transform = landed
                return landed
            }
            var landed = CATransform3DIdentity
            if tilt != 0 {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                landed = turn(0)
                if let badge {
                    let appear = CABasicAnimation(keyPath: "opacity")
                    appear.fromValue = 0
                    appear.toValue = 1
                    appear.duration = duration * 0.4
                    badge.add(appear, forKey: "opacity")
                    badge.opacity = 1
                }
                CATransaction.commit()
            }
            // The strip may still be rebuilding as focus moves on; steer to where the tile ends up.
            if let retarget {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard self.generation == currentGeneration, let corrected = retarget() else { return }
                    let target = perspective?()
                    let correctedLanding = turned(target?.angle ?? tilt, target.map {
                        CGPoint(x: $0.pivot.x - corrected.midX, y: $0.pivot.y - corrected.midY) } ?? .zero)
                    guard corrected != destination
                        || (tilt != 0 && !CATransform3DEqualToTransform(correctedLanding, landed)) else { return }
                    destination = corrected
                    let remaining = duration - 0.15
                    move(destination, remaining, CAMediaTimingFunction(name: .easeOut))
                    // The tile's perspective depends on where it sits, so the landing tilt moves with it.
                    if tilt != 0 {
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        landed = turn(CGFloat(0.15 / duration))
                        CATransaction.commit()
                    }
                }
            }
            // The curve has covered about 95% of the way by half time. A title card has no content
            // to show, so the window takes over there rather than leaving the user waiting for it.
            let handover = image == nil && tilt == 0 ? duration / 2 : duration
            DispatchQueue.main.asyncAfter(deadline: .now() + handover, execute: finish)
        }
        guard let shown else { animate(); return }
        // The image must be on screen before the window leaves, and the window gone before the image moves.
        CATransaction.flush()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            shown()
            animate()
        }
    }

    /// The tile's title at window size, so the text lands exactly as the tile draws it (StripItemView).
    private static func titleImage(_ title: String, between a: CGSize, and b: CGSize) -> NSImage {
        let large = a.width >= b.width ? a : b
        let zoom = large.width / max(min(a.width, b.width), 1)
        return NSImage(size: large, flipped: false) { bounds in
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11 * zoom, weight: .medium),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph
            ]
            let width = max(0, bounds.width - 32 * zoom)
            let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine]
            let text = title as NSString
            let height = min(36 * zoom, ceil(text.boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: options, attributes: attributes).height))
            text.draw(with: CGRect(x: 16 * zoom, y: (bounds.height - height) / 2, width: width, height: height),
                      options: options, attributes: attributes)
            return true
        }
    }
}
