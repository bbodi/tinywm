/// The welcome window's line on how to move around, built from the focus keys the config binds.
public enum MoveHint {
    /// In H J K L order, as vim reads them.
    static let directions = ["left", "down", "up", "right"]

    public static func text(bindings: [String: MetaKeyBindings.Chord], meta: MetaModifier) -> String {
        let held = meta == .rightCommand ? "the right ⌘ key" : "⌃⌥"
        let groups = [keys(directions.map { "focus-\($0)" }, bindings, meta),
                      keys(directions.map { "focus-\($0)-arrow" }, bindings, meta)].compactMap { $0 }
        guard !groups.isEmpty else { return "Hold \(held) and press a focus key to move around. The config binds none yet." }
        return "Hold \(held) and press \(groups.joined(separator: " or ")) to move around."
    }

    /// The keys of `actions`, or nil when none is bound. The four plain arrows read as one phrase.
    private static func keys(_ actions: [String], _ bindings: [String: MetaKeyBindings.Chord], _ meta: MetaModifier) -> String? {
        let chords = actions.compactMap { bindings[$0] }
        guard !chords.isEmpty else { return nil }
        let arrows = directions.map { MetaKeyBindings.Chord(keyCode: KeyNames.codes[$0]!, shift: false, option: false) }
        if chords == arrows { return "the arrow keys" }
        return chords.map { key($0, meta) }.joined(separator: " ")
    }

    static func key(_ chord: MetaKeyBindings.Chord, _ meta: MetaModifier) -> String {
        var s = ""
        if chord.control { s += "⌃" }
        if chord.shift { s += "⇧" }
        if chord.option { s += meta == .rightCommand ? "⌥" : "⌘" }
        let name = KeyNames.name(of: chord.keyCode) ?? "key \(chord.keyCode)"
        let arrows = ["left": "←", "right": "→", "up": "↑", "down": "↓"]
        return s + (arrows[name] ?? (name.count == 1 ? name.uppercased() : name.capitalized))
    }
}
