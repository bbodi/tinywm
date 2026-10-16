/// Tells an app's own choice of focus after it closes a window from a choice the user made.
///
/// When a window closes, macOS lets its app focus another of its windows, and the app may pick
/// one on another workspace. tinywm knows when an app is closing a window: it presses the close
/// button itself for meta+Q, and it sees other windows go. That app's first focus change
/// afterwards is its own choice. Activating another app is the user's choice and ends the wait.
public struct CloseFocus: Sendable {
    /// The app closing a window, and the window, until the app's next focus change.
    public private(set) var closing: (app: Int32, window: String)?

    public init() {}

    public mutating func closing(_ window: String, app: Int32) { closing = (app, window) }

    /// The close of `window` did not happen after all.
    public mutating func cancel(_ window: String) {
        if closing?.window == window { closing = nil }
    }

    public mutating func activated(app: Int32) {
        if app != closing?.app { closing = nil }
    }

    /// Whether to keep focus on the shown workspace instead of following the app to `onOtherWorkspace`.
    public mutating func keepsFocus(app: Int32, onOtherWorkspace: Bool) -> Bool {
        guard let c = closing, c.app == app else { return false }
        closing = nil
        return onOtherWorkspace
    }
}
