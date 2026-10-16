import AppKit
import ApplicationServices
import Foundation
import StripEngine
import StripModel
import WindowCore
import WindowKit

/// Saves the layout to disk and brings it back when tinywm starts.
///
/// While a restore is pending, windows found at startup are held instead of placed. Once the first
/// scan has settled they are matched against the saved layout in one pass, so the order does not
/// depend on which window the system listed first.
@MainActor
final class LayoutPersistence {
    private let windows: AXWindows
    private let displays: StripDisplays
    private let url: URL
    /// Whether saving and restoring are on, read afresh each time so the config can switch them.
    var enabled: () -> Bool = { true }
    /// True while windows found at startup are still being read. The restore waits for them,
    /// since an app can take a while to answer.
    var reading: () -> Bool = { false }
    /// The longest the restore waits for those reads.
    var readLimit = 10.0

    private var held: [StripDisplays.Pending] = []
    private var holding = false
    /// Saving waits for the restore, or the empty startup layout would overwrite the saved one.
    private var ready = false
    private var pendingSave: DispatchWorkItem?
    /// Merging, encoding and writing run here, in order, so the main thread never waits on the disk.
    private let io = DispatchQueue(label: "tinywm.layout", qos: .utility)

    /// Time to let the initial window scan and the windows it triggers arrive before matching.
    var settle = 0.6
    var debounce = 1.0

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/tinywm/layout.json")
    }

    init(windows: AXWindows, displays: StripDisplays, url: URL = LayoutPersistence.defaultURL) {
        self.windows = windows
        self.displays = displays
        self.url = url
    }

    // MARK: Restore

    /// Call before the first window scan. Windows are held until `settle` has passed.
    func beginRestore() {
        guard enabled(), load() != nil else { ready = true; return }
        holding = true
        // Counted from the first check, so the settle time does not count against the read limit.
        var start: Double?
        func check() {
            if start == nil { start = ProcessInfo.processInfo.systemUptime }
            guard let start else { return }
            let waited = ProcessInfo.processInfo.systemUptime - start
            if reading(), waited < readLimit {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated(check) }
                return
            }
            if waited >= readLimit { Log.note("restore", "windows still being read after \(readLimit) s; restoring anyway") }
            finishRestore()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { MainActor.assumeIsolated(check) }
    }

    /// Takes a window that is about to be placed. Returns true when it is held for the restore.
    func hold(_ id: String, frame: Rect?, recognition: Recognition) -> Bool {
        guard holding, let d = descriptor(of: id) else { return false }
        held.append(.init(live: LiveWindow(id: id, descriptor: d), frame: frame,
                          floating: recognition.placement != .tiled, takesFocus: recognition.allowsFocus))
        return true
    }

    /// The restore keeps the focused window's workspace, so the focus is read first. No focus
    /// change is reported for a window that was already focused when tinywm started.
    private func finishRestore() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return matchHeld() }
        // A managed window read here is recorded as the known focus.
        windows.readFocused(of: front.processIdentifier) { [weak self] _ in self?.matchHeld() }
    }

    private func matchHeld() {
        holding = false
        // A window that closed while held is no longer known.
        let pending = held.filter { windows.element(of: $0.live.id) != nil }
        Log.note("restore", "matching \(pending.count) windows against the saved layout")
        held = []
        if enabled(), let saved = load() { displays.restore(saved, pending: pending) } else {
            for p in pending { displays.windowAdded(p.live.id, frame: p.frame, floating: p.floating, takesFocus: p.takesFocus) }
        }
        ready = true
        scheduleSave()
    }

    private func load() -> SavedLayout? {
        let data: Data
        do { data = try Data(contentsOf: url) } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            Log.note("restore", "could not read \(url.path): \(error)")
            return nil
        }
        guard let saved = SavedLayout.decoded(from: data) else {
            Log.note("restore", "\(url.path) does not decode; starting without the saved layout")
            return nil
        }
        return saved
    }

    // MARK: Save

    func changed() {
        guard ready else { return }
        scheduleSave()
    }

    private func scheduleSave() {
        guard ready else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    /// Saves now. Merges into the file so displays that are not attached keep their layout.
    /// `wait` blocks until the file is written, for a save just before tinywm quits.
    func saveNow(wait: Bool = false) {
        pendingSave?.cancel()
        guard ready, enabled() else { return }
        var current: [String: SavedWorkspaces] = [:]
        for (id, engine) in displays.engines {
            current[id] = SavedWorkspaces(engine.workspaces, describe: { [self] in descriptor(of: $0) })
        }
        let url = url, snapshot = current
        let write: @Sendable () -> Void = { Self.write(snapshot, to: url) }
        if wait { io.sync(execute: write) } else { io.async(execute: write) }
    }

    private nonisolated static func write(_ current: [String: SavedWorkspaces], to url: URL) {
        var saved: SavedLayout?
        do {
            saved = SavedLayout.decoded(from: try Data(contentsOf: url))
            if saved == nil { Log.note("restore", "\(url.path) does not decode; saving over it loses its other displays") }
        } catch CocoaError.fileReadNoSuchFile {
        } catch {
            Log.note("restore", "could not read \(url.path) before saving, so its other displays are lost: \(error)")
        }
        do {
            let data = try (saved ?? SavedLayout()).merged(with: current).encoded()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.note("restore", "could not save the layout to \(url.path): \(error)")
        }
    }

    /// Built from what is already known, since asking each app would hold up the main thread.
    private func descriptor(of id: String) -> WindowDescriptor? {
        guard windows.element(of: id) != nil, let pid = windows.pid(of: id) else { return nil }
        return WindowDescriptor(windowNumber: windows.number(of: id), bundleID: windows.bundleID(of: id),
                                title: windows.cachedTitle(of: id) ?? "", pid: pid)
    }
}
