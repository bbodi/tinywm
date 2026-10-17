import AppKit
import ApplicationServices
import WindowCore

/// What a window looked like when the tracker accepted it, read on its app's queue.
public struct WindowProbe: Sendable {
    public var isDockable: Bool
    public var frame: Rect?
    public var title: String?
}

/// An app's observer and its windows, carried from the app's queue to the main thread.
private struct Subscription: @unchecked Sendable {
    let observer: AXObserver
    let windows: [AXRef]

    /// The tracker, passed to every callback.
    struct Context: @unchecked Sendable { let pointer: UnsafeMutableRawPointer }
}

/// Notifications to add on an app's queue.
private struct PendingNotifications: @unchecked Sendable {
    let observer: AXObserver
    let element: AXUIElement
    let context: UnsafeMutableRawPointer
}

/// What one sweep found, carried from the background queue to the main thread.
private struct SweepResult: @unchecked Sendable {
    let unwatched: [NSRunningApplication]
    /// The real processes of apps listed with process ID -1.
    let resolved: [(pid_t, NSRunningApplication)]
    /// Each app's windows, for the apps that answered. An app whose list could not be read is
    /// left out, so none of its windows count as missing.
    let lists: [(pid_t, [AXRef])]
    /// A fullscreen window was on screen. In its Space, apps list only that Space's windows.
    let fullScreenShows: Bool
}

/// Reports windows as they appear, close and take focus, across every manageable app.
@MainActor
public final class WindowTracker {
    /// A window to tile. Told when a window is accepted, with what it looked like then, and
    /// again whenever an accepted window is reported, such as on each focus change, with no probe.
    public var onAdded: (AXUIElement, pid_t, WindowProbe?) -> Void = { _, _, _ in }
    /// A window left. `temporary` windows (minimized, or their app hidden) keep their slot.
    public var onRemoved: (AXUIElement, _ temporary: Bool) -> Void = { _, _ in }
    public var onAppQuit: (pid_t) -> Void = { _ in }
    /// An app hid. Its windows leave temporarily.
    public var onAppHidden: (pid_t) -> Void = { _ in }
    /// An app became excluded, so every window it has should be released.
    public var onAppExcluded: (pid_t) -> Void = { _ in }
    /// A window that floated because it could not tile now can.
    public var onBecameDockable: (AXUIElement) -> Void = { _ in }
    public var onFocused: (AXUIElement, pid_t) -> Void = { _, _ in }
    /// When set, a minimized window is reported here instead of as a temporary removal.
    public var onMinimized: ((AXUIElement) -> Void)?
    public var onDeminiaturized: (AXUIElement) -> Void = { _ in }
    /// Extra subscribers told when an app's focused window changes, after it was admitted.
    public var focusListeners: [(AXUIElement) -> Void] = []
    /// A managed window moved or resized (`resized`), whoever caused it. Callers filter their own writes.
    public var onFrameChanged: (AXUIElement, _ resized: Bool) -> Void = { _, _ in }
    /// Subscribers told when a managed window's title changes.
    public var titleListeners: [(AXUIElement) -> Void] = []
    /// Excludes an app, judged by its bundle ID and name. Read afresh on every check.
    public var isIgnored: (_ bundleID: String?, _ name: String?) -> Bool = { _, _ in false }

    public init() {}

    private var observers: [pid_t: AXObserver] = [:]
    private var tokens: [NSObjectProtocol] = []
    private var registered: Set<AXRef> = []
    public func start() {
        for app in NSWorkspace.shared.runningApplications { watch(app) }
        sweeper = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
        let nc = NSWorkspace.shared.notificationCenter
        tokens.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self.watch(app) }
        })
        // A bare executable started from a terminal is never announced as launched, only as
        // activated. Without this its windows wait for the next sweep.
        tokens.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self.watch(app) }
        })
        tokens.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated {
                self.observers[pid] = nil
                self.onAppQuit(pid)
            }
        })
    }

    /// Whether the app's windows may be managed: an app with windows, not us, not excluded.
    /// Accessory apps count too; some, like Steam's helper, own an app's main window.
    /// macOS's own prompts: permission requests, password and Touch ID sheets, and the warning
    /// before opening a downloaded app. Each must stay where macOS shows it. Tiled or parked on a
    /// workspace, a prompt can end up out of sight while it waits for an answer.
    public static let systemPrompts: Set<String> = [
        "com.apple.accessibility.universalAccessAuthWarn",
        "com.apple.SecurityAgent",
        "com.apple.LocalAuthentication.UIAgent",
        "com.apple.UserNotificationCenter",
        "com.apple.coreservices.uiagent",
    ]

    public func manageable(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy != .prohibited, app.processIdentifier != getpid(), !app.isTerminated else { return false }
        if let bundleID = app.bundleIdentifier, Self.systemPrompts.contains(bundleID) { return false }
        if isIgnored(app.bundleIdentifier, app.localizedName) { return false }
        return true
    }

    /// Applies a changed exclusion list: windows of newly excluded apps are released and apps that
    /// are no longer excluded are picked up.
    public func applyExclusions() {
        forgetExcludedApps()
        for app in NSWorkspace.shared.runningApplications { watch(app) }
    }

    private func forgetExcludedApps() {
        for pid in Array(observers.keys) {
            guard let app = NSRunningApplication(processIdentifier: pid), !manageable(app) else { continue }
            if let observer = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
            // Its windows must be subscribed afresh if the app is managed again.
            registered = registered.filter { ref in
                var owner: pid_t = 0
                AXUIElementGetPid(ref.element, &owner)
                return owner != pid
            }
            onAppExcluded(pid)
        }
    }

    /// Re-reads an app's windows. New ones are admitted; known ones are re-reported, which lets
    /// the engine restore a window that was hidden.
    public func rescan(pid: pid_t) {
        guard observers[pid] != nil else { return }
        let axApp = AXUIElementCreateApplication(pid)
        for w in AX.attribute(axApp, kAXWindowsAttribute, as: [AXUIElement].self) ?? [] { admit(w, pid: pid) }
    }

    /// Brings each app's window list in line with what is managed. Some apps hide a window on
    /// close instead of destroying it, like Steam, so no destroyed notification ever comes; a
    /// window missing from its app's list twice in a row is dropped. One that appears, as when
    /// Steam shows that window again, is admitted.
    ///
    /// The questions to each app run on a background queue, since every one waits for the app
    /// to answer; only the bookkeeping runs on the main thread.
    private func sweep() {
        guard !paused, !sweeping else { return }
        sweeping = true
        let pids = Array(observers.keys)
        sweepQueue.async { [weak self] in
            // An app started through a wrapper script, such as a bundle whose executable is a shell
            // script, is announced before its real process exists, with process ID -1. Some never
            // get a real ID in that list, so their process is also looked up by its executable.
            let watched = Set(pids)
            let unwatched = NSWorkspace.shared.runningApplications.filter { !watched.contains($0.processIdentifier) }
            let resolved = Self.realProcesses(of: unwatched.filter { $0.processIdentifier <= 0 }, excluding: watched)
            var lists: [(pid_t, [AXRef])] = []
            for pid in pids {
                // A hidden app lists no windows, so they leave the strip and return to their
                // slots when it is shown again.
                guard NSRunningApplication(processIdentifier: pid)?.isHidden == false else {
                    lists.append((pid, []))
                    continue
                }
                let axApp = AXUIElementCreateApplication(pid)
                guard let listed = AX.attribute(axApp, kAXWindowsAttribute, as: [AXUIElement].self) else { continue }
                lists.append((pid, listed.map { AXRef(element: $0) }))
            }
            let result = SweepResult(unwatched: unwatched, resolved: resolved, lists: lists,
                                     fullScreenShows: AX.fullScreenWindowShows())
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishSweep(result) } }
        }
    }

    /// The running processes behind apps listed with process ID -1: those whose executable is
    /// the app's, and which macOS maps back to the same app. macOS hands back the listed app,
    /// which still reports -1, so each comes with the real process ID.
    private nonisolated static func realProcesses(of apps: [NSRunningApplication], excluding watched: Set<pid_t>) -> [(pid_t, NSRunningApplication)] {
        // proc_pidpath reports the executable with symlinks resolved, so the keys are resolved too.
        let wanted = Dictionary(apps.compactMap { app in
            app.executableURL.map { ($0.resolvingSymlinksInPath().path, app.bundleIdentifier) }
        }, uniquingKeysWith: { a, _ in a })
        guard !wanted.isEmpty else { return [] }
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var found: [(pid_t, NSRunningApplication)] = []
        var path = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(max(0, count)) where pid > 0 && !watched.contains(pid) {
            let length = Int(proc_pidpath(pid, &path, UInt32(path.count)))
            guard length > 0,
                  let bundleID = wanted[String(decoding: path.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)],
                  let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier == bundleID else { continue }
            found.append((pid, app))
        }
        return found
    }

    private func finishSweep(_ result: SweepResult) {
        sweeping = false
        for app in result.unwatched where observers[app.processIdentifier] == nil { watch(app) }
        for (pid, app) in result.resolved where observers[pid] == nil { watch(app, pid: pid, resolved: true) }
        var seen: Set<AXRef> = []
        for (pid, listed) in result.lists where observers[pid] != nil {
            for ref in listed {
                seen.insert(ref)
                if !registered.contains(ref) { admit(ref.element, pid: pid) }
            }
        }
        // Windows on other Spaces are left out of the lists, not gone.
        guard !result.fullScreenShows else { missing = []; return }
        let answered = Set(result.lists.map(\.0))
        var listed: Set<CGWindowID>?
        for ref in registered where !seen.contains(ref) {
            var pid: pid_t = 0
            AXUIElementGetPid(ref.element, &pid)
            guard observers[pid] != nil, answered.contains(pid) else { continue }
            if missing.insert(ref).inserted { continue }
            registered.remove(ref)
            // A window the system still lists was only hidden, and may come back.
            if listed == nil {
                let info = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
                listed = Set(info.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
            }
            let temporary = WindowNumbers.windowID(of: ref.element, pid: pid).map { listed!.contains($0) } ?? false
            onRemoved(ref.element, temporary)
        }
        missing = missing.filter { !seen.contains($0) && registered.contains($0) }
    }
    private var sweeper: Timer?
    private let sweepQueue = DispatchQueue(label: "tinywm.sweep", qos: .utility)
    private var sweeping = false
    /// Skips the sweep while windows move. Its calls block until each app answers, and apps
    /// answer late while they redraw, which stalls the motion.
    public var paused = false
    private var missing: Set<AXRef> = []

    /// `pid` overrides the app's own process ID, for an app listed with -1.
    ///
    /// Subscribing asks the app and waits for its answer, which an app that hangs never gives. So
    /// it runs on the app's own queue, and one such app holds up only itself.
    private func watch(_ app: NSRunningApplication, pid: pid_t? = nil, resolved: Bool = false) {
        let pid = pid ?? app.processIdentifier
        guard pid > 0, manageable(app), observers[pid] == nil, subscribing.insert(pid).inserted else { return }
        let name = app.localizedName ?? "?"
        let context = Subscription.Context(pointer: Unmanaged.passUnretained(self).toOpaque())
        queue(for: pid).async { [weak self] in
            let start = ProcessInfo.processInfo.systemUptime
            var observer: AXObserver?
            var subscription: Subscription?
            if AXObserverCreate(pid, axCallback, &observer) == .success, let observer {
                let axApp = AXUIElementCreateApplication(pid)
                // The other app notifications are added once its windows are looked at.
                AXObserverAddNotification(observer, axApp, kAXWindowCreatedNotification as CFString, context.pointer)
                let windows = AX.attribute(axApp, kAXWindowsAttribute, as: [AXUIElement].self) ?? []
                subscription = Subscription(observer: observer, windows: windows.map(AXRef.init(element:)))
            }
            let took = ProcessInfo.processInfo.systemUptime - start
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self?.subscribed(subscription, pid: pid, name: name, took: took, resolved: resolved)
            } }
        }
    }

    private func subscribed(_ subscription: Subscription?, pid: pid_t, name: String, took: Double, resolved: Bool) {
        subscribing.remove(pid)
        if took > 1 { Log.note("tracker", "\(name) (process \(pid)) took \(String(format: "%.1f", took)) s to answer") }
        guard let subscription, observers[pid] == nil,
              NSRunningApplication(processIdentifier: pid)?.isTerminated == false else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(subscription.observer), .defaultMode)
        observers[pid] = subscription.observer
        if resolved { Log.note("tracker", "\(name) runs as process \(pid); watching it") }
        for ref in subscription.windows { admit(ref.element, pid: pid) }
        subscribe([kAXFocusedWindowChangedNotification, kAXApplicationHiddenNotification, kAXApplicationShownNotification],
                  on: AXUIElementCreateApplication(pid), observer: subscription.observer, pid: pid)
    }

    /// Adds notifications on the app's queue, after the requests already waiting there. Each one
    /// waits for the app, so a slow app holds up neither the main thread nor a window being placed.
    private func subscribe(_ names: [String], on element: AXUIElement, observer: AXObserver, pid: pid_t) {
        let pending = PendingNotifications(observer: observer, element: element,
                                           context: Unmanaged.passUnretained(self).toOpaque())
        queue(for: pid).async {
            for name in names {
                AXObserverAddNotification(pending.observer, pending.element, name as CFString, pending.context)
            }
        }
    }

    /// Apps being subscribed to on their own queue.
    private var subscribing: Set<pid_t> = []

    fileprivate func handle(_ element: AXUIElement, _ notification: String) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard observers[pid] != nil else { return }
        switch notification {
        case kAXWindowCreatedNotification:
            admit(element, pid: pid)
        case kAXFocusedWindowChangedNotification:
            admit(element, pid: pid)
            onFocused(element, pid)
            for l in focusListeners { l(element) }
        case kAXWindowMiniaturizedNotification:
            if let onMinimized { onMinimized(element) } else { onRemoved(element, true) }
        case kAXWindowDeminiaturizedNotification:
            onDeminiaturized(element)
        case kAXUIElementDestroyedNotification:
            registered.remove(AXRef(element: element))
            onRemoved(element, false)
        case kAXWindowMovedNotification:
            onFrameChanged(element, false)
        case kAXWindowResizedNotification:
            onFrameChanged(element, true)
        case kAXTitleChangedNotification:
            for l in titleListeners { l(element) }
        case kAXApplicationHiddenNotification:
            onAppHidden(pid)
        case kAXApplicationShownNotification:
            // Windows reappear a moment after the app reports itself shown.
            for delay in [0.15, 0.6] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated { self.rescan(pid: pid) }
                }
            }
        default:
            break
        }
    }

    /// Accepts a standard window and subscribes to the events that end its life in the layout.
    ///
    /// A new window is looked at on its app's queue: each question waits for the app, and an app
    /// that is still starting answers slowly. A window already accepted is only reported again.
    private func admit(_ window: AXUIElement, pid: pid_t) {
        guard observers[pid] != nil else { return }
        let ref = AXRef(element: window)
        if registered.contains(ref) { return onAdded(window, pid, nil) }
        guard probing.insert(ref).inserted else { return }
        queue(for: pid).async { [weak self] in
            let seen = AX.inspect(ref.element)
            let probe = seen.isTileable ? WindowProbe(isDockable: seen.isDockable, frame: seen.frame, title: seen.title) : nil
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.accept(ref, pid: pid, probe) } }
        }
    }

    private func accept(_ ref: AXRef, pid: pid_t, _ probe: WindowProbe?) {
        probing.remove(ref)
        guard let probe, let observer = observers[pid], registered.insert(ref).inserted else { return }
        subscribe([kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification,
                   kAXWindowDeminiaturizedNotification, kAXWindowMovedNotification,
                   kAXWindowResizedNotification, kAXTitleChangedNotification],
                  on: ref.element, observer: observer, pid: pid)
        onAdded(ref.element, pid, probe)
        if !probe.isDockable { recheckDockable(ref, pid: pid, attempts: [1, 3]) }
    }

    /// Windows being looked at on their app's queue, so a second report does not start another look.
    private var probing: Set<AXRef> = []
    /// True while windows are still being looked at, before they are reported.
    public var isProbing: Bool { !probing.isEmpty || !subscribing.isEmpty }
    private var queues: [pid_t: DispatchQueue] = [:]

    private func queue(for pid: pid_t) -> DispatchQueue {
        if let queue = queues[pid] { return queue }
        let queue = DispatchQueue(label: "tinywm.track.\(pid)", qos: .userInitiated)
        queues[pid] = queue
        return queue
    }

    /// Windows often gain their zoom button after they open, so a window that could not dock is
    /// looked at again before it is left floating for good.
    private func recheckDockable(_ ref: AXRef, pid: pid_t, attempts: [Double]) {
        guard let delay = attempts.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let box = ref
            MainActor.assumeIsolated {
                guard self.observers[pid] != nil, self.registered.contains(box) else { return }
                if AX.isDockable(box.element) {
                    self.onBecameDockable(box.element)
                } else {
                    self.recheckDockable(box, pid: pid, attempts: Array(attempts.dropFirst()))
                }
            }
        }
    }
}

private func axCallback(_: AXObserver, element: AXUIElement, notification: CFString, context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let tracker = Unmanaged<WindowTracker>.fromOpaque(context).takeUnretainedValue()
    let name = notification as String
    let ref = AXRef(element: element)
    MainActor.assumeIsolated { tracker.handle(ref.element, name) }
}
