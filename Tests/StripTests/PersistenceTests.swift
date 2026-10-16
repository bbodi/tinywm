import Foundation
import Testing
import WindowCore
@testable import StripEngine
@testable import StripModel

private func desc(_ number: UInt32?, _ bundle: String? = "app.a", _ title: String = "", pid: Int32 = 10) -> WindowDescriptor {
    WindowDescriptor(windowNumber: number, bundleID: bundle, title: title, pid: pid)
}

private func desc(_ number: UInt32?, title: String) -> WindowDescriptor { desc(number, "app.a", title) }

private func live(_ id: String, _ d: WindowDescriptor) -> LiveWindow { LiveWindow(id: id, descriptor: d) }

/// A display with one workspace of the given columns (each a list of descriptors), between two empty ones.
private func saved(_ columns: [[WindowDescriptor]], floating: [WindowDescriptor] = [], focusedColumn: Int? = 0,
                   scroll: Double = 0, widths: [Double]? = nil) -> SavedWorkspaces {
    let cols = columns.enumerated().map {
        SavedColumn(windows: $1, focused: 0, width: widths?[$0] ?? 0.5, widthBeforeFull: nil)
    }
    let empty = SavedStrip(columns: [], focusedColumn: nil, scroll: 0, floating: [])
    let mid = SavedStrip(columns: cols, focusedColumn: focusedColumn, scroll: scroll, floating: floating)
    return SavedWorkspaces(strips: [empty, mid, empty], active: 1)
}

private func layout(_ displays: [String: SavedWorkspaces]) -> SavedLayout { SavedLayout(displays: displays) }

@Suite struct SavedLayoutTests {
    @Test func captureAndRoundTrip() throws {
        var w = Workspaces()
        w.current.insert("w1", width: 0.5, columnID: "c1", focus: true)
        w.current.insert("w2", width: 0.4, columnID: "c2", focus: true)
        w.current.addFloating("w3")
        w.normalize()
        w.current.scroll = 120
        let names: [String: WindowDescriptor] = ["w1": desc(1, title: "one"), "w2": desc(2, title: "two"), "w3": desc(3)]
        let s = SavedWorkspaces(w, describe: { names[$0] })
        #expect(s.strips.count == w.strips.count)
        let cur = s.strips[s.active]
        #expect(cur.columns.map(\.width) == [0.5, 0.4])
        #expect(cur.columns.map { $0.windows.map(\.title) } == [["one"], ["two"]])
        #expect(cur.focusedColumn == 1)
        #expect(cur.floating == [desc(3)])
        #expect(cur.scroll == 120)

        let file = layout(["D1": s])
        #expect(SavedLayout.decoded(from: try file.encoded()) == file)
    }

    @Test func unreadableOrNewerDataIsIgnored() throws {
        #expect(SavedLayout.decoded(from: Data("nope".utf8)) == nil)
        var future = layout([:])
        future.version = 99
        #expect(SavedLayout.decoded(from: try future.encoded()) == nil)
    }

    @Test func windowsWithoutADescriptorAreLeftOut() {
        var w = Workspaces()
        w.current.insert("w1", width: 0.5, columnID: "c1", focus: true)
        w.current.insert("w2", width: 0.5, columnID: "c2", focus: true)
        let s = SavedWorkspaces(w, describe: { $0 == "w2" ? desc(2) : nil })
        #expect(s.strips[s.active].columns.count == 1)
        #expect(s.strips[s.active].focusedColumn == 0)
    }

    @Test func mergingKeepsDisplaysThatAreNotCurrent() {
        let old = layout(["A": saved([[desc(1)]]), "B": saved([[desc(2)]])])
        let merged = old.merged(with: ["A": saved([[desc(9)]])])
        #expect(merged.displays["B"] == old.displays["B"])
        #expect(merged.displays["A"]?.strips[1].columns[0].windows == [desc(9)])
    }
}

@Suite struct LayoutMatchingTests {
    private func slots(_ d: SavedWorkspaces) -> [(LayoutSlot, WindowDescriptor)] {
        layout(["A": d]).slots(for: ["A"])
    }

    @Test func exactNumberWinsOverTitle() {
        let s = slots(saved([[desc(5, title: "x")], [desc(6, title: "y")]]))
        let r = LayoutMatcher.assign(slots: s, windows: [live("w1", desc(6, title: "x"))])
        #expect(r["w1"] == s[1].0)
    }

    @Test func aReusedNumberNeedsTheSamePidAndApp() {
        let s = slots(saved([[desc(5, "app.a", "doc", pid: 10)]]))
        let other = LayoutMatcher.assign(slots: s, windows: [live("w1", desc(5, "app.b", "zzz", pid: 10))])
        #expect(other.isEmpty)
        let newPid = LayoutMatcher.assign(slots: s, windows: [live("w1", desc(5, "app.a", "doc", pid: 99))])
        #expect(newPid["w1"] == s[0].0) // by title instead
    }

    @Test func titleFallbackNeedsTheSameApp() {
        let s = slots(saved([[desc(5, "app.a", "Inbox")]]))
        #expect(LayoutMatcher.assign(slots: s, windows: [live("w1", desc(7, "app.b", "Inbox"))]).isEmpty)
        #expect(LayoutMatcher.assign(slots: s, windows: [live("w1", desc(7, "app.a", "Inbox"))])["w1"] == s[0].0)
    }

    @Test func similarTitlesMatchAfterExactOnes() {
        let s = slots(saved([[desc(1, "app.a", "notes.txt - Editor")], [desc(2, "app.a", "todo.md - Editor")]]))
        let r = LayoutMatcher.assign(slots: s, windows: [
            live("w1", desc(8, "app.a", "todo.md (edited) - Editor")),
            live("w2", desc(9, "app.a", "notes.txt - Editor")),
        ])
        #expect(r["w2"] == s[0].0)
        #expect(r["w1"] == s[1].0)
    }

    @Test func titlesTooDifferentDoNotMatch() {
        let s = slots(saved([[desc(1, "app.a", "Inbox")]]))
        #expect(LayoutMatcher.assign(slots: s, windows: [live("w1", desc(2, "app.a", "Calendar"))]).isEmpty)
        #expect(LayoutMatcher.assign(slots: slots(saved([[desc(1, "app.a", "")]])),
                                     windows: [live("w1", desc(2, "app.a", ""))]).isEmpty)
    }

    @Test func eachSlotIsUsedOnce() {
        let s = slots(saved([[desc(1, "app.a", "Same")]]))
        let r = LayoutMatcher.assign(slots: s, windows: [live("w1", desc(2, "app.a", "Same")), live("w2", desc(3, "app.a", "Same"))])
        #expect(r == ["w1": s[0].0])
    }
}

@Suite struct LayoutPlanTests {
    @Test func windowsLandInTheirSavedPlaces() {
        let file = layout(["A": saved([[desc(1)], [desc(2), desc(3)]], focusedColumn: 1, widths: [0.3, 0.7])])
        // Opened in a different order than saved.
        let plan = file.plan(displays: ["A"], windows: [live("c", desc(3)), live("b", desc(2)), live("a", desc(1))])
        let w = plan.workspaces["A"]!
        #expect(plan.unplaced.isEmpty)
        #expect(w.current.columns.map(\.windows) == [["a"], ["b", "c"]])
        #expect(w.current.columns.map(\.width) == [0.3, 0.7])
        #expect(w.current.focusedColumn == 1)
        #expect(w.strips.count == 3 && w.strips[0].isEmpty && w.strips[2].isEmpty)
    }

    @Test func unmatchedSlotsAreDroppedAndNewWindowsAreLeftToAppend() {
        let file = layout(["A": saved([[desc(1)], [desc(2)], [desc(3)]], focusedColumn: 2)])
        let plan = file.plan(displays: ["A"], windows: [live("n1", desc(50, "app.z")), live("a", desc(1)), live("n2", desc(51, "app.z")), live("c", desc(3))])
        let w = plan.workspaces["A"]!
        #expect(w.current.columns.map(\.windows) == [["a"], ["c"]])
        #expect(w.current.focusedColumn == 1)
        #expect(plan.unplaced == ["n1", "n2"])
    }

    @Test func aWorkspaceThatLostEveryWindowDisappears() {
        let empty = SavedStrip(columns: [], focusedColumn: nil, scroll: 0, floating: [])
        func strip(_ n: UInt32) -> SavedStrip {
            SavedStrip(columns: [SavedColumn(windows: [desc(n)], focused: 0, width: 0.5, widthBeforeFull: nil)],
                       focusedColumn: 0, scroll: 0, floating: [])
        }
        let file = layout(["A": SavedWorkspaces(strips: [empty, strip(1), strip(2), empty], active: 2)])
        let plan = file.plan(displays: ["A"], windows: [live("a", desc(1))])
        let w = plan.workspaces["A"]!
        #expect(w.strips.map(\.isEmpty) == [true, false, true])
        #expect(w.current.allWindows == ["a"])
    }

    @Test func floatingWindowsKeepFloating() {
        let file = layout(["A": saved([[desc(1)]], floating: [desc(2)])])
        let plan = file.plan(displays: ["A"], windows: [live("a", desc(1)), live("f", desc(2))], floating: ["a"])
        let w = plan.workspaces["A"]!
        #expect(w.strips.allSatisfy { $0.columns.isEmpty })
        #expect(w.current.floating.sorted() == ["a", "f"])
    }

    @Test func eachDisplayIsRebuiltAndOthersAreIgnored() {
        let file = layout(["A": saved([[desc(1)]]), "B": saved([[desc(2)]]), "gone": saved([[desc(3)]])])
        let plan = file.plan(displays: ["A", "B"], windows: [live("a", desc(1)), live("b", desc(2)), live("c", desc(3))])
        #expect(plan.workspaces["A"]?.current.allWindows == ["a"])
        #expect(plan.workspaces["B"]?.current.allWindows == ["b"])
        #expect(plan.workspaces["gone"] == nil)
        #expect(plan.unplaced == ["c"])
    }

    @Test func noMatchLeavesTheDisplayAlone() {
        let file = layout(["A": saved([[desc(1, "app.q", "x")]])])
        let plan = file.plan(displays: ["A"], windows: [live("a", desc(2, "app.z", "y"))])
        #expect(plan.workspaces.isEmpty)
        #expect(plan.unplaced == ["a"])
    }

    @Test func columnIDsAreUnique() {
        let file = layout(["A": saved([[desc(1)], [desc(2)]]), "B": saved([[desc(3)]])])
        let plan = file.plan(displays: ["A", "B"], windows: [live("a", desc(1)), live("b", desc(2)), live("c", desc(3))])
        let ids = plan.workspaces.values.flatMap { $0.strips.flatMap(\.columns).map(\.id) }
        #expect(Set(ids).count == 3)
    }
}

@MainActor
@Suite struct RestoreOnDisplaysTests {
    final class Windows: WindowSystem {
        var frames: [String: Rect] = [:]
        var focusedWindow: String?
        func setFrame(_ id: String, _ rect: Rect, completion: @escaping @MainActor (Rect?) -> Void) {
            frames[id] = rect; completion(rect)
        }
        func focus(_ id: String) { focusedWindow = id }
    }

    let a = TiledDisplay(id: "A", frame: Rect(x: 0, y: 0, width: 1000, height: 600), visible: Rect(x: 0, y: 0, width: 1000, height: 600))
    let b = TiledDisplay(id: "B", frame: Rect(x: 1000, y: 0, width: 1000, height: 600), visible: Rect(x: 1000, y: 0, width: 1000, height: 600))

    private func pending(_ id: String, _ d: WindowDescriptor, floating: Bool = false) -> StripDisplays.Pending {
        .init(live: live(id, d), frame: nil, floating: floating, takesFocus: false)
    }

    @Test func restoresPlacesThenAppendsTheRest() {
        let w = Windows()
        let d = StripDisplays(windows: w, configure: { _, _ in }, discard: { _ in })
        d.update([a])
        let file = layout(["A": saved([[desc(1)], [desc(2)]], focusedColumn: 0)])
        d.restore(file, pending: [pending("n", desc(9, "app.z")), pending("b", desc(2)), pending("a", desc(1))])
        let e = d.engines["A"]!
        #expect(e.strip.columns.map(\.windows) == [["a"], ["n"], ["b"]]) // n joins right of the focused column, as any new window does
        #expect(e.workspaces.strips.count == 3)
        #expect(w.frames["a"] != nil && w.frames["n"] != nil)
    }

    @Test func aDisabledDisplayIsNotRestoredAndItsWindowsJoinTheNormalWay() {
        let w = Windows()
        let d = StripDisplays(windows: w, disabled: ["B"], configure: { _, _ in }, discard: { _ in })
        d.update([a, b])
        let file = layout(["A": saved([[desc(1)]]), "B": saved([[desc(2)]])])
        d.restore(file, pending: [pending("a", desc(1)), pending("b", desc(2))])
        #expect(d.engines["B"] == nil)
        #expect(d.engines["A"]?.strip.columns.map(\.windows) == [["a"], ["b"]])
    }

    @Test func theFocusedWindowKeepsFocusedAfterRestore() {
        let w = Windows()
        w.focusedWindow = "b"
        let d = StripDisplays(windows: w, configure: { _, _ in }, discard: { _ in })
        d.update([a])
        d.restore(layout(["A": saved([[desc(1)], [desc(2)]], focusedColumn: 0)]),
                  pending: [pending("a", desc(1)), pending("b", desc(2))])
        #expect(d.engines["A"]?.strip.focusedWindow == "b")
    }
}

@Suite struct TitleSimilarityTests {
    @Test func scoresSharedLetterPairs() {
        #expect(LayoutMatcher.similarity("night", "nacht") == 0.25)
        #expect(LayoutMatcher.similarity("Ghostty", "ghostty") == 1)
    }

    @Test func aRepeatedPairCountsOnlyAsOftenAsBothHaveIt() {
        #expect(LayoutMatcher.similarity("aaaa", "aa") == 0.5)
    }

    @Test func emptyTitlesAreNeverAlikeAndOneLetterCountsAsItself() {
        #expect(LayoutMatcher.similarity("", "") == 0)
        #expect(LayoutMatcher.similarity("a", "a") == 1)
        #expect(LayoutMatcher.similarity("a", "b") == 0)
    }
}
