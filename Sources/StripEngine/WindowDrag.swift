import StripModel
import WindowCore

/// Draws a window dragged with the mouse: its picture under the pointer and the slot where it
/// would land.
@MainActor
public protocol DragPresenter: AnyObject {
    /// Shows the dragged window's picture at `picture`, at the window's own size, and the slot
    /// it would take at `slot`, or no slot for nil. Both are in screen coordinates.
    func show(window: String, picture: Rect, slot: Rect?)
    /// Removes the picture and the slot. With `fade`, the picture fades instead of vanishing,
    /// for a window whose real frame is written at the drop point.
    func hide(fade: Bool)
}

/// Meta plus a left-button drag moves a window, as in niri.
///
/// A tiled window's picture follows the pointer at full size. The slot it would take shows
/// where it would land: a new column in a gap, a place in a stack, or a column on another
/// display. Once a target holds for a moment, the other pictures move aside to open a gap
/// there. No real window moves during the drag. On release the real windows take the frames
/// their pictures already show. Released where no slot shows, or with Esc, the window goes
/// back. A floating window's picture follows the pointer, and the window keeps its new place.
@MainActor
public final class WindowDragger {
    public weak var presenter: DragPresenter?
    /// Runs the waits for stacking and for opening the gap. Without one, both happen at once.
    public var clock: Clock?
    public var style = DropStyle() { didSet { tracker.style = style } }
    /// The gap opens once a target held this long, so passing over targets moves nothing.
    public var roomDelay = 0.15
    /// How often the strip scrolls while the pointer rests near a display's edge.
    public var scrollTick = 1.0 / 60

    private enum Kind { case tiled, floating }
    private struct Session {
        var id: String
        var kind: Kind
        var source: StripEngine
        var frame: Rect
        /// The width the window takes in a new column: its column's width.
        var width: Double
        var grabbed: Point
        /// False until the pointer moved past the threshold; a press without a drag is a click.
        var started = false
        var picture: Rect
        var pointer: Point
        /// The target the slot shows now, and the slot's frame.
        var shown: DropChoice?
        var slot: Rect?
        /// The target the pictures are laid out for.
        var arranged: DropChoice?
        /// Every display whose pictures the drag has laid out.
        var involved: Set<String> = []
    }
    private var session: Session?
    private var scrolling = false
    private var lastTick = 0.0
    /// Where edge scrolling hit the strip's end; it does not restart until the pointer moves.
    private var stalledAt: Point?
    private var tracker = DropTracker()
    private let displays: StripDisplays
    private let windows: WindowSystem

    public init(displays: StripDisplays, windows: WindowSystem) {
        self.displays = displays
        self.windows = windows
    }

    /// True from a press on a managed window until the button is released or the drag is cancelled.
    public var isActive: Bool { session != nil }
    /// The window being dragged, if any.
    public var dragged: String? { session?.id }
    /// The target the window would drop on now.
    public var target: DropTarget? { tracker.current?.hint.target }
    /// The slot shown now, in screen coordinates.
    public var slot: Rect? { session?.slot }

    /// Takes a press at `p`. Returns false when no managed window is there, so the click can go
    /// to the app.
    @discardableResult
    public func press(at p: Point) -> Bool {
        guard session == nil else { return true }
        // The display under the pointer is asked first; floating windows may reach past it.
        let all = Array(displays.engines.values)
        let engines = all.filter { $0.viewport.contains(p) } + all.filter { !$0.viewport.contains(p) }
        for e in engines {
            guard let hit = e.window(at: p) else { continue }
            let width = e.strip.column(of: hit.id).map { e.strip.columns[$0].width } ?? e.settings.defaultWidth
            session = Session(id: hit.id, kind: hit.floating ? .floating : .tiled, source: e, frame: hit.frame,
                              width: width, grabbed: p, picture: hit.frame, pointer: p)
            tracker = DropTracker(style: style)
            return true
        }
        return false
    }

    public func move(to p: Point) {
        guard var s = session else { return }
        s.pointer = p
        if !s.started {
            let dx = p.x - s.grabbed.x, dy = p.y - s.grabbed.y
            guard (dx * dx + dy * dy).squareRoot() >= style.threshold else { session = s; return }
            s.started = true
            s.source.beginDrag(s.id)
            if let id = displays.id(of: s.source) { s.involved.insert(id) }
        }
        s.picture = dragPictureRect(frame: s.frame, grabbed: s.grabbed, pointer: p)
        if s.kind == .tiled {
            if tracker.update(candidate(at: p, dragging: s.id), at: p, now: clock?.now ?? 0) {
                if let clock {
                    clock.after(style.holdDelay) { [weak self] in
                        guard let self, let s = self.session, s.started else { return }
                        self.move(to: s.pointer)
                    }
                } else {
                    _ = tracker.update(candidate(at: p, dragging: s.id), at: p, now: style.holdDelay)
                }
            }
            let choice = tracker.current
            // The slot follows the view as edge scrolling moves it, so it is found on every move.
            s.slot = choice.flatMap { c in
                displays.engines[c.display]?.dropSlot(s.id, at: c.hint.target, width: s.width)
            }
            if choice != s.shown {
                s.shown = choice
                if let clock {
                    clock.after(roomDelay) { [weak self] in
                        guard let self, let now = self.session, now.shown == choice else { return }
                        self.arrange()
                    }
                }
            }
        }
        session = s
        if s.kind == .tiled, clock == nil { arrange() }
        presenter?.show(window: s.id, picture: s.picture, slot: s.slot)
        scrollIfNearEdge()
    }

    /// Starts edge scrolling when the pointer is near a tiled display's left or right edge.
    private func scrollIfNearEdge() {
        guard !scrolling, let clock, let s = session, s.started, s.kind == .tiled,
              s.pointer != stalledAt, edge(at: s.pointer) != nil else { return }
        stalledAt = nil
        scrolling = true
        lastTick = clock.now
        clock.after(scrollTick) { [weak self] in self?.scrollStep() }
    }

    private func scrollStep() {
        scrolling = false
        guard let clock, var s = session, s.started, s.kind == .tiled, let (id, e, speed) = edge(at: s.pointer) else { return }
        let dt = clock.now - lastTick
        if !s.involved.contains(id) {
            s.involved.insert(id)
            session = s
            e.beginDrag(s.id)
        }
        if e.dragScroll(by: speed * dt) { tracker.forget() } else { stalledAt = s.pointer }
        // Targets come from the view that just moved.
        move(to: s.pointer)
    }

    private func edge(at p: Point) -> (id: String, engine: StripEngine, speed: Double)? {
        for (id, e) in displays.engines {
            let v = edgeScrollSpeed(at: p, viewport: e.viewport, style: style)
            if v != 0 { return (id, e, v) }
        }
        return nil
    }

    /// Drops the window into the slot, or puts it back when no slot shows.
    /// A press that never became a drag focuses the window, as the click would have.
    public func release(at p: Point) {
        guard session != nil else { return }
        move(to: p)
        // The drop goes where the slot shows, even if the gap has not opened yet.
        arrange()
        guard let s = session else { return }
        session = nil
        Log.note("drag", "release \(Log.name(s.id)) kind=\(s.kind) started=\(s.started) at \(Log.rect(s.picture)) "
            + "slot=\(s.shown.map { "\($0.display.prefix(8)) \($0.hint.target)" } ?? "none")")
        guard s.started else {
            displays.windowFocused(s.id)
            windows.focus(s.id)
            return
        }
        switch s.kind {
        case .floating:
            windows.setFrame(s.id, s.picture) { _ in }
            s.source.endDrag(from: s.picture)
            presenter?.hide(fade: true)
            // A float let go over another tiled display belongs to that display from now on.
            if let target = displays.engine(owning: s.picture), target !== s.source {
                Log.note("drag", "floating \(Log.name(s.id)) hands over from \(s.source.label) to \(target.label)")
                s.source.handOver(s.id)
                target.windowAdded(s.id, floating: true, takesFocus: false)
            }
            windows.focus(s.id)
        case .tiled:
            finish(s)
        }
    }

    /// Puts the window back where the drag began.
    public func cancel() {
        guard var s = session else { return }
        Log.note("drag", "cancel \(Log.name(s.id))")
        guard s.started else { session = nil; return }
        tracker = DropTracker(style: style)
        s.shown = nil
        s.slot = nil
        session = s
        arrange()
        session = nil
        finish(s)
    }

    /// Ends the drag of a window that closed, with no drop, so the window does not land anywhere.
    public func windowRemoved(_ id: String) {
        guard session?.id == id else { return }
        cancel()
    }

    /// Writes what the pictures show, the window's own display first so a window leaving it is
    /// gone before another display takes it.
    private func finish(_ s: Session) {
        let sourceID = displays.id(of: s.source)
        let order = s.involved.filter { $0 == sourceID } + s.involved.filter { $0 != sourceID }
        for id in order {
            displays.engines[id]?.endDrag(from: s.picture)
        }
        presenter?.hide(fade: false)
    }

    /// Lays out every display's pictures for the target the slot shows: a gap opens there, the
    /// window's own display closes its slot when the window leaves it, and displays the target
    /// left go back to how they are.
    private func arrange() {
        guard var s = session, s.started, s.kind == .tiled, s.arranged != s.shown else { return }
        let choice = s.shown
        let sourceID = displays.id(of: s.source)
        if let c = choice { s.involved.insert(c.display) }
        for id in s.involved {
            guard let e = displays.engines[id] else { continue }
            let target = choice?.display == id ? choice?.hint.target : nil
            let leaving = e === s.source && choice != nil && choice?.display != sourceID
            e.previewDrop(s.id, at: target, width: s.width, leaving: leaving)
        }
        s.arranged = choice
        session = s
    }

    private func candidate(at p: Point, dragging id: String) -> DropChoice? {
        for (display, e) in displays.engines {
            if let h = e.dropHint(at: p, dragging: id, style: style) { return DropChoice(display: display, hint: h) }
        }
        return nil
    }
}
