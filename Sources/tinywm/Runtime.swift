import AppKit
import ApplicationServices
import StripEngine
import StripModel
import WindowCore
import WindowKit

/// Settings tinywm keeps in the user defaults.
enum Defaults {
    static let disabledDisplays = "disabledDisplays"
    static let livePictures = "liveWindowPictures"
    static let minimumWidths = "minimumWidths"
}

/// tinywm while it runs: everything that needs Accessibility access, built at once when access
/// is granted. Windows, displays, motion, keys, swipes and the config all start here.
@MainActor
final class Runtime {
    private(set) var config = StripConfig()
    private(set) var swipeEnabled = true
    private(set) var recognizer = SwipeRecognizer()

    private let menu: StatusMenu
    private let configFile: ConfigFile
    private let windows = AXWindows()
    private let tracker = WindowTracker()
    private let hotkeys = Hotkeys()
    private let snapshots: ScreenCaptureSnapshots
    /// Pictures or, in cover mode, covers for every overlay.
    private let pictures: WindowPictures
    private let highlight: FocusHighlight
    private let overview: Overview
    private let displays: StripDisplays
    private let release: WindowRelease
    private let arrivals: WindowArrivals
    private let persistence: LayoutPersistence
    private let focusKeeper: FocusKeeper
    private let metaKey = MetaKey()
    /// Meta + left drag moves windows; the overlay draws the picture and the drop marker.
    private let dragger: WindowDragger
    private let dragOverlay: DragOverlay
    private let lifecycle: WindowLifecycle
    private let commands: ShortcutCommands
    private let touches = Multitouch()

    /// Each display's overlay and minimap, by display ID.
    private var overlays: [String: (pictures: PictureMotion, minimap: MinimapPanel)] = [:]
    private var motionDisplays: Set<String> = []
    private var coveringOverlays = 0
    private var swipeAxis: SwipeRecognizer.Axis?
    private var swipeEngine: StripEngine?
    private var verticalTravel = 0.0
    private var icons: [pid_t: NSImage] = [:]
    private var appNames: [pid_t: String] = [:]

    /// Lets the displays reach this object, which does not exist yet when they are made.
    private final class DisplayHooks {
        var attach: (StripEngine, TiledDisplay) -> Void = { _, _ in }
        var detach: (String) -> Void = { _ in }
    }

    init(menu: StatusMenu, configFile: ConfigFile) {
        self.menu = menu
        self.configFile = configFile
        Self.startLog()
        // Motion shows live window pictures unless the user turns them off; those need
        // Screen Recording access, and without it windows move at once.
        snapshots = ScreenCaptureSnapshots(windows: windows)
        pictures = WindowPictures(snapshots: snapshots, covers: CoverArt(windows: windows))
        // Set before anything asks for a picture, so cards never record the screen.
        pictures.coverMode = !UserDefaults.standard.bool(forKey: Defaults.livePictures)
        // Fetch the real desktop picture early, so the first motion already has it.
        _ = snapshots.wallpaper()
        highlight = FocusHighlight(windows: windows)
        overview = Overview(pictures: pictures, windows: windows)
        let hooks = DisplayHooks()
        let saved = UserDefaults.standard.stringArray(forKey: Defaults.disabledDisplays) ?? []
        displays = StripDisplays(windows: windows, disabled: Set(saved),
                                 configure: { hooks.attach($0, $1) }, discard: { hooks.detach($0) })
        release = WindowRelease(windows: windows, displays: { NSScreen.screens.map { Screens.axRect($0.frame) } })
        arrivals = WindowArrivals(windows: windows)
        persistence = LayoutPersistence(windows: windows, displays: displays)
        focusKeeper = FocusKeeper(windows: windows)
        dragger = WindowDragger(displays: displays, windows: windows)
        dragOverlay = DragOverlay(pictures: pictures)
        lifecycle = WindowLifecycle(windows: windows, tracker: tracker, displays: displays, arrivals: arrivals,
                                    persistence: persistence, focusKeeper: focusKeeper, dragger: dragger,
                                    snapshots: snapshots)
        commands = ShortcutCommands(windows: windows, displays: displays, overview: overview, dragger: dragger,
                                    lifecycle: lifecycle, metaKey: metaKey)

        hooks.attach = { [unowned self] engine, info in attach(engine, to: info) }
        hooks.detach = { [unowned self] id in detach(id) }
        start()
    }

    private func start() {
        lifecycle.rules = { [unowned self] in config.rules }
        commands.config = { [unowned self] in config }
        Log.describe = { [unowned self] id in
            MainActor.assumeIsolated {
                let app = windows.pid(of: id).map(appName) ?? "?"
                let title = windows.cachedTitle(of: id).map { "\"\($0.prefix(60))\"" } ?? (windows.pid(of: id) == nil ? "(gone)" : "")
                return "\(id) \(app) \(title)"
            }
        }
        overview.ringStyle = highlight.style
        overview.activate = { [unowned self] id in
            displays.windowFocused(id)
            windows.focus(id)
        }
        displays.appOf = { [unowned self] id in windows.bundleID(of: id) }
        displays.minimums = MinimumWidths(UserDefaults.standard.dictionary(forKey: Defaults.minimumWidths) as? [String: Double] ?? [:])
        displays.onMinimumsChanged = { UserDefaults.standard.set($0.widths, forKey: Defaults.minimumWidths) }
        release.beforeRelease = { [unowned self] in persistence.saveNow(wait: true) }
        release.install()
        persistence.enabled = { [unowned self] in config.restoreLayout }

        lifecycle.focusMoved = { [unowned self] restack in updateHighlight(restack: restack) }
        lifecycle.retileAll = { [unowned self] in retileAll() }
        lifecycle.install()

        // The first read happens before displays exist, so their engines start with the configured layout.
        let first = configFile.load()
        config = first.config
        menu.showIssues(first.issues)
        configFile.onChange = { [unowned self] in applyConfig($0) }
        highlight.showBorder = config.focusBorder
        swipeEnabled = config.swipe
        recognizer.fingers = config.swipeFingers
        refreshSwipeWarning()
        overview.keys = OverviewKeys(bindings: config.bindings)
        displays.settings = config.applied(to: displays.settings)
        displays.update(Screens.infos())
        menu.showDisplays(disabled: displays.disabled)
        commands.registered = { [unowned self] in showShortcuts() }
        commands.install(on: hotkeys)
        metaKey.onChange = { [unowned self] in showShortcuts() }
        dragger.clock = MacClock()
        dragger.presenter = dragOverlay
        metaKey.dragger = dragger
        metaKey.canDrag = { [unowned self] in !overview.isOpen }
        metaKey.setMode(config.meta)
        metaKey.start()
        configFile.watch()
        startSwipes()
        persistence.reading = { [unowned self] in tracker.isProbing || arrivals.isJudging }
        persistence.beginRestore()
        // An app that hangs would otherwise hold each call for macOS's default of 6 seconds.
        // Set on the system-wide element, the limit applies to every element.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        tracker.start()
        watchScreens()
    }

    /// Every decision goes to ~/Library/Logs/tinywm/tinywm.log, so a misplaced window can be
    /// traced afterwards.
    private static func startLog() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/tinywm/tinywm.log")
        Log.start(at: url)
        let info = ProcessInfo.processInfo
        Log.note("start", "tinywm pid \(info.processIdentifier) from \(Bundle.main.executablePath ?? "?") "
            + "macOS \(info.operatingSystemVersionString)")
    }

    /// Log lines name windows from what is already known, so writing one never waits on an app.
    private func appName(_ pid: pid_t) -> String {
        if let known = appNames[pid] { return known }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        appNames[pid] = name
        return name
    }

    // MARK: Config

    /// Applies a freshly read config to everything that follows it. Nothing here needs a restart.
    private func applyConfig(_ parsed: StripConfig.Parsed) {
        Log.note("config", "reloaded; \(parsed.issues.count) issues")
        config = parsed.config
        menu.showIssues(parsed.issues)
        commands.reload()
        metaKey.setMode(config.meta)
        displays.settings = config.applied(to: displays.settings)
        for engine in displays.engines.values {
            let settings = config.applied(to: engine.settings)
            if settings != engine.settings { engine.settings = settings }
        }
        highlight.showBorder = config.focusBorder
        swipeEnabled = config.swipe
        recognizer.fingers = config.swipeFingers
        refreshSwipeWarning()
        overview.keys = OverviewKeys(bindings: config.bindings)
        showShortcuts()
        lifecycle.applyRules()
    }

    private func showShortcuts() {
        let registry = ShortcutRegistry.shared
        menu.showShortcuts(registry.entries) { [unowned self] action in
            registry.shortcut(for: action).map(metaKey.display) ?? "none"
        }
    }

    // MARK: Menu choices

    /// By default each window shows as a live picture while it moves, which records the
    /// windows. Turned off, each window shows as a card with its app's icon and title, so
    /// tinywm never records the screen. The choice takes effect at the next motion.
    func setLivePictures(_ live: Bool) {
        pictures.coverMode = !live
        // Every window needs a picture before its next move.
        if live { for e in displays.engines.values { snapshots.prime(Set(e.workspaces.strips.flatMap(\.allWindows))) } }
    }

    func toggleDisplay(_ id: String) {
        Log.note("display", "menu toggles \(id): \(displays.disabled.contains(id) ? "on" : "off")")
        if displays.disabled.contains(id) {
            displays.setEnabled(id, true)
            lifecycle.adoptWindows(on: id)
        } else {
            let released = displays.setEnabled(id, false)
            lifecycle.restore(released)
        }
        UserDefaults.standard.set(Array(displays.disabled), forKey: Defaults.disabledDisplays)
        for (id, engine) in displays.engines { overlays[id]?.pictures.viewport = engine.viewport }
        menu.showDisplays(disabled: displays.disabled)
    }

    func retileAll() {
        displays.retileAll(Screens.infos())
        for (id, engine) in displays.engines { overlays[id]?.pictures.viewport = engine.viewport }
    }

    /// Shows a menu warning when a macOS gesture reacts to the same fingers as tinywm's swipes.
    func refreshSwipeWarning() {
        let clashes = swipeEnabled ? SwipeClash.clashes(fingers: recognizer.fingers, settings: SystemSetup.trackpadSettings()) : []
        menu.showSwipeClashes(clashes, fingers: recognizer.fingers)
    }

    // MARK: Displays

    /// True while the screen is locked or asleep.
    private var userAway = false
    private var pendingScreens: DispatchWorkItem?
    private var settleRetile: DispatchWorkItem?

    private func watchScreens() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        // While the screen is locked or asleep, displays drop out and come back; the layout
        // waits until the user is back.
        let away: [(NotificationCenter, Notification.Name)] = [
            (NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")),
        ]
        let back: [(NotificationCenter, Notification.Name)] = [
            (NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidBecomeActiveNotification),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")),
        ]
        for (center, name) in away {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    Log.note("display", "user away: \(name.rawValue)")
                    self?.userAway = true
                }
            }
        }
        for (center, name) in back {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    Log.note("display", "user back: \(name.rawValue)")
                    self?.userAway = false
                    self?.screensChanged()
                }
            }
        }
    }

    /// A display that disappears is given a few seconds to come back before its windows move,
    /// since displays blink out while waking or when a cable wiggles. While the user is away
    /// nothing moves; the change is applied once they are back.
    private func screensChanged() {
        pendingScreens?.cancel()
        let infos = Screens.infos()
        let vanished = displays.engines.keys.contains { id in !infos.contains { $0.id == id } }
        Log.note("display", "screens changed: \(infos.count) attached, vanished=\(vanished), away=\(userAway)")
        guard vanished || userAway else { return applyScreens() }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.userAway { return }
                self.applyScreens()
            }
        }
        pendingScreens = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (userAway ? 2 : 5), execute: work)
    }

    private func applyScreens() {
        displays.update(Screens.infos())
        for (id, engine) in displays.engines { overlays[id]?.pictures.viewport = engine.viewport }
        menu.showDisplays(disabled: displays.disabled)
        // macOS moves windows itself for a while after a display changes, as on a new resolution,
        // so every window is written again once the displays have been quiet for a moment.
        settleRetile?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.userAway else { return }
                Log.note("display", "displays settled; retiling")
                self.retileAll()
            }
        }
        settleRetile = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// Gives a new display's engine its overlay, minimap and observers.
    private func attach(_ engine: StripEngine, to info: TiledDisplay) {
        let id = info.id
        let screen: () -> NSScreen? = { Screens.screen(id: id) }
        let pictures = PictureMotion(pictures: self.pictures, windows: windows)
        pictures.screen = screen
        pictures.viewport = info.visible
        pictures.ringStyle = highlight.style
        pictures.showRing = { [unowned self] in highlight.showBorder }
        // Each display has its own pictures; nudges wait while any of them covers windows.
        pictures.onCovering = { [unowned self] on in
            coveringOverlays = max(0, coveringOverlays + (on ? 1 : -1))
            windows.holdsNudges = coveringOverlays > 0
            tracker.paused = coveringOverlays > 0
        }
        pictures.onActive = { [unowned self] on in
            if on { motionDisplays.insert(id) } else { motionDisplays.remove(id) }
            highlight.setSuspended(!motionDisplays.isEmpty)
            if !on { updateHighlight() }
        }
        let minimap = MinimapPanel()
        minimap.screen = screen
        minimap.icon = { [unowned self] wid in
            guard let pid = windows.pid(of: wid) else { return nil }
            if let cached = icons[pid] { return cached }
            let image = NSRunningApplication(processIdentifier: pid)?.icon
            icons[pid] = image
            return image
        }
        overlays[id] = (pictures, minimap)

        engine.clock = MacClock()
        engine.presenter = pictures
        engine.observers.append { [unowned self] _ in updateHighlight() }
        engine.observers.append { [unowned self] _ in persistence.changed() }
        // Windows are captured only around motion. A new window gets one picture now so its
        // first move is not blank.
        engine.observers.append { [unowned self] e in
            snapshots.prime(Set(e.workspaces.strips.flatMap(\.allWindows)))
        }
        engine.observers.append { [unowned self] e in overlays[id]?.minimap.show(e) }
        engine.observers.append { [unowned self] e in
            let ws = e.workspaces
            // The top empty workspace is 0, so the first one with windows is 1.
            menu.setTitle(ws.strips.count > 3 || ws.active != 1 ? " \(ws.active)" : "")
        }
    }

    private func detach(_ id: String) {
        if let ui = overlays.removeValue(forKey: id) {
            ui.pictures.close()
            ui.minimap.close()
        }
        motionDisplays.remove(id)
    }

    /// Puts the highlight on the strip's focused window when it really has focus. While another
    /// app is in front, such as a fullscreen game tinywm leaves alone, the border is hidden: it
    /// shows on every Space and would sit over that app.
    private func updateHighlight(restack: Bool = false) {
        guard let id = windows.focusedWindow, let engine = displays.engine(holding: id),
              engine.strip.focusedWindow == id else {
            highlight.show(nil, frame: nil)
            return
        }
        highlight.show(id, frame: engine.frame(of: id), restack: restack)
    }

    // MARK: Swipes

    /// Trackpad swipes: sideways drags the strip under the fingers and settles on a column,
    /// up or down steps one workspace, with content following the fingers' direction.
    private func startSwipes() {
        touches.onFrame = { [unowned self] contacts, t in
            guard swipeEnabled else { return }
            for event in recognizer.feed(contacts, at: t) { handle(event) }
        }
        touches.start()
    }

    private func handle(_ event: SwipeRecognizer.Event) {
        switch event {
        case .began(let axis):
            swipeAxis = axis
            verticalTravel = 0
            swipeEngine = displays.underPointer(Screens.pointer())
            if axis == .horizontal { swipeEngine?.beginSwipe() }
        case .moved(let dx, let dy):
            if swipeAxis == .horizontal { swipeEngine?.swipe(by: dx) } else { verticalTravel += dy }
        case .ended(let velocity):
            if swipeAxis == .horizontal {
                swipeEngine?.endSwipe(velocity: velocity)
            } else if abs(verticalTravel) > 0.08 {
                // Fingers moving up push the stack up, bringing the workspace below into view.
                swipeEngine?.switchWorkspace(by: verticalTravel > 0 ? 1 : -1)
            }
            swipeAxis = nil
            swipeEngine = nil
        case .cancelled:
            if swipeAxis == .horizontal { swipeEngine?.endSwipe(velocity: 0) }
            swipeAxis = nil
            swipeEngine = nil
        }
    }
}
