import Testing
import WindowCore
@testable import StripEngine
@testable import StripModel

@Suite struct MinimumWidthsTests {
    @Test func aRefusalTeachesTheWidthTheWindowTook() {
        var m = MinimumWidths()
        let learned = m.refused(app: "slack", asked: 400, took: 600, screenWidth: 1200)
        #expect(learned)
        #expect(m.width(for: "slack") == 600)
    }

    @Test func roundingAndNearlyFullScreenWindowsTeachNothing() {
        var m = MinimumWidths()
        let rounding = m.refused(app: "a", asked: 400, took: 401, screenWidth: 1200)
        #expect(!rounding)
        let nearlyScreen = m.refused(app: "a", asked: 400, took: 1180, screenWidth: 1200)
        #expect(!nearlyScreen)
        #expect(m.width(for: "a") == nil)
    }

    @Test func aRefusalNeverLowersTheLearnedWidth() {
        var m = MinimumWidths(["slack": 600])
        let lowered = m.refused(app: "slack", asked: 300, took: 500, screenWidth: 1200)
        #expect(!lowered)
        #expect(m.width(for: "slack") == 600)
    }

    @Test func aWindowSeenNarrowerLowersTheLearnedWidth() {
        var m = MinimumWidths(["slack": 600])
        let wider = m.seen(app: "slack", width: 650)
        #expect(!wider)
        let unknown = m.seen(app: "other", width: 100)
        #expect(!unknown)
        let narrower = m.seen(app: "slack", width: 500)
        #expect(narrower)
        #expect(m.width(for: "slack") == 500)
    }
}

@Suite struct ColumnMinimumTests {
    let m = StripMetrics(viewport: Rect(x: 0, y: 0, width: 1200, height: 600), gap: 0, minimums: ["s": 600, "huge": 5000])

    @Test func aColumnWidensToItsWindowsMinimum() {
        #expect(m.width(of: Column(id: "c", windows: ["a"], width: 0.333)) == m.columnWidth(0.333))
        #expect(m.width(of: Column(id: "c", windows: ["a", "s"], width: 0.333)) == 600)
        #expect(m.width(of: Column(id: "c", windows: ["s"], width: 0.667)) == m.columnWidth(0.667))
    }

    @Test func aMinimumNeverWidensAColumnPastTheScreen() {
        #expect(m.width(of: Column(id: "c", windows: ["huge"], width: 0.333)) == 1200)
    }
}

/// Windows whose apps refuse widths below a minimum, as real apps do.
@MainActor
final class StubbornWindows: WindowSystem {
    var frames: [String: Rect] = [:]
    var focusedWindow: String?
    var minimums: [String: Double] = [:]
    /// Report the frame from before the next write, as an app still busy with the change does.
    var staleOnce: Set<String> = []
    private(set) var asked: [String: [Double]] = [:]

    func setFrame(_ id: String, _ rect: Rect, completion: @escaping @MainActor (Rect?) -> Void) {
        asked[id, default: []].append(rect.width)
        let before = frames[id]
        let took = Rect(x: rect.x, y: rect.y, width: max(rect.width, minimums[id] ?? 0), height: rect.height)
        frames[id] = took
        if staleOnce.remove(id) != nil, let before { completion(before) } else { completion(took) }
    }
    func focus(_ id: String) { focusedWindow = id }
    func frameOf(_ id: String) -> Rect? { frames[id] }
}

@MainActor
@Suite struct MinimumLearningTests {
    let display = TiledDisplay(id: "A", frame: Rect(x: 0, y: 0, width: 1200, height: 600),
                               visible: Rect(x: 0, y: 0, width: 1200, height: 600))
    let apps = ["s": "slack", "s2": "slack"]

    func make() -> (StripDisplays, StubbornWindows) {
        let w = StubbornWindows()
        w.minimums = ["s": 600, "s2": 600]
        let d = StripDisplays(windows: w, configure: { _, _ in }, discard: { _ in })
        d.settings.gap = 0
        d.appOf = { [apps] id in apps[id] ?? "app.\(id)" }
        d.update([display])
        return (d, w)
    }

    func add(_ d: StripDisplays, _ w: StubbornWindows, _ ids: [String]) {
        for id in ids {
            w.frames[id] = Rect(x: 100, y: 100, width: 300, height: 300)
            w.focusedWindow = id
            d.windowAdded(id, frame: w.frames[id])
        }
    }

    @Test func aRefusedWidthWidensTheColumnSoItsNeighbourMovesAside() {
        let (d, w) = make()
        var saved: MinimumWidths?
        d.onMinimumsChanged = { saved = $0 }
        add(d, w, ["a", "s", "b"])
        #expect(d.minimums.width(for: "slack") == 600)
        #expect(saved?.width(for: "slack") == 600)
        let s = w.frames["s"]!, b = w.frames["b"]!
        #expect(s.width == 600)
        #expect(b.x >= s.maxX)
    }

    @Test func aNewWindowOfAKnownAppIsAskedForItsMinimumAtOnce() {
        let (d, w) = make()
        d.minimums = MinimumWidths(["slack": 600])
        add(d, w, ["a", "s2"])
        #expect(w.asked["s2"]?.allSatisfy { $0 >= 600 } == true)
    }

    @Test func anAppStillBusyWithTheChangeTeachesNothing() {
        let (d, w) = make()
        // The first report after the write still shows the old 900-point width, which looks
        // like a refusal of the 400 asked; the read a moment later shows the write took.
        w.frames["a"] = Rect(x: 100, y: 100, width: 900, height: 300)
        w.staleOnce = ["a"]
        w.focusedWindow = "a"
        d.windowAdded("a", frame: w.frames["a"])
        #expect(w.staleOnce.isEmpty)
        #expect(w.frames["a"]!.width < 900)
        #expect(d.minimums.widths.isEmpty)
    }

    @Test func aTiledWindowSeenNarrowerNarrowsItsAppsColumns() {
        let (d, w) = make()
        add(d, w, ["a", "s", "b"])
        w.minimums["s"] = 500
        w.frames["s"]!.width = 500
        d.windowSeen("s", width: 500)
        #expect(d.minimums.width(for: "slack") == 500)
        #expect(w.frames["b"]!.x == w.frames["s"]!.maxX)
    }

    @Test func aWindowOffTheStripLowersNothing() {
        let (d, _) = make()
        d.minimums = MinimumWidths(["slack": 600])
        d.windowSeen("s", width: 300)
        #expect(d.minimums.width(for: "slack") == 600)
    }
}
