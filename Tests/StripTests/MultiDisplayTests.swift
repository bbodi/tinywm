import Testing
import WindowCore
@testable import StripEngine
@testable import StripModel

private func rect(_ x: Double, _ y: Double, _ w: Double = 1000, _ h: Double = 600) -> Rect {
    Rect(x: x, y: y, width: w, height: h)
}

private func overlapsAny(_ r: Rect, _ others: [Rect]) -> Bool { others.contains { $0.overlap(r) != nil } }

@Suite struct DisplayRoutingTests {
    let side = [rect(0, 0), rect(1000, 0)]

    @Test func windowBelongsToTheDisplayHoldingItsCentre() {
        // Mostly on the second display although its left edge is on the first.
        #expect(owningDisplay(of: rect(900, 100, 800, 300), among: side) == 1)
        #expect(owningDisplay(of: rect(100, 100, 400, 300), among: side) == 0)
    }

    @Test func aWindowOffEveryDisplayGoesToTheNearest() {
        #expect(owningDisplay(of: rect(-900, 100, 400, 300), among: side) == 0)
        #expect(owningDisplay(of: rect(2500, 100, 400, 300), among: side) == 1)
        #expect(owningDisplay(of: rect(0, 0), among: []) == nil)
    }

    @Test func displaysAreOrderedLeftToRightThenTopToBottom() {
        let frames = [rect(1000, 0), rect(0, 0), rect(0, 600)]
        #expect(displayOrder(frames) == [1, 2, 0])
    }

    @Test func nextAndPreviousWrapAround() {
        #expect(adjacentDisplay(from: 0, by: 1, among: side) == 1)
        #expect(adjacentDisplay(from: 1, by: 1, among: side) == 0)
        #expect(adjacentDisplay(from: 0, by: -1, among: side) == 1)
        #expect(adjacentDisplay(from: 0, by: 1, among: [rect(0, 0)]) == 0)
    }
}

@Suite struct HideawayTests {
    let size = Size(width: 400, height: 500)

    private func park(_ screen: Rect, _ others: [Rect]) -> Rect {
        let o = Hideaway(screen: screen, others: others).parkOrigin(size: size)
        return Rect(x: o.x, y: o.y, width: size.width, height: size.height)
    }

    @Test func aLoneDisplayParksAtTheBottomRightCorner() {
        let o = Hideaway(screen: rect(0, 0)).parkOrigin(size: size)
        #expect(o == Point(x: 999, y: 599))
    }

    @Test func sideBySideDisplaysParkOnTheOuterSides() {
        let a = rect(0, 0), b = rect(1000, 0)
        let left = park(a, [b]), right = park(b, [a])
        #expect(!overlapsAny(left, [b]))
        #expect(left.maxX == 1)
        #expect(right == Rect(x: 1999, y: 599, width: 400, height: 500))
    }

    @Test func stackedDisplaysParkBesideTheStackNotBelowOrAbove() {
        let top = rect(0, 0), bottom = rect(0, 600)
        #expect(!overlapsAny(park(top, [bottom]), [bottom]))
        #expect(!overlapsAny(park(bottom, [top]), [top]))
        #expect(park(top, [bottom]).x == 999)
    }

    @Test func lShapedDisplaysAvoidEveryNeighbour() {
        // A on top left, B below it, C right of B.
        let a = rect(0, 0), b = rect(0, 600), c = rect(1000, 600)
        for (screen, others) in [(a, [b, c]), (b, [a, c]), (c, [a, b])] {
            let spot = park(screen, others)
            #expect(!overlapsAny(spot, others))
        }
        // C's bottom-right corner is free, as on a lone display.
        #expect(park(c, [a, b]).x == 1999)
    }

    @Test func columnsScrolledPastABlockedEdgeHideBeyondTheOtherEdge() {
        let screen = rect(1000, 0)
        let h = Hideaway(screen: screen, others: [rect(0, 0)])
        let r = Rect(x: 400, y: 10, width: 500, height: 580)
        let s = h.sliver(r, pastRight: false, sliver: 2)
        #expect(!overlapsAny(s, [rect(0, 0)]))
        #expect(s == Rect(x: 1998, y: 10, width: 500, height: 580))
        let free = Hideaway(screen: screen, others: [])
        #expect(free.sliver(r, pastRight: false, sliver: 2).x == 1000 - 500 + 2)
    }

    @Test func columnsBlockedOnBothSidesHangBelow() {
        let screen = rect(1000, 0)
        let h = Hideaway(screen: screen, others: [rect(0, 0), rect(2000, 0)])
        let s = h.sliver(Rect(x: 1800, y: 10, width: 500, height: 580), pastRight: true, sliver: 2)
        #expect(!overlapsAny(s, [rect(0, 0), rect(2000, 0)]))
        #expect(s.y == 598)
    }

    @Test func aColumnPeekingOntoANeighbourIsHiddenButOneOnAFreeSideIsKept() {
        var s = Strip()
        s.columns = (0..<3).map { Column(id: "c\($0)", windows: ["w\($0)"], width: 0.4) }
        s.focusedColumn = 0
        let screen = rect(1000, 0)
        let m = StripMetrics(viewport: screen, gap: 0)
        let blocked = stripFrames(s, m, hideaway: Hideaway(screen: screen, others: [rect(2000, 0)]))
        #expect(blocked["w2"].map { !overlapsAny($0, [rect(2000, 0)]) } == true)
        #expect(blocked["w1"] == Rect(x: 1400, y: 0, width: 400, height: 600))
        let free = stripFrames(s, m, hideaway: Hideaway(screen: screen, others: [rect(0, 0)]))
        #expect(free["w2"] == Rect(x: 1800, y: 0, width: 400, height: 600))
    }
}

@MainActor
@Suite struct StripDisplaysTests {
    final class Windows: WindowSystem {
        var frames: [String: Rect] = [:]
        var focusedWindow: String?
        func setFrame(_ id: String, _ rect: Rect, completion: @escaping @MainActor (Rect?) -> Void) {
            frames[id] = rect; completion(rect)
        }
        func focus(_ id: String) { focusedWindow = id }
    }

    let a = TiledDisplay(id: "A", frame: rect(0, 0), visible: rect(0, 0))
    let b = TiledDisplay(id: "B", frame: rect(1000, 0), visible: rect(1000, 0))

    func make(_ disabled: Set<String> = []) -> (StripDisplays, Windows) {
        let w = Windows()
        let d = StripDisplays(windows: w, disabled: disabled, configure: { _, _ in }, discard: { _ in })
        d.settings.gap = 0
        return (d, w)
    }

    @Test func eachDisplayGetsItsOwnEngine() {
        let (d, _) = make()
        d.update([a, b])
        #expect(d.engines.count == 2)
        d.windowAdded("x", frame: rect(100, 100, 300, 300))
        d.windowAdded("y", frame: rect(1100, 100, 300, 300))
        #expect(d.engines["A"]?.workspaces.workspace(of: "x") != nil)
        #expect(d.engines["B"]?.workspaces.workspace(of: "y") != nil)
        #expect(d.engines["A"]?.workspaces.workspace(of: "y") == nil)
    }

    @Test func anOpenOnRuleSendsANewWindowToTheNamedDisplayWithoutFocus() {
        let (d, w) = make()
        let left = TiledDisplay(id: "A", frame: rect(0, 0), visible: rect(0, 0), name: "Built-in Display")
        let right = TiledDisplay(id: "B", frame: rect(1000, 0), visible: rect(1000, 0), name: "LS37D80xU")
        d.update([left, right])
        d.windowAdded("x", frame: rect(100, 100, 300, 300))
        w.focusedWindow = "x"; d.windowFocused("x")
        d.newWindowAdded("z", frame: rect(100, 100, 300, 300), openOn: OpenOn(display: "ls37"))
        #expect(d.engines["B"]?.workspaces.workspace(of: "z") != nil)
        #expect(w.focusedWindow == "x")
    }

    @Test func anOpenOnRuleForAMissingDisplayLeavesTheWindowWhereItWouldGo() {
        let (d, w) = make()
        d.update([a, b])
        d.windowAdded("x", frame: rect(100, 100, 300, 300))
        w.focusedWindow = "x"; d.windowFocused("x")
        d.newWindowAdded("z", frame: rect(1100, 100, 300, 300), openOn: OpenOn(display: "Projector"))
        #expect(d.engines["A"]?.workspaces.workspace(of: "z") != nil)
    }

    @Test func anOpenOnRuleSendsANewWindowToAnotherWorkspace() {
        let (d, w) = make()
        d.update([a, b])
        d.windowAdded("x", frame: rect(100, 100, 300, 300))
        w.focusedWindow = "x"; d.windowFocused("x")
        d.newWindowAdded("z", frame: rect(100, 100, 300, 300), openOn: OpenOn(workspace: 2))
        let ws = d.engines["A"]!.workspaces
        #expect(ws.workspace(of: "z") == 2)
        #expect(ws.active == 1)
        #expect(ws.current.focusedWindow == "x")
    }

    @Test func aNewWindowJoinsTheDisplayWithTheFocusedWindow() {
        let (d, w) = make()
        d.update([a, b])
        d.windowAdded("x", frame: rect(100, 100, 300, 300))
        d.windowAdded("y", frame: rect(1100, 100, 300, 300))
        w.focusedWindow = "y"; d.windowFocused("y")
        d.newWindowAdded("z", frame: rect(100, 100, 300, 300))
        #expect(d.engines["B"]?.workspaces.workspace(of: "z") != nil)
        #expect(d.engines["B"]?.strip.columns.map(\.windows) == [["y"], ["z"]])
    }

    @Test func aNewWindowJoinsTheDisplayWhoseDesktopWasClicked() {
        let (d, w) = make()
        d.update([a, b])
        d.windowAdded("y", frame: rect(1100, 100, 300, 300))
        w.focusedWindow = "y"; d.windowFocused("y")
        d.desktopClicked(on: d.engines["A"]!)
        d.newWindowAdded("z", frame: rect(1100, 100, 300, 300))
        #expect(d.engines["A"]?.strip.columns.map(\.windows) == [["z"]])
        #expect(d.engines["B"]?.strip.columns.map(\.windows) == [["y"]])
    }

    @Test func windowsGoBackToADisplayThatReturns() {
        let (d, _) = make()
        d.update([a, b])
        d.windowAdded("x", frame: rect(100, 100, 300, 300))
        d.windowAdded("y", frame: rect(1100, 100, 300, 300))
        d.windowAdded("z", frame: rect(1100, 100, 300, 300))
        d.windowAdded("f", frame: rect(1100, 100, 300, 300), floating: true)
        let before = d.engines["B"]!.strip.columns.map(\.windows)
        d.update([a])
        #expect(d.engines["A"]?.workspaces.workspace(of: "y") != nil)
        d.update([a, b])
        #expect(d.engines["B"]?.strip.columns.map(\.windows) == before)
        #expect(d.engines["B"]?.strip.floating == ["f"])
        #expect(d.engines["A"]?.strip.columns.map(\.windows) == [["x"]])
    }

    @Test func aWindowClosedWhileItsDisplayWasAwayStaysGone() {
        let (d, _) = make()
        d.update([a, b])
        d.windowAdded("y", frame: rect(1100, 100, 300, 300))
        d.windowAdded("z", frame: rect(1100, 100, 300, 300))
        d.update([a])
        d.windowRemoved("z")
        d.update([a, b])
        #expect(d.engines["B"]?.strip.columns.map(\.windows) == [["y"]])
    }

    @Test func aNewFloatingWindowStaysWhereItOpened() {
        let (d, w) = make()
        d.update([a, b])
        d.windowAdded("y", frame: rect(1100, 100, 300, 300))
        w.focusedWindow = "y"; d.windowFocused("y")
        d.newWindowAdded("dialog", frame: rect(100, 100, 300, 300), floating: true)
        #expect(d.engines["A"]?.strip.floating == ["dialog"])
    }

    @Test func aDetachedDisplaysWindowsMoveToTheMainDisplay() {
        let (d, _) = make()
        d.update([a, b])
        d.windowAdded("x", frame: rect(100, 100, 300, 300))
        d.windowAdded("y", frame: rect(1100, 100, 300, 300))
        d.update([a])
        #expect(d.engines.keys.sorted() == ["A"])
        #expect(d.engines["A"]?.workspaces.workspace(of: "y") == d.engines["A"]?.workspaces.active)
        #expect(d.engines["A"]?.strip.allWindows.sorted() == ["x", "y"])
    }

    @Test func aReconnectedDisplayKeepsItsTilingChoice() {
        let (d, _) = make(["B"])
        d.update([a, b])
        #expect(d.engines.keys.sorted() == ["A"])
        d.windowAdded("y", frame: rect(1100, 100, 300, 300))
        #expect(d.engine(holding: "y") == nil)
    }

    @Test func disablingADisplayReleasesItsWindows() {
        let (d, _) = make()
        d.update([a, b])
        d.windowAdded("y", frame: rect(1100, 100, 300, 300))
        #expect(d.setEnabled("B", false) == ["y"])
        #expect(d.engines["B"] == nil)
        d.setEnabled("B", true)
        #expect(d.engines["B"]?.strip.allWindows == [])
    }

    @Test func commandsFollowTheFocusedWindowThenThePointer() {
        let (d, w) = make()
        d.update([a, b])
        w.focusedWindow = "y"; d.windowAdded("y", frame: rect(1100, 100, 300, 300))
        #expect(d.active(pointer: Point(x: 10, y: 10)) === d.engines["B"])
        w.focusedWindow = nil
        #expect(d.active(pointer: Point(x: 10, y: 10)) === d.engines["A"])
        #expect(d.active(pointer: Point(x: 5000, y: 10)) === d.engines["B"])
    }

    @Test func movingTheFocusedWindowKeepsItsWidthAndFocusesIt() {
        let (d, w) = make()
        d.update([a, b])
        w.focusedWindow = "x"; d.windowAdded("x", frame: rect(100, 100, 300, 300))
        d.engines["A"]?.cycleWidth()
        let width = d.engines["A"]!.strip.columns[0].width
        w.focusedWindow = "z"; d.windowAdded("z", frame: rect(1100, 100, 300, 300))
        w.focusedWindow = "x"
        #expect(d.moveFocused(by: 1, from: d.engines["A"]) == "B")
        let b = d.engines["B"]!
        #expect(b.strip.allWindows == ["z", "x"])
        #expect(b.strip.columns[1].width == width)
        #expect(b.strip.focusedWindow == "x")
        #expect(w.focusedWindow == "x")
        #expect(d.engines["A"]?.strip.allWindows == [])
        #expect((w.frames["x"]?.x ?? 0) >= 1000)
    }

    @Test func focusingAnEmptyDisplayRoutesCommandsThere() {
        let (d, w) = make()
        d.update([a, b])
        w.focusedWindow = "x"; d.windowAdded("x", frame: rect(100, 100, 300, 300))
        #expect(d.focusDisplay(by: 1, from: d.engines["A"]) == "B")
        #expect(d.active(pointer: Point(x: 0, y: 0)) === d.engines["B"])
        d.windowFocused("x")
        #expect(d.active(pointer: Point(x: 0, y: 0)) === d.engines["A"])
    }

    @Test func focusingAcrossDisplaysFocusesTheirWindow() {
        let (d, w) = make()
        d.update([a, b])
        w.focusedWindow = "x"; d.windowAdded("x", frame: rect(100, 100, 300, 300))
        w.focusedWindow = "y"; d.windowAdded("y", frame: rect(1100, 100, 300, 300))
        w.focusedWindow = "x"
        d.focusDisplay(by: 1, from: d.engines["A"])
        #expect(w.focusedWindow == "y")
    }

    @Test func parkedWindowsStayOffTheNeighbour() {
        let (d, w) = make()
        d.update([a, b])
        w.focusedWindow = "x"; d.windowAdded("x", frame: rect(100, 100, 300, 300))
        d.engines["A"]?.switchWorkspace(by: 1)
        let parked = w.frames["x"]!
        #expect(!overlapsAny(parked, [b.frame]))
    }
}

@MainActor
@Suite struct TransferWriteTests {
    @Test func aWindowMovedToAnotherDisplayIsNotWrittenBackByTheFirst() {
        let w = FakeWindows()
        let clock = TestClock()
        let presenter = FakePresenter()
        let source = StripEngine(windows: w, viewport: rect(0, 0))
        source.clock = clock
        source.presenter = presenter
        w.focusedWindow = "a"
        source.windowAdded("a")
        source.wider()
        let target = StripEngine(windows: w, viewport: rect(1000, 0))
        let moved = source.takeFocused()!
        target.adopt(moved.id, width: moved.width, focus: true)
        let expected = target.frame(of: "a")
        clock.advance(by: 0.1)
        #expect(w.frames["a"] == expected)
    }
}
