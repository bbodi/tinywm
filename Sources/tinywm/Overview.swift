import AppKit
import QuartzCore
import StripEngine
import StripModel
import WindowCore
import WindowKit

/// A niri-style overview: the display's workspaces zoom out into stacked rows of live window
/// pictures, one selection moves among them, and choosing a window zooms into its workspace.
/// The real windows do not move while it is open.
@MainActor
final class Overview {
    private enum Phase { case closed, open, closing }

    /// Switches to the window's workspace and gives it focus.
    var activate: (String) -> Void = { _ in }
    /// Floating windows' frames, read once when the overview opens.
    private var floats: [String: Rect] = [:]
    var ringStyle = FocusHighlight.Style()
    var stiffness = Spring.stiffness
    /// Pictures refresh this often while the overview is open.
    var rate = 10.0

    private let snapshots: ScreenCaptureSnapshots
    private let pictures: WindowPictures
    private let windows: AXWindows
    private let panel: OverviewPanel
    private let view = OverviewView()
    private let root = CALayer()
    private let backdrop = CALayer()
    private let dim = CALayer()
    private let ring = CALayer()
    private var layers: [String: WindowLayer] = [:]

    private var phase = Phase.closed
    private var engine: StripEngine?
    private var screen: NSScreen?
    private var viewport = Rect(x: 0, y: 0, width: 1, height: 1)
    private var metrics = StripMetrics(viewport: Rect(x: 0, y: 0, width: 1, height: 1), gap: 0)
    private var layout: OverviewLayout?
    /// Each window's real frame when the overview opened, which is also its picture's size.
    private var real: [String: Rect] = [:]
    private var selected: String?
    private var previous: String?
    private var pan = 0.0
    private var token = 0

    var isOpen: Bool { phase != .closed }
    var keys: OverviewKeys {
        get { view.keys }
        set { view.keys = newValue }
    }

    init(pictures: WindowPictures, windows: AXWindows) {
        self.pictures = pictures
        self.snapshots = pictures.snapshots
        self.windows = windows
        panel = OverviewPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.animationBehavior = .none
        panel.alphaValue = 0

        view.wantsLayer = true
        view.layer?.addSublayer(root)
        root.masksToBounds = true
        root.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        backdrop.contentsGravity = .resizeAspectFill
        root.addSublayer(backdrop)
        dim.backgroundColor = NSColor(white: 0, alpha: 0.45).cgColor
        root.addSublayer(dim)
        ring.zPosition = 10
        root.addSublayer(ring)
        panel.contentView = view

        view.onKey = { [weak self] in self?.handle($0) }
        view.onHover = { [weak self] p in
            guard let self, phase == .open, let hit = layout?.window(at: Point(x: p.x, y: p.y)) else { return }
            select(hit.id)
        }
        view.onClick = { [weak self] p in
            guard let self, phase == .open, let hit = layout?.window(at: Point(x: p.x, y: p.y)) else { return }
            close(selecting: hit.id)
        }
        view.onScroll = { [weak self] delta in
            guard let self, phase == .open, let layout else { return }
            pan = max(0, min(layout.panRange, pan - Double(delta)))
            relayout(animated: false)
        }
        snapshots.onUpdate.append { [weak self] id in self?.pictureArrived(id) }
    }

    /// Opens on `engine`'s display, or closes onto the highlighted window.
    func toggle(_ engine: StripEngine, on screen: NSScreen?) {
        switch phase {
        case .closed: open(engine, on: screen)
        case .open: close(selecting: selected)
        case .closing: break
        }
    }

    // MARK: Opening

    private func open(_ engine: StripEngine, on screen: NSScreen?) {
        guard pictures.available, let screen else { return }
        let ws = engine.workspaces
        let m = engine.metrics
        let size = Size(width: m.viewport.width, height: m.viewport.height)
        floats = engine.floatFrames()
        let probe = overviewLayout(ws, m, screen: size, floats: floats)
        guard let first = probe.windows.first?.id else { return }

        self.engine = engine
        self.screen = screen
        viewport = engine.viewport
        metrics = m
        previous = windows.focusedWindow
        selected = ws.current.focusedWindow.flatMap { probe.window($0) != nil ? $0 : nil } ?? first
        pan = probe.pan(toReveal: selected!, current: 0)
        layout = overviewLayout(ws, m, screen: size, pan: pan, floats: floats)
        real = overviewRealFrames(ws, m, floats: floats)
        phase = .open
        token += 1

        place()
        refreshBackdrop()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (_, layer) in layers { layer.removeFromSuperlayer() }
        layers = [:]
        for w in layout!.windows {
            guard let r = real[w.id] else { continue }
            let layer = WindowLayer()
            layer.bounds = CGRect(origin: .zero, size: CGSize(width: r.width, height: r.height))
            layer.position = CGPoint(x: r.center.x, y: r.center.y)
            pictures.show(w.id, on: layer)
            root.addSublayer(layer)
            layers[w.id] = layer
        }
        styleRing()
        ring.removeAllAnimations()
        ring.frame = outset(NSRect(real[selected!]!))
        dim.opacity = 0
        CATransaction.commit()
        CATransaction.flush()

        snapshots.beginLive(Set(layers.keys), rate: rate)
        panel.alphaValue = PictureMotion.coveringAlpha
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(view)

        relayout(animated: true, fromModel: true)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.25
        dim.add(fade, forKey: "dim")
        dim.opacity = 1
    }

    // MARK: Keys and selection

    func handle(_ key: OverviewCommand) {
        guard phase == .open, let layout, let selected else { return }
        let next: String?
        switch key {
        case .left: next = overviewMove(layout, from: selected, .left)
        case .right: next = overviewMove(layout, from: selected, .right)
        case .up: next = overviewMove(layout, from: selected, .up)
        case .down: next = overviewMove(layout, from: selected, .down)
        case .next: next = overviewStep(layout, from: selected, by: 1)
        case .previous: next = overviewStep(layout, from: selected, by: -1)
        case .confirm: return close(selecting: selected)
        case .cancel: return close(selecting: nil)
        }
        if let next { select(next) }
    }

    private func select(_ id: String) {
        guard id != selected, let layout else { return }
        selected = id
        pan = layout.pan(toReveal: id, current: pan)
        relayout(animated: true)
    }

    // MARK: Closing

    /// Zooms into `id`'s workspace, or back to the unchanged layout for nil.
    private func close(selecting id: String?) {
        guard phase == .open, let engine else { return }
        phase = .closing
        token += 1
        let mine = token
        var targets = real
        var ringTarget = (id ?? previous).flatMap { real[$0] }
        if let id {
            activate(id)
            targets = overviewRealFrames(engine.workspaces, engine.metrics, floats: engine.floatFrames())
            ringTarget = targets[id]
        } else if let previous {
            windows.focus(previous)
        }

        var longest: CFTimeInterval = 0
        CATransaction.begin()
        for (wid, layer) in layers {
            guard let t = targets[wid] ?? real[wid] else { continue }
            longest = max(longest, move(layer, to: CGPoint(x: t.center.x, y: t.center.y),
                                        scale: CGFloat(t.width) / layer.bounds.width))
        }
        if let ringTarget { longest = max(longest, moveRing(to: outset(NSRect(ringTarget)))) }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = dim.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = longest
        dim.add(fade, forKey: "dim")
        dim.opacity = 0
        CATransaction.commit()

        DispatchQueue.main.asyncAfter(deadline: .now() + longest) { [weak self] in
            MainActor.assumeIsolated { self?.finish(mine) }
        }
    }

    private func finish(_ mine: Int) {
        guard phase == .closing, mine == token else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.phase == .closing, self.token == mine else { return }
                self.panel.orderOut(nil)
                for (_, layer) in self.layers { layer.removeFromSuperlayer() }
                self.layers = [:]
                self.engine = nil
                self.layout = nil
                self.snapshots.endLive(after: 1.0)
                self.phase = .closed
            }
        })
    }

    // MARK: Drawing

    /// Puts every picture and the ring where the current layout says. Pictures are scaled by
    /// their layer's transform, so each stays in proportion.
    private func relayout(animated: Bool, fromModel: Bool = false) {
        guard let engine else { return }
        let size = Size(width: viewport.width, height: viewport.height)
        let next = overviewLayout(engine.workspaces, metrics, screen: size, pan: pan, floats: floats)
        layout = next
        CATransaction.begin()
        if !animated { CATransaction.setDisableActions(true) }
        for w in next.windows {
            guard let layer = layers[w.id] else { continue }
            let centre = CGPoint(x: w.rect.center.x, y: w.rect.center.y)
            let scale = CGFloat(w.rect.width) / layer.bounds.width
            if animated { _ = move(layer, to: centre, scale: scale, fromModel: fromModel) } else {
                layer.removeAllAnimations()
                layer.position = centre
                layer.transform = CATransform3DMakeScale(scale, scale, 1)
            }
        }
        if let selected, let w = next.window(selected) {
            let target = outset(NSRect(w.rect))
            if animated { _ = moveRing(to: target, fromModel: fromModel) } else {
                ring.removeAllAnimations()
                ring.frame = target
            }
        }
        CATransaction.commit()
    }

    /// Sets the layer's final state and springs it there from where it is on screen.
    private func move(_ layer: CALayer, to centre: CGPoint, scale: CGFloat, fromModel: Bool = false) -> CFTimeInterval {
        let from = fromModel ? nil : layer.presentation()
        let fromPosition = from?.position ?? layer.position
        // Read the scale from the matrix. A key-value read of "transform.scale" can fail to cast,
        // and falling back to 1 made every picture jump to full size before shrinking back.
        let fromScale = (from ?? layer).transform.m11
        layer.removeAllAnimations()
        layer.position = centre
        layer.transform = CATransform3DMakeScale(scale, scale, 1)
        let position = spring("position", NSValue(point: fromPosition), NSValue(point: centre))
        let zoom = spring("transform.scale", NSNumber(value: Double(fromScale)), NSNumber(value: Double(scale)))
        let group = CAAnimationGroup()
        group.animations = [position, zoom]
        group.duration = max(position.duration, zoom.duration)
        layer.add(group, forKey: "move")
        return group.duration
    }

    private func moveRing(to target: NSRect, fromModel: Bool = false) -> CFTimeInterval {
        let from = fromModel ? ring.frame : (ring.presentation()?.frame ?? ring.frame)
        ring.removeAllAnimations()
        ring.frame = target
        let position = spring("position", NSValue(point: NSPoint(x: from.midX, y: from.midY)),
                              NSValue(point: NSPoint(x: target.midX, y: target.midY)))
        let size = spring("bounds.size", NSValue(size: from.size), NSValue(size: target.size))
        let group = CAAnimationGroup()
        group.animations = [position, size]
        group.duration = max(position.duration, size.duration)
        ring.add(group, forKey: "move")
        return group.duration
    }

    private func spring(_ key: String, _ from: Any, _ to: Any) -> CASpringAnimation {
        Spring.critical(key, from: from, to: to, stiffness: stiffness)
    }

    private func pictureArrived(_ id: String) {
        guard phase != .closed, !pictures.coverMode, let layer = layers[id] else { return }
        layer.setPicture(snapshots.surface(of: id))
    }

    private func styleRing() {
        let color = ringStyle.color.cgColor
        ring.borderWidth = ringStyle.borderWidth
        ring.borderColor = color
        ring.cornerRadius = ringStyle.cornerRadius / 2 + ringStyle.borderWidth / 2
        ring.shadowColor = color
        ring.shadowOpacity = ringStyle.glowRadius > 0 ? 0.9 : 0
        ring.shadowRadius = ringStyle.glowRadius
        ring.shadowOffset = .zero
    }

    private func outset(_ r: NSRect) -> NSRect { r.insetBy(dx: -ringStyle.borderWidth, dy: -ringStyle.borderWidth) }

    /// Shows the captured desktop, which is what is really on screen, or the desktop picture's
    /// file when there is no capture, so the backdrop is ready on the first frame.
    private func refreshBackdrop() {
        // The captured desktop is what is really on screen; the picture's file can differ.
        if let captured = snapshots.wallpaper() {
            backdrop.contents = captured
            return
        }
        guard let screen else { return }
        if let url = NSWorkspace.shared.desktopImageURL(for: screen), let image = NSImage(contentsOf: url),
           let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            backdrop.contents = cg
        }
    }

    /// Covers the display's usable area; the viewport is in Accessibility coordinates.
    private func place() {
        let frame = Screens.appKitRect(viewport)
        panel.setFrame(frame, display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = NSRect(origin: .zero, size: frame.size)
        dim.frame = root.bounds
        if let screen {
            let whole = Screens.axRect(screen.frame)
            backdrop.frame = NSRect(x: whole.x - viewport.x, y: whole.y - viewport.y, width: whole.width, height: whole.height)
        } else {
            backdrop.frame = root.bounds
        }
        CATransaction.commit()
    }
}
