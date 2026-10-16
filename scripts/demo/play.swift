// Plays tinywm's demo: opens the demo windows, presses keys with right ⌘ held as a person would,
// and shows a caption for each feature. Built and run by record.sh, which sets these:
//   DEMO_TT          the tinytext editor binary          DEMO_FILES  files to open, ":"-separated
//   DEMO_TERMINAL    the script the terminal window runs  DEMO_BROWSER_PROFILE  an empty profile folder
//   DEMO_ICON        the app icon PNG for the title card  DEMO_LAUNCHED  file that lists what was started
// The caption window is borderless and never takes focus, so tinywm leaves it alone.
import AppKit
import Carbon.HIToolbox

let env = ProcessInfo.processInfo.environment
let screen = NSScreen.screens.first!
/// Captions are sized for a 1280-point-wide screen and scaled up, so they stay readable in the GIF.
let u = max(1, screen.frame.width / 1280)

// MARK: Keys and mouse

let rightCommand: UInt64 = 0x10 // per-side bit tinywm reads to tell right ⌘ from left
let source = CGEventSource(stateID: .hidSystemState)

func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }

func setRightCommand(_ down: Bool) {
    let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_RightCommand), keyDown: down)
    e?.type = .flagsChanged
    e?.flags = down ? CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | rightCommand) : []
    post(e)
}

/// Presses `key` with right ⌘ (and optionally ⇧) held, then waits `pause` seconds.
func meta(_ key: Int, shift: Bool = false, pause: Double = 0.9) {
    var raw = CGEventFlags.maskCommand.rawValue | rightCommand
    if shift { raw |= CGEventFlags.maskShift.rawValue }
    setRightCommand(true)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)
        e?.flags = CGEventFlags(rawValue: raw)
        post(e)
        usleep(30_000)
    }
    setRightCommand(false)
    wait(pause)
}

/// A plain key press, for the overview, which takes keys without the meta key.
func plain(_ key: Int, pause: Double = 0.7) {
    for down in [true, false] {
        post(CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down))
        usleep(30_000)
    }
    wait(pause)
}

/// Drags with right ⌘ held from `from` to `to`, in global top-left coordinates, over `seconds`.
func metaDrag(from: CGPoint, to: CGPoint, seconds: Double) {
    let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | rightCommand)
    func mouse(_ type: CGEventType, _ p: CGPoint) {
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
        e?.flags = flags
        post(e)
    }
    CGWarpMouseCursorPosition(from)
    wait(0.3)
    setRightCommand(true)
    usleep(50_000)
    mouse(.leftMouseDown, from)
    let steps = Int(seconds * 60)
    for i in 1...steps {
        // Ease in and out, as a hand moves.
        let t = Double(i) / Double(steps), e = t * t * (3 - 2 * t)
        mouse(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e))
        usleep(useconds_t(1_000_000 / 60))
    }
    wait(0.4)
    mouse(.leftMouseUp, to)
    usleep(50_000)
    setRightCommand(false)
}

func wait(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

// MARK: Apps

let launched = env["DEMO_LAUNCHED"].map { URL(fileURLWithPath: $0) }

/// Notes a started app, so record.sh can quit it even if this program stops early.
func note(_ pid: pid_t, _ name: String) {
    guard pid > 0, let launched else { return }
    let line = Data("\(pid) \(name)\n".utf8)
    if let h = try? FileHandle(forWritingTo: launched) { h.seekToEndOfFile(); h.write(line); try? h.close() }
    else { try? line.write(to: launched) }
}

func openEditor(_ file: String) {
    guard let tt = env["DEMO_TT"] else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tt)
    p.arguments = [file]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    note(p.processIdentifier, "tt")
}

/// Starts a separate copy of an app, so its windows and settings stay apart from the user's own.
func openApp(_ bundleID: String, _ arguments: [String]) {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = true
    config.arguments = arguments
    let done = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
        if let app { note(app.processIdentifier, bundleID) }
        done.signal()
    }
    _ = done.wait(timeout: .now() + 10)
}

// MARK: Captions

let accent = [NSColor(srgbRed: 0.55, green: 0.40, blue: 1, alpha: 1), NSColor(srgbRed: 0.95, green: 0.45, blue: 0.85, alpha: 1)]

func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    l.font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    l.textColor = color
    return l
}

/// A key cap, such as "right ⌘" or "←".
func keycap(_ text: String) -> NSView {
    let l = label(text, size: 22 * u, weight: .semibold, color: NSColor(white: 0.12, alpha: 1))
    let cap = NSView()
    cap.wantsLayer = true
    cap.layer?.backgroundColor = NSColor(white: 0.96, alpha: 1).cgColor
    cap.layer?.cornerRadius = 9 * u
    cap.layer?.borderColor = NSColor(white: 0.75, alpha: 1).cgColor
    cap.layer?.borderWidth = 1
    cap.layer?.shadowColor = NSColor.black.cgColor
    cap.layer?.shadowOpacity = 0.35
    cap.layer?.shadowOffset = CGSize(width: 0, height: -2 * u)
    cap.layer?.shadowRadius = 0
    l.translatesAutoresizingMaskIntoConstraints = false
    cap.addSubview(l)
    NSLayoutConstraint.activate([
        l.centerXAnchor.constraint(equalTo: cap.centerXAnchor), l.centerYAnchor.constraint(equalTo: cap.centerYAnchor),
        cap.heightAnchor.constraint(equalToConstant: 40 * u),
        cap.widthAnchor.constraint(greaterThanOrEqualToConstant: 40 * u),
        cap.widthAnchor.constraint(equalTo: l.widthAnchor, constant: 26 * u),
    ])
    return cap
}

/// A round badge with an SF Symbol in the accent gradient.
func badge(_ symbol: String) -> NSView {
    let v = NSView()
    v.wantsLayer = true
    let g = CAGradientLayer()
    g.colors = accent.map(\.cgColor)
    g.startPoint = CGPoint(x: 0, y: 1); g.endPoint = CGPoint(x: 1, y: 0)
    g.cornerRadius = 24 * u
    g.frame = CGRect(x: 0, y: 0, width: 48 * u, height: 48 * u)
    v.layer?.addSublayer(g)
    let image = NSImageView()
    image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 22 * u, weight: .semibold))
    image.contentTintColor = .white
    image.translatesAutoresizingMaskIntoConstraints = false
    v.addSubview(image)
    NSLayoutConstraint.activate([
        v.widthAnchor.constraint(equalToConstant: 48 * u), v.heightAnchor.constraint(equalToConstant: 48 * u),
        image.centerXAnchor.constraint(equalTo: v.centerXAnchor), image.centerYAnchor.constraint(equalTo: v.centerYAnchor),
    ])
    return v
}

/// A dark, blurred bubble with a gradient rim around `content`.
func bubble(_ content: NSView, padding: NSEdgeInsets, radius: CGFloat) -> NSView {
    let blur = NSVisualEffectView()
    blur.material = .hudWindow
    blur.blendingMode = .behindWindow
    blur.state = .active
    blur.appearance = NSAppearance(named: .darkAqua)
    blur.wantsLayer = true
    blur.layer?.cornerRadius = radius
    blur.layer?.masksToBounds = true
    content.translatesAutoresizingMaskIntoConstraints = false
    blur.addSubview(content)
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: padding.left),
        content.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -padding.right),
        content.topAnchor.constraint(equalTo: blur.topAnchor, constant: padding.top),
        content.bottomAnchor.constraint(equalTo: blur.bottomAnchor, constant: -padding.bottom),
    ])
    blur.layoutSubtreeIfNeeded()
    let size = blur.fittingSize
    blur.frame = NSRect(origin: .zero, size: size)

    // The rim: a gradient seen through a stroked outline.
    let rim = CAGradientLayer()
    rim.colors = accent.map(\.cgColor)
    rim.startPoint = CGPoint(x: 0, y: 0.5); rim.endPoint = CGPoint(x: 1, y: 0.5)
    rim.frame = blur.bounds
    let outline = CAShapeLayer()
    outline.path = CGPath(roundedRect: blur.bounds.insetBy(dx: u, dy: u), cornerWidth: radius - u, cornerHeight: radius - u, transform: nil)
    outline.fillColor = nil
    outline.strokeColor = NSColor.white.cgColor
    outline.lineWidth = 2 * u
    rim.mask = outline
    blur.layer?.addSublayer(rim)

    // A container carries the shadow, since the bubble itself clips to its corners.
    let holder = NSView(frame: blur.frame)
    holder.wantsLayer = true
    holder.layer?.shadowColor = NSColor.black.cgColor
    holder.layer?.shadowOpacity = 0.45
    holder.layer?.shadowRadius = 24 * u
    holder.layer?.shadowOffset = CGSize(width: 0, height: -8 * u)
    holder.addSubview(blur)
    return holder
}

enum Caption {
    /// A feature: an icon, a line of text and the keys that do it.
    case feature(symbol: String, text: String, keys: [String])
    /// The title card, in the middle of the screen.
    case card(title: String, subtitle: String, footer: String?)
}

@MainActor
final class Captions {
    private let panel: NSPanel
    private var current: NSView?

    init(screen: NSScreen) {
        panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        panel.contentView?.wantsLayer = true
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
    }

    func show(_ caption: Caption) {
        hide()
        guard let root = panel.contentView else { return }
        let view = make(caption)
        let bounds = root.bounds
        switch caption {
        case .feature:
            view.setFrameOrigin(NSPoint(x: (bounds.width - view.frame.width) / 2, y: 70 * u))
        case .card:
            view.setFrameOrigin(NSPoint(x: (bounds.width - view.frame.width) / 2, y: (bounds.height - view.frame.height) / 2))
        }
        root.addSubview(view)
        current = view
        guard let layer = view.layer else { return }
        let rise = CASpringAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -28 * u; rise.toValue = 0
        rise.damping = 14; rise.stiffness = 180; rise.mass = 1
        rise.duration = rise.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.25
        layer.add(rise, forKey: "rise")
        layer.add(fade, forKey: "fade")
    }

    func hide() {
        guard let view = current else { return }
        current = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            view.animator().alphaValue = 0
        }, completionHandler: { view.removeFromSuperview() })
    }

    private func make(_ caption: Caption) -> NSView {
        switch caption {
        case let .feature(symbol, text, keys):
            let row = NSStackView(views: [badge(symbol), label(text, size: 30 * u, weight: .bold, color: .white)])
            row.spacing = 18 * u
            row.alignment = .centerY
            if !keys.isEmpty {
                let caps = NSStackView(views: keys.map(keycap))
                caps.spacing = 8 * u
                row.addArrangedSubview(caps)
                row.setCustomSpacing(26 * u, after: row.arrangedSubviews[1])
            }
            return bubble(row, padding: NSEdgeInsets(top: 14 * u, left: 16 * u, bottom: 14 * u, right: 26 * u), radius: 38 * u)
        case let .card(title, subtitle, footer):
            var views: [NSView] = []
            if let path = env["DEMO_ICON"], let icon = NSImage(contentsOfFile: path) {
                let image = NSImageView(image: icon)
                image.translatesAutoresizingMaskIntoConstraints = false
                image.widthAnchor.constraint(equalToConstant: 150 * u).isActive = true
                image.heightAnchor.constraint(equalToConstant: 150 * u).isActive = true
                views.append(image)
            }
            views.append(label(title, size: 64 * u, weight: .heavy, color: .white))
            views.append(label(subtitle, size: 28 * u, weight: .medium, color: NSColor(white: 1, alpha: 0.8)))
            if let footer { views.append(label(footer, size: 24 * u, weight: .semibold, color: accent[1])) }
            let column = NSStackView(views: views)
            column.orientation = .vertical
            column.spacing = 10 * u
            column.alignment = .centerX
            return bubble(column, padding: NSEdgeInsets(top: 34 * u, left: 60 * u, bottom: 38 * u, right: 60 * u), radius: 44 * u)
        }
    }
}

// MARK: The demo

/// Shows a caption on the main thread and returns at once.
func caption(_ c: Caption?) {
    DispatchQueue.main.async { MainActor.assumeIsolated { if let c { captions.show(c) } else { captions.hide() } } }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let captions = MainActor.assumeIsolated { Captions(screen: screen) }

/// The middle of the main display, in global top-left coordinates.
let centre = CGPoint(x: screen.frame.midX, y: screen.frame.height / 2)

func play() {
    // New windows open on the display in use, so the pointer goes to the recorded one.
    CGWarpMouseCursorPosition(centre)
    wait(0.8)

    caption(.card(title: "tinywm", subtitle: "A scrolling window manager for macOS", footer: nil))
    wait(3)

    caption(.feature(symbol: "plus.rectangle.on.rectangle", text: "New windows open next to the one you use", keys: []))
    let files = (env["DEMO_FILES"] ?? "").split(separator: ":").map(String.init)
    for f in files { openEditor(f); wait(1.3) }
    if let script = env["DEMO_TERMINAL"] {
        openApp("com.mitchellh.ghostty", ["--command=\(script)", "--title=tinywm config", "--window-save-state=never",
                                         "--confirm-close-surface=false", "--quit-after-last-window-closed=true"])
        wait(2)
    }
    if let profile = env["DEMO_BROWSER_PROFILE"] {
        openApp("org.mozilla.firefox", ["-profile", profile, "-no-remote", "-new-instance", "https://github.com/YaLTeR/niri"])
        wait(3.5)
    }

    caption(.feature(symbol: "arrow.left.and.right", text: "Scroll the strip", keys: ["right ⌘", "←", "→"]))
    meta(kVK_LeftArrow); meta(kVK_LeftArrow); meta(kVK_LeftArrow); meta(kVK_LeftArrow)
    meta(kVK_RightArrow); meta(kVK_RightArrow, pause: 1.2)

    caption(.feature(symbol: "rectangle.split.3x1", text: "Cycle widths: ⅓ · ½ · ⅔", keys: ["right ⌘", "R"]))
    meta(kVK_ANSI_R, pause: 1.1); meta(kVK_ANSI_R, pause: 1.1); meta(kVK_ANSI_R, pause: 1.1)

    caption(.feature(symbol: "arrow.up.left.and.arrow.down.right", text: "Full width, and back", keys: ["right ⌘", "F"]))
    meta(kVK_ANSI_F, pause: 1.4); meta(kVK_ANSI_F, pause: 1.1)

    caption(.feature(symbol: "arrow.left.arrow.right.square", text: "Move a window along the strip", keys: ["right ⌘", "⇧", "←"]))
    meta(kVK_LeftArrow, shift: true); meta(kVK_LeftArrow, shift: true, pause: 1.1)

    caption(.feature(symbol: "hand.draw", text: "Or drag it anywhere", keys: ["right ⌘", "drag"]))
    meta(kVK_ANSI_C, pause: 0.8)
    metaDrag(from: centre, to: CGPoint(x: centre.x + screen.frame.width * 0.38, y: centre.y), seconds: 1.4)
    wait(1.2)

    caption(.feature(symbol: "square.stack.3d.up", text: "Workspaces stack vertically", keys: ["right ⌘", "⇧", "U"]))
    meta(kVK_ANSI_U, shift: true, pause: 1.5)
    caption(.feature(symbol: "square.stack.3d.up", text: "Workspaces stack vertically", keys: ["right ⌘", "I"]))
    meta(kVK_ANSI_I, pause: 1.5)

    caption(.feature(symbol: "square.grid.2x2", text: "See every window at once", keys: ["right ⌘", "Esc"]))
    meta(kVK_Escape, pause: 1.6)
    plain(kVK_LeftArrow); plain(kVK_LeftArrow); plain(kVK_DownArrow, pause: 0.9); plain(kVK_UpArrow, pause: 0.9)
    plain(kVK_Return, pause: 1.6)

    caption(.card(title: "tinywm", subtitle: "Free and open source", footer: "github.com/bbodi/tinywm"))
    wait(3.5)
    caption(nil)
    wait(0.5)
}

/// DEMO_PREVIEW=<folder>: shows a few captions over a plain backdrop and saves a screenshot of each.
func preview(into folder: String) {
    DispatchQueue.main.sync {
        let backdrop = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.level = .floating
        backdrop.backgroundColor = NSColor(srgbRed: 0.18, green: 0.2, blue: 0.3, alpha: 1)
        backdrop.setFrame(screen.frame, display: true)
        backdrop.orderFrontRegardless()
    }
    let samples: [Caption] = [
        .card(title: "tinywm", subtitle: "A scrolling window manager for macOS", footer: nil),
        .feature(symbol: "arrow.left.arrow.right.square", text: "Move a window along the strip", keys: ["right ⌘", "⇧", "←"]),
        .card(title: "tinywm", subtitle: "Free and open source", footer: "github.com/bbodi/tinywm"),
    ]
    for (i, c) in samples.enumerated() {
        caption(c)
        wait(1)
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", "-D", "1", "\(folder)/caption-\(i).png"]
        try? shot.run()
        shot.waitUntilExit()
    }
}

Thread.detachNewThread {
    if let folder = env["DEMO_PREVIEW"] { preview(into: folder) } else { play() }
    DispatchQueue.main.async { app.terminate(nil) }
}
app.run()
