import Foundation

/// The engine's only view of real windows. The app implements it with the Accessibility API;
/// tests implement it with a dictionary.
@MainActor
public protocol WindowSystem: AnyObject {
    /// Moves a window. The completion receives the frame the window actually took, because apps
    /// can refuse sizes below their minimum.
    func setFrame(_ id: String, _ rect: Rect, completion: @escaping @MainActor (Rect?) -> Void)
    func focus(_ id: String)
    var focusedWindow: String? { get }
    /// The focused window as last seen, without asking any app. Code that runs on every key
    /// press or motion reads this, because an app busy redrawing answers late.
    var knownFocus: String? { get }
    /// Where the window was when last seen, or nil when that is unknown. It never asks the
    /// window's app, since hit tests and drags read it while an app may be busy.
    func frameOf(_ id: String) -> Rect?
    /// Asks the window's app where the window is now, without blocking the main thread.
    func readFrame(_ id: String, completion: @escaping @MainActor (Rect?) -> Void)
}

public extension WindowSystem {
    func frameOf(_ id: String) -> Rect? { nil }
    var knownFocus: String? { focusedWindow }
    func readFrame(_ id: String, completion: @escaping @MainActor (Rect?) -> Void) { completion(frameOf(id)) }
}
