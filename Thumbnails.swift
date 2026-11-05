import AppKit
import ScreenCaptureKit

/// Keeps the last successful image for windows that later become minimized.
final class ThumbnailStore {
    private var images: [CGWindowID: NSImage] = [:]
    private var requests = Set<CGWindowID>()
    private var lastRequest: [CGWindowID: Date] = [:]
    private var withoutThumbnail = Set<CGWindowID>()
    var onChange: (() -> Void)?

    func image(for id: CGWindowID) -> NSImage? { images[id] }

    func refresh(items: [WindowItem]) {
        for item in items where !item.minimized && !requests.contains(item.id)
            && Date().timeIntervalSince(lastRequest[item.id] ?? .distantPast)
                >= (withoutThumbnail.contains(item.id) ? 30 : 2) {
            requests.insert(item.id)
            lastRequest[item.id] = Date()
            let id = item.id
            let ax = item.ax
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.requests.remove(id) }
                // While a window is restoring, CGWindowList already lists it, but this stays true.
                guard !Self.isMinimized(ax) else { return }
                do {
                    let available = try await SCShareableContent.excludingDesktopWindows(
                        false, onScreenWindowsOnly: true)
                    guard let window = available.windows.first(where: { $0.windowID == id }) else { return }
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    let configuration = SCStreamConfiguration()
                    // Full size: the same image fills the whole window while it flies to and from
                    // the strip, and a tile-sized one turns the text to mush there.
                    let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 1
                    configuration.width = max(1, Int((window.frame.width * scale).rounded()))
                    configuration.height = max(1, Int((window.frame.height * scale).rounded()))
                    configuration.showsCursor = false
                    configuration.ignoreShadowsSingleWindow = true
                    configuration.scalesToFit = true
                    configuration.preservesAspectRatio = true
                    configuration.captureResolution = .best
                    let cgImage = try await SCScreenshotManager.captureImage(
                        contentFilter: filter, configuration: configuration)
                    // The capture shows the window warped by the minimize animation, and the
                    // minimized flag turns true only when that ends. So wait, then ask again.
                    try await Task.sleep(nanoseconds: 700_000_000)
                    guard !Self.isMinimized(ax) else { return }
                    // A window that hides itself from capture comes back blank: drop any earlier
                    // image, so the panel shows the framed title instead of an empty tile.
                    guard Self.hasVisibleContent(cgImage) else {
                        self.withoutThumbnail.insert(id)
                        if self.images.removeValue(forKey: id) != nil { self.onChange?() }
                        return
                    }
                    self.withoutThumbnail.remove(id)
                    self.images[id] = NSImage(cgImage: cgImage,
                                              size: NSSize(width: cgImage.width, height: cgImage.height))
                    self.onChange?()
                } catch {
                    // Screen Recording may be denied. The panel displays the app icon and title.
                }
            }
        }
    }

    private static func isMinimized(_ window: AXUIElement?) -> Bool {
        guard let window else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success
        else { return false }
        return value as? Bool == true
    }

    private static func hasVisibleContent(_ image: CGImage) -> Bool {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                              | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard rendered else { return false }

        var maximum = [UInt8](repeating: 0, count: 3)
        var visiblePixels = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            guard pixels[offset + 3] > 8 else { continue }
            visiblePixels += 1
            for channel in 0..<3 {
                let value = pixels[offset + channel]
                maximum[channel] = max(maximum[channel], value)
            }
        }
        // A mostly transparent capture is blank too, even if a few pixels got through.
        guard visiblePixels * 2 >= side * side else { return false }
        // Only all-black counts as blank: an empty dark window is still a window to show.
        return !maximum.allSatisfy { $0 <= 12 }
    }
}
