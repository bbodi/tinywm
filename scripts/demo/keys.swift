// Plays tinywm's demo by pressing keys with right ⌘ held, as a person would.
// Usage: swift scripts/demo/keys.swift   (the running terminal needs Accessibility access)
import AppKit
import Carbon.HIToolbox

let rightCommand: UInt64 = 0x10 // per-side bit tinywm reads to tell right ⌘ from left
let source = CGEventSource(stateID: .hidSystemState)

func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }

func setRightCommand(_ down: Bool) {
    let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_RightCommand), keyDown: down)
    e?.type = .flagsChanged
    e?.flags = down ? CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | rightCommand) : []
    post(e)
}

/// Presses `key` with right ⌘ (and optionally ⇧ or ⌥) held, then waits `pause` seconds.
func meta(_ key: Int, shift: Bool = false, option: Bool = false, pause: Double = 0.9) {
    var raw = CGEventFlags.maskCommand.rawValue | rightCommand
    if shift { raw |= CGEventFlags.maskShift.rawValue }
    if option { raw |= CGEventFlags.maskAlternate.rawValue }
    setRightCommand(true)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)
        e?.flags = CGEventFlags(rawValue: raw)
        post(e)
        usleep(30_000)
    }
    setRightCommand(false)
    Thread.sleep(forTimeInterval: pause)
}

/// A plain key press, for the overview, which takes keys without the meta key.
func plain(_ key: Int, pause: Double = 0.7) {
    for down in [true, false] {
        post(CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down))
        usleep(30_000)
    }
    Thread.sleep(forTimeInterval: pause)
}

// Scroll along the strip.
meta(kVK_LeftArrow); meta(kVK_LeftArrow); meta(kVK_LeftArrow)
meta(kVK_RightArrow); meta(kVK_RightArrow)
// Widths: cycle, then full width and back.
meta(kVK_ANSI_R); meta(kVK_ANSI_R)
meta(kVK_ANSI_F, pause: 1.2); meta(kVK_ANSI_F)
// Move a column along the strip.
meta(kVK_LeftArrow, shift: true); meta(kVK_LeftArrow, shift: true); meta(kVK_RightArrow)
// Take a window down to a new workspace, look around, and come back.
meta(kVK_DownArrow, shift: true, option: true, pause: 1.2)
meta(kVK_UpArrow, option: true, pause: 1.2)
// Overview: zoom out, pick a window, zoom back in.
meta(kVK_Escape, pause: 1.4)
plain(kVK_RightArrow); plain(kVK_RightArrow); plain(kVK_DownArrow)
plain(kVK_Return, pause: 1.5)
