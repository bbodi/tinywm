import Testing
import WindowCore
@testable import StripModel

private let screenRect = Rect(x: 100, y: 50, width: 1000, height: 600)
private let metrics = StripMetrics(viewport: screenRect, gap: 10)
private let display = Size(width: 1000, height: 600)

private func column(_ id: String, _ windows: [String], _ width: Double = 0.5) -> Column {
    Column(id: id, windows: windows, width: width)
}

private func strip(_ columns: [Column], focus: Int? = 0) -> Strip {
    var s = Strip()
    s.columns = columns
    s.focusedColumn = focus
    return s
}

/// Rows: 0 empty top, 1 holds a,(b over c), 2 holds d, 3 empty bottom.
private func sample(active: Int = 1) -> Workspaces {
    var ws = Workspaces()
    ws.strips = [Strip(), strip([column("1", ["a"]), column("2", ["b", "c"])]), strip([column("3", ["d"])]), Strip()]
    ws.active = active
    return ws
}

@Suite struct OverviewLayoutTests {
    @Test func rowsAreWorkspacesWithWindowsPlusTheActiveOne() {
        #expect(overviewLayout(sample(), metrics, screen: display).rows.map(\.workspace) == [1, 2])
        #expect(overviewLayout(sample(active: 3), metrics, screen: display).rows.map(\.workspace) == [1, 2, 3])
    }

    @Test func windowsKeepTheirProportions() {
        let real = overviewRealFrames(sample(), metrics)
        let layout = overviewLayout(sample(), metrics, screen: display)
        for w in layout.windows {
            let r = real[w.id]!
            #expect(abs(w.rect.width / r.width - layout.scale) < 1e-9)
            #expect(abs(w.rect.height / r.height - layout.scale) < 1e-9)
        }
    }

    @Test func scaleFitsAllRowsAndStaysUnderTheCap() {
        let layout = overviewLayout(sample(), metrics, screen: display)
        #expect(layout.scale <= 0.6)
        let style = OverviewStyle()
        for r in layout.rows {
            #expect(r.rect.y >= 0 && r.rect.maxY <= display.height)
            #expect(r.rect.x >= style.margin - 1e-9 && r.rect.maxX <= display.width - style.margin + 1e-9)
        }
        // A lone small strip on a big screen is capped.
        var one = Workspaces()
        one.strips = [strip([column("1", ["a"])])]
        #expect(overviewLayout(one, metrics, screen: Size(width: 4000, height: 3000)).scale == 0.6)
    }

    @Test func manyWorkspacesShrinkUntilEveryRowFits() {
        var ws = Workspaces()
        ws.strips = (0..<8).map { strip([column("c\($0)", ["w\($0)"])]) }
        let layout = overviewLayout(ws, metrics, screen: display)
        #expect(layout.rows.count == 8)
        #expect(layout.scale < OverviewStyle().minScale)
        for r in layout.rows { #expect(r.rect.y >= 0 && r.rect.maxY <= display.height) }
    }

    @Test func rowsStackInWorkspaceOrderWithAGap() {
        let rows = overviewLayout(sample(), metrics, screen: display).rows
        #expect(rows[1].rect.y > rows[0].rect.maxY)
        #expect(abs(rows[1].rect.y - rows[0].rect.maxY - OverviewStyle().rowGap) < 1e-9)
    }

    @Test func stackedWindowsShareAColumn() {
        let layout = overviewLayout(sample(), metrics, screen: display)
        let b = layout.window("b")!, c = layout.window("c")!
        #expect(b.rect.x == c.rect.x && b.rect.y < c.rect.y)
        #expect(b.column == 1 && c.index == 1)
    }

    @Test func wideRowsStopShrinkingAndPan() {
        var ws = Workspaces()
        ws.strips = [strip((0..<20).map { column("c\($0)", ["w\($0)"], 0.5) })]
        let layout = overviewLayout(ws, metrics, screen: display)
        #expect(layout.scale == OverviewStyle().minScale)
        #expect(layout.panRange > 0)
        let panned = overviewLayout(ws, metrics, screen: display, pan: 100)
        #expect(abs(panned.window("w0")!.rect.x - (layout.window("w0")!.rect.x - 100)) < 1e-9)
        // Panning is clamped to the range.
        let far = overviewLayout(ws, metrics, screen: display, pan: 1e9)
        #expect(abs(far.rows[0].rect.maxX - (display.width - OverviewStyle().margin)) < 1e-6)
    }

    @Test func revealingPansJustEnoughAndClamps() {
        var ws = Workspaces()
        ws.strips = [strip((0..<20).map { column("c\($0)", ["w\($0)"], 0.5) })]
        let layout = overviewLayout(ws, metrics, screen: display)
        let pan = layout.pan(toReveal: "w19", current: 0)
        let shown = overviewLayout(ws, metrics, screen: display, pan: pan).window("w19")!.rect
        #expect(shown.maxX <= display.width - OverviewStyle().margin + 1e-6)
        #expect(layout.pan(toReveal: "w0", current: 0) == 0)
    }

    @Test func realFramesStackWorkspacesOneScreenApart() {
        let real = overviewRealFrames(sample(), metrics)
        #expect(real["a"]!.x == 10 && real["a"]!.y == 10)
        #expect(real["d"]!.y == real["a"]!.y + 600)
    }
}

@Suite struct OverviewNavigationTests {
    let layout = overviewLayout(sample(), metrics, screen: display)

    @Test func leftAndRightMoveBetweenColumnsAndStopAtEnds() {
        #expect(overviewMove(layout, from: "a", .right) != nil)
        #expect(overviewMove(layout, from: "a", .left) == nil)
        #expect(overviewMove(layout, from: "b", .right) == nil)
    }

    @Test func sidewaysLandsOnTheNearestHeight() {
        // a is full height, so its centre is between b and c; b is nearer to the top-biased tie.
        #expect(["b", "c"].contains(overviewMove(layout, from: "a", .right)!))
        #expect(overviewMove(layout, from: "c", .left) == "a")
    }

    @Test func verticalWalksTheStackThenCrossesRows() {
        #expect(overviewMove(layout, from: "b", .down) == "c")
        #expect(overviewMove(layout, from: "c", .up) == "b")
        #expect(overviewMove(layout, from: "c", .down) == "d")
        #expect(overviewMove(layout, from: "d", .up) == "a")
        #expect(overviewMove(layout, from: "d", .down) == nil)
        #expect(overviewMove(layout, from: "a", .up) == nil)
    }

    @Test func crossingRowsPicksTheHorizontallyNearestWindow() {
        var ws = Workspaces()
        ws.strips = [strip([column("1", ["a"]), column("2", ["b"]), column("3", ["c"])]),
                     strip([column("4", ["d"]), column("5", ["e"])])]
        let l = overviewLayout(ws, metrics, screen: display)
        #expect(overviewMove(l, from: "a", .down) == "d")
        #expect(overviewMove(l, from: "c", .down) == "e")
        #expect(overviewMove(l, from: "e", .up) == "b")
    }

    @Test func emptyRowsAreSkipped() {
        var ws = Workspaces()
        ws.strips = [strip([column("1", ["a"])]), Strip(), strip([column("2", ["b"])])]
        ws.active = 1
        let l = overviewLayout(ws, metrics, screen: display)
        #expect(l.rows.count == 3)
        #expect(overviewMove(l, from: "a", .down) == "b")
        #expect(overviewMove(l, from: "b", .up) == "a")
    }

    @Test func stepFollowsReadingOrder() {
        #expect(overviewStep(layout, from: "a", by: 1) == "b")
        #expect(overviewStep(layout, from: "c", by: 1) == "d")
        #expect(overviewStep(layout, from: "a", by: -1) == nil)
    }

    @Test func hitTestFindsTheWindowUnderThePoint() {
        let d = layout.window("d")!
        #expect(layout.window(at: d.rect.center)?.id == "d")
        #expect(layout.window(at: Point(x: 1, y: 1)) == nil)
    }
}

@Suite struct OverviewFloatingTests {
    /// The sample with floating "f" on workspace 1 and "g" alone on workspace 3.
    private func withFloats() -> (Workspaces, [String: Rect]) {
        var ws = sample()
        ws.strips[1].floating = ["f"]
        ws.strips[3].floating = ["g"]
        return (ws, ["f": Rect(x: 200, y: 100, width: 300, height: 200), "g": Rect(x: 0, y: 0, width: 400, height: 300)])
    }

    @Test func floatingWindowsShowAtTheirPlaceAboveTheStrip() {
        let (ws, floats) = withFloats()
        let layout = overviewLayout(ws, metrics, screen: display, floats: floats)
        let row = layout.rows.first { $0.workspace == 1 }!
        let f = layout.window("f")!
        #expect(row.windows.last?.id == "f")
        #expect(f.column == 2)
        #expect(abs(f.rect.x - (row.rect.x + 200 * layout.scale)) < 1e-9)
        #expect(abs(f.rect.width - 300 * layout.scale) < 1e-9)
        #expect(layout.window(at: f.rect.center)?.id == "f")
    }

    @Test func aWorkspaceHoldingOnlyAFloatingWindowGetsARow() {
        let (ws, floats) = withFloats()
        #expect(overviewLayout(ws, metrics, screen: display, floats: floats).rows.map(\.workspace) == [1, 2, 3])
        #expect(overviewLayout(ws, metrics, screen: display).rows.map(\.workspace) == [1, 2])
    }

    @Test func floatingWindowsAreReachedByKeysAndHaveRealFrames() {
        let (ws, floats) = withFloats()
        let layout = overviewLayout(ws, metrics, screen: display, floats: floats)
        #expect(overviewMove(layout, from: "b", .right) == "f")
        #expect(overviewStep(layout, from: "c", by: 1) == "f")
        let real = overviewRealFrames(ws, metrics, floats: floats)
        #expect(real["f"] == floats["f"])
        #expect(real["g"]!.y == 2 * 600)
    }
}
