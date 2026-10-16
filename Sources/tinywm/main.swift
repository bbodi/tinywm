import AppKit
import ApplicationServices
import StripEngine

/// Starts tinywm: shows the menu and the welcome window, waits for Accessibility access, then
/// builds the runtime. Before access is granted only the menu and the welcome window work.
@MainActor
final class TinyWMApp: NSObject, NSApplicationDelegate {
    private let configFile = ConfigFile()
    private let welcome = WelcomeWindow()
    private var menu: StatusMenu!
    /// Nil until Accessibility access is granted.
    private var runtime: Runtime?

    func applicationDidFinishLaunching(_: Notification) {
        UserDefaults.standard.register(defaults: [Defaults.livePictures: true])
        menu = StatusMenu(livePictures: UserDefaults.standard.bool(forKey: Defaults.livePictures))
        menu.toggleLivePictures = { [unowned self] in toggleLivePictures() }
        menu.showWelcome = { [unowned self] in welcome.show() }
        menu.editConfig = { [unowned self] in configFile.edit() }
        menu.reloadConfig = { [unowned self] in configFile.reload() }
        menu.retileAll = { [unowned self] in runtime?.retileAll() }
        menu.canRetile = { [unowned self] in runtime != nil }
        menu.toggleDisplay = { [unowned self] id in runtime?.toggleDisplay(id) }
        menu.willOpen = { [unowned self] in runtime?.refreshSwipeWarning() }

        welcome.editConfig = { [unowned self] in configFile.edit() }
        welcome.swipe = { [unowned self] in
            guard let runtime else { return (true, SwipeRecognizer().fingers) }
            return (runtime.swipeEnabled, runtime.recognizer.fingers)
        }
        welcome.moveHint = { [unowned self] in
            let config = runtime?.config ?? StripConfig()
            return MoveHint.text(bindings: config.bindings, meta: config.meta)
        }
        let welcoming = Onboarding.shouldShowOnLaunch(seenBefore: UserDefaults.standard.bool(forKey: WelcomeWindow.seenKey))
        if welcoming { welcome.show() }
        // The welcome window's Grant button asks instead of a bare system prompt here.
        // The literal is the value of kAXTrustedCheckOptionPrompt, which Swift 6 flags as mutable global state.
        let options = ["AXTrustedCheckOptionPrompt": !welcoming] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            menu.setTitle(" needs Accessibility")
            Task { @MainActor in
                while !AXIsProcessTrusted() { try? await Task.sleep(for: .seconds(2)) }
                menu.setTitle("")
                start()
            }
            return
        }
        start()
    }

    private func start() {
        runtime = Runtime(menu: menu, configFile: configFile)
    }

    /// By default each window shows as a live picture while it moves, which records the
    /// windows. Turned off, each window shows as a card with its app's icon and title, so
    /// tinywm never records the screen. The choice takes effect at the next motion.
    private func toggleLivePictures() {
        let live = !UserDefaults.standard.bool(forKey: Defaults.livePictures)
        UserDefaults.standard.set(live, forKey: Defaults.livePictures)
        menu.setLivePictures(live)
        runtime?.setLivePictures(live)
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { TinyWMApp() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
