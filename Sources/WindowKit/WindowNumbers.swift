import ApplicationServices
import CoreGraphics
import Foundation
import WindowCore

/// Maps Accessibility windows to CGWindowIDs, which ScreenCaptureKit needs.
///
/// Primary: the SPI `_AXUIElementGetWindow`, resolved with dlsym so nothing private is linked.
/// It is exact and has been stable for over a decade; many window managers rely on it.
/// Fallback when the symbol is missing or fails: match the CGWindow list by owner pid,
/// frame and title.
public enum WindowNumbers {
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static let getWindow: GetWindow? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(sym, to: GetWindow.self)
    }()

    public static func windowID(of element: AXUIElement, pid: pid_t) -> CGWindowID? {
        if let id = exactWindowID(of: element) { return id }
        return match(pid: pid, frame: AX.frame(element),
                     title: AX.attribute(element, kAXTitleAttribute, as: String.self))
    }

    /// The window number from the SPI alone, without the fallback match, which two windows of one
    /// app at the same frame would confuse.
    public static func exactWindowID(of element: AXUIElement) -> CGWindowID? {
        guard let getWindow else { return nil }
        var id: CGWindowID = 0
        return getWindow(element, &id) == .success && id != 0 ? id : nil
    }

    private static func match(pid: pid_t, frame: Rect?, title: String?) -> CGWindowID? {
        guard let frame,
              let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        var best: (id: CGWindowID, score: Int)?
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let b = info[kCGWindowBounds as String] as? [String: Double] else { continue }
            let r = Rect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard r.isApproximately(frame, tolerance: 2) else { continue }
            let score = (title != nil && (info[kCGWindowName as String] as? String) == title) ? 2 : 1
            if score > (best?.score ?? 0) { best = (id, score) }
        }
        return best?.id
    }
}
