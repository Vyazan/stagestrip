import AppKit
import CoreGraphics

enum StripSide: String {
    case left, right, off
}

enum DisplaySettings {
    static func key(for screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value)) else {
            return "display-\(screen.frame.minX)-\(screen.frame.minY)"
        }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }

    static func side(for screen: NSScreen) -> StripSide {
        StripSide(rawValue: UserDefaults.standard.string(forKey: "side.\(key(for: screen))") ?? "left") ?? .left
    }

    static func setSide(_ side: StripSide, for screen: NSScreen) {
        UserDefaults.standard.set(side.rawValue, forKey: "side.\(key(for: screen))")
    }
}
