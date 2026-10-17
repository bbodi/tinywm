import AppKit
import ApplicationServices
import StripEngine
import StripModel
import WindowCore
import WindowKit

/// What happens to windows as the system reports them: they arrive and are placed, move, take
/// focus, hide and come back, and go. The strips follow, the rules apply, and every cache that
/// knows a window forgets it in one place.
@MainActor
final class WindowLifecycle {
    /// Called when focus may have moved, so the focus border can follow. `restack` raises the border too.
    var focusMoved: (_ restack: Bool) -> Void = { _ in }
    /// Writes every window's frame again.
    var retileAll: () -> Void = {}
    /// The rules in force, read afresh each time so a config reload applies at once.
    var rules: () -> WindowRules = { WindowRules() }

    private let windows: AXWindows
    private let tracker: WindowTracker
    private let displays: StripDisplays
    private let arrivals: WindowArrivals
    private let persistence: LayoutPersistence
    private let focusKeeper: FocusKeeper
    private let dragger: WindowDragger
    private let snapshots: ScreenCaptureSnapshots

    /// Windows floating only because they could not take a tile yet.
    private var autoFloats: Set<String> = []
    /// Slots of windows their apps hid instead of closing, by window number, so each comes back
    /// where it was when the app shows it again.
    private var hiddenSlots: [CGWindowID: StripDisplays.Slot] = [:]
    /// Slots of windows that went fullscreen, so each comes back where it was.
    private var fullScreenSlots: [String: StripDisplays.Slot] = [:]
    private var closeFocus = CloseFocus()
    private var framesBeingRead: Set<String> = []
    private var framesChangedAgain: Set<String> = []
    private var snapping: Set<String> = []
    private var snapTimes: [String: [Double]] = [:]

    init(windows: AXWindows, tracker: WindowTracker, displays: StripDisplays, arrivals: WindowArrivals,
         persistence: LayoutPersistence, focusKeeper: FocusKeeper, dragger: WindowDragger,
         snapshots: ScreenCaptureSnapshots) {
        self.windows = windows
        self.tracker = tracker
        self.displays = displays
        self.arrivals = arrivals
        self.persistence = persistence
        self.focusKeeper = focusKeeper
        self.dragger = dragger
        self.snapshots = snapshots
    }

    /// Subscribes to the tracker, app activation and screen locks. Call once, before the tracker starts.
    func install() {
        focusKeeper.rules = { [unowned self] in rules() }
        tracker.isIgnored = { [unowned self] bundleID, name in rules().ignores(bundleID: bundleID, appName: name) }
        installArrivals()
        installRemovals()
        installFocus()
        installMoves()
        installLocks()
    }

    // MARK: Arrival

    private func installArrivals() {
        // The window's app may still be starting and answer slowly, so it is read on its own queue.
        arrivals.recognize = { [unowned self] id, _, done in
            windows.read(id) { [unowned self] reading in
                guard let reading else { return }
                let facts = Self.facts(reading)
                done(.init(recognition: recognition(id, facts), facts: facts, frame: reading.frame))
            }
        }
        arrivals.place = { [unowned self] id, judged in place(id, judged) }
        tracker.onAdded = { [unowned self] element, pid, probe in
            let isNew = windows.knownID(for: element) == nil
            let (id, rebound) = windows.identify(element, pid: pid, known: probe.map { ($0.frame, $0.title) })
            // Some apps, such as Brave, report a window gone during the lock and hand back the
            // same element after it, so any report of a held window ends its hold.
            let wasHeld = heldWhileLocked.remove(id) != nil
            if rebound {
                Log.note("tracker", "\(Log.name(id)) is back with a new element, window number \(windows.number(of: id).map(String.init) ?? "?"); it keeps its place")
                return
            }
            if wasHeld { Log.note("tracker", "\(Log.name(id)) is back with the same element; it keeps its place") }
            Log.note("tracker", "window appeared \(Log.name(id)) new=\(isNew) at \(Log.rect(windows.landedFrame(of: id) ?? windows.originalFrames[id]))")
            // Dialogs and fixed-size windows stay floating where the app put them.
            if isNew { arrivals.arrived(id, element: element) }
        }
        // A window that could not dock when it opened, such as a tab still being dragged out,
        // joins the strip once it can.
        tracker.onBecameDockable = { [unowned self] element in
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return }
            let id = windows.id(for: element, pid: pid)
            let wasAutoFloat = autoFloats.contains(id)
            Log.note("tracker", "\(Log.name(id)) became dockable; auto-floating=\(wasAutoFloat)")
            if autoFloats.remove(id) != nil { displays.windowRemoved(id) }
            arrivals.arrived(id, element: element)
        }
        tracker.onDeminiaturized = { [unowned self] element in
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return }
            let id = windows.id(for: element, pid: pid)
            Log.note("tracker", "deminiaturized \(Log.name(id))")
            // It arrives as a new window does, so it returns to its slot and the rules still apply.
            arrivals.arrived(id, element: element)
        }
        tracker.titleListeners.append { [unowned self] element in
            guard let id = windows.knownID(for: element) else { return }
            windows.refreshTitle(id)
        }
        // Some apps change titles every second, such as a terminal showing a spinner. Checking
        // the rules asks the app several questions, so it runs only when a rule needs the title.
        tracker.titleListeners.append { [unowned self] element in
            guard rules().floatsByTitle, let id = windows.knownID(for: element), isTiled(id) else { return }
            recognize(id) { [unowned self] r, _ in
                guard r.placement == .floating, isTiled(id) else { return }
                Log.note("rules", "\(Log.name(id)) now matches a float rule by its title; floating it")
                displays.floatWindow(id)
            }
        }
    }

    /// Puts a judged window on a strip. Returns the frame it was given, if it was tiled.
    private func place(_ id: String, _ judged: WindowArrivals.Judged) -> Rect? {
        let recognition = judged.recognition
        guard displays.engine(holding: id) == nil else {
            Log.note("place", "\(Log.name(id)) is already on a strip; left as it is")
            return nil
        }
        if let number = windows.number(of: id), let slot = hiddenSlots.removeValue(forKey: number),
           displays.restore(id, to: slot) {
            Log.note("place", "\(Log.name(id)) returns to its slot from before it hid: \(slot)")
            return displays.engine(holding: id)?.frame(of: id)
        }
        if persistence.hold(id, frame: judged.frame, recognition: recognition) {
            Log.note("place", "\(Log.name(id)) held for the layout restore as \(recognition.placement)")
            return nil
        }
        // A window that cannot take a tile floats until it can.
        if recognition.placement == .undockable { autoFloats.insert(id) }
        let openOn = rules().openOn(judged.facts)
        Log.note("place", "\(Log.name(id)) added as \(recognition.placement) at \(Log.rect(judged.frame))"
            + (openOn.map { " by an open-on rule: display \($0.display ?? "any"), workspace \($0.workspace.map(String.init) ?? "current")" } ?? ""))
        displays.newWindowAdded(id, frame: judged.frame,
                                floating: recognition.placement != .tiled, takesFocus: recognition.allowsFocus, openOn: openOn)
        return displays.engine(holding: id)?.frame(of: id)
    }

    // MARK: Removal

    private func installRemovals() {
        tracker.onRemoved = { [unowned self] element, temporary in
            guard let id = windows.knownID(for: element) else { return }
            // While the screen is locked macOS replaces windows' elements, and the windows come
            // back after the unlock, so they keep their places until then.
            if screenLocked {
                heldWhileLocked.insert(id)
                Log.note("tracker", "window gone \(Log.name(id)) while locked, window number \(windows.number(of: id).map(String.init) ?? "?"); held until the unlock")
                return
            }
            Log.note("tracker", "window gone \(Log.name(id)) temporary=\(temporary) slot=\(displays.slot(of: id).map { "\($0)" } ?? "none")")
            if temporary, let number = windows.number(of: id), let slot = displays.slot(of: id) {
                hiddenSlots[number] = slot
            }
            if !temporary, windows.knownFocus == id, let pid = windows.pid(of: id), closeFocus.closing == nil {
                closeFocus.closing(id, app: pid)
            }
            // A window that hid without focus must not pull another app's window to the front.
            forget(id, refocus: !temporary || windows.focusedWindow == id)
        }
        tracker.onAppQuit = { [unowned self] pid in
            Log.note("tracker", "app \(pid) quit; removing \(Log.names(windows.ids(ofPID: pid)))")
            for id in windows.ids(ofPID: pid) { forget(id) }
        }
        tracker.onAppExcluded = { [unowned self] pid in
            let ids = windows.ids(ofPID: pid)
            Log.note("tracker", "app \(pid) is now ignored; releasing \(Log.names(ids))")
            restore(ids)
            for id in ids { forget(id) }
        }
    }

    /// Takes a window off every strip and drops what is known about it.
    private func forget(_ id: String, refocus: Bool = true) {
        autoFloats.remove(id)
        snapTimes[id] = nil
        fullScreenSlots[id] = nil
        heldWhileLocked.remove(id)
        displays.windowRemoved(id, refocus: refocus)
        dragger.windowRemoved(id)
        snapshots.forget(id)
        arrivals.forget(id)
        windows.forget(id)
    }

    /// Puts windows back where they were found, as when quitting.
    func restore(_ ids: [String]) {
        let originals = windows.originalFrames.filter { ids.contains($0.key) }
        let frames = releaseFrames(originals: originals, displays: NSScreen.screens.map { Screens.axRect($0.frame) })
        for (id, frame) in frames { windows.setFrame(id, frame) { _ in } }
    }

    // MARK: Focus

    /// Records that tinywm is closing a window of `app`, so focus after the close is handled.
    func closing(_ id: String, app pid: pid_t) { closeFocus.closing(id, app: pid) }
    func closeCancelled(_ id: String) { closeFocus.cancel(id) }

    private func installFocus() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.activated(app) }
        }
        // Entering or leaving a fullscreen window's Space changes which window is in front.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.focusMoved(true) }
        }
        tracker.onFocused = { [unowned self] element, pid in focused(element, pid: pid) }
        tracker.focusListeners.append { [unowned self] _ in focusMoved(true) }
    }

    private func activated(_ app: NSRunningApplication) {
        Log.note("focus", "app activated: \(app.localizedName ?? "?") pid \(app.processIdentifier)")
        windows.noteActivated()
        let activation = windows.activations
        // An app coming back to the front reports no focused-window change when its window
        // stayed the same, as after a launcher closes, so the border is redrawn here. Its
        // focused window can take a moment to settle.
        focusMoved(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated { self?.focusMoved(true) }
        }
        if app.bundleIdentifier == "com.apple.finder" {
            // A click on an empty desktop activates Finder with no window focused. The display
            // under the pointer is then where the user is, so new windows open there.
            windows.readFocused(of: app.processIdentifier) { [weak self] read in
                guard let self, read.isCurrent, read.id == nil, windows.activations == activation,
                      let engine = displays.underPointer(Screens.pointer()) else { return }
                displays.desktopClicked(on: engine)
            }
        }
        closeFocus.activated(app: app.processIdentifier)
        guard tracker.manageable(app) else { return }
        focusKeeper.activated(app)
        // A click on another app's window activates that app, but the app reports no
        // focused-window change when that window already was its focused one, so the strip
        // follows here, as it does for focus moved with the keyboard.
        windows.readFocused(of: app.processIdentifier) { [weak self] read in
            guard let self, read.isCurrent, windows.activations == activation, let id = read.id else { return }
            displays.windowFocused(id)
        }
    }

    private func focused(_ element: AXUIElement, pid: pid_t) {
        guard let id = windows.knownID(for: element) else { return windows.noteFocusMoved() }
        windows.noteFocused(id)
        let closingWindow = closeFocus.closing?.window
        if let engine = displays.engine(holding: id),
           closeFocus.keepsFocus(app: pid, onOtherWorkspace: engine.workspaces.workspace(of: id) != engine.workspaces.active) {
            // The app picked a window on another workspace after closing one. The closed window's
            // neighbour keeps focus; if the close is not through yet, removing the window
            // focuses that neighbour.
            let neighbour = engine.strip.focusedWindow
            Log.note("focus", "\(Log.name(id)) took focus on another workspace as its app closed a window; "
                + "focus stays on \(neighbour.map(Log.name) ?? "the shown workspace")")
            if let neighbour, neighbour != closingWindow, windows.element(of: neighbour) != nil { windows.focus(neighbour) }
            return
        }
        if focusKeeper.focused(window: id) {
            Log.note("focus", "\(Log.name(id)) took focus by itself; no-focus rule handed it back")
            return
        }
        displays.windowFocused(id)
    }

    // MARK: Moves

    private func installMoves() {
        // A tiled window the user moves or resizes goes back to its slot once the mouse button
        // is up. One dragged onto a display tinywm does not tile leaves the strip instead, and
        // one dragged back onto a tiled display joins it. tinywm's own writes land where the
        // engine asked, so they are told apart from a drag by the frame they report.
        // The frame is read on the app's queue: every write of tinywm's own reports back here,
        // while the app is busy redrawing. Reports that arrive during one read share it.
        tracker.onFrameChanged = { [unowned self] element, _ in
            guard !screenLocked, let id = windows.knownID(for: element) else { return }
            readChangedFrame(id)
        }
    }

    /// A report that arrives during a read gets one more read after it, so the last frame the
    /// app reported is the one recorded.
    private func readChangedFrame(_ id: String) {
        guard framesBeingRead.insert(id).inserted else { framesChangedAgain.insert(id); return }
        windows.readFrame(id) { [unowned self] now in
            framesBeingRead.remove(id)
            if let now { frameChanged(id, now) }
            if framesChangedAgain.remove(id) != nil, windows.element(of: id) != nil { readChangedFrame(id) }
        }
    }

    /// Sends a window the user moved or resized back to its slot, or takes it off or onto a strip.
    private func frameChanged(_ id: String, _ now: Rect) {
        if windows.isFullScreen(id) {
            // A fullscreen window, such as a game, keeps its own frame. Snapping it back would fight it.
            guard let slot = displays.slot(of: id) else { return }
            Log.note("place", "\(Log.name(id)) went fullscreen; it leaves the strip until it comes back")
            fullScreenSlots[id] = slot
            displays.windowRemoved(id, refocus: false)
            return
        }
        // During a drag the strip must not move under the pointer; snapBack looks again at mouse-up.
        if NSEvent.pressedMouseButtons == 0 { displays.windowSeen(id, width: now.width) }
        if let engine = displays.engine(holding: id) {
            if let asked = engine.frame(of: id), abs(now.x - asked.x) < 2, abs(now.y - asked.y) < 2 {
                if userResized(id, now) { snapBack(id) }
                return
            }
            if displays.engine(owning: now) == nil {
                Log.note("drag", "\(Log.name(id)) moved to \(Log.rect(now)), off every tiled display; it leaves the strip")
                displays.windowRemoved(id)
            } else if engine.frame(of: id) != nil {
                snapBack(id)
            }
        } else if !arrivals.isPending(id), displays.engine(owning: now) != nil {
            recognize(id, log: false) { [unowned self] r, _ in
                guard r.placement == .tiled || r.placement == .floating, displays.engine(holding: id) == nil,
                      !arrivals.isPending(id), displays.engine(owning: now) != nil else { return }
                if let slot = fullScreenSlots.removeValue(forKey: id), displays.restore(id, to: slot) {
                    Log.note("place", "\(Log.name(id)) left fullscreen; it returns to its slot \(slot)")
                    return
                }
                Log.note("drag", "\(Log.name(id)) moved onto a tiled display at \(Log.rect(now)); joins as \(r.placement)")
                displays.windowAdded(id, frame: now, floating: r.placement == .floating, takesFocus: false)
            }
        }
    }

    /// Writes a dragged window's slot frame back as soon as the mouse button is up. Writing
    /// during the drag would fight the pointer.
    private func snapBack(_ id: String) {
        guard snapping.insert(id).inserted else { return }
        func attempt() {
            guard NSEvent.pressedMouseButtons == 0 else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated(attempt) }
                return
            }
            windows.readFrame(id) { [unowned self] now in
                snapping.remove(id)
                if let now { settle(id, at: now) }
            }
        }
        attempt()
    }

    private func settle(_ id: String, at now: Rect) {
        guard !windows.isFullScreen(id) else { return frameChanged(id, now) }
        displays.windowSeen(id, width: now.width)
        guard let engine = displays.engine(holding: id), let asked = engine.frame(of: id),
              displays.engine(owning: now) != nil,
              abs(now.x - asked.x) >= 2 || abs(now.y - asked.y) >= 2 || userResized(id, now) else { return }
        // macOS keeps moving a window whose slot it will not allow, such as one at the very
        // edge of a display. Snapping it back again and again would only flicker.
        let time = ProcessInfo.processInfo.systemUptime
        let recent = (snapTimes[id] ?? []).filter { time - $0 < 3 } + [time]
        snapTimes[id] = recent
        guard recent.count <= 5 else {
            if recent.count == 6 { Log.note("drag", "\(Log.name(id)) keeps moving away from its slot; left where macOS put it") }
            return
        }
        Log.note("drag", "\(Log.name(id)) snaps back from \(Log.rect(now)) to its slot \(Log.rect(asked))")
        windows.setFrame(id, asked) { _ in }
    }

    /// Whether a window's size differs from the one it took on tinywm's last write. A size the
    /// app refused is not the user's doing, and asking for it again would only repeat the refusal.
    private func userResized(_ id: String, _ now: Rect) -> Bool {
        guard let took = windows.landedFrame(of: id) else { return false }
        return abs(now.width - took.width) >= 2 || abs(now.height - took.height) >= 2
    }

    // MARK: Screen lock

    /// True from a lock until the unlock. Windows that go meanwhile keep their places.
    private var screenLocked = false
    private var heldWhileLocked: Set<String> = []
    private var lockRelease: DispatchWorkItem?
    /// Time after the unlock for apps to hand back their windows' new elements.
    private let lockReturnWait = 5.0

    private func installLocks() {
        // The screen wakes at the lock screen, before the user is in, so only an unlock or a
        // return to this session ends the hold on windows that went.
        let locks: [(NotificationCenter, Notification.Name, Bool)] = [
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"), true),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification, true),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked"), false),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidBecomeActiveNotification, false),
        ]
        for (center, name, locked) in locks {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setScreenLocked(locked) }
            }
        }
    }

    private func setScreenLocked(_ locked: Bool) {
        guard locked != screenLocked else { return }
        screenLocked = locked
        lockRelease?.cancel()
        guard !locked else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.releaseLockHold() }
        }
        lockRelease = work
        DispatchQueue.main.asyncAfter(deadline: .now() + lockReturnWait, execute: work)
    }

    /// Removes the windows that went during the lock and did not come back, then writes every
    /// window again, since macOS may have moved some meanwhile.
    private func releaseLockHold() {
        guard !screenLocked else { return }
        let gone = heldWhileLocked
        heldWhileLocked = []
        Log.note("tracker", "lock hold ends; \(gone.isEmpty ? "every window came back" : "gone for good: \(Log.names(Array(gone)))")")
        for id in gone { forget(id) }
        // Moves during the lock went unread, so each recorded frame is read again.
        for id in windows.allIDs { windows.readFrame(id) { _ in } }
        retileAll()
    }

    // MARK: Rules

    /// Releases newly ignored apps, picks up the ones no longer ignored, and floats tiled windows a float rule now covers.
    func applyRules() {
        tracker.applyExclusions()
        for id in windows.allIDs where isTiled(id) {
            recognize(id) { [unowned self] r, _ in
                guard r.placement == .floating, isTiled(id) else { return }
                Log.note("rules", "\(Log.name(id)) matches a float rule; floating it")
                displays.floatWindow(id)
            }
        }
    }

    /// Tiles the windows already sitting on a display that was just switched on.
    func adoptWindows(on id: String) {
        guard displays.engines[id] != nil else { return }
        for wid in windows.allIDs {
            recognize(wid) { [unowned self] r, reading in
                guard r.placement == .tiled || r.placement == .floating, displays.engine(holding: wid) == nil,
                      let engine = displays.engines[id], let frame = reading.frame,
                      displays.engine(owning: frame) === engine else { return }
                displays.windowAdded(wid, frame: frame, floating: r.placement == .floating, takesFocus: false)
            }
        }
    }

    /// Judges a window by the rules from a fresh reading, taken on its app's queue. Answers later
    /// on the main thread, or not at all when the window is gone.
    private func recognize(_ id: String, log: Bool = true,
                           done: @escaping @MainActor (Recognition, AXWindows.Reading) -> Void) {
        windows.read(id) { [unowned self] reading in
            guard let reading else { return }
            done(recognition(id, Self.facts(reading), log: log), reading)
        }
    }

    private static func facts(_ r: AXWindows.Reading) -> WindowFacts {
        WindowFacts(bundleID: r.bundleID, appName: r.appName, title: r.title, isTileable: r.isTileable, isDockable: r.isDockable)
    }

    private func isTiled(_ id: String) -> Bool { displays.engine(holding: id)?.frame(of: id) != nil }

    private func recognition(_ id: String, _ facts: WindowFacts, log: Bool = true) -> Recognition {
        let r = rules().recognize(facts)
        if log { Log.note("rules", "\(Log.name(id)): \(r.placement), tileable=\(facts.isTileable) dockable=\(facts.isDockable) "
            + "allowsFocus=\(r.allowsFocus) bundle=\(facts.bundleID ?? "nil")") }
        return r
    }
}
