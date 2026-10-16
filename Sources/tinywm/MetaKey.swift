import AppKit
import Carbon.HIToolbox
import StripEngine
import WindowCore
import WindowKit

/// Makes right ⌘ a dedicated meta key.
///
/// macOS and apps treat both ⌘ keys alike, but raw key events carry a per-side bit. An event tap
/// reads it: while right ⌘ is held, every key goes to tinywm and none reaches the app in front.
/// Left ⌘ keeps working as usual. Secure input (password fields) pauses event taps, so tinywm
/// keys do nothing there.
///
/// The same tap reads the left mouse button for meta + drag, with either meta key. A press with
/// the meta key held on a managed window, and the rest of that click, never reach the app.
@MainActor
final class MetaKey {
    /// Set when the modifier choice changes; the shortcut menu redraws from it.
    var onChange: () -> Void = {}

    private(set) var mode = MetaModifier.rightCommand
    private var bindings = MetaKeyBindings()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var rightCommandDown = false
    /// The last key pressed anywhere, so a launcher closed with Esc can be told from one that
    /// opened an app.
    private(set) var lastKeyDown: (code: Int, at: Date)?
    /// Moves windows dragged with the meta key held.
    weak var dragger: WindowDragger?
    /// Whether a meta press may start a drag now, e.g. not while the overview is open.
    var canDrag: () -> Bool = { true }
    /// True from a press the dragger took until the button goes up, so the whole click is kept
    /// from the app even after Esc ended the drag.
    private var holdingClick = false
    /// Right-⌘ device bit in CGEventFlags (NX_DEVICERCMDKEYMASK).
    private static let rightCommandBit: UInt64 = 0x10

    init() {
        ShortcutRegistry.shared.listeners.append { [weak self] in self?.rebuild() }
    }

    func start() {
        apply()
    }

    func setMode(_ m: MetaModifier) {
        guard m != mode else { return }
        mode = m
        apply()
        onChange()
    }

    /// Right ⌘ mode reads keys through the tap and switches the ⌃⌥ system hotkeys off. The tap
    /// runs in both modes, since it also reads the mouse.
    private func apply() {
        rebuild()
        ShortcutRegistry.shared.setSuspended(mode == .rightCommand)
        installTap()
    }

    private func rebuild() {
        let registry = ShortcutRegistry.shared
        bindings = MetaKeyBindings(registry.entries.compactMap { e in
            registry.shortcut(for: e.action).map { (e.action, $0.keyCode, $0.modifiers) }
        })
    }

    /// The action of each chord, run through the registry so rebinding keeps working.
    private func run(_ action: String) {
        ShortcutRegistry.shared.entries.first { $0.action == action }?.handler()
    }

    /// How a shortcut reads in menus for the current meta key.
    func display(_ s: Shortcut) -> String {
        MetaKeyBindings.display(keyName: Shortcut.keyName(s.keyCode), modifiers: s.modifiers, mode: mode)
    }

    // MARK: Event tap

    private func installTap() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: metaKeyCallback, userInfo: me
        ) else { return }
        tap = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// The parts of an event tinywm reads, copied out on the tap's thread.
    fileprivate struct KeyEvent: Sendable {
        let type: CGEventType
        let keyCode: Int
        let isRepeat: Bool
        let flags: UInt64
        /// The pointer, in the Accessibility coordinates the strips use.
        let location: Point
    }

    private static let escape = 53

    /// Returns true when the event belongs to tinywm and must not reach apps.
    fileprivate func handle(_ e: KeyEvent) -> Bool {
        let type = e.type
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns a slow tap off; turn it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .flagsChanged:
            rightCommandDown = e.flags & Self.rightCommandBit != 0
            return false
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            return mouse(e)
        case .keyDown where e.keyCode == Self.escape && dragger?.isActive == true:
            dragger?.cancel()
            return true
        case .keyDown, .keyUp:
            if type == .keyDown { lastKeyDown = (e.keyCode, Date()) }
            guard mode == .rightCommand, rightCommandDown else { return false }
            if type == .keyDown {
                let flags = CGEventFlags(rawValue: e.flags)
                if let action = bindings.action(keyCode: e.keyCode, shift: flags.contains(.maskShift),
                                                option: flags.contains(.maskAlternate),
                                                control: flags.contains(.maskControl)),
                   !e.isRepeat || StripActions.spec(named: action)?.repeats == true {
                    run(action)
                }
            }
            // Dedicated key: nothing typed with right ⌘ reaches the app in front.
            return true
        default:
            return false
        }
    }

    /// Left-button events, which pass straight through unless a meta drag owns the click.
    /// Every other click returns at the first check, so the tap stays fast.
    private func mouse(_ e: KeyEvent) -> Bool {
        switch e.type {
        case .leftMouseDown:
            let held = mode.isHeld(flags: e.flags) || (mode == .rightCommand && rightCommandDown)
            guard held, canDrag(), let dragger, dragger.press(at: e.location) else { return false }
            holdingClick = true
            return true
        case .leftMouseDragged:
            guard holdingClick else { return false }
            dragger?.move(to: e.location)
            return true
        case .leftMouseUp:
            guard holdingClick else { return false }
            holdingClick = false
            dragger?.release(at: e.location)
            return true
        default:
            return false
        }
    }
}

private func metaKeyCallback(
    _: CGEventTapProxy, type: CGEventType, event: CGEvent, info: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let info else { return Unmanaged.passUnretained(event) }
    if event.getIntegerValueField(.eventSourceUserData) == CommandRunner.marker { return Unmanaged.passUnretained(event) }
    let key = Unmanaged<MetaKey>.fromOpaque(info).takeUnretainedValue()
    let p = event.location
    let e = MetaKey.KeyEvent(
        type: type, keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
        isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, flags: event.flags.rawValue,
        location: Point(x: p.x, y: p.y))
    let swallow = MainActor.assumeIsolated { key.handle(e) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
