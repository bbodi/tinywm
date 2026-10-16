import WindowCore

/// Edits on a strip. Each changes the strip in place and touches no real window; the engine
/// scrolls and moves windows after.

public enum Direction: Sendable { case left, right, up, down }

extension Strip {
    /// Adds a window as a new column right of the focused one, or at the end of an empty strip.
    public mutating func insert(_ window: String, width: Double, columnID: String, focus: Bool) {
        guard column(of: window) == nil, !floating.contains(window) else { return refused(window, "insert") }
        let index = focusedColumn.map { $0 + 1 } ?? columns.count
        columns.insert(Column(id: columnID, windows: [window], width: width), at: index)
        if focus || focusedColumn == nil {
            focusedColumn = index
        } else if let f = focusedColumn, f >= index {
            focusedColumn = f + 1
        }
    }

    /// Adds a window as a new column at `index`, clamped to the strip. Focus stays where it is.
    public mutating func insert(_ window: String, width: Double, columnID: String, at index: Int) {
        guard column(of: window) == nil, !floating.contains(window) else { return refused(window, "insert at \(index)") }
        let at = max(0, min(index, columns.count))
        columns.insert(Column(id: columnID, windows: [window], width: width), at: at)
        if let f = focusedColumn { if f >= at { focusedColumn = f + 1 } } else { focusedColumn = at }
    }

    /// Adds a window that keeps its own frame instead of taking a column.
    public mutating func addFloating(_ window: String) {
        guard column(of: window) == nil, !floating.contains(window) else { return refused(window, "addFloating") }
        floating.append(window)
    }

    /// A window already on this strip cannot be added again; the log shows where it already is.
    private func refused(_ window: String, _ what: String) {
        Log.note("anomaly", "\(what) refused for \(Log.name(window)): already \(floating.contains(window) ? "floating" : "tiled") on this strip")
    }

    /// Takes a tiled window off the strip; it keeps its own frame from then on.
    public mutating func floatOut(_ window: String) {
        guard column(of: window) != nil else { return }
        remove(window)
        floating.append(window)
    }

    /// Removes a window. An emptied column disappears and focus moves to its left neighbour.
    public mutating func remove(_ window: String) {
        floating.removeAll { $0 == window }
        guard let c = column(of: window), let r = columns[c].windows.firstIndex(of: window) else { return }
        columns[c].windows.remove(at: r)
        if r < columns[c].focused { columns[c].focused -= 1 }
        if columns[c].windows.isEmpty {
            columns.remove(at: c)
            if let f = focusedColumn {
                if columns.isEmpty { focusedColumn = nil }
                else if f > c || f == columns.count { focusedColumn = f - 1 }
                else if f == c { focusedColumn = max(0, c - 1) }
            }
        } else {
            columns[c].focused = min(columns[c].focused, columns[c].windows.count - 1)
        }
    }

    /// Marks `window` as focused, for focus changes that come from the user clicking a window.
    public mutating func focus(window: String) {
        guard let c = column(of: window), let r = columns[c].windows.firstIndex(of: window) else { return }
        focusedColumn = c
        columns[c].focused = r
    }

    /// Moves focus one column sideways or one window within the stack.
    public mutating func focus(_ d: Direction) {
        guard let f = focusedColumn else { return }
        switch d {
        case .left: focusedColumn = max(0, f - 1)
        case .right: focusedColumn = min(columns.count - 1, f + 1)
        case .up: columns[f].focused = max(0, columns[f].focused - 1)
        case .down: columns[f].focused = min(columns[f].windows.count - 1, columns[f].focused + 1)
        }
    }

    public mutating func focusColumn(_ index: Int) {
        guard columns.indices.contains(index) else { return }
        focusedColumn = index
    }

    /// Swaps the focused column with its neighbour, or the focused window within its stack.
    public mutating func move(_ d: Direction) {
        guard let f = focusedColumn else { return }
        switch d {
        case .left where f > 0:
            columns.swapAt(f, f - 1); focusedColumn = f - 1
        case .right where f < columns.count - 1:
            columns.swapAt(f, f + 1); focusedColumn = f + 1
        case .up where columns[f].focused > 0:
            let r = columns[f].focused
            columns[f].windows.swapAt(r, r - 1); columns[f].focused = r - 1
        case .down where columns[f].focused < columns[f].windows.count - 1:
            let r = columns[f].focused
            columns[f].windows.swapAt(r, r + 1); columns[f].focused = r + 1
        default: break
        }
    }

    /// Moves the focused window into the bottom of the neighbouring column's stack.
    public mutating func stack(_ d: Direction) {
        guard let f = focusedColumn, let window = columns[f].focusedWindow else { return }
        let target = d == .left ? f - 1 : f + 1
        guard columns.indices.contains(target) else { return }
        let targetID = columns[target].id
        // Take it out of the source first; afterwards the window would be found in the target.
        remove(window)
        guard let t = columns.firstIndex(where: { $0.id == targetID }) else { return }
        columns[t].windows.append(window)
        columns[t].focused = columns[t].windows.count - 1
        focusedColumn = t
    }

    /// Takes the focused window out of its stack into its own column on the right.
    public mutating func popOut(columnID: String) {
        guard let f = focusedColumn, columns[f].windows.count > 1, let window = columns[f].focusedWindow else { return }
        let width = columns[f].width
        columns[f].windows.remove(at: columns[f].focused)
        columns[f].focused = min(columns[f].focused, columns[f].windows.count - 1)
        columns.insert(Column(id: columnID, windows: [window], width: width), at: f + 1)
        focusedColumn = f + 1
    }

    /// Steps the focused column through `presets`, starting from the first preset wider than now.
    public mutating func cycleWidth(_ presets: [Double]) {
        guard let f = focusedColumn, !presets.isEmpty else { return }
        let current = columns[f].width
        let next = presets.first { $0 > current + 0.01 } ?? presets[0]
        columns[f].width = next
        columns[f].widthBeforeFull = nil
    }

    /// Full width on, or back to the width it had before.
    public mutating func toggleFullWidth() {
        guard let f = focusedColumn else { return }
        if let before = columns[f].widthBeforeFull {
            columns[f].width = before
            columns[f].widthBeforeFull = nil
        } else {
            columns[f].widthBeforeFull = columns[f].width
            columns[f].width = 1
        }
    }

    public mutating func nudgeWidth(by delta: Double) {
        guard let f = focusedColumn else { return }
        columns[f].width = min(1, max(0.1, columns[f].width + delta))
        columns[f].widthBeforeFull = nil
    }

    /// Takes the focused window off the strip, or puts a floating window back beside the focused column.
    public mutating func toggleFloat(_ window: String, width: Double, columnID: String) {
        if floating.contains(window) {
            floating.removeAll { $0 == window }
            insert(window, width: width, columnID: columnID, focus: true)
        } else if column(of: window) != nil {
            remove(window)
            floating.append(window)
        }
    }
}
