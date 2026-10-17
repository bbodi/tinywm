import AppKit
import QuartzCore
import StripEngine
import WindowCore
import WindowKit

/// Pictures in motion: window pictures slide over the desktop picture while each
/// real window is written once underneath, and the pictures fade only after the windows landed.
@MainActor
final class PictureMotion: StripPresenter {
    /// Real windows are written 0.034 s after the pictures go up, so the pictures cover them first.
    let writeDelay = 0.034
    /// Gives up waiting 0.95 s after the motion settled, or 1.4 s after it began.
    var settleTimeout = 0.95
    var startTimeout = 1.4
    /// How long the pictures take to fade out.
    var fadeDuration = 0.2
    var stiffness = Spring.stiffness
    /// Told when pictures start covering the screen (true) and when they start fading (false).
    var onActive: (Bool) -> Void = { _ in }
    /// Told when pictures cover the screen (true) and once they are fully gone (false).
    var onCovering: (Bool) -> Void = { _ in }
    /// The focus border's look, and whether it is on. The ring in the pictures matches it.
    var ringStyle = FocusHighlight.Style()
    var showRing: () -> Bool = { true }

    private let snapshots: ScreenCaptureSnapshots
    /// Shows each window's picture, or its cover in cover mode.
    private let pictures: WindowPictures
    private let windows: AXWindows
    private let panel: NSPanel
    private let root = CALayer()
    private let backdrop = CALayer()
    private var layers: [String: WindowLayer] = [:]
    /// The focus border drawn among the pictures, so it travels with them.
    private let ring = CALayer()
    /// Where the ring was last sent, which is where the real border sits between motions.
    private var ringTarget: NSRect?
    private var backdropURL: URL?
    private let meter = FrameMeter()

    private enum Phase {
        /// The panel is hidden.
        case idle
        /// Fingers or a drag place the pictures directly, and no motion has taken over yet.
        case previewing
        /// The pictures spring to their targets while the real windows are written underneath.
        case moving
        /// The panel fades out over the windows, which are in place.
        case fading
    }
    private var phase = Phase.idle
    /// True while the panel is up, in any phase but idle.
    private var active: Bool { phase != .idle }

    /// Counts motions. Each callback carries the token of the motion it belongs to, and one from
    /// an earlier motion is ignored.
    private var token = 0

    /// What one motion waits for before the pictures fade. `begin` starts a new one.
    private struct Motion {
        /// When the motion began, for the timings in the log; 0 once it has ended.
        var began: CFTimeInterval = 0
        var settledAt: Double?
        /// The windows the engine wrote, once it has written them all.
        var issued: Set<String>?
        var landed: Set<String> = []
        /// Resized windows still waiting for a picture at their new size.
        var needsPicture: Set<String> = []
        /// Final size, in points, of each window that changes size, to recognise its new picture.
        var targetSizes: [String: CGSize] = [:]
        /// Windows whose newest picture waits for the motion to end.
        var deferred: Set<String> = []
    }
    private var current = Motion()
    /// Pictures are retaken this often while anything moves. A motion lasts under half a
    /// second, so a picture taken as it begins stays good, and capturing more often costs drawing time.
    var motionRate = 4.0
    /// Pictures keep refreshing this long after motion ends, so quick repeated moves stay current.
    var liveLinger = 1.0

    /// The usable screen area in Accessibility coordinates; the pictures cover exactly this.
    var viewport = Rect(x: 0, y: 0, width: 1, height: 1) { didSet { place() } }
    /// The screen this overlay covers, for its desktop picture.
    var screen: () -> NSScreen? = { NSScreen.main }

    init(pictures: WindowPictures, windows: AXWindows) {
        self.pictures = pictures
        self.snapshots = pictures.snapshots
        self.windows = windows
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.animationBehavior = .none
        panel.alphaValue = 0

        // A flipped view gives its layer a top-left origin, matching Accessibility coordinates.
        // Setting isGeometryFlipped on a view's own layer does not stick: AppKit resets it.
        let view = FlippedView()
        view.wantsLayer = true
        view.layer?.addSublayer(root)
        root.masksToBounds = true
        root.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        backdrop.contentsGravity = .resizeAspectFill
        root.addSublayer(backdrop)
        ring.zPosition = 10
        ring.isHidden = true
        root.addSublayer(ring)
        panel.contentView = view
        snapshots.onUpdate.append { [weak self] id in self?.pictureArrived(id) }
    }

    /// Just under opaque: macOS then still counts the windows behind the overlay as visible, so
    /// apps like Chromium keep drawing them and their pictures stay complete.
    static let coveringAlpha: CGFloat = 0.999

    /// Ends a motion still on screen as a fade would, since the fade's completion never runs
    /// once the overlay is gone, and covering would otherwise stay counted.
    func close() {
        if active {
            token += 1
            phase = .idle
            meter.stop(label)
            current = Motion()
            onActive(false)
            onCovering(false)
            snapshots.endLive(after: liveLinger)
        }
        panel.orderOut(nil)
    }

    // MARK: StripPresenter

    func begin(moves: [String: (from: Rect, to: Rect)], still: [String: Rect], focused: String?) -> Int? {
        guard pictures.available else { return nil }
        current = Motion(began: CACurrentMediaTime())
        token += 1
        // A cover fits any size, so in cover mode no resized window waits for a new picture.
        if !pictures.coverMode {
            for (id, m) in moves where abs(m.from.width - m.to.width) > 1 || abs(m.from.height - m.to.height) > 1 {
                current.needsPicture.insert(id)
                current.targetSizes[id] = CGSize(width: m.to.width, height: m.to.height)
            }
        }

        // Pictures that a drag moved aside glide on from where they are, though their windows
        // are written without motion.
        var glides = moves
        if active {
            for (id, r) in still where moves[id] == nil {
                if let p = layers[id]?.presentation(), !p.frame.equalTo(local(r)) { glides[id] = (r, r) }
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        refreshBackdrop()
        // A picture already in flight continues from where it is on screen.
        var start: [String: NSRect] = [:]
        for (id, m) in glides {
            if active, let p = layers[id]?.presentation() { start[id] = p.frame } else { start[id] = local(m.from) }
        }
        let shown = Set(moves.keys).union(still.keys)
        for (id, layer) in layers where !shown.contains(id) {
            layer.removeFromSuperlayer()
            layers[id] = nil
        }
        for id in shown {
            let layer = layers[id] ?? makeLayer(id)
            layer.removeAllAnimations()
            layer.frame = start[id] ?? local(still[id]!)
            // The picture shows at its own size and is clipped, never stretched. A window that
            // changes size gets live pictures at its new size as soon as it has relaid out.
            pictures.show(id, on: layer, growingTo: current.targetSizes[id])
        }
        // The ring starts where the real border is: around the window focused before this motion.
        var ringTo: NSRect?
        if showRing(), let focused, let end = moves[focused]?.to ?? still[focused] {
            ringTo = outset(local(end))
            let from: NSRect
            if active, !ring.isHidden, let p = ring.presentation() { from = p.frame }
            else if let last = ringTarget { from = last }
            else { from = outset(start[focused] ?? local(end)) }
            styleRing()
            ring.removeAllAnimations()
            ring.frame = from
            ring.isHidden = false
        } else {
            ring.isHidden = true
        }
        CATransaction.commit()
        // The first frame on screen must already show the pictures, never an empty panel.
        CATransaction.flush()

        // A fade already reported the motion as over, so a motion that interrupts it starts a new one.
        if phase == .idle || phase == .fading { onActive(true) }
        if !active {
            panel.orderFrontRegardless()
            onCovering(true)
        }
        phase = .moving
        if let view = panel.contentView { meter.start(on: view) }
        // Cancels a fade still running from the previous motion.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            panel.animator().alphaValue = Self.coveringAlpha
        }

        let motion = token
        CATransaction.begin()
        var longest: CFTimeInterval = 0
        for (id, m) in glides {
            guard let layer = layers[id] else { continue }
            let from = layer.frame
            let to = local(m.to)
            layer.frame = to
            let group = springs(from: from, to: to)
            longest = max(longest, group.duration)
            layer.add(group, forKey: "move")
            layer.followCover(from: from.size, to: to.size) { spring("position", $0, $1) }
        }
        if let ringTo {
            let from = ring.frame
            ring.frame = ringTo
            if from != ringTo {
                let group = springs(from: from, to: ringTo)
                longest = max(longest, group.duration)
                ring.add(group, forKey: "move")
            }
            ringTarget = ringTo
        }
        CATransaction.commit()
        snapshots.beginLive(shown, rate: motionRate)
        Log.note("motion", "\(label) begins \(moves.count) moves, \(shown.count) shown, \(pictures.coverMode ? "covers" : "pictures"); "
            + "setup \(ms(since: current.began)) ms, spring \(Int(longest * 1000)) ms")
        DispatchQueue.main.asyncAfter(deadline: .now() + longest) { [weak self] in
            MainActor.assumeIsolated { self?.settled(motion) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + startTimeout) { [weak self] in
            MainActor.assumeIsolated { self?.fade(motion, because: "start timeout") }
        }
        return motion
    }

    func preview(frames: [String: Rect], focused: String?) -> Bool {
        guard pictures.available else { return false }
        token += 1 // a fade or settle still pending from an earlier motion no longer applies
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !active { refreshBackdrop() }
        for (id, layer) in layers where frames[id] == nil {
            layer.removeFromSuperlayer()
            layers[id] = nil
        }
        for (id, r) in frames {
            let isNew = layers[id] == nil
            let layer = layers[id] ?? makeLayer(id)
            layer.removeAllAnimations()
            if isNew || !active { pictures.show(id, on: layer) }
            layer.frame = local(r)
        }
        if showRing(), let focused, let r = frames[focused] {
            styleRing()
            ring.removeAllAnimations()
            ring.frame = outset(local(r))
            ring.isHidden = false
            ringTarget = ring.frame
        } else {
            ring.isHidden = true
        }
        CATransaction.commit()
        CATransaction.flush()
        if phase == .idle || phase == .fading { onActive(true) }
        if !active {
            panel.orderFrontRegardless()
            onCovering(true)
            snapshots.beginLive(Set(frames.keys), rate: motionRate)
        }
        phase = .previewing
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            panel.animator().alphaValue = Self.coveringAlpha
        }
        return true
    }

    func arrange(frames: [String: Rect]) -> Bool {
        guard phase == .previewing else { return preview(frames: frames, focused: nil) }
        token += 1 // a fade or settle still pending from an earlier motion no longer applies
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, layer) in layers where frames[id] == nil {
            layer.removeFromSuperlayer()
            layers[id] = nil
        }
        for (id, r) in frames {
            let to = local(r)
            guard let layer = layers[id] else {
                let layer = makeLayer(id)
                pictures.show(id, on: layer)
                layer.frame = to
                continue
            }
            let from = layer.presentation()?.frame ?? layer.frame
            layer.removeAnimation(forKey: "move")
            layer.frame = to
            if !from.equalTo(to) {
                layer.add(springs(from: from, to: to), forKey: "move")
                layer.followCover(from: from.size, to: to.size) { spring("position", $0, $1) }
            }
        }
        CATransaction.commit()
        return true
    }

    func endPreview() {
        guard phase == .previewing else { return }
        fade(token)
    }

    func writesIssued(_ ids: Set<String>, token: Int) {
        guard token == self.token else { return }
        current.issued = ids
        advance()
    }

    func landed(_ id: String, token: Int) {
        guard token == self.token else { return }
        current.landed.insert(id)
        // A resized window needs a fresh picture before the real one can show through cleanly.
        if current.needsPicture.contains(id) { snapshots.resize([id]) }
        advance()
    }

    // MARK: Landing

    private func settled(_ motion: Int) {
        guard motion == token else { return }
        current.settledAt = CACurrentMediaTime()
        Log.note("motion", "\(label) settled after \(ms(since: current.began)) ms")
        let waiting = current.deferred
        current.deferred = []
        for id in waiting { pictureArrived(id) }
        advance()
        DispatchQueue.main.asyncAfter(deadline: .now() + settleTimeout) { [weak self] in
            MainActor.assumeIsolated { self?.fade(motion, because: "settle timeout") }
        }
    }

    /// New frames of a resizing window go straight onto its layer, so its new layout shows while
    /// it is still moving. Once a frame matches the final size, the landing can finish.
    private func pictureArrived(_ id: String) {
        guard active, !pictures.coverMode, let layer = layers[id] else { return }
        let surface = snapshots.surface(of: id)
        // A shrinking window's new picture is smaller than its frame until the motion ends; the
        // old, larger picture keeps covering the frame until then.
        if current.settledAt == nil, let surface, layer.wouldLeaveGap(surface, growingTo: current.targetSizes[id]) {
            current.deferred.insert(id)
            return
        }
        layer.setPicture(surface, growingTo: current.targetSizes[id])
        guard current.needsPicture.contains(id) else { return }
        if current.landed.contains(id), let size = current.targetSizes[id], layer.pictureFits(size) {
            current.needsPicture.remove(id)
            advance()
        }
    }

    /// Fades once the motion settled, every written window landed, and resized ones were re-pictured.
    private func advance() {
        guard phase == .moving, current.settledAt != nil, let issued = current.issued, issued.isSubset(of: current.landed),
              current.needsPicture.isDisjoint(with: current.landed) else { return }
        fade(token, because: "landed")
    }

    private func fade(_ motion: Int, because reason: String = "preview ended") {
        guard active, motion == token else { return }
        if current.began > 0 {
            let waiting = current.needsPicture.isEmpty ? "" : ", still waiting for \(current.needsPicture.count) pictures"
            Log.note("motion", "\(label) fades after \(ms(since: current.began)) ms (\(reason)\(waiting))")
        }
        token += 1 // later callbacks for this motion are ignored
        let done = token
        phase = .fading
        // The real border moves under the pictures now, so it is in place as they fade.
        onActive(false)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fadeDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.token == done else { return }
                self.phase = .idle
                self.meter.stop(self.label)
                self.current = Motion()
                self.onCovering(false)
                self.snapshots.endLive(after: self.liveLinger)
            }
        })
    }

    private var label: String { screen()?.localizedName ?? "display" }

    private func ms(since t: CFTimeInterval) -> Int { Int((CACurrentMediaTime() - t) * 1000) }

    // MARK: Drawing

    private func spring(_ key: String, _ a: NSValue, _ b: NSValue) -> CASpringAnimation {
        Spring.critical(key, from: a, to: b, stiffness: stiffness)
    }

    private func springs(from: NSRect, to: NSRect) -> CAAnimationGroup {
        let move = spring("position", NSValue(point: NSPoint(x: from.midX, y: from.midY)),
                          NSValue(point: NSPoint(x: to.midX, y: to.midY)))
        let size = spring("bounds.size", NSValue(size: from.size), NSValue(size: to.size))
        let group = CAAnimationGroup()
        group.animations = [move, size]
        group.duration = max(move.duration, size.duration)
        return group
    }

    /// The ring sits just outside the window, like the real border.
    private func outset(_ r: NSRect) -> NSRect { r.insetBy(dx: -ringStyle.borderWidth, dy: -ringStyle.borderWidth) }

    private func styleRing() {
        let color = ringStyle.color.cgColor
        ring.borderWidth = ringStyle.borderWidth
        ring.borderColor = color
        ring.cornerRadius = ringStyle.cornerRadius + ringStyle.borderWidth / 2
        ring.shadowColor = color
        ring.shadowOpacity = ringStyle.glowRadius > 0 ? 0.9 : 0
        ring.shadowRadius = ringStyle.glowRadius
        ring.shadowOffset = .zero
    }

    private func refreshBackdrop() {
        // The captured desktop is what is really on screen. The desktop picture's file can differ,
        // for example with dynamic or aerial wallpapers, so it is only a fallback until a capture exists.
        if let captured = snapshots.wallpaper() {
            backdrop.contents = captured
            backdropURL = nil
            return
        }
        guard let screen = screen() else { return }
        let url = NSWorkspace.shared.desktopImageURL(for: screen)
        guard url != backdropURL || backdrop.contents == nil else { return }
        backdropURL = url
        if let url, let image = NSImage(contentsOf: url),
           let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            backdrop.contents = cg
        }
    }

    private func makeLayer(_ id: String) -> WindowLayer {
        let layer = WindowLayer()
        root.addSublayer(layer)
        layers[id] = layer
        return layer
    }


    private func local(_ r: Rect) -> NSRect {
        NSRect(x: r.x - viewport.x, y: r.y - viewport.y, width: r.width, height: r.height)
    }

    /// Converts the Accessibility viewport (top-left origin) to an AppKit frame.
    private func place() {
        let frame = Screens.appKitRect(viewport)
        panel.setFrame(frame, display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = NSRect(origin: .zero, size: frame.size)
        // The desktop picture spans the whole screen, so offset it to line up with the real desktop.
        if let screen = screen() {
            let whole = Screens.axRect(screen.frame)
            backdrop.frame = NSRect(x: whole.x - viewport.x, y: whole.y - viewport.y, width: whole.width, height: whole.height)
        } else {
            backdrop.frame = root.bounds
        }
        CATransaction.commit()
    }
}

/// A view whose layer tree uses a top-left origin.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
