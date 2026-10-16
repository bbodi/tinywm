import Testing
import WindowCore
@testable import StripEngine
@testable import StripModel

private let screen = Rect(x: 0, y: 0, width: 1000, height: 600)
private let m = StripMetrics(viewport: screen, gap: 0)

/// Columns c0, c1, … each holding w0, w1, … at half the screen's width.
private func strip(_ n: Int) -> Strip {
    var s = Strip()
    s.columns = (0..<n).map { Column(id: "c\($0)", windows: ["w\($0)"], width: 0.5) }
    s.focusedColumn = 0
    return s
}

private func at(_ x: Double, _ y: Double) -> Point { Point(x: x, y: y) }

private let stackingOff = Comment(rawValue: "Dropping onto another window to stack under it is off for now. It will come back niri's way: a window can be dropped under another window, but never into an empty column at half height.")
/// The drop style with stacking on, for the tests that wait for it to come back.
private let stacking: DropStyle = { var s = DropStyle(); s.stacking = true; return s }()

@Suite struct DropHintTests {
    @Test func theSidesOfAColumnAndTheGapsMakeANewColumn() {
        let s = strip(3)
        #expect(dropHint(at: at(50, 300), in: s, m, dragging: nil)?.target == .newColumn(0))
        #expect(dropHint(at: at(450, 300), in: s, m, dragging: nil)?.target == .newColumn(1))
        #expect(dropHint(at: at(560, 300), in: s, m, dragging: nil)?.target == .newColumn(1))
    }

    @Test func eachHalfOfAColumnInsertsOnItsSide() {
        let s = strip(3)
        #expect(dropHint(at: at(200, 300), in: s, m, dragging: nil)?.target == .newColumn(0))
        #expect(dropHint(at: at(300, 300), in: s, m, dragging: nil)?.target == .newColumn(1))
        // A stack is no target either: over it the window still gets a column of its own.
        var t = strip(2)
        t.columns[0].windows = ["w0", "x"]
        #expect(dropHint(at: at(200, 100), in: t, m, dragging: nil)?.target == .newColumn(0))
    }

    @Test(.disabled(stackingOff)) func theMiddleOfAColumnStacksAboveOrBelowByHalf() {
        var s = strip(2)
        s.columns[0].windows = ["w0", "x"]
        #expect(dropHint(at: at(250, 100), in: s, m, dragging: nil, style: stacking)?.target == .stack(column: 0, row: 0))
        #expect(dropHint(at: at(250, 200), in: s, m, dragging: nil, style: stacking)?.target == .stack(column: 0, row: 1))
        #expect(dropHint(at: at(250, 500), in: s, m, dragging: nil, style: stacking)?.target == .stack(column: 0, row: 2))
    }

    @Test func theDraggedWindowsOwnColumnPutsItBack() {
        let s = strip(3)
        #expect(dropHint(at: at(700, 300), in: s, m, dragging: "w1")?.target == .newColumn(1))
    }

    @Test(.disabled(stackingOff)) func aStackedDraggedWindowIsLeftOutOfTheRows() {
        var t = strip(2)
        t.columns[0].windows = ["w0", "x"]
        #expect(dropHint(at: at(250, 500), in: t, m, dragging: "x", style: stacking)?.target == .stack(column: 0, row: 1))
    }

    @Test func offTheDisplayThereIsNoTarget() {
        let s = strip(3)
        #expect(dropHint(at: at(1200, 300), in: s, m, dragging: nil) == nil)
        #expect(dropHint(at: at(250, 900), in: s, m, dragging: nil) == nil)
        // Just below the usable area, over the Dock, still counts.
        #expect(dropHint(at: at(300, 650), in: s, m, dragging: nil)?.target == .newColumn(1))
    }

    @Test func anEmptyStripTakesANewFirstColumn() {
        #expect(dropHint(at: at(500, 300), in: Strip(), m, dragging: nil)?.target == .newColumn(0))
    }

    @Test func aScrolledStripUsesWhereColumnsShow() {
        var s = strip(3)
        s.scroll = 250
        // Column 0 spans -250…250 now, so the pointer at its right side inserts after it.
        let h = dropHint(at: at(200, 300), in: s, m, dragging: nil)
        #expect(h?.target == .newColumn(1))
        let left = dropHint(at: at(5, 100), in: s, m, dragging: nil)
        #expect(left?.target == .newColumn(1))
    }
}

@Suite struct DropTrackerTests {
    let s = strip(3)
    func choice(_ p: Point) -> DropChoice? {
        dropHint(at: p, in: s, m, dragging: "w0", style: stacking).map { DropChoice(display: "A", hint: $0) }
    }

    @Test func aTargetHoldsNearItsEdge() {
        var t = DropTracker()
        _ = t.update(choice(at(560, 300)), at: at(560, 300), now: 0)
        #expect(t.current?.hint.target == .newColumn(1))
        // Into the next zone by less than the hysteresis: the target stays.
        _ = t.update(choice(at(490, 300)), at: at(490, 300), now: 0)
        #expect(t.current?.hint.target == .newColumn(1))
        _ = t.update(choice(at(440, 300)), at: at(440, 300), now: 0)
        #expect(t.current?.hint.target == .newColumn(0))
        #expect(stickyHint(nil, nil, at: at(0, 0), margin: 16) == nil)
    }

    @Test func forgettingDropsTheHeldTarget() {
        var t = DropTracker()
        _ = t.update(choice(at(560, 300)), at: at(560, 300), now: 0)
        t.forget()
        #expect(t.current == nil)
        _ = t.update(choice(at(490, 300)), at: at(490, 300), now: 0)
        #expect(t.current?.hint.target == .newColumn(0))
    }

    @Test(.disabled(stackingOff)) func stackingWaitsForThePointerToRest() {
        var t = DropTracker()
        _ = t.update(choice(at(560, 300)), at: at(560, 300), now: 0)
        #expect(t.current?.hint.target == .newColumn(1))
        // Into the middle of column 1: the stack target waits; the old target is too far to keep.
        let waitsOnEntry = t.update(choice(at(750, 100)), at: at(750, 100), now: 0.1)
        #expect(waitsOnEntry)
        #expect(t.current == nil)
        let waitsAgain = t.update(choice(at(752, 101)), at: at(752, 101), now: 0.2)
        #expect(!waitsAgain)
        #expect(t.current == nil)
        _ = t.update(choice(at(752, 101)), at: at(752, 101), now: 0.3)
        #expect(t.current?.hint.target == .stack(column: 1, row: 0))
    }

    @Test(.disabled(stackingOff)) func movingOnRestartsTheWait() {
        var t = DropTracker()
        let waitsFirst = t.update(choice(at(750, 100)), at: at(750, 100), now: 0)
        #expect(waitsFirst)
        let waitsAfterMoving = t.update(choice(at(760, 120)), at: at(760, 120), now: 0.15)
        #expect(waitsAfterMoving)
        _ = t.update(choice(at(760, 120)), at: at(760, 120), now: 0.25)
        #expect(t.current == nil)
        _ = t.update(choice(at(760, 120)), at: at(760, 120), now: 0.35)
        #expect(t.current?.hint.target == .stack(column: 1, row: 0))
    }
}

@Suite struct PlaceTests {
    @Test func aLoneWindowTakesItsColumnAlong() {
        var s = strip(3)
        s.columns[0].width = 0.7
        s.place("w0", at: .newColumn(3), width: 0.5, columnID: "n")
        #expect(s.columns.map(\.id) == ["c1", "c2", "c0"])
        #expect(s.columns[2].width == 0.7)
        #expect(s.focusedColumn == 2)

        var t = strip(3)
        t.place("w2", at: .newColumn(0), width: 0.5, columnID: "n")
        #expect(t.columns.map(\.id) == ["c2", "c0", "c1"])
        #expect(t.focusedColumn == 0)
    }

    @Test func droppingOnItsOwnSlotChangesNothing() {
        for i in [1, 2] {
            var s = strip(3)
            s.place("w1", at: .newColumn(i), width: 0.5, columnID: "n")
            #expect(s.columns.map(\.id) == ["c0", "c1", "c2"])
            #expect(s.focusedColumn == 1)
        }
    }

    @Test func stackingInsertsAtTheRow() {
        var s = strip(3)
        s.place("w0", at: .stack(column: 2, row: 0), width: 0.5, columnID: "n")
        #expect(s.columns.map(\.windows) == [["w1"], ["w0", "w2"]])
        #expect(s.focusedColumn == 1)
        #expect(s.columns[1].focused == 0)
    }

    @Test func aStackedWindowGetsANewColumnOfItsColumnsWidth() {
        var s = strip(3)
        s.columns[0].windows = ["w0", "x"]
        s.columns[0].width = 0.6
        s.place("x", at: .newColumn(2), width: 0.5, columnID: "n")
        #expect(s.columns.map(\.id) == ["c0", "c1", "n", "c2"])
        #expect(s.columns[2].width == 0.6)
        #expect(s.columns[0].windows == ["w0"])
    }

    @Test func aWindowFromElsewhereGetsTheGivenWidth() {
        var s = strip(2)
        s.place("x", at: .newColumn(1), width: 0.4, columnID: "n")
        #expect(s.columns.map(\.id) == ["c0", "n", "c1"])
        #expect(s.columns[1].width == 0.4)
        s.place("y", at: .stack(column: 0, row: 5), width: 0.4, columnID: "m")
        #expect(s.columns[0].windows == ["w0", "y"])
    }
}

@Suite struct DragPictureTests {
    @Test func theGrabbedPointStaysUnderThePointerAtFullSize() {
        let frame = Rect(x: 100, y: 0, width: 400, height: 600)
        let r = dragPictureRect(frame: frame, grabbed: at(200, 300), pointer: at(600, 350))
        #expect(r == Rect(x: 500, y: 50, width: 400, height: 600))
    }
}

@Suite struct EdgeScrollTests {
    @Test func speedGrowsTowardTheEdge() {
        #expect(edgeScrollSpeed(at: at(500, 300), viewport: screen) == 0)
        #expect(edgeScrollSpeed(at: at(40, 300), viewport: screen) == 0)
        #expect(edgeScrollSpeed(at: at(20, 300), viewport: screen) == -600)
        #expect(edgeScrollSpeed(at: at(0, 300), viewport: screen) == -1200)
        #expect(edgeScrollSpeed(at: at(990, 300), viewport: screen) == 900)
        // Off the display, another display's edge decides.
        #expect(edgeScrollSpeed(at: at(1010, 300), viewport: screen) == 0)
    }
}

@Suite struct BaseTargetTests {
    @Test func targetsOnThePreviewMapToTheStripsOwnIndices() {
        let base = strip(3)
        // The preview shows w2 dropped first: c2, c0, c1.
        let preview = dropLayout(base, moving: "w2", to: .newColumn(0), leaving: false, width: 0.5, columnID: "n", m)
        // Next to the slot means the same place.
        #expect(baseTarget(.newColumn(0), from: preview, to: base, dragging: "w2") == .newColumn(0))
        #expect(baseTarget(.newColumn(1), from: preview, to: base, dragging: "w2") == .newColumn(0))
        // Between c0 and c1 on screen, which is before c1 in the strip.
        #expect(baseTarget(.newColumn(2), from: preview, to: base, dragging: "w2") == .newColumn(1))
        #expect(baseTarget(.newColumn(3), from: preview, to: base, dragging: "w2") == .newColumn(3))
    }
}

@Suite struct DropLayoutTests {
    @Test func aTargetOpensAGapWhereTheWindowLands() {
        let s = dropLayout(strip(3), moving: "w2", to: .newColumn(0), leaving: false, width: 0.5, columnID: "n", m)
        #expect(s.columns.map(\.id) == ["c2", "c0", "c1"])
        #expect(s.scroll == 0)
        #expect(stripFrames(s, m, clamp: false)["w2"] == Rect(x: 0, y: 0, width: 500, height: 600))
    }

    @Test func aDropKeepsTheView() {
        var s = strip(3)
        s.scroll = 500
        let end = dropLayout(s, moving: "w0", to: .newColumn(3), leaving: false, width: 0.5, columnID: "n", m)
        #expect(end.columns.map(\.id) == ["c1", "c2", "c0"])
        #expect(end.scroll == 500)
        let start = dropLayout(s, moving: "w2", to: .newColumn(0), leaving: false, width: 0.5, columnID: "n", m)
        #expect(start.scroll == 500)
    }

    @Test func aWindowLeavingClosesItsGapAndNoTargetChangesNothing() {
        var s = strip(3)
        s.scroll = 500
        let left = dropLayout(s, moving: "w2", to: nil, leaving: true, width: 0.5, columnID: "n", m)
        #expect(left.columns.map(\.id) == ["c0", "c1"])
        #expect(left.scroll == 0)
        #expect(dropLayout(s, moving: "w2", to: nil, leaving: false, width: 0.5, columnID: "n", m) == s)
    }
}

@MainActor
final class DragWindows: WindowSystem {
    var frames: [String: Rect] = [:]
    var writes: [String: [Rect]] = [:]
    var focusedWindow: String?
    func setFrame(_ id: String, _ rect: Rect, completion: @escaping @MainActor (Rect?) -> Void) {
        frames[id] = rect
        writes[id, default: []].append(rect)
        completion(rect)
    }
    func focus(_ id: String) { focusedWindow = id }
    func frameOf(_ id: String) -> Rect? { frames[id] }
}

@MainActor
final class FakeDragPresenter: DragPresenter {
    var shown: [(window: String, picture: Rect, slot: Rect?)] = []
    var hidden = 0
    func show(window: String, picture: Rect, slot: Rect?) { shown.append((window, picture, slot)) }
    func hide(fade: Bool) { hidden += 1 }
}

@MainActor
@Suite struct WindowDragTests {
    let a = TiledDisplay(id: "A", frame: screen, visible: screen)
    let b = TiledDisplay(id: "B", frame: Rect(x: 1000, y: 0, width: 1000, height: 600),
                         visible: Rect(x: 1000, y: 0, width: 1000, height: 600))

    /// Display A holds x and y side by side, x focused; display B is empty.
    func make() -> (StripDisplays, WindowDragger, DragWindows, FakeDragPresenter) {
        let w = DragWindows()
        let d = StripDisplays(windows: w, configure: { _, _ in }, discard: { _ in })
        d.settings.gap = 0
        d.settings.defaultWidth = 0.5
        d.update([a, b])
        w.focusedWindow = "x"
        d.windowAdded("x", frame: Rect(x: 0, y: 0, width: 300, height: 300))
        d.windowAdded("y", frame: Rect(x: 0, y: 0, width: 300, height: 300))
        w.writes = [:]
        let drag = WindowDragger(displays: d, windows: w)
        let p = FakeDragPresenter()
        drag.presenter = p
        return (d, drag, w, p)
    }

    func order(_ d: StripDisplays, _ id: String = "A") -> [[String]] {
        d.engines[id]!.strip.columns.map(\.windows)
    }

    @Test func pressingOffEveryWindowLetsTheClickThrough() {
        let (_, drag, _, _) = make()
        #expect(!drag.press(at: at(1500, 300)))
        #expect(!drag.isActive)
    }

    @Test func aDropInAGapMovesTheColumnAndWritesOnlyOnRelease() {
        let (d, drag, w, p) = make()
        #expect(drag.press(at: at(700, 300)))
        drag.move(to: at(702, 301))
        #expect(p.shown.isEmpty) // still under the drag threshold
        drag.move(to: at(60, 300))
        #expect(drag.target == .newColumn(0))
        // The picture keeps its full size; the slot is where the window will be.
        #expect(p.shown.last?.picture == Rect(x: -140, y: 0, width: 500, height: 600))
        #expect(p.shown.last?.slot == Rect(x: 0, y: 0, width: 500, height: 600))
        #expect(w.writes.isEmpty)
        drag.release(at: at(60, 300))
        #expect(order(d) == [["y"], ["x"]])
        #expect(d.engines["A"]!.strip.focusedWindow == "y")
        #expect(w.writes["y"] == [Rect(x: 0, y: 0, width: 500, height: 600)])
        #expect(p.hidden == 1)
        #expect(!drag.isActive)
    }

    @Test func theOtherPicturesMakeRoomAndTheWindowsLandThere() {
        let (d, drag, w, _) = make()
        let pictures = FakePresenter()
        d.engines["A"]!.presenter = pictures
        drag.press(at: at(700, 300))
        drag.move(to: at(60, 300))
        // First the strip without the dragged window, then x moved aside for it.
        #expect(pictures.previews.first?.keys.sorted() == ["x"])
        #expect(pictures.previews.last == ["x": Rect(x: 500, y: 0, width: 500, height: 600)])
        drag.release(at: at(60, 300))
        #expect(pictures.begun.last?.moves["y"]?.from == Rect(x: -140, y: 0, width: 500, height: 600))
        #expect(w.writes["x"]?.last == pictures.previews.last?["x"])
    }

    @Test func zonesFollowThePicturesOnScreen() {
        let (_, drag, _, p) = make()
        drag.press(at: at(700, 300))
        drag.move(to: at(60, 300))
        // y's slot opened at the left, so x now shows at 500…1000.
        #expect(p.shown.last?.slot == Rect(x: 0, y: 0, width: 500, height: 600))
        // Over x's left half as it shows now: still before x. By the old frames this was y's own place.
        drag.move(to: at(560, 300))
        #expect(drag.target == .newColumn(0))
        #expect(p.shown.last?.slot == Rect(x: 0, y: 0, width: 500, height: 600))
        // Over x's right half: after x, which puts y back.
        drag.move(to: at(900, 300))
        #expect(drag.target == .newColumn(2))
        #expect(p.shown.last?.slot == Rect(x: 500, y: 0, width: 500, height: 600))
    }

    @Test func nearTheEdgeTheStripScrollsUntilItsEnd() {
        let (d, drag, w, _) = make()
        w.focusedWindow = "y"
        d.windowFocused("y")
        d.windowAdded("z", frame: Rect(x: 0, y: 0, width: 300, height: 300))
        #expect(order(d) == [["x"], ["y"], ["z"]])
        let pictures = FakePresenter()
        d.engines["A"]!.presenter = pictures
        let clock = TestClock()
        drag.clock = clock
        drag.press(at: at(250, 300))
        drag.move(to: at(990, 300))
        clock.advance(by: 0.1)
        let y = pictures.previews.last?["y"]?.x ?? 500
        #expect(y < 450 && y > 350)
        clock.advance(by: 2)
        // Scrolled to the end, 500 points on, where x's gap opened after z.
        #expect(pictures.previews.last?["y"]?.x == -500)
        #expect(pictures.previews.last?["z"]?.x == 0)
        drag.release(at: at(990, 300))
        #expect(order(d) == [["y"], ["z"], ["x"]])
        #expect(d.engines["A"]!.strip.scroll == 500)
    }

    @Test func theGapOpensOnlyOnceATargetHolds() {
        let (d, drag, _, _) = make()
        let pictures = FakePresenter()
        d.engines["A"]!.presenter = pictures
        let clock = TestClock()
        drag.clock = clock
        drag.press(at: at(700, 300))
        drag.move(to: at(60, 300))
        #expect(pictures.previews.count == 1)
        clock.advance(by: 0.15)
        #expect(pictures.previews.count == 2)
    }

    @Test(.disabled(stackingOff)) func stackingWaitsForTheHold() {
        let (d, drag, _, p) = make()
        let clock = TestClock()
        drag.clock = clock
        drag.style = stacking
        drag.press(at: at(250, 300))
        drag.move(to: at(750, 100))
        #expect(drag.target == nil)
        #expect(p.shown.last?.slot == nil)
        clock.advance(by: 0.25)
        #expect(drag.target == .stack(column: 1, row: 0))
        // x's own column closes, so the stack it joins moves to the left edge.
        #expect(p.shown.last?.slot == Rect(x: 0, y: 0, width: 500, height: 300))
        drag.release(at: at(750, 100))
        #expect(order(d) == [["x", "y"]])
    }

    @Test func releasedFarFromTheStripTheWindowGoesBack() {
        let (d, drag, w, _) = make()
        drag.press(at: at(700, 300))
        drag.move(to: at(700, 900))
        #expect(drag.target == nil)
        drag.release(at: at(700, 900))
        #expect(order(d) == [["x"], ["y"]])
        #expect(w.writes["y"] == [Rect(x: 500, y: 0, width: 500, height: 600)])
    }

    @Test func escapeCancels() {
        let (d, drag, w, p) = make()
        let pictures = FakePresenter()
        d.engines["A"]!.presenter = pictures
        drag.press(at: at(700, 300))
        drag.move(to: at(60, 300))
        drag.cancel()
        #expect(order(d) == [["x"], ["y"]])
        // The pictures move back before the drag ends.
        #expect(pictures.previews.last == ["x": Rect(x: 0, y: 0, width: 500, height: 600)])
        #expect(w.writes["x"] == nil)
        #expect(p.hidden == 1)
        #expect(!drag.isActive)
    }

    @Test func aWindowClosedDuringItsDragStaysGoneAfterTheDrop() {
        let (d, drag, _, p) = make()
        drag.press(at: at(700, 300))
        drag.move(to: at(60, 300))
        d.windowRemoved("y")
        drag.windowRemoved("y")
        #expect(!drag.isActive)
        #expect(p.hidden == 1)
        drag.release(at: at(60, 300))
        #expect(order(d) == [["x"]])
    }

    @Test func aWindowClosedWhileDraggedToAnotherDisplayDoesNotLandThere() {
        let (d, drag, _, _) = make()
        drag.press(at: at(700, 300))
        drag.move(to: at(1500, 300))
        d.windowRemoved("y")
        drag.windowRemoved("y")
        drag.release(at: at(1500, 300))
        #expect(order(d) == [["x"]])
        #expect(order(d, "B").isEmpty)
    }

    @Test func anEngineDropsAWindowRemovedDuringItsDrag() {
        let (d, _, _, _) = make()
        let e = d.engines["A"]!
        e.beginDrag("y")
        e.previewDrop("y", at: .newColumn(0), width: 0.5, leaving: false)
        e.windowRemoved("y")
        e.endDrag(from: Rect(x: 100, y: 100, width: 400, height: 400))
        #expect(order(d) == [["x"]])
    }

    @Test func aDropOnAnotherDisplayMovesTheWindowThere() {
        let (d, drag, w, p) = make()
        drag.press(at: at(700, 300))
        drag.move(to: at(1500, 300))
        #expect(p.shown.last?.slot == Rect(x: 1000, y: 0, width: 500, height: 600))
        drag.release(at: at(1500, 300))
        #expect(order(d) == [["x"]])
        #expect(order(d, "B") == [["y"]])
        #expect(w.focusedWindow == "y")
        #expect(w.writes["y"]?.last?.x == 1000)
    }

    @Test func aPressWithoutADragFocusesTheWindow() {
        let (d, drag, w, p) = make()
        drag.press(at: at(700, 300))
        drag.release(at: at(701, 300))
        #expect(w.focusedWindow == "y")
        #expect(d.engines["A"]!.strip.focusedWindow == "y")
        #expect(p.shown.isEmpty)
    }

    @Test func aFloatingWindowsPictureMovesAndTheWindowStaysWhereItIsDropped() {
        let (d, drag, w, p) = make()
        w.frames["f"] = Rect(x: 100, y: 100, width: 200, height: 200)
        d.windowAdded("f", frame: w.frames["f"], floating: true)
        #expect(drag.press(at: at(150, 150)))
        drag.move(to: at(450, 350))
        #expect(p.shown.last?.picture == Rect(x: 400, y: 300, width: 200, height: 200))
        #expect(p.shown.last?.slot == nil)
        #expect(w.writes["f"] == nil)
        drag.release(at: at(450, 350))
        #expect(w.frames["f"] == Rect(x: 400, y: 300, width: 200, height: 200))
        #expect(d.engines["A"]!.strip.floating == ["f"])
        #expect(order(d) == [["x"], ["y"]])
        #expect(w.focusedWindow == "f")
    }

    @Test func aFloatingWindowLetGoOnAnotherDisplayJoinsIt() {
        let (d, drag, w, _) = make()
        w.frames["f"] = Rect(x: 100, y: 100, width: 200, height: 200)
        d.windowAdded("f", frame: w.frames["f"], floating: true)
        drag.press(at: at(150, 150))
        drag.move(to: at(1450, 150))
        drag.release(at: at(1450, 150))
        #expect(d.engines["A"]!.strip.floating.isEmpty)
        #expect(d.engines["B"]!.strip.floating == ["f"])
    }
}
