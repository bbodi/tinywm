import Testing
@testable import StripEngine

@Suite struct SwipeClashTests {
    @Test func threeFingerSystemGesturesClashWithThreeFingerSwipes() {
        let s = ["TrackpadThreeFingerHorizSwipeGesture": 2, "TrackpadFourFingerVertSwipeGesture": 2]
        #expect(SwipeClash.clashes(fingers: 3, settings: s) == ["three-finger swipe between pages or full-screen apps"])
        #expect(SwipeClash.clashes(fingers: 4, settings: s) == ["four-finger swipe for Mission Control and App Exposé"])
    }

    @Test func offOrMissingGesturesDoNotClash() {
        #expect(SwipeClash.clashes(fingers: 3, settings: ["TrackpadThreeFingerDrag": 0]).isEmpty)
        #expect(SwipeClash.clashes(fingers: 4, settings: [:]).isEmpty)
    }

    @Test func threeFingerDragClashes() {
        #expect(SwipeClash.clashes(fingers: 3, settings: ["TrackpadThreeFingerDrag": 1]) == ["three-finger drag"])
    }
}

@Suite struct SwipeConfigTests {
    @Test func swipeSettingsParse() {
        let r = StripConfig.parse("swipe = off\nswipe-fingers = 4")
        #expect(r.issues.isEmpty)
        #expect(r.config.swipe == false)
        #expect(r.config.swipeFingers == 4)
    }

    @Test func otherFingerCountsAreRejected() {
        let r = StripConfig.parse("swipe-fingers = 2\nswipe = sometimes")
        #expect(r.issues.count == 2)
        #expect(r.config.swipeFingers == 3)
        #expect(r.config.swipe == true)
    }
}
