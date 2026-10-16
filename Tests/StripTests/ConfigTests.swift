import Foundation
import WindowCore
import Testing
@testable import StripEngine

private typealias Chord = MetaKeyBindings.Chord
private func key(_ name: String, shift: Bool = false, alt: Bool = false, control: Bool = false) -> Chord {
    Chord(keyCode: KeyNames.codes[name]!, shift: shift, option: alt, control: control)
}

@Suite struct ControlModifierTests {
    @Test func controlIsAnExtraModifierWithRightCommand() {
        let r = StripConfig.parse("bind move-left = control+n\nbind move-right = ctrl+shift+i")
        #expect(r.issues.isEmpty)
        #expect(r.config.bindings["move-left"] == key("n", control: true))
        #expect(r.config.bindings["move-right"] == key("i", shift: true, control: true))
        #expect(StripConfig.describe(key("n", control: true), meta: .rightCommand) == "control+n")
    }

    @Test func controlSurvivesTheShortcutRoundTrip() {
        let chord = key("n", control: true)
        let s = Shortcut(keyCode: chord.keyCode, modifiers: 0x1800 | MetaKeyBindings.extraControl)
        let b = MetaKeyBindings([("move-left", s.keyCode, s.modifiers)])
        #expect(b.action(keyCode: chord.keyCode, shift: false, option: false, control: true) == "move-left")
        #expect(b.action(keyCode: chord.keyCode, shift: false, option: false) == nil)
    }

    @Test func controlIsRefusedWithControlOption() {
        let r = StripConfig.parse("meta = control-option\nbind move-left = control+n")
        #expect(r.issues.count == 1)
        #expect(r.config.bindings["move-left"] == key("h", shift: true))
    }
}

@Suite struct ConfigParsingTests {
    @Test func validLinesOverrideOnlyWhatTheyName() {
        let r = StripConfig.parse("""
        gap = 12
        default-width = 0.6
        width-presets = 0.25, 0.5 ,0.75
        focus-border = off
        bind focus-left = n
        """)
        #expect(r.issues.isEmpty)
        #expect(r.config.gap == 12)
        #expect(r.config.defaultWidth == 0.6)
        #expect(r.config.widthPresets == [0.25, 0.5, 0.75])
        #expect(r.config.focusBorder == false)
        #expect(r.config.bindings["focus-left"] == key("n"))
        #expect(r.config.bindings["focus-right"] == key("l"))
    }

    @Test func restoreLayoutDefaultsOnAndParses() {
        #expect(StripConfig().restoreLayout)
        #expect(StripConfig.parse("restore-layout = off").config.restoreLayout == false)
        #expect(StripConfig.parse("restore-layout = on").config.restoreLayout)
        let bad = StripConfig.parse("restore-layout = sometimes")
        #expect(bad.issues.count == 1)
        #expect(bad.config.restoreLayout)
    }

    @Test func commentsAndBlankLinesAreIgnored() {
        let r = StripConfig.parse("# a comment\n\n   \n  gap = 3   # trailing\r\n\t# indented\n")
        #expect(r.issues.isEmpty)
        #expect(r.config.gap == 3)
    }

    @Test func anUnknownActionIsReportedAndSkipped() {
        let r = StripConfig.parse("gap = 4\nbind focus-sideways = n\nunbind nothing")
        #expect(r.issues.map(\.line) == [2, 3])
        #expect(r.issues[0].message.contains("unknown action 'focus-sideways'"))
        #expect(r.config.gap == 4)
        #expect(r.config.bindings == StripActions.defaultBindings)
    }

    @Test func anUnknownKeyOrSettingIsReported() {
        let r = StripConfig.parse("bind focus-left = banana\nbind focus-up = shift+\nspeed = 3\nbind focus-down")
        #expect(r.issues.count == 4)
        #expect(r.issues[0].message.contains("unknown key 'banana'"))
        #expect(r.issues[2].message.contains("unknown setting 'speed'"))
        #expect(r.config.bindings["focus-left"] == key("h"))
    }

    @Test func badValuesKeepTheDefault() {
        let r = StripConfig.parse("gap = wide\ndefault-width = 3\nwidth-presets = 0.5, x\nfocus-border = maybe\nmeta = hyper")
        #expect(r.issues.map(\.line) == [1, 2, 3, 4, 5])
        #expect(r.config == StripConfig())
    }

    @Test func unbindRemovesADefault() {
        let r = StripConfig.parse("unbind focus-left-arrow")
        #expect(r.issues.isEmpty)
        #expect(r.config.bindings["focus-left-arrow"] == nil)
        #expect(r.config.bindings["focus-left"] == key("h"))
    }

    @Test func aClashKeepsTheLaterLineAndIsReported() {
        let r = StripConfig.parse("bind focus-left = x\nbind focus-right = x")
        #expect(r.issues.count == 1)
        #expect(r.issues[0].line == 2)
        #expect(r.config.bindings["focus-right"] == key("x"))
        #expect(r.config.bindings["focus-left"] == nil)
    }

    @Test func takingADefaultKeyUnbindsItsOwnerQuietly() {
        let r = StripConfig.parse("bind float = h")
        #expect(r.issues.isEmpty)
        #expect(r.config.bindings["float"] == key("h"))
        #expect(r.config.bindings["focus-left"] == nil)
    }

    @Test func aSwapIsNotAClash() {
        let r = StripConfig.parse("bind focus-left = l\nbind focus-right = h")
        #expect(r.issues.isEmpty)
        #expect(r.config.bindings["focus-left"] == key("l"))
        #expect(r.config.bindings["focus-right"] == key("h"))
    }

    @Test func modifiersFollowTheMetaKey() {
        let right = StripConfig.parse("bind float = shift+option+f")
        #expect(right.issues.isEmpty)
        #expect(right.config.bindings["float"] == key("f", shift: true, alt: true))
        let bad = StripConfig.parse("bind float = command+f\nbind center = fn+c\nbind wider = shift+shift+equal")
        #expect(bad.issues.map(\.line) == [1, 2, 3])
        #expect(bad.config.bindings["float"] == key("t"))

        let ctrlOpt = StripConfig.parse("meta = control-option\nbind float = shift+command+f\nbind center = option+c")
        #expect(ctrlOpt.config.meta == .controlOption)
        #expect(ctrlOpt.config.bindings["float"] == key("f", shift: true, alt: true))
        #expect(ctrlOpt.issues.map(\.line) == [3])
    }

    @Test func theMetaLineAppliesEvenWhenItComesLast() {
        let r = StripConfig.parse("bind float = command+f\nmeta = control-option")
        #expect(r.issues.isEmpty)
        #expect(r.config.bindings["float"] == key("f", alt: true))
    }

    @Test func punctuationHasSymbolAndNamedForms() {
        let r = StripConfig.parse("bind wider = =\nbind narrower = minus\nbind stack-left = [\nbind stack-right = rightbracket")
        #expect(r.issues.isEmpty)
        #expect(r.config.bindings["wider"] == key("equal"))
        #expect(r.config.bindings["narrower"] == key("-"))
        #expect(r.config.bindings["stack-left"] == key("leftbracket"))
    }

    @Test func layoutValuesCarryIntoStripSettings() {
        var c = StripConfig(); c.gap = 20; c.defaultWidth = 0.4
        var base = StripSettings(); base.nudge = 0.25
        let s = c.applied(to: base)
        #expect(s.gap == 20 && s.defaultWidth == 0.4 && s.nudge == 0.25)
    }
}

@Suite struct ConfigDefaultsTests {
    @Test func everyDefaultKeyIsUnique() {
        let chords = StripActions.all.map(\.chord)
        #expect(Set(chords).count == chords.count)
        #expect(!chords.contains { $0.keyCode < 0 })
    }

    @Test func defaultsAreVimStyleWithArrowsToo() {
        let b = StripConfig().bindings
        #expect(b["focus-left"] == key("h") && b["focus-down"] == key("j"))
        #expect(b["focus-up"] == key("k") && b["focus-right"] == key("l"))
        #expect(b["focus-left-arrow"] == key("left") && b["focus-up-arrow"] == key("up"))
        #expect(b["move-left"] == key("h", shift: true) && b["move-right-arrow"] == key("right", shift: true))
    }

    @Test func theTemplateParsesBackToExactlyTheDefaults() {
        let all = StripConfig.parse(StripConfig.defaultLines.joined(separator: "\n"))
        #expect(all.issues.isEmpty)
        #expect(all.config == StripConfig())
        #expect(StripConfig.parse(StripConfig.template) == StripConfig.Parsed(config: StripConfig(), issues: []))
    }

    @Test func theTemplateListsEveryDefaultLine() {
        for line in StripConfig.defaultLines { #expect(StripConfig.template.contains("# \(line)\n")) }
    }
}

/// A copy of the maintainer's own config, kept to prove it stays valid.
@Suite struct PersonalConfigTests {
    static let fixture = """
    # tinywm personal config: the keys I used before the vim-style defaults.
    # Focus left/right on N/I, workspaces on H/L, displays on O/U. Arrows stay as shipped.
    bind focus-left = n
    bind focus-right = i
    bind move-left = shift+n
    bind move-right = shift+i
    bind workspace-down = h
    bind workspace-up = l
    bind workspace-move-down = shift+h
    bind workspace-move-up = shift+l
    bind display-next = o
    bind display-previous = u
    bind display-move-next = shift+o
    bind display-move-previous = shift+u
    bind display-up = j
    bind display-down = k
    bind display-move-up = shift+j
    bind display-move-down = shift+k
    focus-crosses-displays = on
    """

    @Test func parsesToTheEarlierSetup() {
        let r = StripConfig.parse(Self.fixture)
        #expect(r.issues.isEmpty)
        let b = r.config.bindings
        let expected: [String: Chord] = [
            "focus-left": key("n"), "focus-right": key("i"),
            "focus-left-arrow": key("left"), "focus-right-arrow": key("right"),
            "focus-down-arrow": key("down"), "focus-up-arrow": key("up"),
            "move-left": key("n", shift: true), "move-right": key("i", shift: true),
            "move-left-arrow": key("left", shift: true), "move-right-arrow": key("right", shift: true),
            "move-down-arrow": key("down", shift: true), "move-up-arrow": key("up", shift: true),
            "workspace-down": key("h"), "workspace-up": key("l"),
            "workspace-move-down": key("h", shift: true), "workspace-move-up": key("l", shift: true),
            "workspace-down-arrow": key("down", alt: true), "workspace-up-arrow": key("up", alt: true),
            "workspace-move-down-arrow": key("down", shift: true, alt: true),
            "workspace-move-up-arrow": key("up", shift: true, alt: true),
            "workspace-down-page": key("pagedown"), "workspace-up-page": key("pageup"),
            "workspace-move-down-page": key("pagedown", shift: true), "workspace-move-up-page": key("pageup", shift: true),
            "width-cycle": key("r"), "width-full": key("f"), "center": key("c"),
            "wider": key("="), "narrower": key("-"),
            "stack-right": key("]"), "stack-left": key("["), "pop-out": key("]", shift: true),
            "float": key("t"), "float-focus": key("v"),
            "display-next": key("o"), "display-previous": key("u"),
            "display-move-next": key("o", shift: true), "display-move-previous": key("u", shift: true),
            "display-up": key("j"), "display-down": key("k"),
            "display-move-up": key("j", shift: true), "display-move-down": key("k", shift: true),
            "display-left": key("a"), "display-right": key("d"),
            "display-move-left": key("a", shift: true), "display-move-right": key("d", shift: true),
            "overview": key("esc"), "close-window": key("q"),
        ].merging((1...9).map { ("focus-column-\($0)", key("\($0)")) }) { a, _ in a }
        #expect(b == expected)
        #expect(r.config.meta == .rightCommand)
        #expect(r.config.focusCrossesDisplays)
    }
}

@Suite struct OverviewKeysTests {
    @Test func plainKeysFollowTheFocusBindingsAndArrows() {
        let keys = OverviewKeys(bindings: StripConfig().bindings)
        let code = { KeyNames.codes[$0]! }
        #expect(keys.command(keyCode: code("h"), shift: false) == .left)
        #expect(keys.command(keyCode: code("j"), shift: false) == .down)
        #expect(keys.command(keyCode: code("k"), shift: false) == .up)
        #expect(keys.command(keyCode: code("l"), shift: false) == .right)
        #expect(keys.command(keyCode: code("left"), shift: false) == .left)
        #expect(keys.command(keyCode: code("tab"), shift: false) == .next)
        #expect(keys.command(keyCode: code("tab"), shift: true) == .previous)
        #expect(keys.command(keyCode: code("return"), shift: false) == .confirm)
        #expect(keys.command(keyCode: code("esc"), shift: false) == .cancel)
        #expect(keys.command(keyCode: code("h"), shift: true) == nil)
        #expect(keys.command(keyCode: code("q"), shift: false) == nil)
    }

    @Test func reboundKeysMoveTheSelection() {
        let r = StripConfig.parse("bind focus-left = n\nbind focus-right = i\nunbind focus-up-arrow")
        let keys = OverviewKeys(bindings: r.config.bindings)
        #expect(keys.command(keyCode: KeyNames.codes["n"]!, shift: false) == .left)
        #expect(keys.command(keyCode: KeyNames.codes["i"]!, shift: false) == .right)
        #expect(keys.command(keyCode: KeyNames.codes["h"]!, shift: false) == nil)
        // Arrows work in the overview even when unbound.
        #expect(keys.command(keyCode: KeyNames.codes["up"]!, shift: false) == .up)
    }

    @Test func metaActionsRouteToTheOverview() {
        #expect(OverviewKeys.command(forAction: "focus-left") == .left)
        #expect(OverviewKeys.command(forAction: "focus-down-arrow") == .down)
        #expect(OverviewKeys.command(forAction: "overview") == .confirm)
        #expect(OverviewKeys.command(forAction: "move-left") == nil)
        #expect(OverviewKeys.command(forAction: "close-window") == nil)
    }
}

@Suite struct ConfigReadTests {
    struct Unreadable: Error {}

    @Test func aMissingFileMeansTheDefaults() {
        var previous = StripConfig.parse("gap 30")
        previous.issues = []
        #expect(StripConfig.read(nil, previous: previous) == StripConfig.parse(""))
    }

    @Test func aFileThatCannotBeReadKeepsTheLastGoodConfigAndSaysSo() {
        let previous = StripConfig.parse("gap 30")
        let read = StripConfig.read(.failure(Unreadable()), previous: previous)
        #expect(read.config == previous.config)
        #expect(read.issues.count == 1)
        #expect(read.issues.first?.description.hasPrefix("The config file could not be read") == true)
    }

    @Test func aFileThatIsNotUTF8KeepsTheLastGoodConfig() {
        let previous = StripConfig.parse("gap 30")
        let read = StripConfig.read(.success(Data([0xFF, 0xFE, 0x00, 0xD8])), previous: previous)
        #expect(read.config == previous.config)
        #expect(read.issues.first?.description.contains("UTF-8") == true)
    }

    @Test func aReadableFileIsParsed() {
        #expect(StripConfig.read(.success(Data("gap 30".utf8)), previous: StripConfig.parse("")) == StripConfig.parse("gap 30"))
    }
}
