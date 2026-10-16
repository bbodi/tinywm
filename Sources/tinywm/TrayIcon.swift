import AppKit

/// The menu-bar icon: a screen frame over a strip of columns, with the focused column solid and
/// faded columns running past both edges, because the strip continues off screen.
///
/// It is a template image, so macOS tints it for light and dark menu bars and when highlighted.
enum TrayIcon {
    static let image: NSImage = {
        let size = NSSize(width: 22, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            let ink = NSColor.black

            // Columns past the screen edges: the part of the strip that is scrolled away.
            ink.withAlphaComponent(0.4).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0.5, y: 4, width: 2.2, height: 8), xRadius: 0.8, yRadius: 0.8).fill()
            NSBezierPath(roundedRect: NSRect(x: 19.3, y: 4, width: 2.2, height: 8), xRadius: 0.8, yRadius: 0.8).fill()

            // The screen.
            let frame = NSBezierPath(roundedRect: NSRect(x: 4.1, y: 1.1, width: 13.8, height: 13.8), xRadius: 2.6, yRadius: 2.6)
            frame.lineWidth = 1.3
            ink.setStroke()
            frame.stroke()

            // The focused column, solid, and its neighbour on screen, lighter.
            ink.setFill()
            NSBezierPath(roundedRect: NSRect(x: 6.0, y: 3.0, width: 5.0, height: 10.0), xRadius: 1.1, yRadius: 1.1).fill()
            ink.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: NSRect(x: 12.0, y: 3.0, width: 4.0, height: 10.0), xRadius: 1.1, yRadius: 1.1).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "tinywm"
        return image
    }()
}
