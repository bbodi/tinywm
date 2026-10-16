import WindowCore

/// One vertical slot on the strip. It holds one window, or several stacked top to bottom.
public struct Column: Codable, Equatable, Sendable {
    public var id: String
    public var windows: [String]
    /// Index into `windows` of the window that last had focus in this column.
    public var focused: Int
    /// Share of the usable width, so 0.5 means two such columns fill the screen.
    public var width: Double
    /// The width to return to when full width is toggled off.
    public var widthBeforeFull: Double?

    public init(id: String, windows: [String], width: Double, focused: Int = 0) {
        self.id = id; self.windows = windows; self.width = width; self.focused = focused
    }

    public var focusedWindow: String? { windows.indices.contains(focused) ? windows[focused] : windows.first }
}

/// The whole layout for one display: columns side by side on a strip wider than the screen.
public struct Strip: Codable, Equatable, Sendable {
    public var columns: [Column] = []
    /// Index of the focused column, or nil when the strip is empty.
    public var focusedColumn: Int?
    /// Distance in points from the strip's left edge to the screen's left edge.
    public var scroll: Double = 0
    /// Windows the user took off the strip. They keep their own frames.
    public var floating: [String] = []
    /// The view from before a column grew, so shrinking it back returns to that same view.
    public var viewBeforeGrow: ViewMemory?

    public init() {}

    public var focusedWindow: String? { focusedColumn.flatMap { columns[$0].focusedWindow } }
    public var allWindows: [String] { columns.flatMap(\.windows) }

    public func column(of window: String) -> Int? { columns.firstIndex { $0.windows.contains(window) } }
}

/// Where the strip was scrolled before a column grew past the screen edge.
public struct ViewMemory: Codable, Equatable, Sendable {
    public var column: String
    public var scroll: Double
    /// The column's width at that time; shrinking to this width or less restores the view.
    public var width: Double

    public init(column: String, scroll: Double, width: Double) {
        self.column = column; self.scroll = scroll; self.width = width
    }
}

/// How the strip turns column widths into points.
public struct StripMetrics: Equatable, Sendable {
    public var viewport: Rect
    public var gap: Double
    /// The narrowest width in points each window's app accepts, by window ID.
    public var minimums: [String: Double]

    public init(viewport: Rect, gap: Double, minimums: [String: Double] = [:]) {
        self.viewport = viewport; self.gap = gap; self.minimums = minimums
    }

    /// Width in points of a column with share `fraction`. Two 0.5 columns plus three gaps fill the screen.
    public func columnWidth(_ fraction: Double) -> Double {
        max(1, fraction * (viewport.width - gap) - gap)
    }

    /// Width in points of `column`: its share, widened to the minimum of its widest-minded window,
    /// but never past the screen.
    public func width(of column: Column) -> Double {
        let share = columnWidth(column.width)
        guard let minimum = column.windows.compactMap({ minimums[$0] }).max() else { return share }
        return max(share, min(minimum, viewport.width - 2 * gap))
    }

    /// Left edge of each column in strip coordinates, plus the strip's total width.
    public func columnOffsets(_ strip: Strip) -> (lefts: [Double], total: Double) {
        var lefts: [Double] = []
        var x = gap
        for c in strip.columns {
            lefts.append(x)
            x += width(of: c) + gap
        }
        return (lefts, x)
    }
}
