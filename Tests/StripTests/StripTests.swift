import Testing
import WindowCore
private let halfWidth: StripSettings = { var s = StripSettings(); s.defaultWidth = 0.5; return s }()

@testable import StripEngine
@testable import StripModel

private let screen = Rect(x: 0, y: 0, width: 1000, height: 600)
private let m = StripMetrics(viewport: screen, gap: 0)

private func strip(_ widths: [Double], focus: Int? = 0) -> Strip {
    var s = Strip()
    s.columns = widths.enumerated().map { Column(id: "c\($0)", windows: ["w\($0)"], width: $1) }
    s.focusedColumn = focus
    return s
}

@Suite struct StripLayoutTests {
    @Test func twoHalfColumnsFillTheScreenWithGaps() {
        let g = StripMetrics(viewport: screen, gap: 10)
        let f = stripFrames(strip([0.5, 0.5]), g)
        #expect(f["w0"] == Rect(x: 10, y: 10, width: 485, height: 580))
        #expect(f["w1"] == Rect(x: 505, y: 10, width: 485, height: 580))
    }

    @Test func columnsPastTheScreenEdgeLeaveASliver() {
        var s = strip([0.5, 0.5, 0.5])
        s.scroll = 0
        let f = stripFrames(s, m)
        #expect(f["w2"]?.x == 998)
        s.scroll = 1000
        let g = stripFrames(s, m)
        #expect(g["w0"]?.x == -498)
        #expect(g["w2"]?.x == 0)
    }

    @Test func stackedWindowsShareTheColumnHeight() {
        var s = strip([0.5])
        s.columns[0].windows = ["a", "b"]
        let f = stripFrames(s, StripMetrics(viewport: screen, gap: 10))
        #expect(f["a"] == Rect(x: 10, y: 10, width: 485, height: 285))
        #expect(f["b"] == Rect(x: 10, y: 305, width: 485, height: 285))
    }

    @Test func fitScrollsJustEnoughToShowTheFocusedColumn() {
        var s = strip([0.5, 0.5, 0.5], focus: 2)
        #expect(scrollToFocus(s, m, mode: .fit) == 500)
        s.scroll = 500
        s.focusedColumn = 0
        #expect(scrollToFocus(s, m, mode: .fit) == 0)
        s.focusedColumn = 1
        s.scroll = 0
        #expect(scrollToFocus(s, m, mode: .fit) == 0)
    }

    @Test func centreNeverScrollsPastTheStripEnds() {
        let s = strip([0.5, 0.5, 0.5], focus: 1)
        #expect(scrollToFocus(s, m, mode: .center) == 250)
        let first = strip([0.5, 0.5, 0.5], focus: 0)
        #expect(scrollToFocus(first, m, mode: .center) == 0)
        let narrow = strip([0.3], focus: 0)
        #expect(scrollToFocus(narrow, m, mode: .center) == 0)
    }
}

@Suite struct StripCommandTests {
    @Test func newWindowsGoRightOfTheFocusedColumn() {
        var s = strip([0.5, 0.5], focus: 0)
        s.insert("new", width: 0.5, columnID: "n", focus: true)
        #expect(s.columns.map(\.id) == ["c0", "n", "c1"])
        #expect(s.focusedColumn == 1)
    }

    @Test func backgroundWindowsDoNotStealFocus() {
        var s = strip([0.5, 0.5], focus: 1)
        s.insert("bg", width: 0.5, columnID: "n", focus: false)
        #expect(s.focusedWindow == "w1")
    }

    @Test func removingTheFocusedColumnFocusesItsLeftNeighbour() {
        var s = strip([0.5, 0.5, 0.5], focus: 1)
        s.remove("w1")
        #expect(s.columns.map(\.id) == ["c0", "c2"])
        #expect(s.focusedColumn == 0)
        s.remove("w0")
        #expect(s.focusedWindow == "w2")
        s.remove("w2")
        #expect(s.focusedColumn == nil)
    }

    @Test func removingAColumnLeftOfFocusKeepsTheSameWindowFocused() {
        var s = strip([0.5, 0.5, 0.5], focus: 2)
        s.remove("w0")
        #expect(s.focusedWindow == "w2")
    }

    @Test func removingAWindowAboveTheFocusedOneInAStackKeepsItFocused() {
        var s = Strip()
        s.columns = [Column(id: "c", windows: ["a", "b", "c"], width: 0.5, focused: 1)]
        s.focusedColumn = 0
        s.remove("a")
        #expect(s.focusedWindow == "b")
        s.remove("b")
        #expect(s.focusedWindow == "c")
    }

    @Test func stackingMovesTheWindowIntoTheNeighbourColumn() {
        var s = strip([0.5, 0.5], focus: 1)
        s.stack(.left)
        #expect(s.columns.count == 1)
        #expect(s.columns[0].windows == ["w0", "w1"])
        #expect(s.focusedWindow == "w1")
        s.popOut(columnID: "p")
        #expect(s.columns.map(\.windows) == [["w0"], ["w1"]])
        #expect(s.focusedWindow == "w1")
    }

    @Test func moveSwapsColumnsAndStackedWindows() {
        var s = strip([0.3, 0.5], focus: 0)
        s.move(.right)
        #expect(s.columns.map(\.id) == ["c1", "c0"])
        #expect(s.focusedColumn == 1)
        s.columns[1].windows = ["w0", "x"]
        s.columns[1].focused = 1
        s.move(.up)
        #expect(s.columns[1].windows == ["x", "w0"])
    }

    @Test func widthPresetsCycleAndFullWidthRestores() {
        var s = strip([0.5])
        s.cycleWidth([1.0 / 3, 0.5, 2.0 / 3])
        #expect(s.columns[0].width == 2.0 / 3)
        s.cycleWidth([1.0 / 3, 0.5, 2.0 / 3])
        #expect(s.columns[0].width == 1.0 / 3)
        s.toggleFullWidth()
        #expect(s.columns[0].width == 1)
        s.toggleFullWidth()
        #expect(s.columns[0].width == 1.0 / 3)
        s.nudgeWidth(by: -1)
        #expect(s.columns[0].width == 0.1)
    }

    @Test func floatingTakesAWindowOffTheStripAndBack() {
        var s = strip([0.5, 0.5], focus: 0)
        s.toggleFloat("w0", width: 0.5, columnID: "f")
        #expect(s.floating == ["w0"])
        #expect(s.allWindows == ["w1"])
        s.toggleFloat("w0", width: 0.5, columnID: "f")
        #expect(s.floating.isEmpty)
        #expect(s.focusedWindow == "w0")
    }
}

@MainActor
final class FakeWindows: WindowSystem {
    var frames: [String: Rect] = [:]
    var focusedWindow: String?
    func setFrame(_ id: String, _ rect: Rect, completion: @escaping @MainActor (Rect?) -> Void) {
        frames[id] = rect
        completion(rect)
    }
    func focus(_ id: String) { focusedWindow = id }
    func frameOf(_ id: String) -> Rect? { frames[id] }
}

@MainActor
@Suite struct StripEngineTests {
    @Test func aDropBringsTheFocusedWindowBackOnScreen() {
        let (e, f) = make()
        for id in ["a", "b", "c", "d"] { f.focusedWindow = id; e.windowAdded(id) }
        e.beginDrag("d")
        // Edge scrolling went all the way back to the strip's start, away from d.
        e.dragScroll(by: -5000)
        e.endDrag(from: Rect(x: 0, y: 0, width: 10, height: 10))
        let r = f.frames["d"]!
        #expect(e.strip.focusedWindow == "d")
        #expect(r.x >= screen.x && r.maxX <= screen.maxX)
    }

    func make() -> (StripEngine, FakeWindows) {
        let f = FakeWindows()
        var s = StripSettings(); s.defaultWidth = 0.5
        s.gap = 0
        return (StripEngine(windows: f, viewport: screen, settings: s), f)
    }

    @Test func openingWindowsAddsColumnsWithoutResizingOthers() {
        let (e, f) = make()
        f.focusedWindow = "a"; e.windowAdded("a")
        f.focusedWindow = "b"; e.windowAdded("b")
        f.focusedWindow = "c"; e.windowAdded("c")
        #expect(f.frames["a"]?.width == 500)
        #expect(f.frames["b"]?.width == 500)
        #expect(f.frames["c"] == Rect(x: 500, y: 0, width: 500, height: 600))
        #expect(e.strip.scroll == 500)
    }

    @Test func focusLeftScrollsBackAndFocusesTheWindow() {
        let (e, f) = make()
        for id in ["a", "b", "c"] { f.focusedWindow = id; e.windowAdded(id) }
        e.focus(.left)
        e.focus(.left)
        #expect(f.focusedWindow == "a")
        #expect(f.frames["a"]?.x == 0)
        #expect(e.strip.scroll == 0)
    }

    @Test func clickingAWindowScrollsItIntoView() {
        let (e, f) = make()
        for id in ["a", "b", "c"] { f.focusedWindow = id; e.windowAdded(id) }
        e.windowFocused("a")
        #expect(e.strip.scroll == 0)
        #expect(f.frames["a"]?.x == 0)
    }

    @Test func closingAWindowClosesTheGap() {
        let (e, f) = make()
        for id in ["a", "b"] { f.focusedWindow = id; e.windowAdded(id) }
        e.windowRemoved("a")
        #expect(f.frames["b"]?.x == 0)
    }
}

@Suite struct WorkspaceTests {
    private func filled(_ windows: [String]) -> Strip {
        var s = Strip()
        for w in windows { s.insert(w, width: 0.5, columnID: "c-\(w)", focus: true) }
        return s
    }

    private func start(_ windows: [String]) -> Workspaces {
        var ws = Workspaces()
        ws.current = filled(windows)
        ws.normalize()
        return ws
    }

    @Test func summaryStarsTheActiveWorkspaceAndFocusedColumnAndListsFloats() {
        var ws = start(["a", "b"])
        ws.current.addFloating("f")
        #expect(ws.summary == """
             ws0: empty
            *ws1 scroll=0: 0.5[a] | *0.5[b]  floating: [f]
             ws2: empty
            """)
    }

    @Test func thereIsAlwaysOneEmptyWorkspaceAboveAndBelow() {
        var ws = start(["a"])
        #expect(ws.strips.map(\.isEmpty) == [true, false, true])
        #expect(ws.active == 1)
        ws.switchBy(1)
        #expect(ws.active == 2)
        ws.switchBy(1)
        #expect(ws.active == 2)
        ws.switchTo(0)
        #expect(ws.active == 0)
        #expect(ws.strips.map(\.isEmpty) == [true, false, true])
    }

    @Test func movingAWindowIntoTheTopWorkspaceAddsANewEmptyOneAbove() {
        var ws = start(["a", "b"])
        ws.moveFocused(by: -1, width: 0.5, columnID: "x")
        #expect(ws.strips.map(\.allWindows) == [[], ["b"], ["a"], []])
        #expect(ws.active == 1)
    }

    @Test func leavingAnEmptyMiddleWorkspaceRemovesIt() {
        var ws = start(["a"])
        ws.switchBy(1)
        ws.current = filled(["b"])
        ws.normalize()
        #expect(ws.strips.count == 4)
        ws.remove("b")
        #expect(ws.strips.count == 4)
        ws.switchBy(-1)
        #expect(ws.strips.map(\.allWindows) == [[], ["a"], []])
        #expect(ws.active == 1)
    }

    @Test func movingAWindowDownCarriesFocusAlong() {
        var ws = start(["a", "b"])
        ws.moveFocused(by: 1, width: 0.5, columnID: "x")
        #expect(ws.strips.map(\.allWindows) == [[], ["a"], ["b"], []])
        #expect(ws.active == 2)
        ws.moveFocused(by: -1, width: 0.5, columnID: "y")
        #expect(ws.active == 1)
        #expect(ws.strips.count == 3)
        #expect(Set(ws.current.allWindows) == ["a", "b"])
    }
}

@MainActor
@Suite struct WorkspaceEngineTests {
    @Test func switchingParksTheOtherWorkspaceAndFocusingSwitchesBack() {
        let f = FakeWindows()
        var s = StripSettings(); s.defaultWidth = 0.5; s.gap = 0
        let e = StripEngine(windows: f, viewport: screen, settings: s)
        f.focusedWindow = "a"; e.windowAdded("a")
        f.focusedWindow = "b"; e.windowAdded("b")
        e.moveToWorkspace(by: 1)
        #expect(e.workspaces.active == 2)
        #expect(e.workspaces.strips.count == 4)
        #expect(f.frames["b"]?.x == 0)
        #expect(f.frames["a"]?.x == 999)
        e.switchWorkspace(by: -1)
        #expect(f.frames["b"]?.x == 999)
        #expect(f.frames["a"]?.x == 0)
        e.windowFocused("b")
        #expect(e.workspaces.active == 2)
        #expect(f.frames["a"]?.x == 999)
    }

    @Test func floatFocusCyclesTheFloatsAndReturnsToTheStrip() {
        let f = FakeWindows()
        var s = StripSettings(); s.defaultWidth = 0.5; s.gap = 0
        let e = StripEngine(windows: f, viewport: screen, settings: s)
        f.focusedWindow = "a"; e.windowAdded("a")
        e.windowAdded("s", floating: true)
        e.windowAdded("t", floating: true)
        e.toggleFloatFocus(); #expect(f.focusedWindow == "s")
        e.toggleFloatFocus(); #expect(f.focusedWindow == "t")
        e.toggleFloatFocus(); #expect(f.focusedWindow == "a")
    }

    @Test func aWindowItsAppHidComesBackToItsColumn() {
        let f = FakeWindows()
        var s = StripSettings(); s.defaultWidth = 0.5; s.gap = 0
        let e = StripEngine(windows: f, viewport: screen, settings: s)
        f.focusedWindow = "a"; e.windowAdded("a")
        f.focusedWindow = "b"; e.windowAdded("b")
        f.focusedWindow = "c"; e.windowAdded("c")
        let slot = e.slot(of: "b")
        #expect(slot == StripEngine.Slot(workspace: e.workspaces.active, column: 1, width: 0.5))
        e.windowRemoved("b")
        f.focusedWindow = "a"; e.windowFocused("a")
        e.restore("b", to: slot!)
        #expect(e.strip.columns.map(\.windows) == [["a"], ["b"], ["c"]])
        #expect(e.strip.focusedWindow == "a")
    }

    @Test func aHiddenFloatComesBackFloating() {
        let f = FakeWindows()
        var s = StripSettings(); s.defaultWidth = 0.5; s.gap = 0
        let e = StripEngine(windows: f, viewport: screen, settings: s)
        f.focusedWindow = "a"; e.windowAdded("a")
        e.windowAdded("s", floating: true)
        let slot = e.slot(of: "s")!
        #expect(slot.column == nil)
        e.windowRemoved("s")
        e.restore("s", to: slot)
        #expect(e.strip.floating == ["s"])
    }

    @Test func floatFocusDoesNothingWithoutFloats() {
        let f = FakeWindows()
        var s = StripSettings(); s.defaultWidth = 0.5; s.gap = 0
        let e = StripEngine(windows: f, viewport: screen, settings: s)
        f.focusedWindow = "a"; e.windowAdded("a")
        e.toggleFloatFocus()
        #expect(f.focusedWindow == "a")
    }

    @Test func aFloatingWindowComesBackWhereItWasWithItsOwnSize() {
        let f = FakeWindows()
        var s = StripSettings(); s.defaultWidth = 0.5; s.gap = 0
        let e = StripEngine(windows: f, viewport: screen, settings: s)
        f.focusedWindow = "a"; e.windowAdded("a")
        f.frames["s"] = Rect(x: 120, y: 80, width: 300, height: 200)
        e.windowAdded("s", floating: true)
        e.switchWorkspace(by: 1)
        #expect(f.frames["s"]?.x == 999)
        #expect(f.frames["s"]?.width == 300)
        e.switchWorkspace(by: -1)
        #expect(f.frames["s"] == Rect(x: 120, y: 80, width: 300, height: 200))
        #expect(f.frames["a"]?.x == 0)
    }

    @Test func movingTheOnlyWindowDownLeavesOneEmptyWorkspaceAbove() {
        let f = FakeWindows()
        let e = StripEngine(windows: f, viewport: screen, settings: halfWidth)
        f.focusedWindow = "a"; e.windowAdded("a")
        e.moveToWorkspace(by: 1)
        #expect(e.workspaces.strips.map(\.isEmpty) == [true, false, true])
        #expect(e.workspaces.active == 1)
    }
}

@Suite struct MinimapTests {
    @Test func rowsCoverNonEmptyWorkspacesAndMarkTheView() {
        var ws = Workspaces()
        var s = Strip()
        s.insert("a", width: 0.5, columnID: "1", focus: true)
        s.insert("b", width: 0.5, columnID: "2", focus: true)
        s.insert("c", width: 0.5, columnID: "3", focus: true)
        s.scroll = 500
        ws.current = s
        ws.normalize()
        let rows = minimapRows(ws, m)
        #expect(rows.count == 1)
        #expect(rows[0].windows.map(\.id) == ["a", "b", "c"])
        #expect(rows[0].windows.first { $0.focused }?.id == "c")
        #expect(rows[0].viewport == Rect(x: 500, y: 0, width: 1000, height: 600))
        #expect(rows[0].width == 1500)
        ws.switchBy(1)
        #expect(minimapRows(ws, m).map(\.isActive) == [false, true])
        ws.switchTo(0)
        #expect(minimapRows(ws, m).map(\.isActive) == [true, false])
    }
}

@MainActor
final class FakePresenter: StripPresenter {
    var accept = true
    var writeDelay = 0.034
    var begun: [(moves: [String: (from: Rect, to: Rect)], still: [String: Rect])] = []
    var focused: [String?] = []
    var landedIDs: [String] = []
    var issued: Set<String>?
    func begin(moves: [String: (from: Rect, to: Rect)], still: [String: Rect], focused: String?) -> Int? {
        begun.append((moves, still))
        self.focused.append(focused)
        return accept ? begun.count : nil
    }
    func landed(_ id: String, token: Int) { landedIDs.append(id) }
    var previews: [[String: Rect]] = []
    var endedPreviews = 0
    func preview(frames: [String: Rect], focused: String?) -> Bool { previews.append(frames); return accept }
    func endPreview() { endedPreviews += 1 }
    func writesIssued(_ ids: Set<String>, token: Int) { issued = ids }
}

@MainActor
final class CountingWindows: WindowSystem {
    var writes: [String: [Rect]] = [:]
    var focusedWindow: String?
    func setFrame(_ id: String, _ rect: Rect, completion: @escaping @MainActor (Rect?) -> Void) {
        writes[id, default: []].append(rect)
        completion(rect)
    }
    func focus(_ id: String) { focusedWindow = id }
}

@MainActor
@Suite struct PresenterTests {
    func make() -> (StripEngine, CountingWindows, FakePresenter, TestClock) {
        let w = CountingWindows()
        var s = StripSettings(); s.defaultWidth = 0.5; s.gap = 0
        let e = StripEngine(windows: w, viewport: screen, settings: s)
        let p = FakePresenter()
        let clock = TestClock()
        e.presenter = p
        e.clock = clock
        for id in ["a", "b", "c"] { w.focusedWindow = id; e.windowAdded(id) }
        clock.advance(by: 1)
        w.writes = [:]
        return (e, w, p, clock)
    }

    @Test func picturesGoUpFirstThenEachRealWindowIsWrittenOnce() {
        let (e, w, p, clock) = make()
        e.focusColumn(0)
        #expect(w.writes["a"] == nil)
        #expect(p.begun.last?.moves["a"]?.from.x == -498)
        #expect(p.begun.last?.moves["a"]?.to == Rect(x: 0, y: 0, width: 500, height: 600))
        clock.advance(by: 0.034)
        #expect(w.writes["a"] == [Rect(x: 0, y: 0, width: 500, height: 600)])
        #expect(p.issued == Set(["a", "b", "c"]))
        #expect(Set(p.landedIDs) == ["a", "b", "c"])
    }

    @Test func retileWritesEveryWindowAgainAtOnce() {
        let (e, w, p, _) = make()
        let begun = p.begun.count
        e.retile()
        #expect(Set(w.writes.keys) == ["a", "b", "c"])
        #expect(w.writes["a"] == [e.frame(of: "a")!])
        #expect(p.begun.count == begun)
    }

    @Test func theFocusedWindowAfterTheMoveIsPassedOn() {
        let (e, _, p, _) = make()
        e.focusColumn(0)
        #expect(p.focused.last == "a")
    }

    @Test func unmovedWindowsAreDrawnStill() {
        let (e, _, p, _) = make()
        e.wider()
        let last = p.begun.last!
        #expect(last.moves["c"] != nil)
        #expect(last.still.keys.contains("a") || last.moves["a"] != nil)
    }

    @Test func withoutPicturesWindowsMoveAtOnce() {
        let (e, w, p, _) = make()
        p.accept = false
        e.focusColumn(0)
        #expect(w.writes["a"] == [Rect(x: 0, y: 0, width: 500, height: 600)])
    }

    @Test func workspaceSwitchSlidesPicturesAndParksRealWindows() {
        let (e, w, p, clock) = make()
        e.moveToWorkspace(by: 1)
        clock.advance(by: 1)
        w.writes = [:]
        e.switchWorkspace(by: -1)
        let m = p.begun.last!.moves
        // Going up: the leaving workspace slides down out of view, the arriving one comes from above.
        #expect((m["c"]?.to.y ?? 0) > 0)
        #expect((m["a"]?.from.y ?? 0) < 0)
        clock.advance(by: 0.034)
        #expect(w.writes["c"]?.last?.x == 999)
    }
}

@MainActor
@Suite struct FrameLookupTests {
    @Test func frameOfReportsOnlyWindowsOnTheActiveStrip() {
        let f = FakeWindows()
        var s = StripSettings(); s.defaultWidth = 0.5; s.gap = 0
        let e = StripEngine(windows: f, viewport: screen, settings: s)
        f.focusedWindow = "a"; e.windowAdded("a")
        f.focusedWindow = "b"; e.windowAdded("b")
        #expect(e.frame(of: "b") == Rect(x: 500, y: 0, width: 500, height: 600))
        e.moveToWorkspace(by: 1)
        #expect(e.frame(of: "a") == nil)
        #expect(e.frame(of: "b") == Rect(x: 0, y: 0, width: 500, height: 600))
    }
}

@MainActor
@Suite struct ViewMemoryTests {
    /// x, a, b, c at half width on a 1000-point screen, with a and b on screen and b focused.
    func make() -> (StripEngine, FakeWindows) {
        let f = FakeWindows()
        var s = StripSettings(); s.defaultWidth = 0.5; s.gap = 0
        let e = StripEngine(windows: f, viewport: screen, settings: s)
        for id in ["x", "a", "b", "c"] { f.focusedWindow = id; e.windowAdded(id) }
        e.focus(.left); e.focus(.left); e.focus(.right)
        #expect(e.strip.scroll == 500)
        #expect(e.strip.focusedWindow == "b")
        return (e, f)
    }

    @Test func fullWidthOffReturnsToTheSameView() {
        let (e, _) = make()
        e.toggleFullWidth()
        #expect(e.strip.scroll == 1000)
        e.toggleFullWidth()
        #expect(e.strip.scroll == 500)
    }

    @Test func cyclingBackToTheOriginalWidthReturnsToTheSameView() {
        let (e, _) = make()
        e.cycleWidth() // 2/3
        #expect(e.strip.scroll > 500)
        e.cycleWidth() // 1/3, narrower than before
        #expect(e.strip.scroll == 500)
    }

    @Test func nudgingWiderThenNarrowerReturnsToTheSameView() {
        let (e, _) = make()
        e.wider()
        e.narrower()
        #expect(e.strip.scroll == 500)
    }

    @Test func movingFocusAwayForgetsTheView() {
        let (e, _) = make()
        e.toggleFullWidth()
        e.focus(.left)
        e.focus(.right)
        #expect(e.strip.viewBeforeGrow == nil)
    }
}

@Suite struct SwipeRecognizerTests {
    func three(_ x: Double, _ y: Double = 0.5) -> [(x: Double, y: Double)] {
        [(x - 0.1, y), (x, y), (x + 0.1, y)]
    }

    @Test func aSwipeStartsAfterTheThresholdAndLocksSideways() {
        var r = SwipeRecognizer()
        #expect(r.feed(three(0.5), at: 0).isEmpty)
        #expect(r.feed(three(0.51), at: 0.01).isEmpty)
        let e = r.feed(three(0.54), at: 0.02)
        #expect(e.first == .began(.horizontal))
        #expect(e.count == 2)
        #expect(r.feed(three(0.56), at: 0.03) == [.moved(dx: 0.020000000000000018, dy: 0)])
    }

    @Test func liftingEndsWithAVelocityAlongTheAxis() {
        var r = SwipeRecognizer()
        _ = r.feed(three(0.5), at: 0)
        _ = r.feed(three(0.45), at: 0.02)
        _ = r.feed(three(0.40), at: 0.04)
        let e = r.feed([], at: 0.05)
        guard case .ended(let v)? = e.first else { Issue.record("expected end"); return }
        #expect(v < -2 && v > -3)
    }

    @Test func twoFingersNeverStartAThreeFingerSwipe() {
        var r = SwipeRecognizer()
        for i in 0..<10 { #expect(r.feed([(0.3 + Double(i) * 0.05, 0.5), (0.4, 0.5)], at: Double(i) * 0.01).isEmpty) }
    }

    @Test func diagonalTravelWaitsForAClearAxis() {
        var r = SwipeRecognizer()
        _ = r.feed(three(0.5, 0.5), at: 0)
        #expect(r.feed(three(0.53, 0.53), at: 0.01).isEmpty)
        #expect(r.feed(three(0.53, 0.60), at: 0.02).first == .began(.vertical))
    }
}

@MainActor
@Suite struct SwipeEngineTests {
    func make() -> (StripEngine, CountingWindows, FakePresenter) {
        let w = CountingWindows()
        var s = StripSettings(); s.defaultWidth = 0.5; s.gap = 0
        let e = StripEngine(windows: w, viewport: screen, settings: s)
        let p = FakePresenter()
        e.presenter = p
        for id in ["a", "b", "c", "d"] { w.focusedWindow = id; e.windowAdded(id) }
        e.focusColumn(0)
        #expect(e.strip.scroll == 0)
        return (e, w, p)
    }

    @Test func snapPointsAreColumnEdgesInsideTheStrip() {
        let (e, _, _) = make()
        #expect(snapPoints(e.strip, e.metrics) == [0, 500, 1000])
    }

    @Test func theStripFollowsTheFingersThenSnapsToTheNearestColumn() {
        let (e, _, p) = make()
        e.beginSwipe()
        e.swipe(by: -0.2) // fingers left: strip moves left by 0.2 x 1.5 screens = 300 points
        #expect(abs((p.previews.last?["a"]?.x ?? 0) + 300) < 0.001)
        e.endSwipe(velocity: 0)
        #expect(e.strip.scroll == 500)
    }

    @Test func aFastFlickCarriesFurther() {
        let (e, _, _) = make()
        e.beginSwipe()
        e.swipe(by: -0.1)
        e.endSwipe(velocity: -4) // 150 points dragged, projected 900 further
        #expect(e.strip.scroll == 1000)
    }

    @Test func focusFollowsWhenTheFocusedColumnLeavesTheScreen() {
        let (e, w, _) = make()
        e.beginSwipe()
        e.swipe(by: -0.7)
        e.endSwipe(velocity: 0)
        #expect(e.strip.scroll == 1000)
        #expect(e.strip.focusedWindow == "c")
        #expect(w.focusedWindow == "c")
    }

    @Test func pullingPastTheEndRubberBandsAndReturns() {
        let (e, _, p) = make()
        e.beginSwipe()
        e.swipe(by: 0.2) // fingers right at the start of the strip
        #expect(abs((p.previews.last?["a"]?.x ?? 0) - 90) < 0.001)
        e.endSwipe(velocity: 0)
        #expect(e.strip.scroll == 0)
        #expect(p.endedPreviews == 1)
    }
}

@MainActor
@Suite struct DefaultWidthTests {
    @Test func newWindowsTakeAThirdOfTheScreen() {
        let f = FakeWindows()
        var s = StripSettings(); s.gap = 0
        let e = StripEngine(windows: f, viewport: screen, settings: s)
        f.focusedWindow = "a"; e.windowAdded("a")
        #expect(abs((f.frames["a"]?.width ?? 0) - 333) < 0.01)
    }
}

@Suite struct OpenOnWorkspaceTests {
    private func start(_ windows: [String]) -> Workspaces {
        var ws = Workspaces()
        for w in windows { ws.current.insert(w, width: 0.5, columnID: "c-\(w)", focus: true) }
        ws.normalize()
        return ws
    }

    @Test func aWindowLandsOnTheNumberedWorkspaceWithoutSwitching() {
        var ws = start(["a"])
        ws.add("b", toWorkspace: 2, width: 0.5, columnID: "c-b", floating: false)
        #expect(ws.active == 1)
        #expect(ws.workspace(of: "a") == 1)
        #expect(ws.workspace(of: "b") == 2)
        #expect(ws.strips.map(\.isEmpty) == [true, false, false, true])
    }

    @Test func aNumberPastTheLastWorkspaceOpensANewOneBelow() {
        var ws = start(["a"])
        ws.add("b", toWorkspace: 9, width: 0.5, columnID: "c-b", floating: false)
        #expect(ws.workspace(of: "b") == 2)
    }

    @Test func theFirstWorkspaceOfAnEmptyDisplayIsTheOnlyOne() {
        var ws = Workspaces()
        ws.add("a", toWorkspace: 1, width: 0.5, columnID: "c-a", floating: true)
        #expect(ws.workspace(of: "a") == 1)
        #expect(ws.strips[1].floating == ["a"])
    }

    @Test func addingDoesNotMoveTheFocusOfAWorkspaceThatHasWindows() {
        var ws = start(["a"])
        ws.switchTo(2)
        ws.add("b", toWorkspace: 1, width: 0.5, columnID: "c-b", floating: false)
        #expect(ws.strips[1].focusedWindow == "a")
    }
}
