/// Time source for animation, so tests can drive time by hand.
@MainActor
public protocol Clock: AnyObject {
    /// Seconds on a monotonic scale.
    var now: Double { get }
    /// Runs `action` on the main actor after `seconds`.
    func after(_ seconds: Double, _ action: @escaping @MainActor () -> Void)
}

/// A clock that moves only when told to. Due actions run in time order.
@MainActor
public final class TestClock: Clock {
    public private(set) var now: Double = 0
    private var pending: [(due: Double, seq: Int, action: @MainActor () -> Void)] = []
    private var seq = 0

    public init() {}

    public func after(_ seconds: Double, _ action: @escaping @MainActor () -> Void) {
        seq += 1
        pending.append((now + max(0, seconds), seq, action))
    }

    public func advance(by seconds: Double) {
        let end = now + seconds
        while let i = pending.indices.filter({ pending[$0].due <= end })
            .min(by: { (pending[$0].due, pending[$0].seq) < (pending[$1].due, pending[$1].seq) }) {
            let item = pending.remove(at: i)
            now = max(now, item.due)
            item.action()
        }
        now = end
    }
}
