import AppKit
import ApplicationServices
import WindowCore

/// An AXUIElement is a CF object. This box lets it cross into the per-app write queues.
public struct AXRef: @unchecked Sendable, Hashable {
    public let element: AXUIElement
    public init(element: AXUIElement) { self.element = element }
    public static func == (a: AXRef, b: AXRef) -> Bool { CFEqual(a.element, b.element) }
    public func hash(into h: inout Hasher) { h.combine(CFHash(element)) }
}

public enum AX {
    public static func attribute<T>(_ e: AXUIElement, _ name: String, as _: T.Type) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    /// Reads several attributes in one request. Each request waits for the app, and some apps,
    /// such as games, answer only once per frame, so separate reads add up to seconds.
    /// An attribute the window lacks comes back as nil.
    public static func attributes(_ e: AXUIElement, _ names: [String]) -> [AnyObject?]? {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(e, names as CFArray, [], &values) == .success,
              let list = values as? [AnyObject], list.count == names.count else { return nil }
        // A missing attribute is reported as an AXValue holding the error.
        return list.map { value in
            CFGetTypeID(value) == AXValueGetTypeID() && AXValueGetType(value as! AXValue) == .axError ? nil : value
        }
    }

    public static func frame(_ e: AXUIElement) -> Rect? {
        guard let values = attributes(e, [kAXPositionAttribute, kAXSizeAttribute]) else { return nil }
        return frame(position: values[0], size: values[1])
    }

    /// Reads the frame and whether the window is fullscreen in one request.
    public static func frameAndFullScreen(_ e: AXUIElement) -> (frame: Rect?, isFullScreen: Bool) {
        guard let v = attributes(e, [kAXPositionAttribute, kAXSizeAttribute, fullScreenAttribute]) else { return (nil, false) }
        let frame = frame(position: v[0], size: v[1])
        return (frame, isFullScreen(flag: v[2], frame: frame))
    }

    static let fullScreenAttribute = "AXFullScreen"

    /// A window macOS shows fullscreen, or one that fills a whole display, menu bar included,
    /// as a game's borderless fullscreen window does. Tiles never cover the menu bar.
    static func isFullScreen(flag: AnyObject?, frame: Rect?) -> Bool {
        if flag as? Bool == true { return true }
        guard let frame else { return false }
        return displayBounds().contains { frame.isApproximately($0, tolerance: 1) }
    }

    /// Every display's bounds, menu bar included, in Accessibility coordinates. Safe off the main thread.
    public static func displayBounds() -> [Rect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map {
            let b = CGDisplayBounds($0)
            return Rect(x: b.minX, y: b.minY, width: b.width, height: b.height)
        }
    }

    /// Whether an ordinary window on screen covers a display, as a fullscreen app or game does.
    public static func fullScreenWindowShows() -> Bool {
        let displays = displayBounds()
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.contains { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = info[kCGWindowBounds as String] as? [String: Double] else { return false }
            let r = Rect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            return displays.contains { r.coversAsFullScreen($0) }
        }
    }

    private static func frame(position: AnyObject?, size: AnyObject?) -> Rect? {
        guard let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return Rect(x: point.x, y: point.y, width: extent.width, height: extent.height)
    }

    public static func setPosition(_ e: AXUIElement, _ r: Rect) {
        var p = CGPoint(x: r.x, y: r.y)
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, v) }
    }

    public static func setSize(_ e: AXUIElement, _ r: Rect) {
        var s = CGSize(width: r.width, height: r.height)
        if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(e, kAXSizeAttribute as CFString, v) }
    }

    /// macOS clamps a resize that would push the window off screen, and a move that would push
    /// the old size off screen. Writing position, size, then position again settles both.
    public static func setFrame(_ e: AXUIElement, _ r: Rect) {
        withPlainUI(e) {
            setPosition(e, r)
            setSize(e, r)
            setPosition(e, r)
        }
    }

    /// Moves the window one point and back, and changes its height one point and back. Some apps,
    /// Chromium-based browsers in particular, relayout their content only when the window moves,
    /// so a resize from outside leaves them drawing at the old size until then.
    public static func nudge(_ e: AXUIElement, _ r: Rect) {
        withPlainUI(e) {
            setPosition(e, Rect(x: r.x + 1, y: r.y, width: r.width, height: r.height))
            setSize(e, Rect(x: r.x + 1, y: r.y, width: r.width, height: max(1, r.height - 1)))
            setSize(e, r)
            setPosition(e, r)
        }
    }

    /// Chromium-based browsers switch on an "enhanced user interface" mode when an accessibility
    /// client is present. In that mode they take a new window size but keep drawing the page at
    /// the old one. Turning it off around the change, and back on after, avoids that.
    static func withPlainUI(_ e: AXUIElement, _ body: () -> Void) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(e, &pid) == .success, pid > 0 else { return body() }
        let app = AXUIElementCreateApplication(pid)
        let key = "AXEnhancedUserInterface" as CFString
        let enhanced = attribute(app, key as String, as: Bool.self) == true
        if enhanced { AXUIElementSetAttributeValue(app, key, kCFBooleanFalse) }
        body()
        if enhanced { AXUIElementSetAttributeValue(app, key, kCFBooleanTrue) }
    }

    /// What decides whether a window is managed: its title, frame, and whether it tiles and docks.
    public struct Inspection: Sendable {
        public var title: String?
        public var frame: Rect?
        /// A fullscreen window never tiles.
        public var isFullScreen: Bool
        public var isTileable: Bool
        /// False for a window that does not tile, since only a tileable window is asked.
        public var isDockable: Bool
    }

    /// Looks at a window in two or three requests to its app.
    public static func inspect(_ e: AXUIElement) -> Inspection {
        guard let v = attributes(e, [kAXRoleAttribute, kAXSubroleAttribute, kAXMinimizedAttribute, kAXPositionAttribute,
                                     kAXSizeAttribute, kAXTitleAttribute, kAXFullScreenButtonAttribute, kAXZoomButtonAttribute,
                                     fullScreenAttribute])
        else { return Inspection(title: nil, frame: nil, isFullScreen: false, isTileable: false, isDockable: false) }
        let frame = frame(position: v[3], size: v[4])
        let fullScreen = isFullScreen(flag: v[8], frame: frame)
        // Tiny windows are helpers, such as the window that hosts a title bar's buttons.
        let tileable = v[0] as? String == kAXWindowRole && v[1] as? String == kAXStandardWindowSubrole
            && v[2] as? Bool != true && frame.map { $0.width >= 80 && $0.height >= 40 } == true && !fullScreen
        return Inspection(title: v[5] as? String, frame: frame, isFullScreen: fullScreen, isTileable: tileable,
                          isDockable: tileable && isDockable(e, fullScreenButton: v[6], zoomButton: v[7]))
    }

    /// A tileable window the app lets us resize, unless its zoom button is disabled.
    /// Fixed-size windows (calculators, some preference panes) disable zoom and float instead.
    /// Windows that draw their own title bar, like Steam's, have no zoom button and still tile.
    public static func isDockable(_ e: AXUIElement) -> Bool {
        guard let v = attributes(e, [kAXFullScreenButtonAttribute, kAXZoomButtonAttribute]) else { return false }
        return isDockable(e, fullScreenButton: v[0], zoomButton: v[1])
    }

    private static func isDockable(_ e: AXUIElement, fullScreenButton: AnyObject?, zoomButton: AnyObject?) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(e, kAXSizeAttribute as CFString, &settable) == .success, settable.boolValue
        else { return false }
        if fullScreenButton != nil { return true }
        guard let zoom = zoomButton else { return true }
        guard CFGetTypeID(zoom) == AXUIElementGetTypeID() else { return false }
        return attribute(zoom as! AXUIElement, kAXEnabledAttribute, as: Bool.self) ?? false
    }
}

/// Carries an Accessibility element between threads. AX calls are safe from any thread.
private struct ElementBox: @unchecked Sendable {
    let element: AXUIElement?
}

/// Implements the engine's WindowSystem with the Accessibility API.
@MainActor
public final class AXWindows: WindowSystem {
    public init() {}

    /// What is known about one window. The element can change while the window stays the same.
    private struct Tracked {
        var ref: AXRef
        let pid: pid_t
        /// The window number, read when the window was first seen.
        let number: CGWindowID?
        /// Where the window was when first seen, so excluding its app can put it back.
        let originalFrame: Rect?
        /// The title as last read: when first seen, then after each title change. Code on the main
        /// thread reads this, since asking the app could wait on it.
        var title: String?
        /// The frame the window took on tinywm's last write. An app may refuse a size.
        var landed: Rect?
        /// The frame as last read: when first seen, after each of tinywm's writes, and after
        /// each move or resize the app reports.
        var frame: Rect?
        /// The size last written, to tell a resize from a move.
        var writtenSize: Size?
        /// Whether the window was fullscreen when its frame was last read.
        var isFullScreen = false
    }
    private var tracked: [String: Tracked] = [:]
    private var ids: [AXRef: String] = [:]

    /// Every window known now.
    public var allIDs: [String] { Array(tracked.keys) }
    /// Where each window was when first seen.
    public var originalFrames: [String: Rect] { tracked.compactMapValues(\.originalFrame) }
    private var queues: [pid_t: DispatchQueue] = [:]
    private var nextID = 0
    /// Called when a window is asked to take focus, so callers can tell this from focus the system gave.
    public var onFocusRequested: [(String) -> Void] = []

    /// Returns the stable ID for a window element, registering it on first sight. `known` holds
    /// the frame and title already read off the main thread; without it they are read here.
    public func id(for element: AXUIElement, pid: pid_t, known: (frame: Rect?, title: String?)? = nil) -> String {
        identify(element, pid: pid, known: known).id
    }

    /// The window's ID, and whether the element is a new one for a window already known. macOS
    /// replaces a window's Accessibility element at times, as while the screen is locked; the
    /// window keeps its window number, so it keeps its ID and its place.
    public func identify(_ element: AXUIElement, pid: pid_t, known: (frame: Rect?, title: String?)? = nil)
        -> (id: String, rebound: Bool) {
        let ref = AXRef(element: element)
        if let id = ids[ref] { return (id, false) }
        let number = WindowNumbers.exactWindowID(of: element)
        if let number, let id = tracked.first(where: { $0.value.number == number && $0.value.pid == pid })?.key {
            if let old = tracked[id]?.ref { ids[old] = nil }
            ids[ref] = id
            tracked[id]?.ref = ref
            return (id, true)
        }
        nextID += 1
        let id = "w\(nextID)"
        ids[ref] = id
        let frame = known.map(\.frame) ?? AX.frame(element)
        tracked[id] = Tracked(ref: ref, pid: pid, number: number, originalFrame: frame,
                              title: known.map(\.title) ?? AX.attribute(element, kAXTitleAttribute, as: String.self),
                              frame: frame)
        return (id, false)
    }

    public func number(of id: String) -> CGWindowID? { tracked[id]?.number }

    /// What tinywm's rules look at, read on the window's app queue.
    public struct Reading: Sendable {
        public var bundleID: String?
        public var appName: String?
        public var title: String?
        public var isTileable: Bool
        public var isDockable: Bool
        public var frame: Rect?
        /// Whether the window is its app's focused window.
        public var isFocused: Bool
    }

    /// Reads a window's app, title, buttons and frame on its app's queue, then hands them over on
    /// the main thread. Nil when the window is gone. A focused window whose app is in front is
    /// recorded as the known focus: macOS reports a new window's focus before tinywm knows the window.
    public func read(_ id: String, completion: @escaping @MainActor (Reading?) -> Void) {
        guard let w = tracked[id], w.pid > 0 else { completion(nil); return }
        let ref = w.ref, pid = w.pid
        let revision = focusRevision
        queue(for: pid).async {
            let app = NSRunningApplication(processIdentifier: pid)
            let focused = AX.attribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute, as: AnyObject.self)
            let seen = AX.inspect(ref.element)
            let reading = Reading(bundleID: app?.bundleIdentifier, appName: app?.localizedName, title: seen.title,
                                  isTileable: seen.isTileable, isDockable: seen.isDockable, frame: seen.frame,
                                  isFocused: focused.map { CFEqual($0, ref.element) } ?? false)
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard self.tracked[id] != nil else { return completion(nil) }
                self.tracked[id]?.title = reading.title
                self.tracked[id]?.isFullScreen = seen.isFullScreen
                if let frame = reading.frame { self.tracked[id]?.frame = frame }
                if reading.isFocused, self.isCurrent(revision, pid: pid) { self.knownFocus = id }
                completion(reading)
            } }
        }
    }

    public func knownID(for element: AXUIElement) -> String? { ids[AXRef(element: element)] }

    public func forget(_ id: String) {
        nudgeGeneration[id] = nil
        nudgeTargets[id] = nil
        heldNudges.remove(id)
        if let ref = tracked.removeValue(forKey: id)?.ref { ids[ref] = nil }
        if knownFocus == id { knownFocus = nil }
    }

    public func element(of id: String) -> AXUIElement? { tracked[id]?.ref.element }
    public func pid(of id: String) -> pid_t? { tracked[id]?.pid }
    public func ids(ofPID pid: pid_t) -> [String] { tracked.filter { $0.value.pid == pid }.map(\.key) }

    public func bundleID(of id: String) -> String? {
        tracked[id].flatMap { NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier }
    }

    /// The title as last read, without asking the app.
    public func cachedTitle(of id: String) -> String? { tracked[id]?.title }

    /// The frame the window took on tinywm's last write.
    public func landedFrame(of id: String) -> Rect? { tracked[id]?.landed }

    /// Re-reads a window's title on its app's queue after the title changed.
    public func refreshTitle(_ id: String) {
        guard let w = tracked[id] else { return }
        let ref = w.ref
        queue(for: w.pid).async {
            let title = AX.attribute(ref.element, kAXTitleAttribute, as: String.self)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.tracked[id]?.title = title } }
        }
    }

    /// Reads a window's frame on its app's queue, records it and whether the window is
    /// fullscreen, then hands the frame over on the main thread.
    public func readFrame(_ id: String, completion: @escaping @MainActor (Rect?) -> Void) {
        guard let w = tracked[id] else { completion(nil); return }
        let ref = w.ref, pid = w.pid
        queue(for: pid).async {
            let (frame, fullScreen) = AX.frameAndFullScreen(ref.element)
            DispatchQueue.main.async { MainActor.assumeIsolated {
                if let frame { self.tracked[id]?.frame = frame }
                self.tracked[id]?.isFullScreen = fullScreen
                completion(frame)
            } }
        }
    }

    /// Whether the window was fullscreen when its frame was last read.
    public func isFullScreen(_ id: String) -> Bool { tracked[id]?.isFullScreen ?? false }

    /// AX calls block until the target app answers, so each app gets its own serial queue.
    /// A hung app then delays only its own windows.
    public func setFrame(_ id: String, _ rect: Rect, completion: @escaping @MainActor (Rect?) -> Void) {
        guard let w = tracked[id] else { completion(nil); return }
        let ref = w.ref
        let queue = queue(for: w.pid)
        let resized = w.writtenSize.map { abs($0.width - rect.width) > 0.5 || abs($0.height - rect.height) > 0.5 } ?? true
        tracked[id]?.writtenSize = Size(width: rect.width, height: rect.height)
        queue.async {
            let began = CACurrentMediaTime()
            AX.setFrame(ref.element, rect)
            let actual = AX.frame(ref.element)
            let took = CACurrentMediaTime() - began
            if took > 0.05 { Log.note("ax", "slow write to \(id): \(Int(took * 1000)) ms") }
            DispatchQueue.main.async { MainActor.assumeIsolated {
                    if let actual {
                        self.tracked[id]?.landed = actual
                        self.tracked[id]?.frame = actual
                    }
                    completion(actual)
                }
            }
        }
        if resized { scheduleNudge(id, rect) } else if nudgeTargets[id] != nil { nudgeTargets[id] = rect }
    }

    private var nudgeGeneration: [String: Int] = [:]
    /// The frame each waiting nudge writes. A later move without a resize updates it, so the
    /// nudge never puts a window back where it was.
    private var nudgeTargets: [String: Rect] = [:]
    /// Wait after a resize before nudging, so the app has applied it; later writes restart the wait.
    public var nudgeDelay = 0.25

    /// Some apps, Chromium-based browsers in particular, skip redrawing after a resize from
    /// outside until their size changes again, so each resize gets a one-point nudge after it.
    private func scheduleNudge(_ id: String, _ rect: Rect) {
        let generation = (nudgeGeneration[id] ?? 0) + 1
        nudgeGeneration[id] = generation
        nudgeTargets[id] = rect
        heldNudges.remove(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + nudgeDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.nudgeGeneration[id] == generation else { return }
                guard self.holdsNudges else { return self.runNudge(id) }
                self.heldNudges.insert(id)
                // A cover that never reports going away must not hold nudges forever.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.nudgeGeneration[id] == generation,
                              self.heldNudges.remove(id) != nil else { return }
                        self.runNudge(id)
                    }
                }
            }
        }
    }

    private func runNudge(_ id: String) {
        guard let rect = nudgeTargets.removeValue(forKey: id),
              let w = tracked[id], let queue = queues[w.pid] else { return }
        let ref = w.ref
        queue.async { AX.nudge(ref.element, rect) }
    }

    /// While something covers the windows, such as the motion pictures, nudges wait: an app that
    /// believes its window is hidden may skip the redraw the nudge is there to trigger.
    public var holdsNudges = false {
        didSet {
            guard !holdsNudges, oldValue else { return }
            let held = heldNudges
            heldNudges = []
            for id in held { runNudge(id) }
        }
    }
    private var heldNudges: Set<String> = []

    public func frameOf(_ id: String) -> Rect? { tracked[id]?.frame }

    /// The raise goes through the app's own queue: an app busy with a resize answers late, and
    /// the main thread must keep drawing the motion meanwhile.
    public func focus(_ id: String) {
        guard let w = tracked[id] else { return }
        let ref = w.ref, pid = w.pid
        knownFocus = id
        focusRevision += 1
        for hook in onFocusRequested { hook(id) }
        // An app started through a wrapper can be listed with process ID -1, and activating
        // that entry does nothing, so such an app is brought to the front through Accessibility.
        let app = NSRunningApplication(processIdentifier: pid)
        let listedWithoutPID = app.map { $0.processIdentifier != pid } ?? true
        queue(for: pid).async {
            AXUIElementPerformAction(ref.element, kAXRaiseAction as CFString)
            // The raise alone leaves some apps' key window where it was.
            AXUIElementSetAttributeValue(ref.element, kAXMainAttribute as CFString, kCFBooleanTrue)
            if listedWithoutPID {
                AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            }
        }
        if !listedWithoutPID { app?.activate() }
    }

    private func queue(for pid: pid_t) -> DispatchQueue {
        if let queue = queues[pid] { return queue }
        let queue = DispatchQueue(label: "ax.\(pid)")
        queues[pid] = queue
        return queue
    }

    public private(set) var knownFocus: String?
    /// Changes with each focus change the system reports and each focus tinywm asks for. A read
    /// that began before a change answers for a focus that is no longer current.
    public private(set) var focusRevision = 0
    /// Counts app activations, so a callback can tell that a newer one came after it began. Kept
    /// apart from the focus revision: a new window's app often activates while that window is read.
    public private(set) var activations = 0

    /// Records a focus change the system reported.
    public func noteFocused(_ id: String?) {
        knownFocus = id
        focusRevision += 1
    }

    /// Records a focus change to a window tinywm does not manage, such as a dialog.
    public func noteFocusMoved() { focusRevision += 1 }

    public func noteActivated() { activations += 1 }

    private func isCurrent(_ revision: Int, pid: pid_t) -> Bool {
        focusRevision == revision && Self.isFrontmost(pid)
    }

    /// An app's focused window as one read found it.
    public struct FocusRead {
        public var window: AXRef?
        public var title: String?
        /// The tinywm ID of the window, when it is managed.
        public var id: String?
        /// False when the app is no longer in front, or the focus changed while the read ran.
        public var isCurrent: Bool
    }

    /// Reads the app's focused window and its title on its queue, managed or not, and hands them
    /// over on the main thread. A current managed one is recorded as the known focus. A read that
    /// is no longer current would otherwise take focus back from the window the user moved to.
    public func readFocused(of pid: pid_t, completion: @escaping @MainActor (FocusRead) -> Void) {
        // An app listed without a real process reports ID -1 or 0.
        guard pid > 0 else { completion(FocusRead(isCurrent: false)); return }
        let app = ElementBox(element: AXUIElementCreateApplication(pid))
        let revision = focusRevision
        queue(for: pid).async {
            let value = app.element.flatMap { AX.attribute($0, kAXFocusedWindowAttribute, as: AnyObject.self) }
            let window = value.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? AXRef(element: $0 as! AXUIElement) : nil }
            let title = window.flatMap { AX.attribute($0.element, kAXTitleAttribute, as: String.self) }
            DispatchQueue.main.async { MainActor.assumeIsolated {
                let read = FocusRead(window: window, title: title, id: window.flatMap { self.knownID(for: $0.element) },
                                     isCurrent: self.isCurrent(revision, pid: pid))
                if read.isCurrent, let id = read.id { self.knownFocus = id }
                completion(read)
            } }
        }
    }

    /// Presses the window's close button on its app's queue. `noButton` runs on the main thread
    /// for a window that draws its own title bar and has none.
    public func pressClose(_ window: AXRef, pid: pid_t, noButton: @escaping @MainActor () -> Void) {
        guard pid > 0 else { return }
        queue(for: pid).async {
            if let close = AX.attribute(window.element, kAXCloseButtonAttribute, as: AXUIElement.self) {
                AXUIElementPerformAction(close, kAXPressAction as CFString)
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated(noButton) }
            }
        }
    }

    public static func isFrontmost(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    /// The focused window as last reported, while its app is in front. It never asks an app,
    /// since this is read on every key press and an app busy redrawing answers late.
    public var focusedWindow: String? {
        guard let id = knownFocus else { return nil }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier > 0 else { return id }
        return tracked[id]?.pid == app.processIdentifier ? id : nil
    }
}
