import AppKit
import ApplicationServices
import StripEngine
import WindowCore
import WindowKit

/// Hands focus back when an app marked `no-focus` takes it on its own.
///
/// Opening a window or launching an app makes macOS focus it no matter what tinywm decided.
/// The last window that legitimately had focus is remembered, and focus returns there.
@MainActor
final class FocusKeeper {
    var rules: () -> WindowRules = { WindowRules() }

    private let windows: AXWindows
    private var lastManaged: String?
    private var own: (pid: pid_t, at: Date)?

    init(windows: AXWindows) {
        self.windows = windows
        // Every focus tinywm asks for, including its own focus commands, is left alone.
        windows.onFocusRequested.append { [weak self] id in
            guard let self, let pid = self.windows.pid(of: id) else { return }
            self.own = (pid, Date())
        }
    }

    func facts(of id: String) -> WindowFacts? {
        guard let pid = windows.pid(of: id) else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        return WindowFacts(bundleID: app?.bundleIdentifier, appName: app?.localizedName, title: windows.cachedTitle(of: id))
    }

    /// A known window took focus. Returns true if focus was handed back, so the strip should not follow it.
    func focused(window id: String) -> Bool {
        guard let pid = windows.pid(of: id), let facts = facts(of: id) else { return false }
        if shouldRestore(facts, inputAges(pid: pid)), restore(except: id) { return true }
        lastManaged = id
        return false
    }

    /// An app came to the front. This covers a focus change that reports no window event.
    func activated(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0 else { return }
        // The input is judged as of the activation. A slow read would make a deliberate click look old.
        let input = inputAges(pid: pid)
        let activation = windows.activations
        windows.readFocused(of: pid) { [weak self] read in
            // Once the user has moved on, handing focus back would take it from where they went.
            guard let self, read.isCurrent, windows.activations == activation else { return }
            let facts = WindowFacts(bundleID: app.bundleIdentifier, appName: app.localizedName, title: read.title)
            if shouldRestore(facts, input) {
                _ = restore(except: read.id)
            } else if let id = read.id {
                // An app brought back to its focused window reports no focus change for it.
                lastManaged = id
            }
        }
    }

    /// Seconds since the last click, key press and focus tinywm asked for in the app.
    private struct InputAges {
        var mouseDown: Double
        var keyDown: Double
        var ownFocus: Double?
    }

    /// Seconds since the last event of any of these types, from any source.
    static func since(_ types: [CGEventType]) -> Double {
        types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
    }

    private func inputAges(pid: pid_t) -> InputAges {
        let since = Self.since
        // Releasing ⌘ ends a ⌘-Tab, so modifier changes count as key presses.
        return InputAges(
            mouseDown: since([.leftMouseDown, .rightMouseDown]),
            keyDown: since([.keyDown, .flagsChanged]),
            ownFocus: own.flatMap { $0.pid == pid ? Date().timeIntervalSince($0.at) : nil })
    }

    private func shouldRestore(_ facts: WindowFacts, _ input: InputAges) -> Bool {
        FocusIntent.shouldRestore(
            matchesNoFocus: rules().noFocus(facts),
            secondsSinceMouseDown: input.mouseDown,
            secondsSinceKeyDown: input.keyDown,
            secondsSinceOwnFocus: input.ownFocus)
    }

    private func restore(except id: String?) -> Bool {
        guard let back = lastManaged, back != id, windows.element(of: back) != nil else { return false }
        Log.note("focus", "no-focus rule: focus returns to \(Log.name(back))")
        windows.focus(back)
        return true
    }
}
