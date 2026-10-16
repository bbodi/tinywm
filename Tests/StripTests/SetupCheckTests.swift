import Testing
@testable import StripEngine

@Suite struct SetupCheckTests {
    @Test func swipesAreFreeWithoutAClash() {
        #expect(SetupCheck.swipes(enabled: true, fingers: 3, settings: ["TrackpadFourFingerVertSwipeGesture": 2]).ok)
        #expect(SetupCheck.swipes(enabled: false, fingers: 3, settings: ["TrackpadThreeFingerDrag": 1]).ok)
    }

    @Test func swipeClashNamesTheGesturesAndTheOtherFingerCount() {
        let one = SetupCheck.swipes(enabled: true, fingers: 3, settings: ["TrackpadThreeFingerDrag": 1])
        #expect(!one.ok)
        #expect(one.status == "macOS also uses three-finger drag. Turn it off, or set swipe-fingers = 4 in the config.")
        let two = SetupCheck.swipes(enabled: true, fingers: 4, settings: ["TrackpadFourFingerHorizSwipeGesture": 2,
                                                                         "TrackpadFourFingerVertSwipeGesture": 2])
        #expect(two.status.hasPrefix("macOS also uses four-finger swipe between full-screen apps and four-finger swipe"))
        #expect(two.status.hasSuffix("Turn them off, or set swipe-fingers = 3 in the config."))
    }

    @Test func stageManagerIsOffUnlessSet() {
        #expect(SetupCheck.stageManager(settings: [:]).ok)
        #expect(SetupCheck.stageManager(settings: ["GloballyEnabled": 0]).ok)
        #expect(!SetupCheck.stageManager(settings: ["GloballyEnabled": 1]).ok)
    }

    @Test func edgeTilingIsOnUnlessBothDragsAreOff() {
        #expect(!SetupCheck.edgeTiling(settings: [:]).ok)
        #expect(!SetupCheck.edgeTiling(settings: ["EnableTilingByEdgeDrag": 0]).ok)
        #expect(!SetupCheck.edgeTiling(settings: ["EnableTilingByEdgeDrag": 0, "EnableTopTilingByEdgeDrag": 1]).ok)
        #expect(SetupCheck.edgeTiling(settings: ["EnableTilingByEdgeDrag": 0, "EnableTopTilingByEdgeDrag": 0,
                                                 "EnableTilingOptionAccelerator": 1]).ok)
    }

    @Test func clickWallpaperIsOnUnlessOnlyInStageManager() {
        #expect(!SetupCheck.clickWallpaper(settings: [:]).ok)
        #expect(!SetupCheck.clickWallpaper(settings: ["EnableStandardClickToShowDesktop": 1]).ok)
        #expect(SetupCheck.clickWallpaper(settings: ["EnableStandardClickToShowDesktop": 0]).ok)
    }

    @Test func otherWindowManagersMatchAppsByBundleAndDaemonsByName() {
        #expect(SetupCheck.otherWindowManagers(bundleIDs: ["com.apple.finder"], processNames: ["yabai-helper"]).ok)
        let one = SetupCheck.otherWindowManagers(bundleIDs: ["com.knollsoft.Rectangle"], processNames: [])
        #expect(one == SetupCheck.Result(ok: false, status: "Rectangle is running. Quit it so windows stay where tinywm puts them."))
        let three = SetupCheck.otherWindowManagers(bundleIDs: ["com.crowdcafe.windowmagnet", "bobko.aerospace"],
                                                   processNames: ["yabai"])
        #expect(three.status.hasPrefix("Magnet, AeroSpace and yabai are running. Quit them"))
    }

    @Test func loginRowFollowsTheLoginItem() {
        #expect(SetupCheck.login(.on).ok)
        #expect(!SetupCheck.login(.off).ok)
        #expect(!SetupCheck.login(.needsApproval).ok)
        #expect(SetupCheck.loginButtonTitle(.off) == "Turn On")
        #expect(SetupCheck.loginButtonTitle(.on) == "Turn Off")
        #expect(SetupCheck.loginButtonTitle(.needsApproval) == "Open Settings…")
        #expect(SetupCheck.loginButtonTitle(.unavailable) == nil)
    }
}
