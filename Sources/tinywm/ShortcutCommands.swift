import AppKit
import Carbon.HIToolbox
import StripEngine
import StripModel
import WindowCore
import WindowKit

/// Turns each shortcut into what it does: the strip actions on the active display, the
/// overview, closing a window, and the config's own commands.
@MainActor
final class ShortcutCommands {
    /// Called after the shortcuts change, so the menu can list them.
    var registered: () -> Void = {}
    /// The config in force, read afresh each time so a reload applies at once.
    var config: () -> StripConfig = { StripConfig() }

    private let windows: AXWindows
    private let displays: StripDisplays
    private let overview: Overview
    private let dragger: WindowDragger
    private let lifecycle: WindowLifecycle
    private let focusReturn: FocusReturn
    private let registry = ShortcutRegistry.shared

    init(windows: AXWindows, displays: StripDisplays, overview: Overview, dragger: WindowDragger,
         lifecycle: WindowLifecycle, metaKey: MetaKey) {
        self.windows = windows
        self.displays = displays
        self.overview = overview
        self.dragger = dragger
        self.lifecycle = lifecycle
        focusReturn = FocusReturn(windows: windows)
        focusReturn.lastKeyDown = { [unowned metaKey] in metaKey.lastKeyDown }
    }

    private var activeEngine: StripEngine? { displays.active(pointer: Screens.pointer()) }

    /// Registers every action and command once, bound to `hotkeys`.
    func install(on hotkeys: Hotkeys) {
        registry.batch {
            registry.attach(hotkeys)
            let initial = Self.shortcuts(for: config())
            let actions = engineActions
            for spec in StripActions.all {
                let shortcut = initial[spec.name] ?? nil
                let run: () -> Void
                switch spec.name {
                case "overview":
                    run = { [unowned self] in
                        guard !dragger.isActive, let engine = activeEngine else { return }
                        overview.toggle(engine, on: displays.id(of: engine).flatMap { Screens.screen(id: $0) })
                    }
                case "close-window":
                    run = { [unowned self] in closeFocusedWindow() }
                default:
                    guard let act = actions[spec.name] else { continue }
                    let name = spec.name
                    run = { [unowned self] in runAction(name, act) }
                }
                registry.register(action: spec.name, title: spec.title, defaultKey: shortcut?.keyCode,
                                  defaultModifiers: shortcut?.modifiers ?? 0, handler: run)
            }
            registerCommands()
        }
        registered()
    }

    /// Takes the keys of a freshly read config.
    func reload() {
        registry.batch {
            registry.setDefaultShortcuts(Self.shortcuts(for: config()))
            registerCommands()
        }
        registered()
    }

    private func runAction(_ name: String, _ act: (StripEngine) -> Void) {
        // A drag holds the strip still until it ends, so no key changes it underneath.
        guard !dragger.isActive else { return Log.note("key", "\(name) ignored during a drag") }
        // While the overview is open, focus keys steer it and every other action waits, so no
        // key moves real windows.
        if overview.isOpen {
            Log.note("key", "\(name) in the overview")
            if let command = OverviewKeys.command(forAction: name) { overview.handle(command) }
        } else if let engine = activeEngine {
            Log.note("key", "\(name) on \(engine.label); system focus \(windows.knownFocus.map(Log.name) ?? "none"), "
                + "strip focus \(engine.strip.focusedWindow.map(Log.name) ?? "none")")
            act(engine)
        } else {
            Log.note("key", "\(name): no active display")
        }
    }

    /// The config's own shortcuts, replaced as a set whenever the file changes.
    private func registerCommands() {
        registry.unregister { $0.hasPrefix("command ") }
        for command in config().commands {
            let s = Self.shortcut(command.chord)
            registry.register(action: command.name, title: command.title, defaultKey: s?.keyCode,
                              defaultModifiers: s?.modifiers ?? 0) { [unowned self] in
                Log.note("key", "custom \(command.name)")
                if case .keys = command.kind { focusReturn.watch() }
                CommandRunner.run(command)
            }
        }
    }

    /// Presses the focused window's close button, as a click on it would. Works for any app's
    /// window, tiled or not; the app may still ask to save first.
    private func closeFocusedWindow() {
        // An app macOS lists with process ID -1, such as tinytext started from Alfred, is reached
        // through the real process its focused window belongs to.
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        let pid = front > 0 ? front : windows.knownFocus.flatMap(windows.pid(of:)) ?? -1
        guard pid > 0 else { return }
        // The app is asked on its own queue: one busy redrawing must not hold up the keyboard.
        let moment = CommandMoment(at: ProcessInfo.processInfo.systemUptime,
                                   focusRevision: windows.focusRevision, activations: windows.activations)
        // The app need not be in front: one listed with process ID -1 never is.
        func stillMeant(_ step: String) -> Bool {
            let meant = moment.stillTargets(
                now: ProcessInfo.processInfo.systemUptime, focusRevision: windows.focusRevision,
                activations: windows.activations,
                secondsSinceMouseDown: FocusKeeper.since([.leftMouseDown, .rightMouseDown]),
                secondsSinceKeyDown: FocusKeeper.since([.keyDown]))
            if !meant { Log.note("key", "close-window skipped \(step): focus may have moved while its app was asked") }
            return meant
        }
        windows.readFocused(of: pid) { [unowned self] read in
            guard let window = read.window, stillMeant("at the focus read") else { return }
            // Recorded before the press, since the app's focus change can follow the press at once.
            if let id = read.id { lifecycle.closing(id, app: pid) }
            windows.pressClose(window, pid: pid) { [unowned self] in
                // A window that draws its own title bar, like Steam's, has no button to press. ⌘W
                // closes whichever window is in front by then, so the command is checked again.
                guard stillMeant("before ⌘W") else {
                    if let id = read.id { lifecycle.closeCancelled(id) }
                    return
                }
                CommandRunner.press(KeyStroke(keyCode: 13, command: true), in: pid)
            }
        }
    }

    /// What each action does on the active display's engine. Names and keys come from `StripActions`
    /// and the config file; only the behaviour lives here.
    private var engineActions: [String: (StripEngine) -> Void] {
        var a: [String: (StripEngine) -> Void] = [:]
        let directions: [(String, Direction)] = [("left", .left), ("right", .right), ("down", .down), ("up", .up)]
        for (name, d) in directions {
            for suffix in ["", "-arrow"] {
                a["focus-\(name)\(suffix)"] = { $0.focus(d) }
                a["move-\(name)\(suffix)"] = { $0.move(d) }
            }
        }
        for suffix in ["", "-arrow", "-page"] {
            a["workspace-down\(suffix)"] = { $0.switchWorkspace(by: 1) }
            a["workspace-up\(suffix)"] = { $0.switchWorkspace(by: -1) }
            a["workspace-move-down\(suffix)"] = { $0.moveToWorkspace(by: 1) }
            a["workspace-move-up\(suffix)"] = { $0.moveToWorkspace(by: -1) }
        }
        for n in 1...9 { a["focus-column-\(n)"] = { $0.focusColumn(n - 1) } }
        a["width-cycle"] = { $0.cycleWidth() }
        a["width-full"] = { $0.toggleFullWidth() }
        a["center"] = { $0.center() }
        a["wider"] = { $0.wider() }
        a["narrower"] = { $0.narrower() }
        a["stack-right"] = { $0.stack(.right) }
        a["stack-left"] = { $0.stack(.left) }
        a["pop-out"] = { $0.popOut() }
        a["float"] = { $0.toggleFloat() }
        a["float-focus"] = { $0.toggleFloatFocus() }
        // Displays are walked left to right; the move variants carry the focused window.
        a["display-next"] = { [unowned self] in focusDisplay(by: 1, from: $0) }
        a["display-previous"] = { [unowned self] in focusDisplay(by: -1, from: $0) }
        a["display-move-next"] = { [unowned self] in displays.moveFocused(by: 1, from: $0) }
        a["display-move-previous"] = { [unowned self] in displays.moveFocused(by: -1, from: $0) }
        for (name, d) in directions {
            a["display-\(name)"] = { [unowned self] in focusDisplay(toward: d, from: $0) }
            a["display-move-\(name)"] = { [unowned self] in displays.moveFocused(toward: d, from: $0) }
        }
        // With focus-crosses-displays, focus and move continue past the strip's ends onto the
        // display on that side, so one key travels across everything.
        for (name, d) in directions where d == .left || d == .right {
            for suffix in ["", "-arrow"] {
                a["focus-\(name)\(suffix)"] = { [unowned self] e in
                    if config().focusCrossesDisplays, e.atStripEdge(d) { focusDisplay(toward: d, from: e) } else { e.focus(d) }
                }
                a["move-\(name)\(suffix)"] = { [unowned self] e in
                    if config().focusCrossesDisplays, e.atStripEdge(d) { displays.moveFocused(toward: d, from: e) } else { e.move(d) }
                }
            }
        }
        return a
    }

    /// An empty display has no window to take focus, so the pointer goes there to show where commands act.
    private func focusDisplay(by delta: Int, from engine: StripEngine) {
        pointAt(displays.focusDisplay(by: delta, from: engine))
    }

    private func focusDisplay(toward direction: Direction, from engine: StripEngine) {
        pointAt(displays.focusDisplay(toward: direction, from: engine))
    }

    private func pointAt(_ id: String?) {
        guard let id, displays.engines[id]?.strip.focusedWindow == nil, let info = displays.info(id) else { return }
        let c = info.visible.center
        CGWarpMouseCursorPosition(CGPoint(x: c.x, y: c.y))
    }

    private static func shortcuts(for config: StripConfig) -> [String: Shortcut?] {
        Dictionary(uniqueKeysWithValues: StripActions.all.map { ($0.name, shortcut(config.bindings[$0.name])) })
    }

    /// Registry shortcuts are ⌃⌥ plus extras; the meta key is translated from them later.
    private static func shortcut(_ chord: MetaKeyBindings.Chord?) -> Shortcut? {
        chord.map {
            Shortcut(keyCode: $0.keyCode, modifiers: controlKey | optionKey
                | ($0.shift ? shiftKey : 0) | ($0.option ? cmdKey : 0)
                | ($0.control ? MetaKeyBindings.extraControl : 0))
        }
    }
}
