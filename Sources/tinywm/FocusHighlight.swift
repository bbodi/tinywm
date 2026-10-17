import AppKit
import QuartzCore
import WindowCore
import WindowKit

/// Marks the focused window with a solid border, ordered directly above it in the window stack.
@MainActor
final class FocusHighlight {
    struct Style {
        var borderWidth: CGFloat = 5
        var cornerRadius: CGFloat = 12
        var glowRadius: CGFloat = 0
        /// A bright cyan that stands out against both light and dark windows.
        var color = NSColor(srgbRed: 0.085, green: 1.0, blue: 0.979, alpha: 1)
    }

    var style = Style()
    var showBorder = true { didSet { refresh() } }

    private let windows: AXWindows
    private let border: NSPanel
    private let ring = CAShapeLayer()
    private var suspended = false
    private var current: (id: String, frame: Rect)?
    /// What the panels show now, so an unchanged refresh does not re-stack windows.
    private var drawn: (window: Int, frame: Rect, border: Bool)?

    init(windows: AXWindows) {
        self.windows = windows
        border = Self.makePanel()
        let view = NSView()
        view.wantsLayer = true
        view.layer?.addSublayer(ring)
        border.contentView = view
        ring.fillColor = nil
        ring.lineJoin = .round

    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .normal
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        p.animationBehavior = .none
        return p
    }

    /// Shows the highlight on `id` at `frame` (Accessibility coordinates), or hides it for nil.
    /// `restack` forces re-ordering, for when macOS raised the window over the border.
    func show(_ id: String?, frame: Rect?, restack: Bool = false) {
        if let id, let frame { current = (id, frame) } else { current = nil }
        if restack { drawn = nil }
        refresh()
    }

    /// Holds the highlight still while motion pictures cover the screen, then catches up.
    /// Hiding and re-showing it on every motion is what made it flicker.
    func setSuspended(_ on: Bool) {
        suspended = on
        if !on { refresh() }
    }

    private func refresh() {
        guard !suspended else { return }
        guard let (id, frame) = current,
              let element = windows.element(of: id), let pid = windows.pid(of: id),
              let number = WindowNumbers.windowID(of: element, pid: pid) else {
            border.orderOut(nil)
            drawn = nil
            return
        }
        let target = Int(number)
        if let d = drawn, d.window == target, d.frame == frame, d.border == showBorder { return }
        drawn = (target, frame, showBorder)

        if showBorder {
            let pad = style.borderWidth + style.glowRadius
            let outer = Screens.appKitRect(frame).insetBy(dx: -pad, dy: -pad)
            border.setFrame(outer, display: false)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let color = style.color.cgColor
            ring.frame = NSRect(origin: .zero, size: outer.size)
            let inset = style.glowRadius + style.borderWidth / 2
            ring.path = CGPath(roundedRect: ring.bounds.insetBy(dx: inset, dy: inset),
                               cornerWidth: style.cornerRadius, cornerHeight: style.cornerRadius, transform: nil)
            ring.lineWidth = style.borderWidth
            ring.strokeColor = color
            ring.shadowColor = color
            ring.shadowOpacity = style.glowRadius > 0 ? 0.9 : 0
            ring.shadowRadius = style.glowRadius
            ring.shadowOffset = .zero
            CATransaction.commit()
            border.order(.above, relativeTo: target)
        } else {
            border.orderOut(nil)
        }
    }

}
