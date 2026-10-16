import AppKit
import QuartzCore
import StripEngine
import WindowCore
import WindowKit

/// Draws a meta drag: the dragged window's picture under the pointer, and the slot where it
/// would land.
///
/// Both are panels of their own, so they cross displays with the pointer. They sit above the
/// motion pictures, the slot just below the dragged picture. Every screen is dimmed below them,
/// with a hole where the dragged picture is.
@MainActor
final class DragOverlay: DragPresenter {
    /// How long the slot takes to slide to a new target, and to fade in or out.
    var slideDuration = 0.14
    var slotFade = 0.03
    /// How long a dropped floating window's picture takes to fade.
    var pictureFade = 0.2
    /// How dark the dim is, and how long it takes to come and go.
    var dimOpacity: Float = 0.25
    var dimFade = 0.2

    private let snapshots: ScreenCaptureSnapshots
    private let pictures: WindowPictures
    private let picturePanel: NSPanel
    private let slotPanel: NSPanel
    /// Casts the shadow that makes the picture look lifted.
    private let lifted = CALayer()
    private let picture = WindowLayer()
    private var window: String?
    /// Where the slot is headed, so a target that did not change does not restart its slide.
    private var slotTarget: NSRect?
    private var cursorPushed = false
    /// One dim panel per screen, with its shade and the white edge of its hole.
    private var dims: [(panel: NSPanel, shade: CAShapeLayer, edge: CAShapeLayer)] = []

    private static let shadowRadius: CGFloat = 30
    private static let shadowOffset: CGFloat = 15
    /// Room around the picture inside its panel for the shadow.
    private static let margin = shadowRadius + shadowOffset

    init(pictures: WindowPictures) {
        self.pictures = pictures
        self.snapshots = pictures.snapshots
        slotPanel = Self.makePanel(level: NSWindow.Level.floating.rawValue + 2)
        picturePanel = Self.makePanel(level: NSWindow.Level.floating.rawValue + 3)

        // The slot is a blurred, translucent grey card with a thin light edge.
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        slotPanel.contentView = blur

        let view = FlippedView()
        view.wantsLayer = true
        lifted.shadowColor = NSColor.black.cgColor
        lifted.shadowOpacity = 0.6
        lifted.shadowRadius = Self.shadowRadius
        // The view is flipped, so a positive offset casts the shadow downwards.
        lifted.shadowOffset = CGSize(width: 0, height: Self.shadowOffset)
        lifted.addSublayer(picture)
        view.layer?.addSublayer(lifted)
        picturePanel.contentView = view

        snapshots.onUpdate.append { [weak self] id in
            guard let self, id == self.window, !self.pictures.coverMode else { return }
            self.picture.setPicture(self.snapshots.surface(of: id))
        }
    }

    private static func makePanel(level: Int) -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: level)
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        p.animationBehavior = .none
        p.alphaValue = 0
        return p
    }

    func show(window id: String, picture r: Rect, slot: Rect?) {
        if id != window {
            window = id
            pictures.show(id, on: picture)
            // A window with no picture yet gets one now; it shows when it arrives.
            if !pictures.coverMode, snapshots.surface(of: id) == nil { snapshots.refresh([id]) }
            if !cursorPushed { NSCursor.closedHand.push(); cursorPushed = true }
            layOutPicture(size: CGSize(width: r.width, height: r.height))
            picturePanel.alphaValue = 1
            showDims()
        }
        cutHole(Screens.appKitRect(r))
        let m = Self.margin
        let frame = Screens.appKitRect(r).insetBy(dx: -m, dy: -m)
        if picturePanel.frame.size == frame.size {
            picturePanel.setFrameOrigin(frame.origin)
        } else {
            picturePanel.setFrame(frame, display: false)
            layOutPicture(size: CGSize(width: r.width, height: r.height))
        }
        picturePanel.orderFrontRegardless()
        place(slot: slot.map(Screens.appKitRect))
    }

    func hide(fade: Bool) {
        window = nil
        if cursorPushed { NSCursor.pop(); cursorPushed = false }
        place(slot: nil)
        hideDims()
        if fade {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = pictureFade
                picturePanel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.window == nil else { return }
                    self.picturePanel.orderOut(nil)
                }
            })
        } else {
            picturePanel.alphaValue = 0
            picturePanel.orderOut(nil)
        }
    }

    /// Puts a dim panel over every screen and fades them in.
    private func showDims() {
        for d in dims { d.panel.orderOut(nil) }
        dims = NSScreen.screens.map { screen in
            let panel = Self.makePanel(level: NSWindow.Level.floating.rawValue + 1)
            panel.setFrame(screen.frame, display: false)
            let view = FlippedView()
            view.wantsLayer = true
            let shade = CAShapeLayer()
            shade.fillColor = NSColor.black.cgColor
            shade.fillRule = .evenOdd
            shade.opacity = dimOpacity
            let edge = CAShapeLayer()
            edge.fillColor = nil
            edge.strokeColor = NSColor.white.cgColor
            edge.lineWidth = 1
            view.layer?.addSublayer(shade)
            view.layer?.addSublayer(edge)
            panel.contentView = view
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = dimFade
                panel.animator().alphaValue = 1
            }
            return (panel, shade, edge)
        }
    }

    private func hideDims() {
        let fading = dims
        dims = []
        for panel in fading.map(\.panel) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = dimFade
                panel.animator().alphaValue = 0
            }, completionHandler: {
                // AppKit calls the completion on the main thread.
                MainActor.assumeIsolated { panel.orderOut(nil) }
            })
        }
    }

    /// Leaves the dragged picture undimmed, with a thin white edge around it. `hole` is in
    /// AppKit screen coordinates.
    private func cutHole(_ hole: NSRect) {
        let radius = picture.cornerRadius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for d in dims {
            let f = d.panel.frame
            // The dim's view is flipped, so the hole's top is measured from the panel's top.
            let local = CGRect(x: hole.minX - f.minX, y: f.maxY - hole.maxY, width: hole.width, height: hole.height)
            let bounds = CGRect(origin: .zero, size: f.size)
            let holePath = CGPath(roundedRect: local, cornerWidth: radius, cornerHeight: radius, transform: nil)
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addPath(holePath)
            d.shade.frame = bounds
            d.shade.path = path
            d.edge.frame = bounds
            d.edge.path = holePath
        }
        CATransaction.commit()
    }

    private func layOutPicture(size: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lifted.frame = CGRect(origin: CGPoint(x: Self.margin, y: Self.margin), size: size)
        lifted.shadowPath = CGPath(roundedRect: lifted.bounds, cornerWidth: picture.cornerRadius,
                                   cornerHeight: picture.cornerRadius, transform: nil)
        picture.frame = lifted.bounds
        CATransaction.commit()
    }

    /// Slides the slot to `frame`, fading it in where it first appears and out when it goes.
    private func place(slot frame: NSRect?) {
        guard frame != slotTarget else { return }
        let appearing = slotTarget == nil
        slotTarget = frame
        guard let frame else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = slotFade
                slotPanel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.slotTarget == nil else { return }
                    self.slotPanel.orderOut(nil)
                }
            })
            return
        }
        if appearing {
            slotPanel.setFrame(frame, display: true)
            slotPanel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = slotFade
                slotPanel.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = slideDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                slotPanel.animator().setFrame(frame, display: true)
            }
        }
    }

}
