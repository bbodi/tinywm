// Renders tinywm's app icon: a white frame, the screen, on a purple tile. Two windows of the strip
// show inside it, and a faint window on each side shows that the strip goes on.
//   swift scripts/make-icon.swift <output.iconset>      the .iconset for iconutil
//   swift scripts/make-icon.swift <output.png> <size>   one PNG, such as docs/icon.png
import AppKit

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func rounded(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
}

func withShadow(_ color: NSColor, blur: CGFloat, dy: CGFloat = 0, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: dy)
    shadow.set()
    body()
    NSGraphicsContext.restoreGraphicsState()
}

/// Draws the icon into a square of side `s` pixels, on Apple's grid: an 824 body inside 1024.
func draw(_ s: CGFloat) {
    let k = s / 1024
    // Small sizes drop the fine detail, which only blurs there.
    let detailed = s >= 64
    let tile = NSRect(x: 100 * k, y: 110 * k, width: 824 * k, height: 824 * k)
    let shape = rounded(tile, 185 * k)
    let top = rgb(130, 90, 255), bottom = rgb(70, 40, 190)
    withShadow(rgb(0, 0, 0, 0.35), blur: 28 * k, dy: -12 * k) { bottom.setFill(); shape.fill() }
    NSGradient(starting: top, ending: bottom)!.draw(in: shape, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let cx = tile.midX
    let h = 360 * k, y = tile.midY - h / 2, w = 200 * k
    let shade = rgb(30, 0, 90)

    // A soft light from above, so the tile is not flat.
    NSGradient(starting: rgb(255, 255, 255, 0.22), ending: rgb(255, 255, 255, 0))!
        .draw(fromCenter: NSPoint(x: cx, y: tile.maxY), radius: 0, toCenter: NSPoint(x: cx, y: tile.maxY), radius: 640 * k, options: [])

    // The strip goes on past the screen: one faint window on each side, cut by the tile's edges.
    for x: CGFloat in [-440, 310] where detailed {
        let r = NSRect(x: cx + x * k, y: y, width: 130 * k, height: h)
        let path = rounded(r, 26 * k)
        NSGradient(starting: rgb(255, 255, 255, 0.36), ending: rgb(255, 255, 255, 0.16))!.draw(in: path, angle: -90)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        rgb(255, 255, 255, 0.14).setFill()
        NSRect(x: r.minX, y: r.maxY - 52 * k, width: r.width, height: 52 * k).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // The screen: a ring lit from above.
    let outer = NSRect(x: cx - 272 * k, y: y - 72 * k, width: 544 * k, height: h + 144 * k)
    // The screen's inside is darker than the tile.
    NSGradient(starting: rgb(92, 58, 220), ending: rgb(58, 30, 170))!
        .draw(in: rounded(outer.insetBy(dx: 30 * k, dy: 30 * k), 48 * k), angle: -90)
    let ring = rounded(outer, 76 * k)
    ring.append(rounded(outer.insetBy(dx: 34 * k, dy: 34 * k), 44 * k).reversed)
    if detailed { withShadow(shade.withAlphaComponent(0.45), blur: 36 * k, dy: -14 * k) { rgb(255, 255, 255).setFill(); ring.fill() } }
    NSGradient(starting: rgb(255, 255, 255), ending: rgb(214, 202, 255))!.draw(in: ring, angle: -90)

    // The two windows on screen, each with a title bar; the focused one on the left has coloured buttons.
    for (i, dx) in ([-215, 15] as [CGFloat]).enumerated() {
        let r = NSRect(x: cx + dx * k, y: y, width: w, height: h)
        let path = rounded(r, 26 * k)
        if detailed { withShadow(shade.withAlphaComponent(0.4), blur: 26 * k, dy: -10 * k) { rgb(255, 255, 255).setFill(); path.fill() } }
        NSGradient(starting: rgb(255, 255, 255), ending: rgb(226, 218, 255))!.draw(in: path, angle: -90)
        guard detailed else { continue }
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        rgb(120, 90, 230, 0.12).setFill()
        NSRect(x: r.minX, y: r.maxY - 52 * k, width: r.width, height: 52 * k).fill()
        NSGraphicsContext.restoreGraphicsState()
        let lights = i == 0 ? [rgb(255, 95, 87), rgb(254, 188, 46), rgb(40, 200, 64)] : Array(repeating: rgb(180, 170, 215), count: 3)
        for (j, c) in lights.enumerated() {
            c.setFill()
            let d = 18 * k
            NSBezierPath(ovalIn: NSRect(x: r.minX + 22 * k + CGFloat(j) * 28 * k, y: r.maxY - 26 * k - d / 2, width: d, height: d)).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
}

func png(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
if CommandLine.arguments.count > 2, let size = Int(CommandLine.arguments[2]) {
    try png(size).write(to: out)
} else {
    try? FileManager.default.removeItem(at: out)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try png(base * scale).write(to: out.appendingPathComponent(name))
        }
    }
}
