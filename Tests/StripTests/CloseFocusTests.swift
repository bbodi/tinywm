import Testing
@testable import StripEngine

@Suite struct CloseFocusTests {
    /// A close that was skipped must not change how the app's next focus change is read.
    @Test func aCancelledCloseLeavesTheNextFocusChangeAlone() {
        var c = CloseFocus()
        c.closing("w1", app: 10)
        c.cancel("w2")
        #expect(c.closing?.window == "w1")
        c.cancel("w1")
        #expect(c.closing == nil)
        let kept = c.keepsFocus(app: 10, onOtherWorkspace: true)
        #expect(!kept)
    }

    @Test func theClosingAppsJumpToAnotherWorkspaceIsOverridden() {
        var c = CloseFocus()
        c.closing("w1", app: 10)
        let k1 = c.keepsFocus(app: 10, onOtherWorkspace: true)
        #expect(k1)
    }

    @Test func onlyTheFirstFocusChangeAfterTheCloseIsTheApps() {
        var c = CloseFocus()
        c.closing("w1", app: 10)
        let k2 = c.keepsFocus(app: 10, onOtherWorkspace: false)
        #expect(!k2)
        let k3 = c.keepsFocus(app: 10, onOtherWorkspace: true)
        #expect(!k3)
    }

    @Test func otherAppsAreFollowed() {
        var c = CloseFocus()
        c.closing("w1", app: 10)
        let k4 = c.keepsFocus(app: 20, onOtherWorkspace: true)
        #expect(!k4)
        let k5 = c.keepsFocus(app: 10, onOtherWorkspace: true)
        #expect(k5)
    }

    @Test func activatingAnotherAppEndsTheWait() {
        var c = CloseFocus()
        c.closing("w1", app: 10)
        c.activated(app: 20)
        let k6 = c.keepsFocus(app: 10, onOtherWorkspace: true)
        #expect(!k6)
    }

    @Test func theClosingAppStayingActiveKeepsTheWait() {
        var c = CloseFocus()
        c.closing("w1", app: 10)
        c.activated(app: 10)
        let k7 = c.keepsFocus(app: 10, onOtherWorkspace: true)
        #expect(k7)
    }
}
