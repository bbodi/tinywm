import AppKit
import ApplicationServices
import StripEngine
import WindowCore
import WindowKit

/// Decides when a new window joins a strip.
///
/// A browser tab dragged out becomes a window while the mouse is still held, and the browser
/// moves it itself until the drop. Placing it then fights that drag, and the window may not
/// repaint at its new size. So windows that appear during a mouse press wait for the release.
@MainActor
final class WindowArrivals {
    /// What is known about a window when it joins: how the rules judge it, what they looked at,
    /// and where the window is.
    struct Judged {
        var recognition: Recognition
        var facts: WindowFacts
        var frame: Rect?
    }

    /// Adds a window to a strip. Returns the frame it was given, if it was tiled.
    var place: (String, Judged) -> Rect? = { _, _ in nil }
    /// Judges a window now, from its current title and buttons, and answers later on the main
    /// thread, or not at all when the window is gone. Windows wait for the mouse, so this is asked late.
    var recognize: (String, AXUIElement, @escaping @MainActor (Judged) -> Void) -> Void = { _, _, _ in }

    private let windows: AXWindows
    private var waiting: [String: AXRef] = [:]
    /// Windows being judged on their app's queue, after any wait for the mouse.
    private var joining: Set<String> = []
    private var polling = false

    /// Time after the mouse is released before waiting windows are placed, so the app finishes its drop.
    var settle = 0.15

    init(windows: AXWindows) { self.windows = windows }

    func arrived(_ id: String, element: AXUIElement) {
        if NSEvent.pressedMouseButtons & 1 != 0 {
            Log.note("place", "\(Log.name(id)) waits for the mouse button to come up")
            waiting[id] = AXRef(element: element)
            poll()
        } else {
            join(id, element)
        }
    }

    func forget(_ id: String) {
        waiting[id] = nil
        joining.remove(id)
    }

    /// True while a new window waits for the mouse or for its judgement. The app may move such a
    /// window, as a browser does with a tab dragged out, and that move is not the user's drag.
    func isPending(_ id: String) -> Bool { waiting[id] != nil || joining.contains(id) }

    /// True while any window is still being judged.
    var isJudging: Bool { !joining.isEmpty }

    /// Watches for the mouse release while windows wait. A short poll is enough here and needs no
    /// event monitor that would see every click.
    private func poll() {
        guard !polling else { return }
        polling = true
        func check() {
            guard !waiting.isEmpty else { polling = false; return }
            if NSEvent.pressedMouseButtons & 1 != 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { check() } }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                MainActor.assumeIsolated {
                    self.polling = false
                    let ready = self.waiting
                    self.waiting = [:]
                    // Docking is judged after the drop: during a drag the window may not yet allow it.
                    // A window that still cannot dock is re-checked by the tracker and arrives later.
                    for (id, ref) in ready { self.join(id, ref.element) }
                }
            }
        }
        check()
    }

    private func join(_ id: String, _ element: AXUIElement) {
        joining.insert(id)
        recognize(id, element) { [weak self] judged in
            self?.joining.remove(id)
            switch judged.recognition.placement {
            case .tiled, .floating, .undockable: _ = self?.place(id, judged)
            case .unmanaged: break
            }
        }
    }
}
