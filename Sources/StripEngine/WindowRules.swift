import Foundation

public enum RuleKind: String, CaseIterable, Sendable {
    case float
    case ignore
    case noFocus = "no-focus"
}

/// An app, by bundle ID or name, and optionally the window title.
///
/// The app is matched whole, ignoring case. A `*` in it stands for any run of characters, as in
/// `com.jetbrains.*`. Between slashes it is a regular expression found anywhere in the bundle ID
/// or name, as in `/^micro/`. The title is matched as a substring, or as a regular expression
/// between slashes. All matching ignores case.
public struct AppPattern: Equatable, Sendable {
    public var app: String { didSet { appMatcher = Matcher(app: app) } }
    public var title: String? { didSet { titleMatcher = title.map(Matcher.init(title:)) } }
    /// The patterns compiled once, since windows are matched against them as they open and retitle.
    private var appMatcher: Matcher
    private var titleMatcher: Matcher?

    public init(app: String, title: String? = nil) {
        self.app = app
        self.title = title
        appMatcher = Matcher(app: app)
        titleMatcher = title.map(Matcher.init(title:))
    }

    public static func == (a: AppPattern, b: AppPattern) -> Bool { a.app == b.app && a.title == b.title }

    /// A title pattern needs a window title to look at.
    public func matches(bundleID: String?, appName: String?, windowTitle: String?) -> Bool {
        guard appMatcher.matches(bundleID) || appMatcher.matches(appName) else { return false }
        guard let titleMatcher else { return true }
        return titleMatcher.matches(windowTitle)
    }

    private enum Matcher: @unchecked Sendable {
        case regex(NSRegularExpression)
        case whole(String)
        case contains(String)
        /// A wildcard pattern that does not compile matches nothing.
        case nothing

        init(app pattern: String) {
            if let regex = AppPattern.regex(pattern) {
                self = .regex(regex)
            } else if pattern.contains("*") {
                let parts = pattern.split(separator: "*", omittingEmptySubsequences: false)
                    .map { NSRegularExpression.escapedPattern(for: String($0)) }
                let regex = try? NSRegularExpression(pattern: "^" + parts.joined(separator: ".*") + "$", options: .caseInsensitive)
                self = regex.map(Matcher.regex) ?? .nothing
            } else {
                self = .whole(pattern.lowercased())
            }
        }

        init(title pattern: String) {
            self = AppPattern.regex(pattern).map(Matcher.regex) ?? .contains(pattern.lowercased())
        }

        func matches(_ text: String?) -> Bool {
            guard let text else { return false }
            switch self {
            case .regex(let regex): return regex.firstMatch(in: text)
            case .whole(let lowered): return text.lowercased() == lowered
            case .contains(let lowered): return text.lowercased().contains(lowered)
            case .nothing: return false
            }
        }
    }

    /// The regular expression between slashes, or nil for a plain pattern or one that does not compile.
    static func regex(_ pattern: String) -> NSRegularExpression? {
        guard isRegex(pattern) else { return nil }
        return try? NSRegularExpression(pattern: String(pattern.dropFirst().dropLast()), options: .caseInsensitive)
    }

    static func isRegex(_ pattern: String) -> Bool { pattern.count >= 3 && pattern.hasPrefix("/") && pattern.hasSuffix("/") }

    /// Why a pattern between slashes does not compile, or nil.
    static func regexError(_ pattern: String) -> String? {
        guard isRegex(pattern) else { return nil }
        do { _ = try NSRegularExpression(pattern: String(pattern.dropFirst().dropLast()), options: .caseInsensitive); return nil }
        catch { return "bad regular expression \(pattern)" }
    }

    /// `app` or `app: "title"` separated by commas. A comma inside quotes belongs to the title.
    /// A bad item is reported and skipped; the others still count.
    public static func parse(_ text: String) -> (patterns: [AppPattern], errors: [String]) {
        var patterns: [AppPattern] = []
        var errors: [String] = []
        for item in splitOutsideQuotes(text) {
            let s = item.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { errors.append("empty pattern"); continue }
            guard let quote = s.firstIndex(of: "\""), !isRegex(s) else {
                if let error = regexError(s) { errors.append(error); continue }
                patterns.append(AppPattern(app: s))
                continue
            }
            let head = s[..<quote].trimmingCharacters(in: .whitespaces)
            let tail = s[quote...]
            guard head.hasSuffix(":") else { errors.append("expected 'app: \"title\"' in '\(s)'"); continue }
            let app = head.dropLast().trimmingCharacters(in: .whitespaces)
            guard !app.isEmpty else { errors.append("missing app name in '\(s)'"); continue }
            guard tail.count >= 2, tail.hasSuffix("\""), !tail.dropFirst().dropLast().contains("\"") else {
                errors.append("unterminated or misplaced quote in '\(s)'"); continue
            }
            let title = String(tail.dropFirst().dropLast())
            guard !title.isEmpty else { errors.append("empty window title in '\(s)'"); continue }
            if let error = regexError(app) ?? regexError(title) { errors.append(error); continue }
            patterns.append(AppPattern(app: app, title: title))
        }
        return (patterns, errors)
    }

    /// A comma inside quotes, or inside a regular expression between slashes, does not split.
    private static func splitOutsideQuotes(_ text: String) -> [String] {
        var parts: [String] = [], current = "", inQuotes = false, inSlashes = false
        for c in text {
            if c == "\"" { inQuotes.toggle() }
            if c == "/", !inQuotes, inSlashes || current.trimmingCharacters(in: .whitespaces).isEmpty { inSlashes.toggle() }
            if c == ",", !inQuotes, !inSlashes { parts.append(current); current = "" } else { current.append(c) }
        }
        parts.append(current)
        return parts
    }
}

/// Where a new window opens: on a display, on a workspace, or both.
public struct OpenOn: Equatable, Sendable {
    /// The start of the display's name, ignoring case, such as `Built-in`.
    public var display: String?
    /// Counted from 1, the top workspace. A number past the last one means a new workspace below it.
    public var workspace: Int?

    public init(display: String? = nil, workspace: Int? = nil) { self.display = display; self.workspace = workspace }
}

/// An `open-on` line: the windows it matches and where they open.
public struct OpenOnRule: Equatable, Sendable {
    public var patterns: [AppPattern]
    public var target: OpenOn
}

/// What the config's `float`, `ignore`, `no-focus` and `open-on` lines say. Each kind is the union
/// of all its lines; for `open-on`, the first matching line wins.
public struct WindowRules: Equatable, Sendable {
    public var float: [AppPattern] = []
    public var ignore: [AppPattern] = []
    public var noFocus: [AppPattern] = []
    public var openOn: [OpenOnRule] = []

    public init() {}

    /// Whether a float rule looks at window titles, so a title change can change the decision.
    public var floatsByTitle: Bool { float.contains { $0.title != nil } }

    /// Adds the patterns on one line and returns a message for each bad one.
    public mutating func add(_ kind: RuleKind, _ text: String) -> [String] {
        var (patterns, errors) = AppPattern.parse(text)
        if kind == .ignore {
            // Ignoring is decided per app, before any window exists to read a title from.
            let titled = patterns.filter { $0.title != nil }
            if !titled.isEmpty { errors.append("ignore applies to whole apps; drop the window title") }
            patterns.removeAll { $0.title != nil }
        }
        switch kind {
        case .float: float += patterns
        case .ignore: ignore += patterns
        case .noFocus: noFocus += patterns
        }
        return errors
    }

    /// Adds one `open-on` line, `patterns -> display <name> workspace <n>`, and returns a message
    /// for each problem. Either part of the target may be left out.
    public mutating func addOpenOn(_ text: String) -> [String] {
        guard let arrow = text.range(of: "->", options: .backwards) else {
            return ["expected 'apps -> display <name> workspace <n>'"]
        }
        var (patterns, errors) = AppPattern.parse(String(text[..<arrow.lowerBound]))
        var target = OpenOn()
        let words = text[arrow.upperBound...].split(whereSeparator: \.isWhitespace)
        var i = 0
        while i < words.count {
            switch words[i].lowercased() {
            case "display":
                var name: [Substring] = []
                i += 1
                while i < words.count, words[i].lowercased() != "workspace" { name.append(words[i]); i += 1 }
                let joined = name.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if joined.isEmpty { errors.append("missing display name after 'display'") } else { target.display = joined }
            case "workspace":
                if i + 1 < words.count, let n = Int(words[i + 1]), n >= 1 { target.workspace = n } else {
                    errors.append("expected a workspace number from 1 after 'workspace'")
                }
                i += 2
            default:
                errors.append("expected 'display <name>' or 'workspace <n>', found '\(words[i])'")
                i = words.count
            }
        }
        if target == OpenOn(), errors.isEmpty { errors.append("missing 'display <name>' or 'workspace <n>' after '->'") }
        if !errors.isEmpty { patterns = [] }
        if !patterns.isEmpty { openOn.append(OpenOnRule(patterns: patterns, target: target)) }
        return errors
    }

    /// Where the first matching `open-on` line sends a new window.
    public func openOn(_ f: WindowFacts) -> OpenOn? {
        openOn.first { $0.patterns.contains { $0.matches(bundleID: f.bundleID, appName: f.appName, windowTitle: f.title) } }?.target
    }

    public func ignores(bundleID: String?, appName: String?) -> Bool {
        ignore.contains { $0.matches(bundleID: bundleID, appName: appName, windowTitle: nil) }
    }

    public func floats(_ f: WindowFacts) -> Bool {
        float.contains { $0.matches(bundleID: f.bundleID, appName: f.appName, windowTitle: f.title) }
    }

    public func noFocus(_ f: WindowFacts) -> Bool {
        noFocus.contains { $0.matches(bundleID: f.bundleID, appName: f.appName, windowTitle: f.title) }
    }
}

/// What is known about a window when deciding whether to manage it.
public struct WindowFacts: Equatable, Sendable {
    public var bundleID: String?
    public var appName: String?
    public var title: String?
    public var isTileable: Bool
    public var isDockable: Bool

    public init(bundleID: String? = nil, appName: String? = nil, title: String? = nil,
                isTileable: Bool = true, isDockable: Bool = true) {
        self.bundleID = bundleID; self.appName = appName; self.title = title
        self.isTileable = isTileable; self.isDockable = isDockable
    }
}

public enum Placement: Equatable, Sendable {
    /// Not ours: ignored app or not a standard window.
    case unmanaged
    /// Joins the strip as a floating window, because a rule says so.
    case floating
    /// Cannot take a tile; left where the app put it and looked at again soon.
    case undockable
    case tiled
}

public struct Recognition: Equatable, Sendable {
    public var placement: Placement
    public var allowsFocus: Bool

    public init(placement: Placement, allowsFocus: Bool) { self.placement = placement; self.allowsFocus = allowsFocus }
}

extension WindowRules {
    /// Rules win over the dockable heuristic; the heuristic only applies to windows no rule claims.
    public func recognize(_ f: WindowFacts) -> Recognition {
        let allowsFocus = !noFocus(f)
        if ignores(bundleID: f.bundleID, appName: f.appName) { return Recognition(placement: .unmanaged, allowsFocus: true) }
        if !f.isTileable { return Recognition(placement: .unmanaged, allowsFocus: allowsFocus) }
        if floats(f) { return Recognition(placement: .floating, allowsFocus: allowsFocus) }
        if !f.isDockable { return Recognition(placement: .undockable, allowsFocus: allowsFocus) }
        return Recognition(placement: .tiled, allowsFocus: allowsFocus)
    }
}

/// Tells a focus change the user made from one an app made on its own.
public enum FocusIntent {
    /// How recent a click or key press must be for the focus change after it to count as the user's.
    public static let userWindow = 0.4
    /// How long after tinywm moves focus itself that the resulting event is left alone.
    public static let ownWindow = 1.0

    public static func isUserInitiated(secondsSinceMouseDown: Double, secondsSinceKeyDown: Double) -> Bool {
        min(secondsSinceMouseDown, secondsSinceKeyDown) < userWindow
    }

    /// A no-focus app took focus by itself, and tinywm did not ask for it: hand focus back.
    public static func shouldRestore(
        matchesNoFocus: Bool, secondsSinceMouseDown: Double, secondsSinceKeyDown: Double, secondsSinceOwnFocus: Double?
    ) -> Bool {
        guard matchesNoFocus else { return false }
        if let own = secondsSinceOwnFocus, own < ownWindow { return false }
        return !isUserInitiated(secondsSinceMouseDown: secondsSinceMouseDown, secondsSinceKeyDown: secondsSinceKeyDown)
    }

    /// Whether a command for the focused window, which waited for the window's app, may still act on
    /// the window the app reports. A click or key press since the command, an app coming to the
    /// front, or a focus change tinywm saw could each have moved focus. Ignored apps report no focus
    /// changes, so the input times are what covers them. Modifier changes do not count: the meta key
    /// comes up right after the shortcut.
    public static func stillTargets(
        secondsSinceCommand: Double, secondsSinceMouseDown: Double, secondsSinceKeyDown: Double,
        focusChanged: Bool, appActivated: Bool
    ) -> Bool {
        !focusChanged && !appActivated && secondsSinceMouseDown >= secondsSinceCommand && secondsSinceKeyDown >= secondsSinceCommand
    }
}

/// What was true when a command for the focused window was given. A command that waits on the
/// window's app checks it again before each step that acts on the app's focused window.
public struct CommandMoment: Sendable {
    public let at: Double
    public let focusRevision: Int
    public let activations: Int

    public init(at: Double, focusRevision: Int, activations: Int) {
        self.at = at
        self.focusRevision = focusRevision
        self.activations = activations
    }

    /// Takes the values as they are now, not as an earlier step saw them.
    public func stillTargets(now: Double, focusRevision: Int, activations: Int,
                             secondsSinceMouseDown: Double, secondsSinceKeyDown: Double) -> Bool {
        FocusIntent.stillTargets(secondsSinceCommand: now - at, secondsSinceMouseDown: secondsSinceMouseDown,
                                 secondsSinceKeyDown: secondsSinceKeyDown,
                                 focusChanged: focusRevision != self.focusRevision, appActivated: activations != self.activations)
    }
}

extension NSRegularExpression {
    func firstMatch(in text: String) -> Bool {
        firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
