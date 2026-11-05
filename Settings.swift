import AppKit
import CoreGraphics

enum StripSide: String {
    case left, right, off
}

enum CaptionPlace: Int, CaseIterable {
    case aboveTile, besideIcon, belowTile

    var title: String {
        switch self {
        case .aboveTile: return "Над плиткой"
        case .besideIcon: return "Рядом со значком"
        case .belowTile: return "Под плиткой"
        }
    }
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

    static let tileCountChoices = Array(1...10)
    static let transparencyChoices = [0, 10, 20, 30, 40, 50, 60, 70, 80]

    static var maxTiles: Int {
        get {
            let saved = UserDefaults.standard.object(forKey: "maxTiles") as? Int ?? 5
            return min(max(saved, tileCountChoices[0]), tileCountChoices[tileCountChoices.count - 1])
        }
        set { UserDefaults.standard.set(newValue, forKey: "maxTiles") }
    }

    /// Where the title goes on the tiles of an app with several windows open.
    static var captionPlace: CaptionPlace {
        get { CaptionPlace(rawValue: UserDefaults.standard.integer(forKey: "captionPlace")) ?? .aboveTile }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "captionPlace") }
    }

    /// Percent; 0 means fully opaque tiles.
    static var transparency: Int {
        get {
            let saved = UserDefaults.standard.object(forKey: "transparency") as? Int ?? 0
            return min(max(saved, transparencyChoices[0]), transparencyChoices[transparencyChoices.count - 1])
        }
        set { UserDefaults.standard.set(newValue, forKey: "transparency") }
    }
}
