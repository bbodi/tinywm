/// Finds macOS trackpad gestures that use the same number of fingers as tinywm's swipes.
///
/// tinywm reads raw finger positions but cannot stop macOS from reacting to the same touches,
/// so a clashing system gesture fires alongside every swipe.
public enum SwipeClash {
    /// The trackpad preference keys checked, with what each means when it is on.
    /// Any non-zero value means macOS uses the gesture.
    public static let gestures: [(key: String, fingers: Int, label: String)] = [
        ("TrackpadThreeFingerHorizSwipeGesture", 3, "three-finger swipe between pages or full-screen apps"),
        ("TrackpadThreeFingerVertSwipeGesture", 3, "three-finger swipe for Mission Control and App Exposé"),
        ("TrackpadThreeFingerDrag", 3, "three-finger drag"),
        ("TrackpadFourFingerHorizSwipeGesture", 4, "four-finger swipe between full-screen apps"),
        ("TrackpadFourFingerVertSwipeGesture", 4, "four-finger swipe for Mission Control and App Exposé"),
    ]

    /// Labels of the system gestures that clash with tinywm swiping with `fingers` fingers.
    /// `settings` holds each key's value; built-in and Bluetooth trackpads should be merged first.
    public static func clashes(fingers: Int, settings: [String: Int]) -> [String] {
        gestures.filter { $0.fingers == fingers && (settings[$0.key] ?? 0) != 0 }.map(\.label)
    }
}
