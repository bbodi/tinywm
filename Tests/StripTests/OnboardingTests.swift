import Testing
@testable import StripEngine

@Suite struct OnboardingTests {
    @Test func stepFollowsPermissions() {
        #expect(Onboarding.step(accessibility: false, screenRecording: false) == .needsAccessibility)
        #expect(Onboarding.step(accessibility: false, screenRecording: true) == .needsAccessibility)
        #expect(Onboarding.step(accessibility: true, screenRecording: false) == .canStart)
        #expect(Onboarding.step(accessibility: true, screenRecording: true) == .allSet)
    }

    @Test func primaryButtonWaitsForAccessibility() {
        #expect(!Onboarding.primaryButtonEnabled(.needsAccessibility))
        #expect(Onboarding.primaryButtonEnabled(.canStart))
        #expect(Onboarding.primaryButtonEnabled(.allSet))
        #expect(Onboarding.primaryButtonTitle(.needsAccessibility) == "Start tinywm")
        #expect(Onboarding.primaryButtonTitle(.allSet) == "Done")
    }

    @Test func showsOnlyOnFirstLaunch() {
        #expect(Onboarding.shouldShowOnLaunch(seenBefore: false))
        #expect(!Onboarding.shouldShowOnLaunch(seenBefore: true))
    }

    @Test func restartOnlyWhenScreenRecordingArrivedAfterLaunchInBundle() {
        #expect(Onboarding.needsRestart(screenRecordingAtLaunch: false, screenRecordingNow: true, inBundle: true))
        #expect(!Onboarding.needsRestart(screenRecordingAtLaunch: true, screenRecordingNow: true, inBundle: true))
        #expect(!Onboarding.needsRestart(screenRecordingAtLaunch: false, screenRecordingNow: false, inBundle: true))
        #expect(!Onboarding.needsRestart(screenRecordingAtLaunch: false, screenRecordingNow: true, inBundle: false))
    }

    @Test func loginItemStatesMapToActions() {
        #expect(LoginItemState.off.action == .register)
        #expect(LoginItemState.on.action == .unregister)
        #expect(LoginItemState.needsApproval.action == .openSettings)
        #expect(LoginItemState.unavailable.action == .none)
        #expect(LoginItemState.on.isChecked)
        #expect(LoginItemState.needsApproval.isChecked)
        #expect(!LoginItemState.off.isChecked)
        #expect(!LoginItemState.unavailable.isChecked)
    }
}
