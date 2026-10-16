// Hides or shows apps for the demo recording, so nothing personal ends up in it.
//   swift apps.swift front         prints the PID of the app in front (the terminal running the demo)
//   swift apps.swift hide [pid]    hides every app except Finder and the demo editor, minimises the
//                                  windows of [pid]; prints what to restore
//   swift apps.swift show <pids>   shows those apps again
//   swift apps.swift check         lists apps still visible besides Finder and the demo editor
//   swift apps.swift others        bundle IDs of every other app, for an ignore rule
import AppKit
import ApplicationServices

let args = CommandLine.arguments.dropFirst()

/// Finder stays, for the desktop; the demo editor (tinytext, run as `tt`) stays, for the windows.
func isKept(_ app: NSRunningApplication) -> Bool {
    app.bundleIdentifier == "com.apple.finder" || app.executableURL?.lastPathComponent == "tt"
}

func windows(of app: NSRunningApplication) -> [AXUIElement] {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute as CFString, &value)
    return value as? [AXUIElement] ?? []
}

func isMinimized(_ w: AXUIElement) -> Bool {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &value)
    return (value as? Bool) ?? false
}

func setMinimized(_ app: NSRunningApplication, _ on: Bool) {
    for w in windows(of: app) { AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, on as CFBoolean) }
}

/// Apps that still show a window: not hidden, and with at least one window not minimised.
func visibleOthers() -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular && !$0.isHidden && !isKept($0)
            && (windows(of: $0).isEmpty || windows(of: $0).contains { !isMinimized($0) })
    }
}

switch args.first {
case "front":
    print(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
case "hide":
    // The terminal running the demo shows itself again when focus returns to it, so its windows
    // are minimised rather than only hidden.
    let front = args.dropFirst().first.flatMap(Int32.init).flatMap(NSRunningApplication.init(processIdentifier:))
        .flatMap { isKept($0) ? nil : $0 }
    // Bring Finder forward first: the app in front cannot always be hidden.
    NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }?.activate()
    Thread.sleep(forTimeInterval: 0.3)
    let apps = visibleOthers()
    for app in apps { app.hide() }
    Thread.sleep(forTimeInterval: 0.8)
    // The app in front, such as the terminal running this, can refuse; System Events can hide it.
    for app in visibleOthers() {
        let name = (app.localizedName ?? "").replacingOccurrences(of: "\"", with: "")
        let script = "tell application \"System Events\" to set visible of process \"\(name)\" to false"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }
    Thread.sleep(forTimeInterval: 0.5)
    // Last resort, e.g. the terminal running this: minimise its windows; "show" restores them.
    var stubborn = visibleOthers()
    if let front, !stubborn.contains(front) { stubborn.append(front) }
    for app in stubborn { setMinimized(app, true) }
    Thread.sleep(forTimeInterval: 0.8)
    print((apps.map { String($0.processIdentifier) } + stubborn.map { "min:\($0.processIdentifier)" }).joined(separator: " "))
case "show":
    for arg in args.dropFirst() {
        if arg.hasPrefix("min:"), let pid = Int32(arg.dropFirst(4)), let app = NSRunningApplication(processIdentifier: pid) {
            setMinimized(app, false)
        } else if let pid = Int32(arg) {
            NSRunningApplication(processIdentifier: pid)?.unhide()
        }
    }
case "check":
    for app in visibleOthers() { print(app.localizedName ?? app.bundleIdentifier ?? "?") }
case "others":
    let ids = NSWorkspace.shared.runningApplications.filter { !isKept($0) }.compactMap(\.bundleIdentifier)
        + ["com.apple.finder"]
    print(Array(Set(ids)).sorted().joined(separator: ", "))
default:
    print("usage: apps.swift hide | show <pids> | check | others")
}
