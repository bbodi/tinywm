import AppKit
import QuartzCore
import WindowCore

/// Counts the display's frames while a motion runs and logs how many arrived late.
///
/// The display link fires on the main thread, so a gap here means the main thread was busy
/// and any change it makes in that frame shows late.
@MainActor
final class FrameMeter: NSObject {
    private var link: CADisplayLink?
    private var startedAt: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private var frames = 0
    private var dropped = 0
    private var worstGap: CFTimeInterval = 0
    private var interval: CFTimeInterval = 1 / 60.0

    func start(on view: NSView) {
        guard Log.isOn, link == nil else { return }
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        startedAt = CACurrentMediaTime()
        last = startedAt
        frames = 0
        dropped = 0
        worstGap = 0
    }

    func stop(_ name: String) {
        guard let link else { return }
        link.invalidate()
        self.link = nil
        let total = (last - startedAt) * 1000
        Log.note("frames", "\(name) \(frames) in \(Int(total)) ms at \(Int((1 / interval).rounded())) Hz: "
            + "\(dropped) dropped, worst gap \(String(format: "%.1f", worstGap * 1000)) ms")
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let step = link.targetTimestamp - link.timestamp
        if step > 0 { interval = step }
        let gap = now - last
        if frames > 0 {
            worstGap = max(worstGap, gap)
            dropped += max(0, Int((gap / interval).rounded()) - 1)
        }
        last = now
        frames += 1
    }
}
