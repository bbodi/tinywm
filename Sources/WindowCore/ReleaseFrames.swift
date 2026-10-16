/// Where each window goes when tinywm quits: back to the frame it had when first seen.
///
/// A frame that no longer touches any display (its monitor is gone, or it was parked off screen
/// when first seen) is moved onto the primary display, keeping its size where it fits, so no
/// window is left unreachable.
public func releaseFrames(originals: [String: Rect], displays: [Rect]) -> [String: Rect] {
    guard let primary = displays.first else { return originals }
    var out: [String: Rect] = [:]
    for (id, frame) in originals {
        if displays.contains(where: { visibleArea(frame, in: $0) >= 0.1 * frame.width * frame.height && visibleArea(frame, in: $0) > 0 }) {
            out[id] = frame
            continue
        }
        let w = min(frame.width, primary.width), h = min(frame.height, primary.height)
        out[id] = Rect(x: primary.x + (primary.width - w) / 2, y: primary.y + (primary.height - h) / 2,
                       width: w, height: h)
    }
    return out
}

private func visibleArea(_ r: Rect, in screen: Rect) -> Double {
    guard let o = r.overlap(screen) else { return 0 }
    return o.width * o.height
}
