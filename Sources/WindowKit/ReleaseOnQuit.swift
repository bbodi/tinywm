import AppKit
import ApplicationServices
import WindowCore

/// Puts every window an `AXWindows` knows back where it was found when the process exits, so
/// none is left squeezed into a tile or parked off screen.
///
/// Runs on quit, and on SIGTERM, SIGINT and SIGHUP, which skip `applicationWillTerminate`.
@MainActor
public final class WindowRelease {
    private let windows: AXWindows
    private let displays: () -> [Rect]
    /// Runs first on the way out, while the layout still holds every window.
    public var beforeRelease: () -> Void = {}
    private var released = false
    private var signalSources: [DispatchSourceSignal] = []

    /// `displays` returns the current screen frames, used to keep restored frames reachable.
    public init(windows: AXWindows, displays: @escaping () -> [Rect]) {
        self.windows = windows
        self.displays = displays
    }

    public func install() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.releaseAll() } }

        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.releaseAll()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Writes synchronously: the process is about to end, so queued writes would never run.
    /// Runs at most once.
    public func releaseAll() {
        guard !released else { return }
        released = true
        beforeRelease()
        let frames = releaseFrames(originals: windows.originalFrames, displays: displays())
        for (id, frame) in frames {
            guard let element = windows.element(of: id) else { continue }
            AXUIElementSetMessagingTimeout(element, 0.5)
            AX.setFrame(element, frame)
        }
    }
}
