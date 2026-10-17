import StripModel
import WindowCore

public struct TiledDisplay: Equatable, Sendable {
    /// Stable across reconnects, so settings follow the physical display.
    public var id: String
    /// The whole screen in Accessibility coordinates.
    public var frame: Rect
    /// The usable area, without menu bar and Dock.
    public var visible: Rect
    /// The name macOS shows for it, such as `Built-in Display`.
    public var name: String

    public init(id: String, frame: Rect, visible: Rect, name: String = "") {
        self.id = id; self.frame = frame; self.visible = visible; self.name = name
    }
}

/// One independent strip engine per tiled display, plus the routing between them.
@MainActor
public final class StripDisplays {
    public private(set) var infos: [TiledDisplay] = []
    public private(set) var engines: [String: StripEngine] = [:]
    public private(set) var disabled: Set<String>
    public var settings = StripSettings()
    /// The narrowest width each app accepts, shared by every display.
    public var minimums = MinimumWidths()
    /// The bundle ID of a window's app.
    public var appOf: (String) -> String? = { _ in nil }
    /// Called after a learned width changed, so it can be saved.
    public var onMinimumsChanged: ((MinimumWidths) -> Void)?
    /// Each window's app, looked up once, since layout asks on every frame.
    private var apps: [String: String] = [:]

    /// Set when focus moved to a display with no window to focus; cleared by the next real focus.
    private var chosen: String?
    private let windows: WindowSystem
    private let configure: (StripEngine, TiledDisplay) -> Void
    private let discard: (String) -> Void

    /// `configure` wires a new engine (presenter, observers); `discard` tears that down again.
    public init(
        windows: WindowSystem, disabled: Set<String> = [],
        configure: @escaping (StripEngine, TiledDisplay) -> Void, discard: @escaping (String) -> Void
    ) {
        self.windows = windows
        self.disabled = disabled
        self.configure = configure
        self.discard = discard
    }

    public func info(_ id: String) -> TiledDisplay? { infos.first { $0.id == id } }

    /// Enabled displays, left to right.
    public var ordered: [TiledDisplay] {
        let active = infos.filter { !disabled.contains($0.id) }
        return displayOrder(active.map(\.frame)).map { active[$0] }
    }

    /// Brings the engines in line with the attached displays. Windows of a display that went away
    /// move to the first remaining one, which is the primary display. That display's layout is
    /// kept, and its windows go back to it when it returns.
    public func update(_ displays: [TiledDisplay]) {
        Log.note("display", "update: " + displays.map { "\(Self.short($0.id)) \(Log.rect($0.visible))" }.joined(separator: ", ")
            + (disabled.isEmpty ? "" : "; disabled " + disabled.map(Self.short).joined(separator: ", ")))
        infos = displays
        var orphans: [StripEngine.Released] = []
        for id in engines.keys where !displays.contains(where: { $0.id == id }) || disabled.contains(id) {
            if !disabled.contains(id), let e = engines[id] { retired[id] = e.workspaces }
            Log.note("display", "\(Self.short(id)) went away or was disabled; its windows move to the first display")
            orphans += remove(id)
        }
        for d in displays where !disabled.contains(d.id) {
            let returning = engines[d.id] == nil
            ensureEngine(d)
            if returning, let saved = retired.removeValue(forKey: d.id) {
                Log.note("display", "\(Self.short(d.id)) came back; restoring its layout\n" + saved.summary)
                bringBack(saved, to: d.id)
            }
        }
        guard let home = displays.first(where: { !disabled.contains($0.id) }), let target = engines[home.id] else { return }
        for o in orphans where o.floating { Log.note("display", "floating \(Log.name(o.id)) is released, no display adopts it") }
        for o in orphans where !o.floating { target.adopt(o.id, width: o.width, focus: false) }
    }

    /// Reads the displays again and writes every window's frame on each of them.
    public func retileAll(_ displays: [TiledDisplay]) {
        update(displays)
        for id in ordered.map(\.id) { engines[id]?.retile() }
    }

    /// Layouts of displays that went away, so their windows return with them.
    private var retired: [String: Workspaces] = [:]

    /// Takes a returning display's windows back from wherever they went and lays them out as
    /// they were.
    private func bringBack(_ saved: Workspaces, to id: String) {
        guard let e = engines[id] else { return }
        for w in saved.strips.flatMap({ $0.allWindows + $0.floating }) {
            if let other = engine(holding: w), other !== e {
                Log.note("display", "\(Log.name(w)) returns from \(other.label) to \(Self.short(id))")
                other.windowRemoved(w)
            }
        }
        var layout = saved
        layout.normalize()
        e.restore(layout)
    }

    private func ensureEngine(_ d: TiledDisplay) {
        let others = infos.filter { $0.id != d.id }.map(\.frame)
        if let e = engines[d.id] {
            e.setGeometry(viewport: d.visible, neighbours: others)
            return
        }
        let e = StripEngine(windows: windows, viewport: d.visible, settings: settings)
        e.label = Self.short(d.id)
        e.neighbours = others
        e.minimumWidth = { [unowned self] id in app(of: id).flatMap(minimums.width(for:)) }
        e.onRefusedWidth = { [unowned self, unowned e] id, asked, took in
            guard let app = app(of: id),
                  minimums.refused(app: app, asked: asked.width, took: took.width, screenWidth: e.viewport.width) else { return }
            Log.note("minimum", "\(Log.name(id)) took \(Int(took.width)) points when asked for \(Int(asked.width)); \(app) columns widen to it")
            minimumsChanged()
        }
        engines[d.id] = e
        configure(e, d)
    }

    private func remove(_ id: String) -> [StripEngine.Released] {
        guard let e = engines.removeValue(forKey: id) else { return [] }
        if chosen == id { chosen = nil }
        if lastActive == id { lastActive = nil }
        discard(id)
        return e.releaseAll()
    }

    /// Starts or stops tiling a display. Stopping returns the windows it held so the caller can
    /// put them back where they were.
    @discardableResult
    public func setEnabled(_ id: String, _ on: Bool) -> [String] {
        if on {
            disabled.remove(id)
            if let d = info(id) { ensureEngine(d) }
            return []
        }
        disabled.insert(id)
        return remove(id).map(\.id)
    }

    // MARK: Windows

    /// The engine for the display that owns a window at `frame`, or nil when that display is not tiled.
    public func engine(owning frame: Rect) -> StripEngine? {
        guard let i = owningDisplay(of: frame, among: infos.map(\.frame)) else { return nil }
        return engines[infos[i].id]
    }

    public func engine(holding id: String) -> StripEngine? {
        engines.values.first { $0.workspaces.workspace(of: id) != nil }
    }

    /// A window that just opened joins the display the user last worked on, next to its focused
    /// window, wherever the app put it. A floating window stays on the display it opened on,
    /// since dialogs open over the window they belong to.
    /// `openOn` comes from an `open-on` rule. A window sent to a display other than the active one
    /// does not take focus. A display that is not connected leaves the window where it would go anyway.
    public func newWindowAdded(_ id: String, frame: Rect?, floating: Bool = false, takesFocus: Bool = true, openOn: OpenOn? = nil) {
        guard engine(holding: id) == nil else {
            return Log.note("anomaly", "newWindowAdded: \(Log.name(id)) is already held by \(engine(holding: id)!.label)")
        }
        if let openOn {
            var target: StripEngine?
            if let name = openOn.display {
                target = ordered.first { $0.name.lowercased().hasPrefix(name.lowercased()) }.flatMap { engines[$0.id] }
                if target == nil { Log.note("display", "open-on: no display named \(name) for \(Log.name(id)); it opens as usual") }
            }
            let usual = !floating ? lastActive.flatMap { engines[$0] } : nil
            guard let engine = target ?? usual ?? frame.flatMap({ engine(owning: $0) }) ?? ordered.first.flatMap({ engines[$0.id] }) else {
                return Log.note("display", "\(Log.name(id)) has no display to open on; not added")
            }
            let elsewhere = lastActive.map { engines[$0] !== engine } ?? false
            Log.note("display", "open-on sends \(Log.name(id)) to \(engine.label)" + (openOn.workspace.map { " workspace \($0)" } ?? ""))
            engine.windowAdded(id, floating: floating, takesFocus: takesFocus && !elsewhere, workspace: openOn.workspace)
            return
        }
        if !floating, let last = lastActive, let e = engines[last] {
            Log.note("display", "new \(Log.name(id)) goes to the last active display \(Self.short(last))")
            e.windowAdded(id, floating: false, takesFocus: takesFocus)
            return
        }
        windowAdded(id, frame: frame, floating: floating, takesFocus: takesFocus)
    }

    /// The display the user last focused a window on or switched to.
    public private(set) var lastActive: String?

    public func windowAdded(_ id: String, frame: Rect?, floating: Bool = false, takesFocus: Bool = true) {
        guard engine(holding: id) == nil else {
            return Log.note("display", "windowAdded: \(Log.name(id)) is already held by \(engine(holding: id)!.label)")
        }
        let target = frame.map { engine(owning: $0) } ?? ordered.first.flatMap { engines[$0.id] }
        if target == nil { Log.note("display", "\(Log.name(id)) at \(Log.rect(frame)) is on no tiled display; not added") }
        target?.windowAdded(id, floating: floating, takesFocus: takesFocus)
    }

    /// A window found at startup, waiting to be matched against the saved layout.
    public struct Pending {
        public var live: LiveWindow
        public var frame: Rect?
        public var floating: Bool
        public var takesFocus: Bool

        public init(live: LiveWindow, frame: Rect?, floating: Bool, takesFocus: Bool) {
            self.live = live; self.frame = frame; self.floating = floating; self.takesFocus = takesFocus
        }
    }

    /// Rebuilds each enabled display from `saved` around the windows found at startup, then adds
    /// the windows no slot claimed the normal way. Call once, before any other window joins.
    public func restore(_ saved: SavedLayout, pending: [Pending]) {
        let ids = ordered.map(\.id)
        let plan = saved.plan(displays: ids, windows: pending.map(\.live),
                              floating: Set(pending.filter(\.floating).map(\.live.id)))
        for p in pending {
            Log.note("restore", "found \(Log.name(p.live.id)) number=\(p.live.descriptor.windowNumber.map(String.init) ?? "nil") "
                + "floating=\(p.floating) at \(Log.rect(p.frame))")
        }
        Log.note("restore", "unplaced: \(Log.names(plan.unplaced))")
        for (id, w) in plan.workspaces { engines[id]?.restore(w) }
        let byID = Dictionary(pending.map { ($0.live.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in plan.unplaced {
            guard let p = byID[id] else { continue }
            windowAdded(id, frame: p.frame, floating: p.floating, takesFocus: p.takesFocus)
        }
    }

    public func floatWindow(_ id: String) { engine(holding: id)?.floatWindow(id) }

    /// A window's place across displays, for one that hides for a while.
    public struct Slot: Equatable, Sendable {
        public var display: String
        public var slot: StripEngine.Slot
    }

    public func slot(of id: String) -> Slot? {
        for (d, e) in engines { if let s = e.slot(of: id) { return Slot(display: d, slot: s) } }
        return nil
    }

    /// Puts a window back where it was. False when that display is no longer tiled.
    public func restore(_ id: String, to s: Slot) -> Bool {
        guard engine(holding: id) == nil, let e = engines[s.display] else { return false }
        e.restore(id, to: s.slot)
        return true
    }

    /// A tiled window seen narrower than its app's learned width proves the app allows it.
    public func windowSeen(_ id: String, width: Double) {
        guard engine(holding: id)?.frame(of: id) != nil, let app = app(of: id),
              minimums.seen(app: app, width: width) else { return }
        Log.note("minimum", "\(Log.name(id)) is \(Int(width)) points wide; \(app) columns narrow to it")
        minimumsChanged()
    }

    private func app(of id: String) -> String? {
        if let app = apps[id] { return app }
        let app = appOf(id)
        apps[id] = app
        return app
    }

    private func minimumsChanged() {
        onMinimumsChanged?(minimums)
        for e in engines.values { e.apply() }
    }

    public func windowRemoved(_ id: String, refocus: Bool = true) {
        apps[id] = nil
        engine(holding: id)?.windowRemoved(id, refocus: refocus)
        for d in retired.keys { retired[d]?.remove(id) }
    }

    public func windowFocused(_ id: String) {
        guard let e = engine(holding: id) else { return Log.note("focus", "\(Log.name(id)) focused; not on any strip") }
        Log.note("focus", "\(Log.name(id)) focused on \(e.label)")
        chosen = nil
        lastActive = self.id(of: e)
        e.windowFocused(id)
    }

    /// The user clicked an empty desktop on this display: it becomes the active display, and
    /// commands act on it until a window takes focus.
    public func desktopClicked(on engine: StripEngine) {
        guard let target = id(of: engine) else { return }
        Log.note("display", "desktop clicked on \(Self.short(target)); it becomes the active display")
        lastActive = target
        chosen = target
    }

    // MARK: Routing

    /// The engine commands act on: the display holding the focused window, else the one the
    /// user last switched to, else the one under the pointer.
    public func active(pointer: Point) -> StripEngine? {
        if let chosen, let e = engines[chosen] { return e }
        if let id = windows.knownFocus, let e = engine(holding: id) { return e }
        return underPointer(pointer)
    }

    public func underPointer(_ pointer: Point) -> StripEngine? {
        guard let i = nearestDisplay(to: pointer, among: infos.map(\.frame)) else { return nil }
        return engines[infos[i].id]
    }

    public func id(of engine: StripEngine) -> String? {
        engines.first { $0.value === engine }?.key
    }

    /// Switches to the next (positive) or previous display. Returns it, even when it is empty.
    @discardableResult
    public func focusDisplay(by delta: Int, from current: StripEngine?) -> String? {
        guard let target = neighbour(of: current, by: delta), let e = engines[target] else { return nil }
        lastActive = target
        if e.strip.focusedWindow != nil {
            chosen = nil
            e.activate()
        } else {
            chosen = target
        }
        return target
    }

    /// Carries the focused window to the next or previous display, as a column right of that
    /// display's focused one, and follows it.
    @discardableResult
    public func moveFocused(by delta: Int, from current: StripEngine?) -> String? {
        guard let current, let target = neighbour(of: current, by: delta), let e = engines[target], e !== current,
              let moved = current.takeFocused() else { return nil }
        Log.note("display", "move \(Log.name(moved.id)) from \(current.label) to \(Self.short(target))")
        chosen = nil
        e.adopt(moved.id, width: moved.width, focus: true)
        return target
    }

    /// Focuses the display lying in `direction`, by the displays' arrangement.
    @discardableResult
    public func focusDisplay(toward direction: Direction, from current: StripEngine?) -> String? {
        guard let target = neighbour(of: current, toward: direction), let e = engines[target] else { return nil }
        lastActive = target
        if e.strip.focusedWindow != nil {
            chosen = nil
            e.activate()
        } else {
            chosen = target
        }
        return target
    }

    /// Carries the focused window to the display lying in `direction` and follows it.
    @discardableResult
    public func moveFocused(toward direction: Direction, from current: StripEngine?) -> String? {
        guard let current, let target = neighbour(of: current, toward: direction), let e = engines[target],
              e !== current, let moved = current.takeFocused() else { return nil }
        Log.note("display", "move \(Log.name(moved.id)) \(direction) from \(current.label) to \(Self.short(target))")
        chosen = nil
        e.adopt(moved.id, width: moved.width, focus: true)
        return target
    }

    /// The start of a display UUID, enough to tell displays apart in the log.
    static func short(_ id: String) -> String { String(id.prefix(8)) }

    private func neighbour(of engine: StripEngine?, toward direction: Direction) -> String? {
        let list = ordered
        guard !list.isEmpty else { return nil }
        let from = engine.flatMap(id(of:)).flatMap { id in list.firstIndex { $0.id == id } } ?? 0
        guard let i = displayToward(direction, from: from, among: list.map(\.frame)) else { return nil }
        return list[i].id
    }

    private func neighbour(of engine: StripEngine?, by delta: Int) -> String? {
        let list = ordered
        guard !list.isEmpty else { return nil }
        let from = engine.flatMap(id(of:)).flatMap { id in list.firstIndex { $0.id == id } } ?? 0
        let frames = list.map(\.frame)
        guard let i = adjacentDisplay(from: from, by: delta, among: frames) else { return nil }
        return list[i].id
    }
}
