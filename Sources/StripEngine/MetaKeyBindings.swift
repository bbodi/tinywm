import WindowCore
/// Which key acts as tinywm's modifier.
public enum MetaModifier: String, Codable, Sendable, CaseIterable {
    /// Right ⌘ alone, read from raw key events. Keys pressed with it never reach apps.
    case rightCommand
    /// ⌃⌥ together, through system hotkeys.
    case controlOption
}

extension MetaModifier {
    /// Whether the meta key is held, read from an event's raw flags (CGEventFlags). Mouse
    /// events carry the same flags as key events, including the bit for each side's ⌘ key.
    public func isHeld(flags: UInt64) -> Bool {
        let control: UInt64 = 0x40000, option: UInt64 = 0x80000, command: UInt64 = 0x100000
        let rightCommand: UInt64 = 0x10
        switch self {
        case .rightCommand: return flags & command != 0 && flags & rightCommand != 0
        case .controlOption: return flags & control != 0 && flags & option != 0
        }
    }
}

/// Translates tinywm's stored shortcuts, written as ⌃⌥ plus extras, into right-⌘ chords.
///
/// Modifier values are Carbon's (`controlKey`, `optionKey`, `shiftKey`, `cmdKey`), so this stays
/// free of Carbon and testable. With right ⌘ as the meta key, ⌘ itself cannot be an extra, so a
/// shortcut's extra ⌘ becomes ⌥.
public struct MetaKeyBindings: Equatable, Sendable {
    public struct Chord: Hashable, Sendable {
        public var keyCode: Int
        public var shift: Bool
        public var option: Bool
        /// Only with right ⌘ as the meta key; ⌃⌥ already holds control.
        public var control: Bool
        public init(keyCode: Int, shift: Bool, option: Bool, control: Bool = false) {
            self.keyCode = keyCode; self.shift = shift; self.option = option; self.control = control
        }
    }

    public static let control = 0x1000
    public static let option = 0x0800
    public static let shift = 0x0200
    public static let command = 0x0100
    /// Stands for an extra control key in a right ⌘ chord, which ⌃⌥ shortcuts cannot carry.
    public static let extraControl = Shortcut.extraControl

    /// Action names by the chord that triggers them with right ⌘ held.
    public private(set) var actions: [Chord: String] = [:]

    public init() {}

    /// Builds the map from `(action, keyCode, Carbon modifiers)` shortcuts. Only shortcuts based on
    /// ⌃⌥ carry over; the first action wins if two translate to the same chord.
    public init(_ shortcuts: [(action: String, keyCode: Int, modifiers: Int)]) {
        for s in shortcuts {
            guard let chord = Self.chord(keyCode: s.keyCode, modifiers: s.modifiers), actions[chord] == nil else { continue }
            actions[chord] = s.action
        }
    }

    public static func chord(keyCode: Int, modifiers: Int) -> Chord? {
        let base = control | option
        guard modifiers & base == base else { return nil }
        return Chord(keyCode: keyCode, shift: modifiers & shift != 0, option: modifiers & command != 0,
                     control: modifiers & extraControl != 0)
    }

    /// The action for a key pressed with right ⌘ held, given the other modifiers held with it.
    public func action(keyCode: Int, shift: Bool, option: Bool, control: Bool = false) -> String? {
        actions[Chord(keyCode: keyCode, shift: shift, option: option, control: control)]
    }

    /// How a shortcut reads in menus for the given meta key.
    public static func display(keyName: String, modifiers: Int, mode: MetaModifier) -> String {
        switch mode {
        case .controlOption:
            var s = ""
            if modifiers & control != 0 { s += "⌃" }
            if modifiers & option != 0 { s += "⌥" }
            if modifiers & shift != 0 { s += "⇧" }
            if modifiers & command != 0 { s += "⌘" }
            return s + keyName
        case .rightCommand:
            var s = "Right⌘ "
            if modifiers & extraControl != 0 { s += "⌃" }
            if modifiers & shift != 0 { s += "⇧" }
            if modifiers & command != 0 { s += "⌥" }
            return s + keyName
        }
    }
}
