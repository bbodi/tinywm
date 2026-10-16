import WindowCore

/// Where a window dragged with the mouse would land on a strip.
///
/// Indices refer to the strip as it is during the drag, with the dragged window still in it.
public enum DropTarget: Equatable, Sendable {
    /// A new column before the column now at this index. The column count means after the last.
    case newColumn(Int)
    /// Into the stack of a column, at `row` among its windows other than the dragged one.
    case stack(column: Int, row: Int)
}

/// A drop target with the screen areas that belong to it.
public struct DropHint: Equatable, Sendable {
    public var target: DropTarget
    /// The pointer positions that give this target, in screen coordinates.
    public var zone: Rect

    public init(target: DropTarget, zone: Rect) {
        self.target = target; self.zone = zone
    }
}

public struct DropStyle: Equatable, Sendable {
    /// Share of a column's width, at each side, that inserts a new column rather than stacking.
    public var edgeShare = 0.25
    /// The side zones never grow wider than this, so wide columns are easy to stack into.
    public var maxEdge = 160.0
    /// How far above or below the usable area the pointer still finds a target, for the menu
    /// bar and the Dock.
    public var reach = 80.0
    /// How far the pointer must leave a target's zone before another target replaces it.
    public var hysteresis = 16.0
    /// Stacking into a column waits until the pointer rests this long over it, so a window
    /// carried across columns does not stack by accident.
    public var holdDelay = 0.2
    /// The pointer counts as resting while it stays within this distance.
    public var holdSlop = 6.0
    /// The pointer must move this far before a press becomes a drag.
    public var threshold = 5.0
    /// Dropping onto another window to stack under it is off for now. It will come back niri's
    /// way: a window can be dropped under another window, but never into an empty column at
    /// half height.
    public var stacking = false
    /// How close to a display's left or right edge the pointer scrolls the strip while dragging.
    public var scrollBand = 40.0
    /// The scroll speed right at the edge, in points per second. It grows from zero across the band.
    public var scrollSpeed = 1200.0

    public init() {}
}

/// The target under `p` when a window is dragged over `strip`, or nil when `p` is off this
/// strip's display.
///
/// Near a column's sides, and in the gaps, the window becomes a new column there. With
/// `style.stacking` on, the middle of a column joins the stack, above or below the window under
/// the pointer by which half of it the pointer is in. With it off, each half of a column
/// inserts on its side. The column that holds only the dragged window counts as a gap, so
/// dropping there puts the window back.
public func dropHint(
    at p: Point, in strip: Strip, _ m: StripMetrics, dragging: String?, style: DropStyle = DropStyle()
) -> DropHint? {
    let v = m.viewport
    let top = v.y - style.reach, bottom = v.maxY + style.reach
    guard p.x >= v.x, p.x < v.maxX, p.y >= top, p.y < bottom else { return nil }
    let frames = stripFrames(strip, m, clamp: false)
    /// The area between `x0` and `x1` at the full height the pointer may use, kept on screen.
    func band(_ x0: Double, _ x1: Double, _ y0: Double = -.infinity, _ y1: Double = .infinity) -> Rect {
        let l = max(v.x, x0), r = min(v.maxX, x1)
        let t = max(top, y0), b = min(bottom, y1)
        return Rect(x: l, y: t, width: max(0, r - l), height: max(0, b - t))
    }

    struct Span { var left: Double; var right: Double; var rows: [Rect]; var onlyDragged: Bool }
    let spans: [Span] = strip.columns.map { c in
        let all = c.windows.compactMap { frames[$0] }
        let left = all.first?.x ?? 0, right = all.first?.maxX ?? 0
        let rows = c.windows.filter { $0 != dragging }.compactMap { frames[$0] }
        return Span(left: left, right: right, rows: rows, onlyDragged: rows.isEmpty)
    }
    guard !spans.isEmpty else {
        return DropHint(target: .newColumn(0), zone: band(v.x, v.maxX))
    }

    // Boundary b sits in the gap before column b; the last one sits after the last column.
    func boundary(_ b: Int) -> Double {
        if b == 0 { return spans[0].left - m.gap / 2 }
        if b == spans.count { return spans[b - 1].right + m.gap / 2 }
        return (spans[b - 1].right + spans[b].left) / 2
    }
    func edge(_ s: Span) -> Double { min((s.right - s.left) * style.edgeShare, style.maxEdge) }

    for (i, s) in spans.enumerated() {
        let x0 = i == 0 ? -Double.infinity : boundary(i)
        let x1 = i == spans.count - 1 ? Double.infinity : boundary(i + 1)
        guard p.x >= x0, p.x < x1 else { continue }
        if s.onlyDragged {
            return DropHint(target: .newColumn(i), zone: band(x0, x1))
        }
        let e = style.stacking ? edge(s) : (s.right - s.left) / 2
        if p.x < s.left + e {
            return DropHint(target: .newColumn(i), zone: band(x0, s.left + e))
        }
        if p.x >= s.right - e {
            return DropHint(target: .newColumn(i + 1), zone: band(s.right - e, x1))
        }
        // Over the middle: before the first window whose centre lies below the pointer.
        let row = s.rows.filter { $0.center.y <= p.y }.count
        let y0 = row == 0 ? -Double.infinity : s.rows[row - 1].center.y
        let y1 = row == s.rows.count ? Double.infinity : s.rows[row].center.y
        return DropHint(target: .stack(column: i, row: row), zone: band(s.left + e, s.right - e, y0, y1))
    }
    return nil
}

/// Keeps the current hint while the pointer stays within `margin` of its zone, so the target
/// does not flicker when the pointer rests on a boundary.
public func stickyHint(_ current: DropHint?, _ candidate: DropHint?, at p: Point, margin: Double) -> DropHint? {
    guard let current, candidate != current else { return candidate }
    let z = current.zone
    let grown = Rect(x: z.x - margin, y: z.y - margin, width: z.width + 2 * margin, height: z.height + 2 * margin)
    return grown.contains(p) ? current : candidate
}

/// The rect of a dragged window's picture: the window at its own size, placed so the point
/// that was grabbed stays under the pointer.
public func dragPictureRect(frame: Rect, grabbed: Point, pointer: Point) -> Rect {
    Rect(x: frame.x + pointer.x - grabbed.x, y: frame.y + pointer.y - grabbed.y, width: frame.width, height: frame.height)
}

/// The strip as it would be after a drop, which the drag shows before the release.
///
/// With a target, `window` is placed there. The view keeps its scroll, kept inside the strip,
/// since the target lies under the pointer. Without one, a strip the window is `leaving` for another display closes its gap, and any
/// other strip stays as it is. The same layout is written on release, so the landing matches
/// what the drag showed.
public func dropLayout(
    _ strip: Strip, moving window: String, to target: DropTarget?, leaving: Bool,
    width: Double, columnID: String, _ m: StripMetrics
) -> Strip {
    var s = strip
    if leaving { s.remove(window) }
    if let target { s.place(window, at: target, width: width, columnID: columnID) }
    let reach = max(0, m.columnOffsets(s).total - m.viewport.width)
    s.scroll = max(0, min(reach, s.scroll))
    return s
}

/// Converts a target found on a drag's `preview` layout into the indices of `base`, the strip
/// the drop is applied to. The column holding only the dragged window is skipped, so a target
/// next to the slot means the same place in both.
public func baseTarget(_ t: DropTarget, from preview: Strip, to base: Strip, dragging: String) -> DropTarget {
    let ids = preview.columns.filter { $0.windows != [dragging] }.map(\.id)
    func index(beforePreviewColumn k: Int) -> Int {
        // The first column at or after k in the preview, other than the slot, anchors the target.
        let rest = preview.columns.dropFirst(max(0, k)).filter { $0.windows != [dragging] }
        guard let anchor = rest.first?.id, let i = base.columns.firstIndex(where: { $0.id == anchor }) else {
            return base.columns.count
        }
        return i
    }
    switch t {
    case .newColumn(let k):
        return .newColumn(index(beforePreviewColumn: k))
    case .stack(let k, let row):
        guard preview.columns.indices.contains(k), ids.contains(preview.columns[k].id) else { return .newColumn(index(beforePreviewColumn: k)) }
        return .stack(column: index(beforePreviewColumn: k), row: row)
    }
}

/// How fast a drag scrolls the strip with the pointer at `p`, in points per second: negative
/// toward the left edge, positive toward the right, growing from zero at the band's inner edge
/// to the full speed at the screen edge. Zero when `p` is off this display.
public func edgeScrollSpeed(at p: Point, viewport v: Rect, style: DropStyle = DropStyle()) -> Double {
    guard p.x >= v.x, p.x < v.maxX, style.scrollBand > 0 else { return 0 }
    let left = p.x - v.x, right = v.maxX - p.x
    if left < style.scrollBand { return -style.scrollSpeed * (1 - left / style.scrollBand) }
    if right < style.scrollBand { return style.scrollSpeed * (1 - right / style.scrollBand) }
    return 0
}

extension Strip {
    /// Moves `window` to `target` and focuses it. `target` uses the indices from before the
    /// move. A window that had a column to itself takes that column along, with its width.
    /// A window from elsewhere gets a new column of `width` with `columnID`.
    public mutating func place(_ window: String, at target: DropTarget, width: Double, columnID: String) {
        let ids = columns.map(\.id)
        var moving = Column(id: columnID, windows: [window], width: width)
        if let c = column(of: window) {
            if columns[c].windows.count == 1 {
                moving = columns[c]
                moving.focused = 0
            } else {
                moving.width = columns[c].width
            }
            remove(window)
        }
        floating.removeAll { $0 == window }

        // A stack target whose column went away falls back to a column where the window was.
        var newColumnAt: Int?
        switch target {
        case .newColumn(let i):
            newColumnAt = i
        case .stack(let c, let row):
            if ids.indices.contains(c), let t = columns.firstIndex(where: { $0.id == ids[c] }) {
                let r = max(0, min(row, columns[t].windows.count))
                columns[t].windows.insert(window, at: r)
                columns[t].focused = r
                focusedColumn = t
            } else {
                newColumnAt = c
            }
        }
        guard let i = newColumnAt else { return }
        // The column that was at index i, or the first one after it that is still there.
        let anchor = ids.dropFirst(max(0, min(i, ids.count))).first { id in columns.contains { $0.id == id } }
        let index = anchor.flatMap { a in columns.firstIndex { $0.id == a } } ?? columns.count
        columns.insert(moving, at: index)
        focusedColumn = index
    }
}

/// A drop target on a particular display.
public struct DropChoice: Equatable, Sendable {
    public var display: String
    public var hint: DropHint

    public init(display: String, hint: DropHint) { self.display = display; self.hint = hint }
}

/// Picks the target a drag shows as the pointer moves.
///
/// Gaps and side targets follow the pointer, with hysteresis at their edges. A stack target
/// takes over only after the pointer rested on it for `holdDelay`. While a stack target waits,
/// the previous target stays only as long as the pointer is near its zone.
public struct DropTracker: Sendable {
    public var style: DropStyle
    public private(set) var current: DropChoice?
    private var waiting: (choice: DropChoice, at: Point, since: Double)?

    public init(style: DropStyle = DropStyle()) { self.style = style }

    /// Drops the current target, for when the view moved under the pointer and its zone no
    /// longer lies where it did.
    public mutating func forget() {
        current = nil
        waiting = nil
    }

    /// Feeds the target under the pointer at `p` at time `now`. Returns true when a stack
    /// target starts waiting; the caller then feeds again after `style.holdDelay`.
    public mutating func update(_ candidate: DropChoice?, at p: Point, now: Double) -> Bool {
        if let c = candidate, case .stack = c.hint.target, c != current {
            if let w = waiting, w.choice == c, distance(w.at, p) <= style.holdSlop {
                if now - w.since >= style.holdDelay - 1e-9 {
                    current = c
                    waiting = nil
                }
                return false
            }
            waiting = (c, p, now)
            if let kept = current, stickyHint(kept.hint, nil, at: p, margin: style.hysteresis) == nil { current = nil }
            return true
        }
        waiting = nil
        let hint = stickyHint(current?.hint, candidate?.hint, at: p, margin: style.hysteresis)
        if hint != current?.hint { current = candidate }
        return false
    }

    private func distance(_ a: Point, _ b: Point) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }
}
