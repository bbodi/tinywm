import AppKit
import ApplicationServices
import StripEngine

/// The first-run window: what tinywm does, the permissions it asks for, and the settings that work against it.
@MainActor
final class WelcomeWindow: NSObject, NSWindowDelegate {
    static let seenKey = "welcomeSeen"

    var editConfig: () -> Void = {}
    /// Whether swipes are on, and with how many fingers, as the config says.
    var swipe: () -> (enabled: Bool, fingers: Int) = { (true, 3) }
    /// How to move around with the keys the config binds.
    var moveHint: () -> String = { "" }

    private let window: NSWindow
    private let accessStatus = NSTextField(labelWithString: "")
    private let accessButton = NSButton()
    private let recordStatus = NSTextField(labelWithString: "")
    private let recordButton = NSButton()
    private let restartButton = NSButton()
    private let swipeStatus = NSTextField(wrappingLabelWithString: "")
    private let swipeButton = NSButton()
    private let stageStatus = NSTextField(wrappingLabelWithString: "")
    private let stageButton = NSButton()
    private let tilingStatus = NSTextField(wrappingLabelWithString: "")
    private let tilingButton = NSButton()
    private let wallpaperStatus = NSTextField(wrappingLabelWithString: "")
    private let wallpaperButton = NSButton()
    private let managersStatus = NSTextField(wrappingLabelWithString: "")
    private let loginStatus = NSTextField(wrappingLabelWithString: "")
    private let loginButton = NSButton()
    private let moveText = NSTextField(wrappingLabelWithString: "")
    private let primary = NSButton()
    private let screenRecordingAtLaunch = CGPreflightScreenCaptureAccess()
    private var timer: Timer?

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 10),
                          styleMask: [.titled, .closable], backing: .buffered, defer: true)
        super.init()
        window.title = "Welcome to tinywm"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = buildContent()
        window.setContentSize(window.contentView!.fittingSize)
    }

    func show() {
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        refresh()
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func windowWillClose(_: Notification) {
        timer?.invalidate()
        timer = nil
    }

    private func buildContent() -> NSView {
        let icon: NSImageView
        if LoginItem.inBundle {
            icon = NSImageView(image: NSApp.applicationIconImage)
            icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        } else {
            // Outside the app bundle there is no app icon, only the generic one for a tool.
            icon = NSImageView(image: TrayIcon.image)
            icon.contentTintColor = .labelColor
            icon.widthAnchor.constraint(equalToConstant: 66).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        let title = Self.label("tinywm", font: .systemFont(ofSize: 22, weight: .semibold))
        let tagline = Self.label("Your windows sit side by side on a strip that scrolls past your screen, and a key moves you along it.",
                                 color: .secondaryLabelColor)
        let header = NSStackView(views: [icon, NSStackView(views: [title, tagline].map { $0 as NSView }, vertical: true, spacing: 4)])
        header.spacing = 16
        header.alignment = .centerY

        setUp(accessButton, "Grant…", #selector(grantAccessibility))
        setUp(recordButton, "Grant…", #selector(grantScreenRecording))
        setUp(restartButton, "Restart tinywm", #selector(restart))
        restartButton.isHidden = true
        let access = row("Accessibility", "To move and size your windows. Needed.", accessStatus, [accessButton])
        let record = row("Screen Recording", "To show what is in your windows while they slide. Without it, windows jump into place. Nothing leaves your Mac.", recordStatus, [recordButton, restartButton])

        let keyTitle = Self.label("The meta key", font: .boldSystemFont(ofSize: 13))
        moveText.font = .systemFont(ofSize: 13)
        moveText.textColor = .secondaryLabelColor
        let edit = NSButton(title: "Edit Config…", target: self, action: #selector(openConfig))
        let keys = hstack([NSStackView(views: [keyTitle, moveText].map { $0 as NSView }, vertical: true, spacing: 2), edit])

        let setupTitle = Self.label("Check your setup", font: .systemFont(ofSize: 15, weight: .semibold))
        setUp(swipeButton, "Open Settings…", #selector(openTrackpadSettings))
        setUp(stageButton, "Open Settings…", #selector(openDesktopSettings))
        setUp(tilingButton, "Open Settings…", #selector(openDesktopSettings))
        setUp(wallpaperButton, "Open Settings…", #selector(openDesktopSettings))
        setUp(loginButton, "Turn On", #selector(toggleLogin))
        var checks = [
            setupTitle,
            row("Trackpad swipes", "tinywm moves the strip with your fingers, so macOS must not use the same number of fingers.", swipeStatus, [swipeButton]),
            row("Stage Manager", "Stage Manager moves and shrinks windows, which fights the strip.", stageStatus, [stageButton]),
        ]
        if SystemSetup.hasEdgeTiling {
            checks.append(row("Tiling at screen edges", "macOS resizes a window you drag to a screen edge, which pulls it out of the strip.", tilingStatus, [tilingButton]))
        }
        checks.append(row("Click wallpaper to reveal desktop", "macOS moves every window off screen when you click the desktop.", wallpaperStatus, [wallpaperButton]))
        checks.append(row("Other window managers", "Two window managers fight over the same windows.", managersStatus, []))
        checks.append(row("Open at Login", "Starts tinywm when you log in.", loginStatus, [loginButton]))
        let setup = NSStackView(views: checks, vertical: true, spacing: 12)

        setUp(primary, "Start tinywm", #selector(finish))
        primary.keyEquivalent = "\r"
        let bottom = NSStackView(views: [NSView(), primary])

        let stack = NSStackView(views: [header, access, record, setup, keys, bottom].map { $0 as NSView }, vertical: true, spacing: 18)
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)
        for v in stack.arrangedSubviews + setup.arrangedSubviews { v.widthAnchor.constraint(equalToConstant: 512).isActive = true }
        return stack
    }

    private func row(_ title: String, _ why: String, _ status: NSTextField, _ buttons: [NSButton]) -> NSView {
        status.font = .systemFont(ofSize: 12, weight: .medium)
        let text = NSStackView(views: [Self.label(title, font: .boldSystemFont(ofSize: 13)),
                                       Self.label(why, color: .secondaryLabelColor), status].map { $0 as NSView },
                               vertical: true, spacing: 2)
        return hstack([text] + buttons)
    }

    private func hstack(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.spacing = 10
        s.alignment = .centerY
        views.first?.setContentHuggingPriority(.defaultLow, for: .horizontal)
        (views.first as? NSStackView)?.alignment = .leading
        return s
    }

    private func setUp(_ b: NSButton, _ title: String, _ action: Selector) {
        b.title = title
        b.bezelStyle = .rounded
        b.target = self
        b.action = action
        b.setContentHuggingPriority(.required, for: .horizontal)
    }

    private static func label(_ text: String, font: NSFont = .systemFont(ofSize: 13), color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = font
        l.textColor = color
        return l
    }

    private func refresh() {
        let access = AXIsProcessTrusted()
        let record = CGPreflightScreenCaptureAccess()
        let step = Onboarding.step(accessibility: access, screenRecording: record)
        Self.show(access, in: accessStatus, off: "Not granted yet")
        Self.show(record, in: recordStatus, off: "Not granted")
        accessButton.isHidden = access
        recordButton.isHidden = record
        let restart = Onboarding.needsRestart(screenRecordingAtLaunch: screenRecordingAtLaunch,
                                              screenRecordingNow: record, inBundle: LoginItem.inBundle)
        restartButton.isHidden = !restart
        if restart { recordStatus.stringValue = "Granted. Restart tinywm to use it." }
        primary.title = Onboarding.primaryButtonTitle(step)
        primary.isEnabled = Onboarding.primaryButtonEnabled(step)

        moveText.stringValue = moveHint()
        let swipe = swipe()
        Self.show(SetupCheck.swipes(enabled: swipe.enabled, fingers: swipe.fingers, settings: SystemSetup.trackpadSettings()),
                  in: swipeStatus, button: swipeButton)
        let windowManager = SystemSetup.windowManagerSettings()
        Self.show(SetupCheck.stageManager(settings: windowManager), in: stageStatus, button: stageButton)
        Self.show(SetupCheck.edgeTiling(settings: windowManager), in: tilingStatus, button: tilingButton)
        Self.show(SetupCheck.clickWallpaper(settings: windowManager), in: wallpaperStatus, button: wallpaperButton)
        Self.show(SetupCheck.otherWindowManagers(bundleIDs: SystemSetup.runningBundleIDs(), processNames: SystemSetup.processNames()),
                  in: managersStatus, button: nil)
        let login = LoginItem.state
        Self.show(SetupCheck.login(login), in: loginStatus, button: nil)
        let loginTitle = SetupCheck.loginButtonTitle(login)
        loginButton.title = loginTitle ?? ""
        loginButton.isHidden = loginTitle == nil
        fitToContent()
    }

    /// Grows or shrinks the window as status lines wrap, keeping its top edge in place.
    private func fitToContent() {
        guard let content = window.contentView else { return }
        let size = content.fittingSize
        guard size != content.frame.size else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    private static func show(_ result: SetupCheck.Result, in field: NSTextField, button: NSButton?) {
        field.stringValue = result.status
        field.textColor = result.ok ? .systemGreen : .systemOrange
        button?.isHidden = result.ok
    }

    private static func show(_ granted: Bool, in field: NSTextField, off: String) {
        field.stringValue = granted ? "Granted" : off
        field.textColor = granted ? .systemGreen : .systemOrange
    }

    @objc private func grantAccessibility() {
        // The literal is the value of kAXTrustedCheckOptionPrompt, which Swift 6 flags as mutable global state.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        Self.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @objc private func grantScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        Self.open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private static func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    /// Relaunches after a short pause so the old instance has put windows back before the new one takes them.
    @objc private func restart() {
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", Bundle.main.bundleURL.path]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    @objc private func openConfig() { editConfig() }

    @objc private func openTrackpadSettings() { SystemSetup.openTrackpadSettings() }

    @objc private func openDesktopSettings() { SystemSetup.openDesktopSettings() }

    @objc private func toggleLogin() {
        LoginItem.toggle()
        refresh()
    }

    @objc private func finish() { window.close() }
}

private extension NSStackView {
    convenience init(views: [NSView], vertical: Bool, spacing: CGFloat) {
        self.init(views: views)
        orientation = vertical ? .vertical : .horizontal
        self.spacing = spacing
        alignment = vertical ? .leading : .centerY
    }
}
