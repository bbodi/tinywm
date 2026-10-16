import WindowCore

/// The display that owns a window: the one holding the centre of its frame, else the nearest.
public func owningDisplay(of frame: Rect, among displays: [Rect]) -> Int? {
    let c = frame.center
    if let i = displays.firstIndex(where: { $0.contains(c) }) { return i }
    return nearestDisplay(to: c, among: displays)
}

public func nearestDisplay(to p: Point, among displays: [Rect]) -> Int? {
    func distance(_ r: Rect) -> Double {
        let dx = max(r.x - p.x, 0, p.x - r.maxX), dy = max(r.y - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }
    if let i = displays.firstIndex(where: { $0.contains(p) }) { return i }
    return displays.indices.min { distance(displays[$0]) < distance(displays[$1]) }
}

/// Display indices left to right, ties top to bottom: the order "next display" walks.
public func displayOrder(_ displays: [Rect]) -> [Int] {
    displays.indices.sorted {
        let a = displays[$0], b = displays[$1]
        return a.x != b.x ? a.x < b.x : a.y < b.y
    }
}

/// The display `delta` steps along `displayOrder` from `index`, wrapping around.
public func adjacentDisplay(from index: Int, by delta: Int, among displays: [Rect]) -> Int? {
    let order = displayOrder(displays)
    guard let at = order.firstIndex(of: index) else { return nil }
    let n = order.count
    return order[((at + delta) % n + n) % n]
}

/// The display next to `index` in `direction`, by where the displays sit (Accessibility
/// coordinates, y down). Only displays lying mainly that way count. The one sharing the most
/// edge with the current display wins, then the nearest.
public func displayToward(_ direction: Direction, from index: Int, among displays: [Rect]) -> Int? {
    guard displays.indices.contains(index) else { return nil }
    let from = displays[index]
    let c = from.center
    var best: (index: Int, overlap: Double, distance: Double)?
    for (i, r) in displays.enumerated() where i != index {
        let dx = r.center.x - c.x, dy = r.center.y - c.y
        let lies: Bool
        switch direction {
        case .left: lies = dx < 0 && abs(dx) >= abs(dy)
        case .right: lies = dx > 0 && abs(dx) >= abs(dy)
        case .up: lies = dy < 0 && abs(dy) > abs(dx)
        case .down: lies = dy > 0 && abs(dy) > abs(dx)
        }
        guard lies else { continue }
        let overlap = direction == .left || direction == .right
            ? max(0, min(from.maxY, r.maxY) - max(from.y, r.y))
            : max(0, min(from.maxX, r.maxX) - max(from.x, r.x))
        let distance = (dx * dx + dy * dy).squareRoot()
        if let b = best, (overlap, -distance) <= (b.overlap, -b.distance) { continue }
        best = (i, overlap, distance)
    }
    return best?.index
}
