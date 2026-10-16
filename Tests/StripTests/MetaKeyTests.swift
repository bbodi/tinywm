import Testing
@testable import StripEngine

@Suite struct MetaKeyBindingTests {
    let ctrlOpt = MetaKeyBindings.control | MetaKeyBindings.option
    let n = 45, left = 123

    @Test func controlOptionShortcutsBecomeRightCommandChords() {
        let b = MetaKeyBindings([
            ("focus.left", n, ctrlOpt),
            ("move.left", n, ctrlOpt | MetaKeyBindings.shift),
            ("column.example", left, ctrlOpt | MetaKeyBindings.command),
        ])
        #expect(b.action(keyCode: n, shift: false, option: false) == "focus.left")
        #expect(b.action(keyCode: n, shift: true, option: false) == "move.left")
        // ⌘ is the meta key itself, so an extra ⌘ in a binding is pressed as ⌥.
        #expect(b.action(keyCode: left, shift: false, option: true) == "column.example")
        #expect(b.action(keyCode: left, shift: false, option: false) == nil)
    }

    @Test func shortcutsWithoutControlOptionAreIgnored() {
        let b = MetaKeyBindings([("other", n, MetaKeyBindings.command)])
        #expect(b.actions.isEmpty)
    }

    @Test func theFirstActionKeepsAChordBothWouldUse() {
        let b = MetaKeyBindings([("a", n, ctrlOpt), ("b", n, ctrlOpt)])
        #expect(b.action(keyCode: n, shift: false, option: false) == "a")
    }

    @Test func menusShowTheChosenMetaKey() {
        let m = ctrlOpt | MetaKeyBindings.shift
        #expect(MetaKeyBindings.display(keyName: "N", modifiers: m, mode: .controlOption) == "⌃⌥⇧N")
        #expect(MetaKeyBindings.display(keyName: "N", modifiers: m, mode: .rightCommand) == "Right⌘ ⇧N")
        #expect(MetaKeyBindings.display(keyName: "←", modifiers: ctrlOpt | MetaKeyBindings.command, mode: .rightCommand) == "Right⌘ ⌥←")
    }

    @Test func theMetaKeyIsReadFromEventFlags() {
        let command: UInt64 = 0x100000, leftCommandBit: UInt64 = 0x08, rightCommandBit: UInt64 = 0x10
        #expect(MetaModifier.rightCommand.isHeld(flags: command | rightCommandBit))
        #expect(!MetaModifier.rightCommand.isHeld(flags: command | leftCommandBit))
        #expect(MetaModifier.controlOption.isHeld(flags: 0x40000 | 0x80000))
        #expect(!MetaModifier.controlOption.isHeld(flags: 0x40000))
    }
}
