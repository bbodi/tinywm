import AppKit
import StripEngine
import StripModel
import WindowCore

/// Shows the strip at the bottom of the screen while things move, then fades away.
@MainActor
final class MinimapPanel {
    private let panel: NSPanel
    private let view = MinimapView()
    private var hideWork: DispatchWorkItem?
    private let rowHeight: CGFloat = 54
    private let rowSpacing: CGFloat = 8
    private let padding: CGFloat = 10

    /// Looks up the app icon for a window ID.
    var icon: (String) -> NSImage? = { _ in nil }
    /// The screen the minimap appears on.
    var screen: () -> NSScreen? = { NSScreen.main }

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = view
    }

    func show(_ engine: StripEngine) {
        guard let screen = screen() else { return }
        let rows = minimapRows(engine.workspaces, engine.metrics)
        guard rows.contains(where: { !$0.windows.isEmpty }) else { return hide() }

        // Scale so a row is `rowHeight` tall, then shrink if the widest row would not fit.
        let worldW = rows.map(\.width).max() ?? 1
        var scale = rowHeight / CGFloat(engine.viewport.height)
        let maxW = screen.visibleFrame.width * 0.7 - padding * 2
        scale = min(scale, maxW / CGFloat(max(1, worldW)))
        let h = CGFloat(engine.viewport.height) * scale
        let size = NSSize(width: CGFloat(worldW) * scale + padding * 2,
                          height: CGFloat(rows.count) * h + CGFloat(rows.count - 1) * rowSpacing + padding * 2)
        let f = screen.visibleFrame
        panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.minY + 24, width: size.width, height: size.height), display: false)

        // The outline glides only while the minimap is already showing; a fresh one starts in place.
        let visible = panel.isVisible && panel.alphaValue > 0
        view.update(rows: rows, scale: scale, rowHeight: h, spacing: rowSpacing, padding: padding, icon: icon,
                    animate: visible)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hide() } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func close() { hideWork?.cancel(); panel.orderOut(nil) }

    private func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            MainActor.assumeIsolated { if panel.alphaValue == 0 { panel.orderOut(nil) } }
        })
    }
}

private final class MinimapView: NSView {
    private var rows: [MinimapRow] = []
    private var scale: CGFloat = 1
    private var rowHeight: CGFloat = 0
    private var spacing: CGFloat = 0
    private var padding: CGFloat = 0
    private var icon: (String) -> NSImage? = { _ in nil }
    /// The viewport outline as drawn now, plus the motion toward its target.
    private var outline: NSRect?
    private var outlineFrom = NSRect.zero
    private var outlineTo = NSRect.zero
    private var motionStart: CFTimeInterval = 0
    /// Steps the outline once per display refresh, so it moves in step with the screen.
    private var link: CADisplayLink?
    /// Same critically damped spring as the window pictures.
    private let omega = sqrt(Double(Spring.stiffness))

    override var isFlipped: Bool { true }

    func update(rows: [MinimapRow], scale: CGFloat, rowHeight: CGFloat, spacing: CGFloat, padding: CGFloat,
                icon: @escaping (String) -> NSImage?, animate: Bool) {
        self.rows = rows; self.scale = scale; self.rowHeight = rowHeight
        self.spacing = spacing; self.padding = padding; self.icon = icon

        guard let r = rows.firstIndex(where: { $0.isActive }), let v = rows[r].viewport else {
            outline = nil
            needsDisplay = true
            return
        }
        let top = padding + CGFloat(r) * (rowHeight + spacing)
        let target = NSRect(x: padding + CGFloat(v.x) * scale, y: top + CGFloat(v.y) * scale,
                            width: CGFloat(v.width) * scale, height: CGFloat(v.height) * scale)
        if animate, let current = outline, current != target {
            outlineFrom = current
            outlineTo = target
            motionStart = CACurrentMediaTime()
            if link == nil {
                let l = displayLink(target: self, selector: #selector(step))
                l.add(to: .main, forMode: .common)
                link = l
            }
        } else {
            outline = target
            outlineTo = target
        }
        needsDisplay = true
    }

    /// Advances the outline along a critically damped spring: x(t) = 1 - (1 + wt) e^(-wt).
    @objc private func step() {
        let t = CACurrentMediaTime() - motionStart
        let p = 1 - (1 + omega * t) * exp(-omega * t)
        if p > 0.999 {
            outline = outlineTo
            link?.invalidate()
            link = nil
        } else {
            let f = CGFloat(p)
            outline = NSRect(x: outlineFrom.minX + (outlineTo.minX - outlineFrom.minX) * f,
                             y: outlineFrom.minY + (outlineTo.minY - outlineFrom.minY) * f,
                             width: outlineFrom.width + (outlineTo.width - outlineFrom.width) * f,
                             height: outlineFrom.height + (outlineTo.height - outlineFrom.height) * f)
        }
        needsDisplay = true
    }

    override func draw(_ dirty: NSRect) {
        drawRows()
        if let outline {
            let path = NSBezierPath(roundedRect: outline.insetBy(dx: -1, dy: -1), xRadius: 5, yRadius: 5)
            path.lineWidth = 2
            NSColor.white.withAlphaComponent(0.9).setStroke()
            path.stroke()
        }
    }

    private func drawRows() {
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        NSColor(white: 0.08, alpha: 0.82).setFill()
        bg.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        bg.stroke()

        for (r, row) in rows.enumerated() {
            let top = padding + CGFloat(r) * (rowHeight + spacing)
            func map(_ rect: Rect) -> NSRect {
                NSRect(x: padding + CGFloat(rect.x) * scale, y: top + CGFloat(rect.y) * scale,
                       width: CGFloat(rect.width) * scale, height: CGFloat(rect.height) * scale)
            }
            let dim: CGFloat = row.isActive ? 1 : 0.45

            for w in row.windows {
                let box = map(w.rect).insetBy(dx: 1, dy: 1)
                let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
                (w.focused ? NSColor.controlAccentColor.withAlphaComponent(0.55)
                           : NSColor.white.withAlphaComponent(0.16 * dim)).setFill()
                path.fill()
                NSColor.white.withAlphaComponent(0.25 * dim).setStroke()
                path.stroke()
                if let image = icon(w.id) {
                    let side = min(box.width, box.height) * 0.62
                    guard side >= 8 else { continue }
                    let iconRect = NSRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
                    image.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: dim,
                               respectFlipped: true, hints: nil)
                }
            }

        }
    }
}
