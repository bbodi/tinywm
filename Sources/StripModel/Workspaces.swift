import WindowCore

/// A vertical stack of strips on one display, like niri's workspaces.
///
/// Both ends of the list are always empty workspaces, so there is somewhere new to go above and
/// below. An empty workspace in between disappears as soon as the user is not on it.
public struct Workspaces: Codable, Equatable, Sendable {
    public var strips: [Strip] = [Strip()]
    public var active = 0

    public init() {}

    public var current: Strip {
        get { strips[active] }
        set { strips[active] = newValue }
    }

    public func workspace(of window: String) -> Int? {
        strips.firstIndex { $0.column(of: window) != nil || $0.floating.contains(window) }
    }

    /// Moves to the workspace above (negative) or below (positive), clamped to the list.
    public mutating func switchBy(_ delta: Int) {
        switchTo(active + delta)
    }

    public mutating func switchTo(_ index: Int) {
        let target = max(0, min(strips.count - 1, index))
        guard target != active else { return }
        active = target
        normalize()
    }

    /// Carries the focused window to the workspace above or below and follows it there.
    public mutating func moveFocused(by delta: Int, width: Double, columnID: String) {
        guard let window = current.focusedWindow else { return }
        let target = active + delta
        guard target >= 0, target < strips.count else { return }
        Log.note("workspace", "move \(Log.name(window)) from workspace \(active) to \(target)")
        strips[active].remove(window)
        strips[target].insert(window, width: width, columnID: columnID, focus: true)
        if strips[target].column(of: window) == nil {
            Log.note("anomaly", "\(Log.name(window)) did not land in a column of workspace \(target): "
                + (workspace(of: window).map { "it is in workspace \($0)" } ?? "it is in no workspace"))
        }
        active = target
        normalize()
    }

    /// The index of workspace `number`, counted from 1 at the top workspace that can hold windows.
    /// A number past the last workspace with windows gives the empty one below it.
    public func index(ofWorkspace number: Int) -> Int {
        // The top workspace is the empty one above the rest, once any workspace holds windows.
        strips.count == 1 ? 0 : max(1, min(number, strips.count - 1))
    }

    /// Adds a window to workspace `number` without switching to it. On a workspace the user is
    /// not on, the window does not take that workspace's focus unless it is the first window there.
    public mutating func add(_ window: String, toWorkspace number: Int, width: Double, columnID: String, floating: Bool) {
        let target = index(ofWorkspace: number)
        Log.note("workspace", "add \(Log.name(window)) to workspace \(number) (index \(target))")
        if floating {
            strips[target].addFloating(window)
        } else {
            strips[target].insert(window, width: width, columnID: columnID, focus: false)
        }
        normalize()
    }

    /// Removes a window from whichever workspace holds it.
    public mutating func remove(_ window: String) {
        guard let w = workspace(of: window) else { return }
        strips[w].remove(window)
        normalize()
    }

    /// Drops empty workspaces between the ends unless the user is on one, then keeps one empty
    /// workspace at the top and one at the bottom.
    public mutating func normalize() {
        var i = strips.count - 2
        while i >= 1 {
            if strips[i].isEmpty, i != active {
                strips.remove(at: i)
                if active > i { active -= 1 }
            }
            i -= 1
        }
        if strips.isEmpty { strips = [Strip()]; active = 0 }
        if strips.count == 1, strips[0].isEmpty { return }
        if !strips[0].isEmpty {
            strips.insert(Strip(), at: 0)
            active += 1
        }
        if !strips[strips.count - 1].isEmpty { strips.append(Strip()) }
        // Two empty workspaces next to an end collapse to one, unless the user is on the inner one.
        while strips.count >= 3, strips[0].isEmpty, strips[1].isEmpty, active != 1 {
            strips.remove(at: 0)
            if active > 0 { active -= 1 }
        }
        while strips.count >= 3, strips[strips.count - 1].isEmpty, strips[strips.count - 2].isEmpty,
              active != strips.count - 2 {
            strips.removeLast()
        }
    }
}

extension Workspaces {
    /// Every workspace with its columns and floating windows, one per line, for the log.
    /// The active workspace and the focused column are starred.
    public var summary: String {
        strips.enumerated().map { i, s in
            let mark = i == active ? "*" : " "
            guard !s.isEmpty else { return "\(mark)ws\(i): empty" }
            let columns = s.columns.enumerated().map { c, col in
                (c == s.focusedColumn ? "*" : "") + "\(col.width)" + Log.names(col.windows)
            }
            var line = "\(mark)ws\(i) scroll=\(Int(s.scroll)): " + columns.joined(separator: " | ")
            if !s.floating.isEmpty { line += "  floating: " + Log.names(s.floating) }
            return line
        }.joined(separator: "\n")
    }
}

extension Strip {
    public var isEmpty: Bool { columns.isEmpty && floating.isEmpty }
}
