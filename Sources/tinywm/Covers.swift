import AppKit
import WindowCore
import WindowKit

/// Builds each window's cover: its app's icon and colour, and its title.
@MainActor
final class CoverArt {
    private let windows: AXWindows
    /// An app's icon, its average colour and its name. Colour is nil for an app without an icon.
    private struct App { var icon: NSImage?; var colour: RGBA?; var name: String? }
    /// Kept per process, since an app's icon does not change.
    private var apps: [pid_t: App] = [:]
    init(windows: AXWindows) { self.windows = windows }

    func cover(of id: String) -> (cover: Cover, icon: NSImage?) {
        let app = windows.pid(of: id).map(appInfo) ?? App()
        let title = windows.cachedTitle(of: id) ?? ""
        let cover = Cover(windowTitle: title, appName: app.name, iconColour: app.colour, background: Self.background())
        return (cover, app.icon)
    }

    private func appInfo(_ pid: pid_t) -> App {
        if let known = apps[pid] { return known }
        let app = NSRunningApplication(processIdentifier: pid)
        let icon = app?.icon
        let info = App(icon: icon, colour: icon.flatMap(Self.averageColour), name: app?.localizedName)
        apps[pid] = info
        return info
    }

    /// Renders the icon at 16 by 16 points and averages its pixels.
    private static func averageColour(_ icon: NSImage) -> RGBA? {
        let side = 16
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let image = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? RGBA.average(premultipliedRGBA: bytes) : nil
    }

    /// The window background colour in the current light or dark appearance.
    private static func background() -> RGBA {
        var out = RGBA(r: 0.5, g: 0.5, b: 0.5)
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let c = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) {
                out = RGBA(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
            }
        }
        return out
    }
}

/// What every overlay shows for a window: its picture, or its cover in cover mode.
///
/// In cover mode tinywm does not record the screen. Captures stop, and no picture or
/// permission is asked for.
@MainActor
final class WindowPictures {
    let snapshots: ScreenCaptureSnapshots
    let covers: CoverArt
    var coverMode = false { didSet { snapshots.inert = coverMode } }

    init(snapshots: ScreenCaptureSnapshots, covers: CoverArt) {
        self.snapshots = snapshots
        self.covers = covers
    }

    /// Whether motion can be drawn: covers always can, pictures need the Screen Recording permission.
    var available: Bool { coverMode || CGPreflightScreenCaptureAccess() }

    /// Puts the window's picture or cover on `layer`. `growingTo` is the size a picture
    /// stretches to while its window grows; a cover fills any size.
    func show(_ id: String, on layer: WindowLayer, growingTo size: CGSize? = nil) {
        if coverMode {
            let c = covers.cover(of: id)
            layer.setCover(c.cover, icon: c.icon)
        } else {
            layer.setPicture(snapshots.surface(of: id), growingTo: size)
        }
    }
}
