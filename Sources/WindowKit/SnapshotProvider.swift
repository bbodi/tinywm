import CoreGraphics

/// Live pictures of windows. The overview and animations draw these in place of real windows.
///
/// Without Screen Recording access there is no provider, and consumers draw a plain placeholder.
@MainActor
public protocol SnapshotProvider: AnyObject {
    /// The latest picture of a window, or nil if none exists yet.
    func snapshot(of windowID: String) -> CGImage?
    /// Keeps these windows' pictures fresh until the next call. An empty set stops refreshing.
    func track(_ windowIDs: Set<String>)
    /// The desktop picture of the main display.
    func wallpaper() -> CGImage?
    /// Called on the main actor whenever any tracked window's picture changes.
    var onUpdate: [(String) -> Void] { get set }
    /// Sets how often tracked windows' pictures refresh, in frames per second.
    func setRate(_ fps: Double)
    /// Takes one fresh picture of each window now, ahead of the next scheduled one.
    func refresh(_ windowIDs: Set<String>)
}

extension SnapshotProvider {
    public func setRate(_: Double) {}
    public func refresh(_: Set<String>) {}
}
