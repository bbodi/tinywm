import Testing
import WindowCore

@Suite struct CoverTests {
    let grey = RGBA(r: 0.9, g: 0.9, b: 0.9)

    @Test func blendingMixesByTheAmount() {
        let red = RGBA(r: 1, g: 0, b: 0)
        let mixed = red.blended(over: RGBA(r: 0, g: 0, b: 1), amount: 0.72)
        #expect(abs(mixed.r - 0.72) < 1e-9)
        #expect(abs(mixed.b - 0.28) < 1e-9)
        #expect(red.blended(over: grey, amount: 2) == red)
        #expect(red.blended(over: grey, amount: -1) == grey)
    }

    @Test func theAverageIgnoresTransparentPixels() {
        // One opaque red pixel, one half-transparent blue one (premultiplied), one clear one.
        let bytes: [UInt8] = [255, 0, 0, 255, 0, 0, 128, 128, 0, 0, 0, 0]
        let avg = RGBA.average(premultipliedRGBA: bytes)
        #expect(avg.map { abs($0.r - 255.0 / 383) < 1e-9 && abs($0.b - 128.0 / 383) < 1e-9 } == true)
        #expect(RGBA.average(premultipliedRGBA: [0, 0, 0, 0]) == nil)
        #expect(RGBA.average(premultipliedRGBA: []) == nil)
    }

    @Test func aCoverShowsTheIconTintedCardAndTheTitle() {
        let blue = RGBA(r: 0, g: 0, b: 1)
        let c = Cover(windowTitle: " Inbox ", appName: "Mail", iconColour: blue, background: grey)
        #expect(c.title == "Inbox")
        #expect(c.showsIcon)
        #expect(c.colour == blue.blended(over: grey, amount: 0.72))
    }

    @Test func anUntitledWindowShowsItsAppsName() {
        #expect(Cover(windowTitle: "", appName: "Mail", iconColour: nil, background: grey).title == "Mail")
        #expect(Cover(windowTitle: nil, appName: nil, iconColour: nil, background: grey).title == "")
    }

    @Test func withoutAnIconTheCardIsPlain() {
        let c = Cover(windowTitle: "Notes", appName: nil, iconColour: nil, background: grey)
        #expect(!c.showsIcon)
        #expect(c.colour == grey)
    }
}
