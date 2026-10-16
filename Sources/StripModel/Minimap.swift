import WindowCore

/// One workspace's row in the minimap, in strip coordinates (unscrolled points).
public struct MinimapRow: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        public var id: String
        public var rect: Rect
        public var focused: Bool
    }

    public var workspace: Int
    public var isActive: Bool
    public var windows: [Window]
    /// The part of the strip the screen shows. Only the active row has one.
    public var viewport: Rect?
    /// Full width of this row's strip.
    public var width: Double
}

/// Rows for every workspace that holds windows, plus the active one even when empty.
public func minimapRows(_ ws: Workspaces, _ m: StripMetrics) -> [MinimapRow] {
    var rows: [MinimapRow] = []
    let h = m.viewport.height
    for (i, strip) in ws.strips.enumerated() where !strip.columns.isEmpty || i == ws.active {
        let (lefts, total) = m.columnOffsets(strip)
        var windows: [MinimapRow.Window] = []
        for (c, column) in strip.columns.enumerated() {
            let w = m.width(of: column)
            let n = Double(column.windows.count)
            let wh = max(1, (h - m.gap * (n + 1)) / n)
            for (j, id) in column.windows.enumerated() {
                let focused = i == ws.active && strip.focusedColumn == c && column.focused == j
                windows.append(.init(id: id, rect: Rect(x: lefts[c], y: m.gap + Double(j) * (wh + m.gap), width: w, height: wh),
                                     focused: focused))
            }
        }
        let active = i == ws.active
        rows.append(MinimapRow(
            workspace: i, isActive: active, windows: windows,
            viewport: active ? Rect(x: strip.scroll, y: 0, width: m.viewport.width, height: h) : nil,
            width: max(total, active ? strip.scroll + m.viewport.width : 0)))
    }
    return rows
}
