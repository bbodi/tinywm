import Testing
import WindowCore
@testable import StripEngine
@testable import StripModel

private func facts(_ bundle: String? = "com.example.app", _ name: String? = "Example", title: String? = "Doc",
                   tileable: Bool = true, dockable: Bool = true) -> WindowFacts {
    WindowFacts(bundleID: bundle, appName: name, title: title, isTileable: tileable, isDockable: dockable)
}

@Suite struct RuleParsingTests {
    @Test func patternsAreSeparatedByCommasAndMayCarryATitle() {
        let r = StripConfig.parse("""
        float = com.apple.calculator, System Settings
        float = Brave Browser: "Picture in Picture"
        """)
        #expect(r.issues.isEmpty)
        #expect(r.config.rules.float == [
            AppPattern(app: "com.apple.calculator"), AppPattern(app: "System Settings"),
            AppPattern(app: "Brave Browser", title: "Picture in Picture"),
        ])
    }

    @Test func aCommaInsideQuotesBelongsToTheTitle() {
        let p = AppPattern.parse(#"Mail: "Re: a, b", Notes"#)
        #expect(p.errors.isEmpty)
        #expect(p.patterns == [AppPattern(app: "Mail", title: "Re: a, b"), AppPattern(app: "Notes")])
    }

    @Test func linesOfTheSameKindAreUnioned() {
        let r = StripConfig.parse("no-focus = Slack\ngap = 4\nno-focus = com.spotify.client\nignore = a\nignore = b")
        #expect(r.config.rules.noFocus.map(\.app) == ["Slack", "com.spotify.client"])
        #expect(r.config.rules.ignore.map(\.app) == ["a", "b"])
        #expect(r.config.rules.float.isEmpty)
    }

    @Test func keywordsAreCaseInsensitiveAndCommentsAreStripped() {
        let r = StripConfig.parse("Float = Calculator  # the app")
        #expect(r.issues.isEmpty)
        #expect(r.config.rules.float == [AppPattern(app: "Calculator")])
    }

    @Test func aBadPatternIsReportedWithItsLineAndTheRestApplies() {
        let r = StripConfig.parse("gap = 4\nfloat = Good, , Brave: \"open, Other: \"\"\nfloat = Fine")
        #expect(r.issues.count == 2)
        #expect(r.issues.allSatisfy { $0.line == 2 })
        #expect(r.config.rules.float.map(\.app) == ["Good", "Fine"])
        #expect(r.config.gap == 4)
    }

    @Test func titleErrors() {
        #expect(AppPattern.parse(#"App: """#).errors.count == 1)
        #expect(AppPattern.parse(#"App: "x"#).errors.count == 1)
        #expect(AppPattern.parse(#": "x""#).errors.count == 1)
        #expect(AppPattern.parse(#"App "x""#).errors.count == 1)
    }

    @Test func ignoreTakesNoTitle() {
        let r = StripConfig.parse("ignore = Finder: \"x\", Preview")
        #expect(r.issues.map(\.line) == [1])
        #expect(r.config.rules.ignore == [AppPattern(app: "Preview")])
    }

    @Test func onlyAFloatRuleWithATitleDependsOnTitles() {
        #expect(!StripConfig.parse("float = Calculator\nno-focus = Slack: \"Huddle\"").config.rules.floatsByTitle)
        #expect(StripConfig.parse("float = Brave Browser: \"Picture in Picture\"").config.rules.floatsByTitle)
    }

    @Test func theTemplateParsesCleanlyWhenUncommented() {
        let kinds = ["# float", "# ignore", "# no-focus", "# open-on"]
        let lines = StripConfig.template.split(separator: "\n").filter { line in kinds.contains { line.hasPrefix($0) } }
        #expect(lines.count == 6)
        let r = StripConfig.parse(lines.map { String($0.dropFirst(2)) }.joined(separator: "\n"))
        #expect(r.issues.isEmpty)
        #expect(r.config.rules.float.count == 3)
        #expect(r.config.rules.openOn.count == 2)
    }
}

@Suite struct RuleMatchingTests {
    @Test func bundleIDOrNameMatchesIgnoringCase() {
        let p = AppPattern(app: "Slack")
        #expect(p.matches(bundleID: "x", appName: "slack", windowTitle: nil))
        #expect(AppPattern(app: "COM.Example.App").matches(bundleID: "com.example.app", appName: nil, windowTitle: nil))
        #expect(!p.matches(bundleID: "x", appName: "Slack Helper", windowTitle: nil))
        #expect(!p.matches(bundleID: nil, appName: nil, windowTitle: "Slack"))
    }

    @Test func aChangedPatternMatchesByItsNewText() {
        var p = AppPattern(app: "Slack", title: "huddle")
        p.app = "com.jetbrains.*"
        p.title = "/^main/"
        #expect(p.matches(bundleID: "com.jetbrains.goland", appName: nil, windowTitle: "main.go"))
        #expect(!p.matches(bundleID: nil, appName: "Slack", windowTitle: "huddle"))
        p.title = nil
        #expect(p.matches(bundleID: "com.jetbrains.goland", appName: nil, windowTitle: nil))
    }

    @Test func titleIsACaseInsensitiveSubstring() {
        let p = AppPattern(app: "Brave Browser", title: "picture in")
        #expect(p.matches(bundleID: nil, appName: "Brave Browser", windowTitle: "Picture in Picture"))
        #expect(!p.matches(bundleID: nil, appName: "Brave Browser", windowTitle: "News"))
        #expect(!p.matches(bundleID: nil, appName: "Brave Browser", windowTitle: nil))
        #expect(!p.matches(bundleID: nil, appName: "Other", windowTitle: "Picture in Picture"))
    }
}

@Suite struct RecognitionTests {
    func rules(float: [AppPattern] = [], ignore: [AppPattern] = [], noFocus: [AppPattern] = []) -> WindowRules {
        var r = WindowRules()
        r.float = float; r.ignore = ignore; r.noFocus = noFocus
        return r
    }
    let app = AppPattern(app: "Example")

    @Test func withoutRulesTheHeuristicDecides() {
        let r = WindowRules()
        #expect(r.recognize(facts()) == Recognition(placement: .tiled, allowsFocus: true))
        #expect(r.recognize(facts(dockable: false)).placement == .undockable)
        #expect(r.recognize(facts(tileable: false)).placement == .unmanaged)
    }

    @Test func ignoreBeatsEverything() {
        let r = rules(float: [app], ignore: [app], noFocus: [app])
        #expect(r.recognize(facts()) == Recognition(placement: .unmanaged, allowsFocus: true))
    }

    @Test func notAStandardWindowIsNeverManagedEvenIfFloatMatches() {
        #expect(rules(float: [app]).recognize(facts(tileable: false)).placement == .unmanaged)
    }

    @Test func floatBeatsTheDockableHeuristicBothWays() {
        let r = rules(float: [app])
        #expect(r.recognize(facts()).placement == .floating)
        #expect(r.recognize(facts(dockable: false)).placement == .floating)
    }

    @Test func aTitledFloatRuleOnlyCatchesThatWindow() {
        let r = rules(float: [AppPattern(app: "Example", title: "Picture")])
        #expect(r.recognize(facts(title: "Picture in Picture")).placement == .floating)
        #expect(r.recognize(facts(title: "Doc")).placement == .tiled)
    }

    @Test func noFocusIsIndependentOfPlacement() {
        let r = rules(noFocus: [app])
        #expect(r.recognize(facts()) == Recognition(placement: .tiled, allowsFocus: false))
        #expect(r.recognize(facts(dockable: false)) == Recognition(placement: .undockable, allowsFocus: false))
        #expect(rules(float: [app], noFocus: [app]).recognize(facts()) == Recognition(placement: .floating, allowsFocus: false))
    }

    @Test func ignoresLooksAtTheAppOnly() {
        let r = rules(ignore: [AppPattern(app: "com.apple.finder")])
        #expect(r.ignores(bundleID: "com.apple.finder", appName: "Finder"))
        #expect(!r.ignores(bundleID: "com.apple.safari", appName: "Safari"))
    }
}

@Suite struct FocusIntentTests {
    /// The close key on window A, a first check at the focus read, then a switch to window B while
    /// the close button is looked up. The check before ⌘W must see the switch.
    @Test func aCloseIsCheckedAgainWithTheCurrentValues() {
        let moment = CommandMoment(at: 100, focusRevision: 7, activations: 3)
        func targets(now: Double, revision: Int = 7, activations: Int = 3, mouse: Double = 30, key: Double = 30) -> Bool {
            moment.stillTargets(now: now, focusRevision: revision, activations: activations,
                                secondsSinceMouseDown: mouse, secondsSinceKeyDown: key)
        }
        #expect(targets(now: 100.2, key: 0.3))
        // A focus report for B during the lookup, in a managed app.
        #expect(!targets(now: 100.6, revision: 8))
        // A click on B in an ignored app, which reports no focus change.
        #expect(!targets(now: 100.6, mouse: 0.2))
        #expect(!targets(now: 100.6, activations: 4))
        #expect(targets(now: 100.6, key: 0.7))
    }

    /// The close key on window A of an app, then a switch to its window B before the app answers.
    /// An ignored app reports no focus change, so the input after the key is what tells.
    @Test func aCloseSkipsWhenTheUserSwitchedBeforeTheAppAnswered() {
        func targets(command: Double = 0.3, mouse: Double = 30, key: Double = 30,
                     focusChanged: Bool = false, activated: Bool = false) -> Bool {
            FocusIntent.stillTargets(secondsSinceCommand: command, secondsSinceMouseDown: mouse, secondsSinceKeyDown: key,
                                     focusChanged: focusChanged, appActivated: activated)
        }
        // The key that fired the command is older than the command itself.
        #expect(targets(key: 0.31))
        // A click on B, a key press such as ⌘-`, or B's app coming to the front.
        #expect(!targets(mouse: 0.1))
        #expect(!targets(key: 0.1))
        #expect(!targets(activated: true))
        // A focus change tinywm saw, in a managed app.
        #expect(!targets(focusChanged: true))
    }

    @Test func aRecentClickOrKeyIsTheUsers() {
        #expect(FocusIntent.isUserInitiated(secondsSinceMouseDown: 0.1, secondsSinceKeyDown: 50))
        #expect(FocusIntent.isUserInitiated(secondsSinceMouseDown: 50, secondsSinceKeyDown: 0.39))
        #expect(!FocusIntent.isUserInitiated(secondsSinceMouseDown: 0.4, secondsSinceKeyDown: 2))
    }

    @Test func onlyUnrequestedFocusOnANoFocusAppIsHandedBack() {
        func restore(_ match: Bool, mouse: Double = 30, key: Double = 30, own: Double? = nil) -> Bool {
            FocusIntent.shouldRestore(matchesNoFocus: match, secondsSinceMouseDown: mouse, secondsSinceKeyDown: key,
                                      secondsSinceOwnFocus: own)
        }
        #expect(restore(true))
        #expect(!restore(false))
        #expect(!restore(true, mouse: 0.05))
        #expect(!restore(true, key: 0.2))
        #expect(!restore(true, own: 0.2))
        #expect(restore(true, own: 5))
    }
}

@MainActor
@Suite struct RuleEngineTests {
    func make() -> (StripEngine, FakeWindows) {
        let f = FakeWindows()
        var s = StripSettings()
        s.gap = 0
        let e = StripEngine(windows: f, viewport: Rect(x: 0, y: 0, width: 1000, height: 600), settings: s)
        for id in ["a", "b", "c"] { f.focusedWindow = id; e.windowAdded(id) }
        return (e, f)
    }

    @Test func aNoFocusWindowJoinsWithoutMovingFocusOrScroll() {
        let (e, f) = make()
        e.windowFocused("a")
        let scroll = e.strip.scroll
        f.focusedWindow = "a"
        e.windowAdded("slack", takesFocus: false)
        #expect(f.focusedWindow == "a")
        #expect(e.strip.focusedWindow == "a")
        #expect(e.strip.scroll == scroll)
        #expect(e.strip.column(of: "slack") == 1)
        #expect(f.frames["slack"] != nil)
    }

    @Test func aNoFocusWindowEvenWithSystemFocusIsNotRaisedOrScrolledTo() {
        let (e, f) = make()
        e.windowFocused("a")
        let scroll = e.strip.scroll
        f.focusedWindow = "slack"
        e.windowAdded("slack", takesFocus: false)
        #expect(e.strip.focusedWindow == "a")
        #expect(e.strip.scroll == scroll)
        #expect(f.focusedWindow == "slack")
    }

    @Test func aFloatRuleWindowLandsInFloating() {
        let (e, f) = make()
        let before = f.focusedWindow
        e.windowAdded("calc", floating: true)
        #expect(e.strip.floating == ["calc"])
        #expect(e.strip.column(of: "calc") == nil)
        #expect(f.frames["calc"] == nil)
        #expect(f.focusedWindow == before)
        e.windowRemoved("calc")
        #expect(e.strip.floating.isEmpty)
    }

    @Test func floatingAFloatedWindowAgainDoesNothingAndATiledOneLeavesTheStrip() {
        let (e, _) = make()
        e.floatWindow("b")
        #expect(e.strip.floating == ["b"])
        #expect(e.strip.allWindows == ["a", "c"])
        e.floatWindow("b")
        #expect(e.strip.floating == ["b"])
    }

    @Test func aFloatedWindowCanBeTiledWithTheFloatCommand() {
        let (e, f) = make()
        e.windowAdded("calc", floating: true)
        f.focusedWindow = "calc"
        e.toggleFloat()
        #expect(e.strip.floating.isEmpty)
        #expect(e.strip.column(of: "calc") != nil)
    }
}

@Suite struct PatternTests {
    private func matches(_ pattern: String, bundle: String? = "com.jetbrains.goland", name: String? = "GoLand", title: String? = "main.go") -> Bool {
        let parsed = AppPattern.parse(pattern)
        #expect(parsed.errors.isEmpty)
        return parsed.patterns.first?.matches(bundleID: bundle, appName: name, windowTitle: title) ?? false
    }

    @Test func aStarStandsForAnyRunOfCharacters() {
        #expect(matches("com.jetbrains.*"))
        #expect(matches("go*"))
        #expect(!matches("com.jetbrains"))
        #expect(!matches("*.idea"))
    }

    @Test func slashesMakeARegularExpressionFoundAnywhere() {
        #expect(matches("/jetbrains/"))
        #expect(matches("/^gol/"))
        #expect(!matches("/^land/"))
        #expect(matches("/^micro(cube)?$/", bundle: nil, name: "Microcube"))
    }

    @Test func aTitleCanBeARegularExpression() {
        #expect(matches(#"GoLand: "/\.go$/""#))
        #expect(!matches(#"GoLand: "/\.rs$/""#))
        #expect(matches(#"GoLand: "main""#))
    }

    @Test func aCommaInsideSlashesDoesNotSplit() {
        let parsed = AppPattern.parse("/^(a|b){1,2}$/, Slack")
        #expect(parsed.errors.isEmpty)
        #expect(parsed.patterns.map(\.app) == ["/^(a|b){1,2}$/", "Slack"])
    }

    @Test func aBadRegularExpressionIsReportedAndSkipped() {
        let parsed = AppPattern.parse("/(/, Slack")
        #expect(parsed.errors == ["bad regular expression /(/"])
        #expect(parsed.patterns.map(\.app) == ["Slack"])
    }
}

@Suite struct OpenOnRuleTests {
    @Test func aLineCarriesTheDisplayTheWorkspaceOrBoth() {
        let r = StripConfig.parse("""
            open-on = /^microcube/ -> workspace 2
            open-on = Slack, Pulse -> display Built-in Display workspace 1
            open-on = Brave Browser: "Meet" -> display LS37D80xU
            """)
        #expect(r.issues.isEmpty)
        #expect(r.config.rules.openOn.map(\.target) == [
            OpenOn(workspace: 2), OpenOn(display: "Built-in Display", workspace: 1), OpenOn(display: "LS37D80xU"),
        ])
    }

    @Test func theFirstMatchingLineWins() {
        let r = StripConfig.parse("open-on = Slack -> workspace 3\nopen-on = /./ -> workspace 1").config.rules
        #expect(r.openOn(WindowFacts(appName: "Slack")) == OpenOn(workspace: 3))
        #expect(r.openOn(WindowFacts(appName: "Pulse")) == OpenOn(workspace: 1))
        #expect(StripConfig.parse("open-on = Slack -> workspace 3").config.rules.openOn(WindowFacts(appName: "Pulse")) == nil)
    }

    @Test func aBadTargetIsReportedAndTheLineIsDropped() {
        for line in ["open-on = Slack", "open-on = Slack ->", "open-on = Slack -> workspace 0",
                     "open-on = Slack -> monitor 2", "open-on = Slack -> display"] {
            let r = StripConfig.parse(line)
            #expect(r.issues.count == 1, "\(line)")
            #expect(r.config.rules.openOn.isEmpty, "\(line)")
        }
    }
}
