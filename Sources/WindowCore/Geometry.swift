public struct Point: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct Size: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

/// A rectangle in a top-left-origin coordinate space, which matches the Accessibility API.
public struct Rect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var center: Point { Point(x: x + width / 2, y: y + height / 2) }

    public func contains(_ p: Point) -> Bool {
        p.x >= x && p.x < maxX && p.y >= y && p.y < maxY
    }

    public func insetBy(_ d: Double) -> Rect {
        Rect(x: x + d, y: y + d, width: max(0, width - 2 * d), height: max(0, height - 2 * d))
    }

    public func isApproximately(_ o: Rect, tolerance: Double = 0.5) -> Bool {
        abs(x - o.x) <= tolerance && abs(y - o.y) <= tolerance
            && abs(width - o.width) <= tolerance && abs(height - o.height) <= tolerance
    }
}

extension Rect {
    /// Whether the rect covers `display` as a fullscreen window does: its whole width, down to its
    /// bottom, starting at most `top` below its top edge. macOS puts fullscreen windows below a notch.
    public func coversAsFullScreen(_ display: Rect, top: Double = 50) -> Bool {
        abs(x - display.x) <= 1 && abs(width - display.width) <= 1 && abs(maxY - display.maxY) <= 1
            && y >= display.y - 1 && y <= display.y + top
    }

    /// The overlap with `other`, or nil when they share no area.
    public func overlap(_ other: Rect) -> Rect? {
        let x0 = max(x, other.x), x1 = min(maxX, other.maxX)
        let y0 = max(y, other.y), y1 = min(maxY, other.maxY)
        guard x1 > x0, y1 > y0 else { return nil }
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
