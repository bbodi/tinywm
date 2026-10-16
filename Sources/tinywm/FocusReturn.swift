import AppKit
import WindowKit

/// Gives focus back to the window that had it after a launcher closes.
///
/// A launcher such as Look shows a panel and may activate its own app for it. When the panel
/// closes, macOS does not always return focus: the launcher stays the front app with no window,
/// or the window under the panel is not made key again. If the launcher opens another app
/// instead, that app comes to the front and nothing is done.
@MainActor
final class FocusReturn {
    private let windows: AXWindows
    private var timer: Timer?

    /// The last key pressed and when, from the key tap.
    var lastKeyDown: () -> (code: Int, at: Date)? = { nil }

    init(windows: AXWindows) { self.windows = windows }

    /// Starts watching, just before tinywm presses keys that may open a launcher.
    func watch() {
        timer?.invalidate()
        guard let app = NSWorkspace.shared.frontmostApplication, let window = windows.focusedWindow else { return }
        let home = app.processIdentifier
        let started = Date()
        var launcher: pid_t?
        var panelSeen = false
        // After focus went back, the launcher may activate itself once more as it finishes
        // closing; focus goes back again while that can still happen.
        var guardUntil: Date?
        var refocused = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let elapsed = Date().timeIntervalSince(started)
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                let owner = Self.keyboardOwner()
                if let until = guardUntil {
                    guard Date() < until else { return self.stop() }
                    if let l = launcher, front == l, refocused < 3, !Self.showsPanel(l) {
                        refocused += 1
                        self.windows.focus(window)
                    }
                    return
                }
                guard let l = launcher else {
                    // The first other app that comes forward or takes the keyboard is the launcher.
                    if let f = front, f != home { launcher = f } else if let o = owner, o != home { launcher = o }
                    else if elapsed > 1.5 { self.stop() }
                    return
                }
                if Self.showsPanel(l) {
                    panelSeen = true
                    if elapsed > 300 { self.stop() }
                    return
                }
                guard panelSeen else {
                    if elapsed > 1.5 { self.stop() }
                    return
                }
                // A third app in front after the launcher closed: the launcher opened it, unless
                // the launcher was cancelled with Esc and macOS picked that app by itself.
                if let f = front, f != home, f != l, !self.cancelled(since: started) { return self.stop() }
                self.windows.focus(window)
                guardUntil = Date().addingTimeInterval(1.5)
            }
        }
    }

    private func cancelled(since start: Date) -> Bool {
        guard let k = lastKeyDown() else { return false }
        return k.code == 53 && k.at > start
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// The app that owns the element with keyboard focus.
    private static func keyboardOwner() -> pid_t? {
        guard let element = AX.attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute, as: AXUIElement.self)
        else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    /// Whether the app has a window on screen above normal windows, as a launcher panel is.
    private static func showsPanel(_ pid: pid_t) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.contains {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && (($0[kCGWindowLayer as String] as? Int) ?? 0) > 0
        }
    }
}

