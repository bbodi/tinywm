import Foundation
import Testing
@testable import WindowCore

@Suite struct ReleaseFramesTests {
    @Test func releaseFramesKeepVisibleFramesAndRescueStrandedOnes() {
        let screens = [Rect(x: 0, y: 0, width: 1000, height: 800)]
        let r = releaseFrames(originals: [
            "ok": Rect(x: 50, y: 50, width: 400, height: 300),
            "parked": Rect(x: 990, y: 790, width: 400, height: 300),
            "gone": Rect(x: 3000, y: 100, width: 1500, height: 900),
        ], displays: screens)
        #expect(r["ok"] == Rect(x: 50, y: 50, width: 400, height: 300))
        #expect(r["parked"] == Rect(x: 300, y: 250, width: 400, height: 300))
        #expect(r["gone"] == Rect(x: 0, y: 0, width: 1000, height: 800))
    }
}

@Suite struct GeometryTests {
    @Test func overlapIsTheSharedAreaOrNil() {
        let a = Rect(x: 0, y: 0, width: 100, height: 100)
        #expect(a.overlap(Rect(x: 50, y: 25, width: 100, height: 100)) == Rect(x: 50, y: 25, width: 50, height: 75))
        #expect(a.overlap(Rect(x: 100, y: 0, width: 10, height: 10)) == nil)
    }

    @Test func aFullScreenWindowCoversItsDisplayEvenBelowANotch() {
        let display = Rect(x: 1000, y: 0, width: 1512, height: 982)
        #expect(display.coversAsFullScreen(display))
        #expect(Rect(x: 1000, y: 32, width: 1512, height: 950).coversAsFullScreen(display))
        // A tile leaves gaps at the sides and bottom.
        #expect(!Rect(x: 1008, y: 39, width: 1496, height: 935).coversAsFullScreen(display))
        #expect(!Rect(x: 1000, y: 0, width: 1512, height: 900).coversAsFullScreen(display))
    }
}

@Suite struct LogTests {
    @Test func notesLandInTheFileWithTheirCategory() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinywm-log-\(UUID().uuidString)/tinywm.log")
        Log.start(at: url)
        Log.note("test", "first line\nsecond line")
        var text = ""
        for _ in 0..<50 where !text.contains("second line") {
            try await Task.sleep(for: .milliseconds(10))
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        #expect(text.contains("[test] first line\n    second line\n"))
    }
}
