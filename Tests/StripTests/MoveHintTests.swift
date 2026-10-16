import Testing
@testable import StripEngine

@Suite struct MoveHintTests {
    @Test func theDefaultsReadAsVimLettersAndArrows() {
        #expect(MoveHint.text(bindings: StripActions.defaultBindings, meta: .rightCommand)
            == "Hold the right ⌘ key and press H J K L or the arrow keys to move around.")
        #expect(MoveHint.text(bindings: StripActions.defaultBindings, meta: .controlOption)
            == "Hold ⌃⌥ and press H J K L or the arrow keys to move around.")
    }

    @Test func reboundKeysShowAsTheConfigHasThem() throws {
        var b = StripActions.defaultBindings
        b["focus-left"] = .init(keyCode: try #require(KeyNames.codes["a"]), shift: false, option: false)
        b["focus-up"] = .init(keyCode: try #require(KeyNames.codes["w"]), shift: true, option: true)
        b["focus-right-arrow"] = nil
        #expect(MoveHint.text(bindings: b, meta: .controlOption)
            == "Hold ⌃⌥ and press A J ⇧⌘W L or ← ↓ ↑ to move around.")
    }

    @Test func noFocusKeysSaysSo() {
        let b = StripActions.defaultBindings.filter { !$0.key.hasPrefix("focus-") || $0.key.hasPrefix("focus-column") }
        #expect(MoveHint.text(bindings: b, meta: .rightCommand)
            == "Hold the right ⌘ key and press a focus key to move around. The config binds none yet.")
    }
}
