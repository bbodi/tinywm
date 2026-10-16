import Testing
@testable import StripEngine

private func chord(_ name: String, shift: Bool = false) -> MetaKeyBindings.Chord {
    .init(keyCode: KeyNames.codes[name]!, shift: shift, option: false)
}

@Suite struct CustomCommandTests {
    @Test func sendTakesADefaultKeyQuietly() {
        let r = StripConfig.parse("send d = cmd+space")
        #expect(r.issues.isEmpty)
        #expect(r.config.commands == [CustomCommand(
            chord: chord("d"), kind: .keys(KeyStroke(keyCode: KeyNames.codes["space"]!, command: true)),
            text: "cmd+space", meta: .rightCommand)])
        #expect(r.config.bindings["display-right"] == nil)
    }

    @Test func runKeepsTheCommandAsWritten() {
        let r = StripConfig.parse("run shift+return = open -na Ghostty --args -e 'Echo Hi'")
        #expect(r.issues.isEmpty)
        #expect(r.config.commands.first?.kind == .shell("open -na Ghostty --args -e 'Echo Hi'"))
        #expect(r.config.commands.first?.chord == chord("return", shift: true))
        #expect(r.config.commands.first?.name == "command shift+return")
    }

    @Test func aLaterLineOnTheSameKeyWins() {
        let r = StripConfig.parse("""
        run d = open -a Look
        send d = cmd+space
        """)
        #expect(r.config.commands.count == 1)
        #expect(r.config.commands.first?.text == "cmd+space")
    }

    @Test func aLaterBindTakesTheKeyFromACommandAndSaysSo() {
        let r = StripConfig.parse("""
        send d = cmd+space
        bind float = d
        """)
        #expect(r.config.commands.isEmpty)
        #expect(r.config.bindings["float"] == chord("d"))
        #expect(r.issues.count == 1)
    }

    @Test func badStrokesAreReported() {
        #expect(StripConfig.parse("send d = hyper+space").issues.count == 1)
        #expect(StripConfig.parse("send d = cmd+nothing").issues.count == 1)
        #expect(StripConfig.parse("run d").issues.count == 1)
    }

    @Test func everyModifierIsRead() {
        let r = StripConfig.parse("send x = ctrl+option+shift+command+k")
        #expect(r.config.commands.first?.kind == .keys(KeyStroke(
            keyCode: KeyNames.codes["k"]!, command: true, shift: true, option: true, control: true)))
    }
}
