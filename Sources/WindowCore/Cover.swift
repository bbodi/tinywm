import Foundation


/// A colour with components from 0 to 1.
public struct RGBA: Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// This colour laid over `base` at `amount`, where 1 is this colour alone.
    public func blended(over base: RGBA, amount: Double) -> RGBA {
        let t = max(0, min(1, amount))
        func mix(_ top: Double, _ bottom: Double) -> Double { top * t + bottom * (1 - t) }
        return RGBA(r: mix(r, base.r), g: mix(g, base.g), b: mix(b, base.b), a: mix(a, base.a))
    }

    /// The average colour of premultiplied RGBA pixels, 4 bytes each. Each pixel counts by its
    /// alpha, so the transparent corners of an icon do not grey the result. Nil when every
    /// pixel is transparent.
    public static func average(premultipliedRGBA bytes: [UInt8]) -> RGBA? {
        var r = 0.0, g = 0.0, b = 0.0, a = 0.0
        var i = 0
        while i + 3 < bytes.count {
            r += Double(bytes[i]); g += Double(bytes[i + 1]); b += Double(bytes[i + 2]); a += Double(bytes[i + 3])
            i += 4
        }
        guard a > 0 else { return nil }
        return RGBA(r: min(1, r / a), g: min(1, g / a), b: min(1, b / a))
    }
}

/// What stands in for a window's picture when tinywm does not record the screen: a card in the
/// app's colour with its icon and the window's title.
public struct Cover: Equatable, Sendable {
    /// The text under the icon: the window's title, else the app's name.
    public var title: String
    public var showsIcon: Bool
    public var colour: RGBA

    /// How strongly the icon's colour tints the card.
    public static let tint = 0.72

    /// `iconColour` is the icon's average colour, or nil for a window whose app has no icon.
    /// Such a window gets a plain card in `background` with its title.
    public init(windowTitle: String?, appName: String?, iconColour: RGBA?, background: RGBA) {
        let trimmed = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        title = trimmed.isEmpty ? (appName ?? "") : trimmed
        showsIcon = iconColour != nil
        colour = iconColour.map { $0.blended(over: background, amount: Self.tint) } ?? background
    }
}
