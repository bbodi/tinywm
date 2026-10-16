/// The narrowest width each app lets its windows take, learned from the widths it refuses.
///
/// Keyed by bundle ID, so a new window of an app that refused before gets a wide enough
/// column at once.
public struct MinimumWidths: Codable, Equatable, Sendable {
    public private(set) var widths: [String: Double]

    /// Differences smaller than this are rounding, not a refusal.
    static let tolerance = 2.0
    /// A window that comes back this close to the screen's width was not refusing a width,
    /// as when it is zoomed to fill the screen, so it teaches nothing.
    static let nearlyScreen = 0.95

    public init(_ widths: [String: Double] = [:]) { self.widths = widths }

    public func width(for app: String) -> Double? { widths[app] }

    /// Records that a window of `app` took `took` points when asked for `asked`.
    /// Returns whether the learned width changed.
    public mutating func refused(app: String, asked: Double, took: Double, screenWidth: Double) -> Bool {
        guard took > asked + Self.tolerance, took < screenWidth * Self.nearlyScreen,
              took > (widths[app] ?? 0) + Self.tolerance else { return false }
        widths[app] = took
        return true
    }

    /// Records a window of `app` seen `width` points wide. Narrower than the learned width
    /// proves the app allows it, so the learned width comes down. Returns whether it changed.
    public mutating func seen(app: String, width: Double) -> Bool {
        guard let learned = widths[app], width < learned - Self.tolerance else { return false }
        widths[app] = width
        return true
    }
}
