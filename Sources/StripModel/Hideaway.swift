import WindowCore

/// Where a display's windows go when they must be out of sight without leaving the screen.
///
/// macOS cannot hide a single window, so hidden ones keep a thin sliver on their own display.
/// Beside another display the usual spot would show them there, so each placement tries a
/// few spots in turn and takes the first one that touches no other display.
public struct Hideaway: Equatable, Sendable {
    /// The usable area of the display, where windows are placed.
    public var screen: Rect
    /// The full frames of every other display.
    public var others: [Rect]

    public init(screen: Rect, others: [Rect] = []) {
        self.screen = screen
        self.others = others
    }

    public func touchesOthers(_ r: Rect) -> Bool {
        others.contains { $0.overlap(r) != nil }
    }

    /// Frame for a window of a column that scrolled past the left or right edge, showing only `sliver` points.
    ///
    /// When a neighbour blocks that edge, the window hides past the opposite edge. macOS pulls a
    /// window hanging below a screen back up until its title bar shows, and never lets one sit
    /// above the menu bar, so those spots are the last resort.
    public func sliver(_ r: Rect, pastRight: Bool, sliver: Double) -> Rect {
        func at(_ x: Double, _ y: Double) -> Rect { Rect(x: x, y: y, width: r.width, height: r.height) }
        let inside = pastRight ? max(screen.x, screen.maxX - r.width) : screen.x
        let candidates = [
            at(pastRight ? screen.maxX - sliver : screen.x - r.width + sliver, r.y),
            at(pastRight ? screen.x - r.width + sliver : screen.maxX - sliver, r.y),
            at(inside, screen.maxY - sliver),
            at(inside, screen.y - r.height + sliver),
        ]
        return candidates.first { !touchesOthers($0) } ?? candidates[0]
    }

    /// Top-left corner for a parked window of `size`. A single display parks at the bottom-right
    /// corner; the other spots only matter when a neighbour covers it.
    public func parkOrigin(size: Size) -> Point {
        let s = screen
        let candidates = [
            Point(x: s.maxX - 1, y: s.maxY - 1),
            Point(x: s.x + 1 - size.width, y: s.maxY - 1),
            Point(x: s.maxX - 1, y: s.y),
            Point(x: s.x + 1 - size.width, y: s.y),
            Point(x: s.maxX - 1, y: s.y + 1 - size.height),
            Point(x: s.x + 1 - size.width, y: s.y + 1 - size.height),
        ]
        return candidates.first {
            !touchesOthers(Rect(x: $0.x, y: $0.y, width: size.width, height: size.height))
        } ?? candidates[0]
    }
}
