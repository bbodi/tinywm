import QuartzCore

/// The spring every picture motion uses: critically damped, the fastest settle without overshoot.
enum Spring {
    static let stiffness: CGFloat = 700

    static func critical(_ key: String, from: Any, to: Any, stiffness: CGFloat = stiffness) -> CASpringAnimation {
        let s = CASpringAnimation(keyPath: key)
        s.mass = 1
        s.stiffness = stiffness
        s.damping = 2 * sqrt(stiffness)
        s.fromValue = from
        s.toValue = to
        s.duration = s.settlingDuration
        return s
    }
}
