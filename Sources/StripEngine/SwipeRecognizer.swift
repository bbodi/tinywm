/// Turns raw trackpad contact frames into strip swipes.
///
/// Coordinates are normalised to the trackpad (0…1, y up). A swipe needs exactly `fingers`
/// touching. It starts after the fingers' average position travels `startDistance`, and locks to
/// the axis that leads by `axisRatio`. The defaults, 0.03 and 1.2, keep a resting hand from
/// starting a swipe and keep diagonal drags from picking an axis.
public struct SwipeRecognizer: Sendable {
    public enum Axis: Sendable { case horizontal, vertical }

    public enum Event: Equatable, Sendable {
        case began(Axis)
        /// Travel since the last event, in trackpad units.
        case moved(dx: Double, dy: Double)
        /// Fingers lifted. Velocity in trackpad units per second along the locked axis.
        case ended(velocity: Double)
        case cancelled
    }

    public var fingers = 3
    public var startDistance = 0.03
    public var axisRatio = 1.2

    private var origin: (x: Double, y: Double)?
    private var last: (x: Double, y: Double, t: Double)?
    private var axis: Axis?
    /// Recent samples along the axis, to estimate the lift-off velocity.
    private var samples: [(t: Double, v: Double)] = []

    public init() {}

    /// Feeds one contact frame: the positions of fingers touching now, at time `t` (seconds).
    public mutating func feed(_ touches: [(x: Double, y: Double)], at t: Double) -> [Event] {
        guard touches.count == fingers else { return finish(at: t) }
        let x = touches.map(\.x).reduce(0, +) / Double(touches.count)
        let y = touches.map(\.y).reduce(0, +) / Double(touches.count)
        guard let o = origin, let l = last else {
            origin = (x, y)
            last = (x, y, t)
            return []
        }
        var events: [Event] = []
        if axis == nil {
            let dx = x - o.x, dy = y - o.y
            guard (dx * dx + dy * dy).squareRoot() >= startDistance else { return [] }
            if abs(dx) >= axisRatio * abs(dy) { axis = .horizontal }
            else if abs(dy) >= axisRatio * abs(dx) { axis = .vertical }
            else { return [] }
            events.append(.began(axis!))
            // The travel that crossed the threshold counts, so the strip does not lag the fingers.
            events.append(.moved(dx: dx, dy: dy))
        } else {
            events.append(.moved(dx: x - l.x, dy: y - l.y))
        }
        let along = axis == .horizontal ? x : y
        samples.append((t, along))
        samples.removeAll { t - $0.t > 0.08 }
        last = (x, y, t)
        return events
    }

    /// Fingers changed count or lifted: ends a swipe in progress.
    private mutating func finish(at t: Double) -> [Event] {
        defer { origin = nil; last = nil; axis = nil; samples = [] }
        guard axis != nil else { return [] }
        guard let first = samples.first, let lastSample = samples.last, lastSample.t > first.t else {
            return [.ended(velocity: 0)]
        }
        return [.ended(velocity: (lastSample.v - first.v) / (lastSample.t - first.t))]
    }
}
