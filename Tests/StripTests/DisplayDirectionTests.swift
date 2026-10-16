import Testing
import WindowCore
@testable import StripEngine
@testable import StripModel

@Suite struct DisplayDirectionTests {
    // A laptop in the middle, a monitor above it, one to its right, one to its left a bit lower.
    let laptop = Rect(x: 0, y: 0, width: 1512, height: 982)
    let above = Rect(x: -200, y: -1440, width: 2560, height: 1440)
    let right = Rect(x: 1512, y: -300, width: 1920, height: 1080)
    let left = Rect(x: -1920, y: 200, width: 1920, height: 1080)
    var all: [Rect] { [laptop, above, right, left] }

    @Test func eachDirectionFindsTheDisplayLyingThatWay() {
        #expect(displayToward(.up, from: 0, among: all) == 1)
        #expect(displayToward(.right, from: 0, among: all) == 2)
        #expect(displayToward(.left, from: 0, among: all) == 3)
        #expect(displayToward(.down, from: 0, among: all) == nil)
        #expect(displayToward(.down, from: 1, among: all) == 0)
    }

    @Test func theDisplaySharingMoreEdgeWins() {
        // Two monitors to the right; the lower one shares more of the laptop's height.
        let high = Rect(x: 1512, y: -900, width: 1920, height: 1000)
        let low = Rect(x: 1512, y: 100, width: 1920, height: 1080)
        #expect(displayToward(.right, from: 0, among: [laptop, high, low]) == 2)
    }

    @Test func aSingleDisplayHasNoNeighbours() {
        for d in [Direction.left, .right, .up, .down] { #expect(displayToward(d, from: 0, among: [laptop]) == nil) }
    }
}

@Suite struct DisplayConfigTests {
    @Test func rebindingADefaultKeyIsQuiet() {
        // J belongs to focus-down by default; taking it is not reported.
        let r = StripConfig.parse("bind display-up = j")
        #expect(r.issues.isEmpty)
        #expect(r.config.bindings["focus-down"] == nil)
    }

    @Test func twoLinesClaimingOneKeyAreReported() {
        let r = StripConfig.parse("bind display-up = j\nbind display-down = j")
        #expect(r.issues.count == 1)
    }

    @Test func crossingDisplaysParses() {
        #expect(StripConfig.parse("focus-crosses-displays = on").config.focusCrossesDisplays)
        #expect(!StripConfig().focusCrossesDisplays)
    }
}

@MainActor
@Suite struct StripEdgeTests {
    @Test func edgesAreTheFirstAndLastColumns() {
        let f = FakeWindows()
        let e = StripEngine(windows: f, viewport: Rect(x: 0, y: 0, width: 1000, height: 600))
        #expect(e.atStripEdge(.left))
        for id in ["a", "b", "c"] { f.focusedWindow = id; e.windowAdded(id) }
        e.focusColumn(1)
        #expect(!e.atStripEdge(.left) && !e.atStripEdge(.right))
        e.focusColumn(0)
        #expect(e.atStripEdge(.left))
        e.focusColumn(2)
        #expect(e.atStripEdge(.right))
    }
}
