import AppKit
import StripEngine
import WindowCore

/// Carries out the config's `run` and `send` shortcuts.
enum CommandRunner {
    /// Stamped on every key event tinywm posts, so its own event tap lets them through.
    static let marker: Int64 = 0x7469_6E79

    static func run(_ command: CustomCommand) {
        switch command.kind {
        case .shell(let line): shell(line)
        case .keys(let stroke): press(stroke)
        }
    }

    /// Starts the command and does not wait for it. Apps launched from the Dock get a short PATH,
    /// so the usual Homebrew locations are added.
    private static func shell(_ line: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", line]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
        p.environment = env
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { Log.note("key", "could not start the command `\(line)`: \(error)") }
    }

    /// Posts the stroke to the process `pid`, whichever app is in front. An app listed without a
    /// real process reports ID -1 or 0, so nothing is sent then.
    static func press(_ s: KeyStroke, in pid: pid_t) {
        guard pid > 0 else { return }
        press(s, pid: pid)
    }

    /// Posts the stroke with exactly its own modifiers, to `pid` or else to the front app. The
    /// right ⌘ the user still holds is left out, so the target sees the combination as written.
    private static func press(_ s: KeyStroke, pid: pid_t? = nil) {
        // Left-side device bits alongside the generic masks, for apps that check which side.
        var flags: UInt64 = 0
        if s.command { flags |= CGEventFlags.maskCommand.rawValue | 0x08 }
        if s.shift { flags |= CGEventFlags.maskShift.rawValue | 0x02 }
        if s.option { flags |= CGEventFlags.maskAlternate.rawValue | 0x20 }
        if s.control { flags |= CGEventFlags.maskControl.rawValue | 0x01 }
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(s.keyCode), keyDown: down) else { continue }
            e.flags = CGEventFlags(rawValue: flags)
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            if let pid { e.postToPid(pid) } else { e.post(tap: .cghidEventTap) }
        }
    }
}
