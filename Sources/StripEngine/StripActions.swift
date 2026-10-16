/// One shortcut action and the chord it has out of the box. The meta key is implied.
public struct ActionSpec: Equatable, Sendable {
    public let name: String
    public let title: String
    public let chord: MetaKeyBindings.Chord
    /// Holding the key repeats the action, as for moving through columns.
    public let repeats: Bool
}

/// Every shortcut action tinywm has, with the shipped vim-style defaults.
///
/// Letters follow vim: H J K L focus, shift moves. U and I switch workspaces and comma and
/// period switch displays, so no default key is used twice. Arrow keys work alongside the letters.
public enum StripActions {
    public static let all: [ActionSpec] = {
        var out: [ActionSpec] = []
        func add(_ name: String, _ title: String, _ key: String, shift: Bool = false, alt: Bool = false, repeats: Bool = false) {
            let code = KeyNames.codes[key] ?? -1
            out.append(ActionSpec(name: name, title: title, chord: .init(keyCode: code, shift: shift, option: alt), repeats: repeats))
        }
        let directions = [("left", "h"), ("down", "j"), ("up", "k"), ("right", "l")]
        for (d, letter) in directions {
            add("focus-\(d)", "Focus \(d)", letter, repeats: true)
            add("focus-\(d)-arrow", "Focus \(d)", d, repeats: true)
        }
        for (d, letter) in directions {
            add("move-\(d)", "Move \(d)", letter, shift: true, repeats: true)
            add("move-\(d)-arrow", "Move \(d)", d, shift: true, repeats: true)
        }
        add("workspace-down", "Workspace below", "u")
        add("workspace-up", "Workspace above", "i")
        add("workspace-move-down", "Move window to workspace below", "u", shift: true)
        add("workspace-move-up", "Move window to workspace above", "i", shift: true)
        add("workspace-down-arrow", "Workspace below", "down", alt: true)
        add("workspace-up-arrow", "Workspace above", "up", alt: true)
        add("workspace-move-down-arrow", "Move window to workspace below", "down", shift: true, alt: true)
        add("workspace-move-up-arrow", "Move window to workspace above", "up", shift: true, alt: true)
        add("workspace-down-page", "Workspace below", "pagedown")
        add("workspace-up-page", "Workspace above", "pageup")
        add("workspace-move-down-page", "Move window to workspace below", "pagedown", shift: true)
        add("workspace-move-up-page", "Move window to workspace above", "pageup", shift: true)
        for n in 1...9 { add("focus-column-\(n)", "Focus column \(n)", "\(n)") }
        add("width-cycle", "Cycle width", "r")
        add("width-full", "Full width", "f")
        add("center", "Center column", "c")
        add("wider", "Wider", "equal", repeats: true)
        add("narrower", "Narrower", "minus", repeats: true)
        add("stack-right", "Stack into right column", "rightbracket")
        add("stack-left", "Stack into left column", "leftbracket")
        add("pop-out", "Pop out of stack", "rightbracket", shift: true)
        add("float", "Float or tile window", "t")
        add("float-focus", "Focus floating windows, then the strip again", "v")
        add("display-next", "Focus next display", "period")
        add("display-previous", "Focus previous display", "comma")
        add("display-move-next", "Move window to next display", "period", shift: true)
        add("display-move-previous", "Move window to previous display", "comma", shift: true)
        // Displays by where they sit, on W A S D so they never collide with H J K L.
        add("display-left", "Focus display on the left", "a")
        add("display-down", "Focus display below", "s")
        add("display-up", "Focus display above", "w")
        add("display-right", "Focus display on the right", "d")
        add("display-move-left", "Move window to display on the left", "a", shift: true)
        add("display-move-down", "Move window to display below", "s", shift: true)
        add("display-move-up", "Move window to display above", "w", shift: true)
        add("display-move-right", "Move window to display on the right", "d", shift: true)
        add("overview", "Overview", "esc")
        add("close-window", "Close window", "q")
        return out
    }()

    public static func spec(named name: String) -> ActionSpec? { all.first { $0.name == name } }

    public static var defaultBindings: [String: MetaKeyBindings.Chord] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0.chord) })
    }
}
