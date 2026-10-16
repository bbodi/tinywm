import AppKit
import StripEngine
import WindowCore

/// Display facts in the coordinates the strips use: Accessibility, origin top-left of the primary display.
enum Screens {
    static func axRect(_ f: CGRect) -> Rect {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? f.maxY
        return Rect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
    }

    /// The other way: an Accessibility rect as an AppKit frame, origin bottom-left of the primary display.
    static func appKitRect(_ r: Rect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: r.x, y: primaryHeight - r.y - r.height, width: r.width, height: r.height)
    }

    /// Primary display first.
    static func infos() -> [TiledDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let id = uuid(of: screen) else { return nil }
            return TiledDisplay(id: id, frame: axRect(screen.frame), visible: axRect(screen.visibleFrame), name: screen.localizedName)
        }
    }

    static func uuid(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let cf = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, cf) else { return nil }
        return string as String
    }

    static func screen(id: String) -> NSScreen? {
        NSScreen.screens.first { uuid(of: $0) == id }
    }

    static func pointer() -> Point {
        let p = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return Point(x: p.x, y: primaryHeight - p.y)
    }
}

extension NSRect {
    /// The same rect, with no change of origin.
    init(_ r: Rect) { self.init(x: r.x, y: r.y, width: r.width, height: r.height) }
}
