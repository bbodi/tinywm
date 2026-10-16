/// A key combination tinywm presses on the user's behalf, such as ⌘Space for a launcher.
public struct KeyStroke: Hashable, Sendable {
    public var keyCode: Int
    public var command = false
    public var shift = false
    public var option = false
    public var control = false

    public init(keyCode: Int, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.keyCode = keyCode; self.command = command; self.shift = shift; self.option = option; self.control = control
    }
}

/// A meta chord the config file ties to a shell command or to a key combination.
public struct CustomCommand: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case shell(String)
        case keys(KeyStroke)
    }

    public var chord: MetaKeyBindings.Chord
    public var kind: Kind
    /// The config text of the target, shown in the shortcuts menu.
    public var text: String
    /// Unique per chord; the shortcut registry and clash reports know the command by it.
    public var name: String

    public init(chord: MetaKeyBindings.Chord, kind: Kind, text: String, meta: MetaModifier) {
        self.chord = chord
        self.kind = kind
        self.text = text
        name = "command \(StripConfig.describe(chord, meta: meta))"
    }

    public var title: String {
        switch kind {
        case .shell: "Run \(text)"
        case .keys: "Press \(text)"
        }
    }
}
