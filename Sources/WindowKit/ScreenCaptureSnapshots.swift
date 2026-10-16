import AppKit
import CoreImage
import CoreMedia
import ScreenCaptureKit
import WindowCore

/// A captured frame. The pixel buffer is not written again while we hold it, so passing it
/// between queues is safe.
struct FrameBox: @unchecked Sendable {
    let pixels: CVPixelBuffer
    /// Where the window's content sits in the buffer, in buffer pixels. A capture sized for the
    /// window's old or new size fits the content inside and leaves the rest of the buffer empty.
    let content: CGRect
    /// Buffer pixels per point of the window, so `content.size / scale` is the window's size.
    let scale: CGFloat
}

/// A window picture as a GPU surface, handed straight to a layer's contents with no copy.
public struct WindowSurface: @unchecked Sendable {
    public let surface: IOSurface
    /// Size of the whole buffer in pixels.
    public let pixelSize: CGSize
    /// The part of the buffer that holds the window, in pixels from the top-left corner.
    public let content: CGRect
    /// Buffer pixels per point.
    public let scale: CGFloat
    /// The window's size in points when the frame was taken.
    public var pointSize: CGSize { CGSize(width: content.width / scale, height: content.height / scale) }
}

/// Reads ScreenCaptureKit sample buffers. It keeps the pixel buffer as is: converting each
/// picture to a CGImage copied it from the GPU and back.
enum FrameSink {
    /// Buffers without the `.complete` status carry no pixels (idle, blank or suspended).
    static func frame(from buffer: CMSampleBuffer, fallbackScale: CGFloat) -> FrameBox? {
        guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { return nil }
        let whole = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]])?.first
        if let raw = info?[.status] as? Int, SCFrameStatus(rawValue: raw) != .complete { return nil }
        var content = whole
        if let d = info?[.contentRect] as? NSDictionary, let r = CGRect(dictionaryRepresentation: d as CFDictionary),
           r.width >= 1, r.height >= 1 {
            content = r.integral.intersection(whole)
        }
        let scale = (info?[.contentScale] as? CGFloat).flatMap { $0 > 0 ? $0 : nil } ?? fallbackScale
        return FrameBox(pixels: pixels, content: content, scale: scale)
    }
}

/// An Accessibility element handed to a background task. AX calls are safe from any thread.
private struct AXBox: @unchecked Sendable {
    let element: AXUIElement
}

/// Window pictures from ScreenCaptureKit, taken as single snapshots.
///
/// A snapshot is taken only when a picture is out of date, and only a few run at once. A live
/// stream per window would load the GPU and WindowServer on every frame and make motion stutter.
@MainActor
public final class ScreenCaptureSnapshots: SnapshotProvider {
    private let windows: AXWindows
    private var frames: [String: FrameBox] = [:]
    /// CGImages made on request from the latest frame, for callers that need one.
    private var images: [String: CGImage] = [:]
    private let context = CIContext()
    private var wallpaperImage: CGImage?
    private var wallpaperFetchedAt = Date.distantPast
    private var wallpaperBusy = false
    private var askedForAccess = false
    private var access: (granted: Bool, checkedAt: CFTimeInterval)?
    public var onUpdate: [(String) -> Void] = []
    /// While true, nothing is captured and no picture is kept, and no call asks for the
    /// Screen Recording permission. Covers stand in for the pictures then.
    public var inert = false {
        didSet {
            guard inert, !oldValue else { return }
            endLiveWork?.cancel()
            track([])
            queued = []
            frames = [:]
            images = [:]
            takenAt = [:]
            requestedAt = [:]
            wallpaperImage = nil
            wallpaperFetchedAt = .distantPast
        }
    }

    /// Windows whose pictures are kept fresh, and how old a picture may get, in seconds.
    private var live: Set<String> = []
    private var interval = 15.0
    private var pump: Timer?
    private var endLiveWork: DispatchWorkItem?
    /// Captures under way. Each one competes with drawing the screen, so few run at once.
    private var inFlight: Set<String> = []
    public var maxInFlight = 4
    /// Windows asked for out of turn, oldest first.
    private var queued: [String] = []
    /// When each window's picture was taken, and when its last capture was asked for.
    private var takenAt: [String: CFTimeInterval] = [:]
    private var requestedAt: [String: CFTimeInterval] = [:]
    /// ScreenCaptureKit's handle on each window and its window number, found once.
    private var targets: [String: SCWindow] = [:]
    private var numbers: [String: CGWindowID] = [:]
    public static let wallpaperID = "wallpaper"

    public init(windows: AXWindows) {
        self.windows = windows
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.wallpaperFetchedAt = .distantPast } }
    }

    /// Checks Screen Recording permission, prompting once per launch. False when denied.
    /// The answer is reused for a few seconds, since every capture asks.
    private func hasAccess() -> Bool {
        if inert { return false }
        let now = CACurrentMediaTime()
        if let access, access.granted || now - access.checkedAt < 5 { return access.granted }
        let granted = CGPreflightScreenCaptureAccess()
        access = (granted, now)
        if !granted, !askedForAccess { askedForAccess = true; _ = CGRequestScreenCaptureAccess() }
        return granted
    }

    public func snapshot(of windowID: String) -> CGImage? {
        if inert { return nil }
        if let image = images[windowID] { return image }
        guard let frame = frames[windowID] else { return nil }
        let ci = CIImage(cvPixelBuffer: frame.pixels)
        // Core Image counts from the bottom; the content rect counts from the top.
        let c = frame.content
        let image = context.createCGImage(ci, from: CGRect(x: c.minX, y: ci.extent.height - c.maxY, width: c.width, height: c.height))
        images[windowID] = image
        return image
    }

    /// The latest picture of a window as a GPU surface, for layer contents with no copy.
    public func surface(of windowID: String) -> WindowSurface? {
        if inert { return nil }
        guard let frame = frames[windowID], let surface = CVPixelBufferGetIOSurface(frame.pixels)?.takeUnretainedValue()
        else { return nil }
        return WindowSurface(surface: surface as IOSurface,
                             pixelSize: CGSize(width: CVPixelBufferGetWidth(frame.pixels), height: CVPixelBufferGetHeight(frame.pixels)),
                             content: frame.content, scale: frame.scale)
    }

    /// Pictures windows again at their new size. An app can take a moment to relayout after a
    /// resize, so each window is pictured once more shortly after.
    public func resize(_ ids: Set<String>) {
        refresh(ids)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated { self?.refresh(ids) }
        }
    }

    public func wallpaper() -> CGImage? {
        if inert { return nil }
        if Date().timeIntervalSince(wallpaperFetchedAt) > 60 { refreshWallpaper() }
        return wallpaperImage
    }

    /// Keeps these windows' pictures fresh at the current rate. An empty set stops it.
    public func track(_ windowIDs: Set<String>) {
        live = windowIDs
        schedulePump()
    }

    public func setRate(_ fps: Double) {
        guard fps > 0, 1 / fps != interval else { return }
        interval = 1 / fps
        schedulePump()
    }

    /// Takes one picture of each window soon, ahead of its turn.
    public func refresh(_ ids: Set<String>) {
        guard !inert else { return }
        for id in ids where !queued.contains(id) { queued.append(id) }
        runPump()
    }

    /// Takes one picture of each window that has none yet, so its first motion is not blank.
    public func prime(_ ids: Set<String>) {
        refresh(ids.filter { frames[$0] == nil })
    }

    /// Drops a closed window's last picture.
    public func forget(_ id: String) {
        live.remove(id)
        queued.removeAll { $0 == id }
        images[id] = nil
        frames[id] = nil
        takenAt[id] = nil
        requestedAt[id] = nil
        targets[id] = nil
        numbers[id] = nil
    }

    // MARK: Pictures around motion

    /// Keeps the pictures of `ids` fresh at `rate` per second, for a motion or the overview.
    public func beginLive(_ ids: Set<String>, rate: Double) {
        endLiveWork?.cancel()
        endLiveWork = nil
        setRate(rate)
        // A window changes while it rests, so a picture older than this is retaken first.
        let now = CACurrentMediaTime()
        let stale = ids.filter { now - (takenAt[$0] ?? 0) > 0.5 }
        track(ids)
        refresh(stale)
        Log.note("capture", "live for \(ids.count) windows at \(Int(rate)) per second; \(stale.count) stale, "
            + "\(inFlight.count) capturing")
    }

    /// Stops refreshing after `delay`, unless a new motion begins first.
    public func endLive(after delay: TimeInterval) {
        endLiveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.track([]) } }
        endLiveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func schedulePump() {
        pump?.invalidate()
        pump = nil
        guard !live.isEmpty else { return }
        let timer = Timer(timeInterval: max(1 / 30, interval / 2), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runPump() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pump = timer
        runPump()
    }

    /// Starts captures until the limit is reached: windows asked for first, then the live
    /// windows whose pictures are oldest.
    private func runPump() {
        guard !inert, hasAccess() else { return }
        let now = CACurrentMediaTime()
        while inFlight.count < maxInFlight {
            if let i = queued.firstIndex(where: { !inFlight.contains($0) }) {
                capture(queued.remove(at: i), now: now)
                continue
            }
            let due = live.filter { !inFlight.contains($0) && now - (requestedAt[$0] ?? 0) >= interval }
            guard let id = due.min(by: { (takenAt[$0] ?? 0) < (takenAt[$1] ?? 0) }) else { break }
            capture(id, now: now)
        }
    }

    /// One snapshot of one window. Its size is read off the main thread: the app answers
    /// late while it redraws, and the main thread must keep drawing the motion meanwhile.
    private func capture(_ id: String, now: CFTimeInterval) {
        guard let element = windows.element(of: id), let pid = windows.pid(of: id) else { return }
        inFlight.insert(id)
        requestedAt[id] = now
        let box = AXBox(element: element)
        Task {
            defer {
                inFlight.remove(id)
                runPump()
            }
            guard let window = await target(of: id, box, pid), let frame = await Self.frame(of: box),
                  frame.width > 0, frame.height > 0 else { return }
            let scale = backingScale(for: frame)
            let size = CGSize(width: (frame.width * scale).rounded(), height: (frame.height * scale).rounded())
            let filter = SCContentFilter(desktopIndependentWindow: window)
            guard let buffer = try? await SCScreenshotManager.captureSampleBuffer(
                      contentFilter: filter, configuration: configuration(size: size)),
                  let box = FrameSink.frame(from: buffer, fallbackScale: scale) else { return }
            store(box, for: id)
        }
    }

    private nonisolated static func frame(of box: AXBox) async -> Rect? { AX.frame(box.element) }

    private nonisolated static func number(of box: AXBox, pid: pid_t) async -> CGWindowID? {
        WindowNumbers.windowID(of: box.element, pid: pid)
    }

    /// ScreenCaptureKit's handle on a window. Looking one up lists every window, so the
    /// handles of all known windows are kept from that list.
    private func target(of id: String, _ box: AXBox, _ pid: pid_t) async -> SCWindow? {
        if let known = targets[id] { return known }
        if numbers[id] == nil { numbers[id] = await Self.number(of: box, pid: pid) }
        guard numbers[id] != nil,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        else { return nil }
        let byNumber = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        for (known, number) in numbers where targets[known] == nil { targets[known] = byNumber[number] }
        return targets[id]
    }

    private func backingScale(for frame: Rect) -> CGFloat {
        let h = NSScreen.screens.first?.frame.height ?? 0
        let appKit = CGRect(x: frame.x, y: h - frame.y - frame.height, width: frame.width, height: frame.height)
        return NSScreen.screens.first { $0.frame.intersects(appKit) }?.backingScaleFactor ?? 2
    }

    private func configuration(size: CGSize) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = Int(size.width); c.height = Int(size.height)
        c.showsCursor = false
        c.pixelFormat = kCVPixelFormatType_32BGRA
        // Without the drop shadow a picture is exactly the window's size.
        c.ignoreShadowsSingleWindow = true
        c.scalesToFit = true
        return c
    }

    private func store(_ box: FrameBox, for id: String) {
        // A capture that was under way when covers took over, or for a window now gone, is dropped.
        if inert || windows.element(of: id) == nil { return }
        frames[id] = box
        images[id] = nil
        takenAt[id] = CACurrentMediaTime()
        for callback in onUpdate { callback(id) }
    }

    // MARK: Wallpaper

    /// The wallpaper is a Dock-owned window at the desktop level; we capture only that window
    /// so no app windows or icons appear in it.
    private func refreshWallpaper() {
        guard !wallpaperBusy, hasAccess() else { return }
        wallpaperBusy = true
        wallpaperFetchedAt = Date()
        Task {
            defer { wallpaperBusy = false }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
            else { return }
            let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
            let candidates = content.windows.filter {
                $0.windowLayer <= desktopLevel && $0.frame.intersects(display.frame)
            }
            guard !candidates.isEmpty else { return }
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let config = SCStreamConfiguration()
            config.width = Int(CGFloat(display.width) * scale); config.height = Int(CGFloat(display.height) * scale)
            config.showsCursor = false
            let filter = SCContentFilter(display: display, including: candidates)
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            else { return }
            wallpaperImage = image
            for callback in onUpdate { callback(Self.wallpaperID) }
        }
    }
}
