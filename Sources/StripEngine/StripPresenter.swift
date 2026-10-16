import WindowCore

/// Shows motion with window pictures while the real windows move once, underneath.
///
/// The landing sequence:
/// - Pictures go up first, then the real windows are written 0.034 s later.
/// - Write completions are counted to know when the windows landed.
/// - The pictures fade only when the
///   motion has settled, every window has landed and fresh pictures exist, or a time-out passes.
/// - Without pictures, windows are written directly, the windows with no animation.
@MainActor
public protocol StripPresenter: AnyObject {
    /// Starts a motion. `focused` is the window that has focus once it lands, so the focus border
    /// can travel with the pictures. Returns a token for it, or nil when pictures are unavailable.
    func begin(moves: [String: (from: Rect, to: Rect)], still: [String: Rect], focused: String?) -> Int?
    /// Seconds to wait after `begin` before writing the real windows.
    var writeDelay: Double { get }
    /// Called when the system confirms a real window reached its frame for motion `token`.
    func landed(_ id: String, token: Int)
    /// Called after every write for motion `token` has been issued, with the windows involved.
    func writesIssued(_ ids: Set<String>, token: Int)
    /// Draws the strip at `frames` right now, without animation, while fingers drag it.
    /// Returns false when pictures are unavailable.
    func preview(frames: [String: Rect], focused: String?) -> Bool
    /// Ends a drag preview that no motion took over, e.g. a swipe that settled where it began.
    func endPreview()
    /// Moves the pictures to `frames` with the motion springs, without writing any window.
    /// While a window is dragged, this opens the gap where it would land. Returns false when
    /// pictures are unavailable.
    func arrange(frames: [String: Rect]) -> Bool
}

public extension StripPresenter {
    func arrange(frames: [String: Rect]) -> Bool { preview(frames: frames, focused: nil) }
}
