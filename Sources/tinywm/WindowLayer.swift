import AppKit
import QuartzCore
import WindowCore
import WindowKit

/// One window in the motion overlay.
///
/// The picture is a GPU surface shown at its real captured size, pinned to the top-left corner
/// and clipped by the window's animated bounds. Only a window that grows stretches its old
/// picture, until one at the new size arrives.
/// Not main-actor isolated, because CALayer's initialisers are not; only the main thread uses it.
final class WindowLayer: CALayer {
    /// Clips the picture to the window's content, which may fill only part of the captured buffer.
    private let crop = CALayer()
    private let picture = CALayer()
    /// Size in points of the picture shown now.
    private(set) var pictureSize: CGSize?
    /// A cover's icon and title, kept in the middle of the layer.
    private let badge = CALayer()
    private let icon = CALayer()
    private let title = CATextLayer()
    private static let iconSize: CGFloat = 64
    private static let titleHeight: CGFloat = 16

    override init() {
        super.init()
        masksToBounds = true
        cornerRadius = 10
        backgroundColor = NSColor.windowBackgroundColor.cgColor
        crop.anchorPoint = .zero
        crop.masksToBounds = true
        picture.anchorPoint = .zero
        picture.contentsGravity = .resize
        crop.addSublayer(picture)
        addSublayer(crop)
        badge.opacity = 0
        badge.bounds = CGRect(x: 0, y: 0, width: Self.iconSize, height: Self.iconSize + 8 + Self.titleHeight)
        icon.frame = CGRect(x: 0, y: 0, width: Self.iconSize, height: Self.iconSize)
        icon.contentsGravity = .resizeAspect
        icon.shadowColor = NSColor.black.cgColor
        icon.shadowOpacity = 0.3
        icon.shadowRadius = 4
        icon.shadowOffset = CGSize(width: 0, height: 2)
        title.font = NSFont.systemFont(ofSize: 12)
        title.fontSize = 12
        title.foregroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        title.alignmentMode = .center
        title.truncationMode = .end
        title.isWrapped = false
        badge.addSublayer(icon)
        badge.addSublayer(title)
        addSublayer(badge)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("WindowLayer is created in code") }

    /// Shows the window content of a captured surface at the size the window had in it.
    /// With `growingTo`, a picture smaller than that size stretches to it, so a growing window
    /// shows its old content until a picture at the new size arrives, never an empty strip.
    func setPicture(_ s: WindowSurface?, growingTo target: CGSize? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let s, s.scale > 0 {
            let size = s.pointSize
            let shown = CGSize(width: max(size.width, target?.width ?? 0), height: max(size.height, target?.height ?? 0))
            let fx = shown.width / size.width, fy = shown.height / size.height
            picture.contents = s.surface
            picture.frame = CGRect(x: -s.content.minX / s.scale * fx, y: -s.content.minY / s.scale * fy,
                                   width: s.pixelSize.width / s.scale * fx, height: s.pixelSize.height / s.scale * fy)
            crop.frame = CGRect(origin: .zero, size: shown)
            crop.opacity = 1
            pictureSize = size
        } else {
            picture.contents = nil
            crop.opacity = 0
            pictureSize = nil
        }
        badge.opacity = 0
        backgroundColor = NSColor.windowBackgroundColor.cgColor
        CATransaction.commit()
    }

    /// Shows a cover instead of a picture: a card in the cover's colour with the app's icon and
    /// the window's title in the middle.
    func setCover(_ cover: Cover, icon image: NSImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = nil
        crop.opacity = 0
        pictureSize = nil
        let c = cover.colour
        backgroundColor = CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        icon.contents = cover.showsIcon ? image?.cgImage(forProposedRect: nil, context: nil, hints: nil) : nil
        icon.isHidden = icon.contents == nil
        icon.contentsScale = scale
        title.string = cover.title
        title.contentsScale = scale
        badge.opacity = 1
        layoutBadge()
        CATransaction.commit()
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutBadge()
        CATransaction.commit()
    }

    /// The icon sits in the middle with the title under it, as wide as the layer allows.
    /// Without an icon the title alone sits in the middle.
    private func layoutBadge() {
        let width = max(Self.iconSize, bounds.width - 24)
        let hasIcon = !icon.isHidden
        let height = hasIcon ? Self.iconSize + 8 + Self.titleHeight : Self.titleHeight
        badge.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        badge.position = CGPoint(x: bounds.midX, y: bounds.midY)
        icon.frame = CGRect(x: (width - Self.iconSize) / 2, y: 0, width: Self.iconSize, height: Self.iconSize)
        title.frame = CGRect(x: 0, y: hasIcon ? Self.iconSize + 8 : 0, width: width, height: Self.titleHeight)
    }

    /// Keeps a cover's icon and title in the middle while the layer's size springs from `from`
    /// to `to`. Layout alone would put them at the final middle at once.
    func followCover(from: CGSize, to: CGSize, animation: (NSValue, NSValue) -> CAAnimation) {
        guard badge.opacity > 0, from != to else { return }
        let a = NSValue(point: NSPoint(x: from.width / 2, y: from.height / 2))
        let b = NSValue(point: NSPoint(x: to.width / 2, y: to.height / 2))
        badge.add(animation(a, b), forKey: "follow")
    }


    /// Whether the picture would replace a larger one and uncover part of the window's frame as
    /// it is now on screen. A window with no picture yet always takes the new one.
    func wouldLeaveGap(_ s: WindowSurface, growingTo target: CGSize?) -> Bool {
        guard pictureSize != nil, crop.opacity > 0 else { return false }
        let frame = (presentation() ?? self).bounds.size
        let now = crop.bounds.size
        let shown = CGSize(width: max(s.pointSize.width, target?.width ?? 0), height: max(s.pointSize.height, target?.height ?? 0))
        let smaller = shown.width < now.width - 1 || shown.height < now.height - 1
        let uncovers = shown.width < frame.width - 1 || shown.height < frame.height - 1
        return smaller && uncovers
    }

    /// Whether the picture matches `size` (points) within 3%, so it shows the window's new layout.
    func pictureFits(_ size: CGSize) -> Bool {
        guard let p = pictureSize, size.width > 0, size.height > 0 else { return false }
        return abs(p.width - size.width) / size.width < 0.03 && abs(p.height - size.height) / size.height < 0.03
    }
}
