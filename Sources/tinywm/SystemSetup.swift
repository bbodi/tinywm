import AppKit
import Darwin
import StripEngine

/// Reads the macOS settings and running processes that `SetupCheck` judges.
@MainActor
enum SystemSetup {
    /// The trackpad gesture settings of the built-in and Bluetooth trackpads, merged.
    static func trackpadSettings() -> [String: Int] {
        var merged: [String: Int] = [:]
        for domain in ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"] {
            for (key, value) in read(SwipeClash.gestures.map(\.key), in: domain) {
                merged[key] = max(merged[key] ?? 0, value)
            }
        }
        return merged
    }

    static func windowManagerSettings() -> [String: Int] {
        read([SetupCheck.stageManagerKey, SetupCheck.clickWallpaperKey] + SetupCheck.edgeTilingKeys, in: "com.apple.WindowManager")
    }

    /// Edge tiling arrived in macOS 15.
    static var hasEdgeTiling: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
    }

    static func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    /// The names of every process the user can see, for daemons that have no app.
    static func processNames() -> Set<String> {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard found > 0 else { return [] }
        var names = Set<String>()
        var buffer = [UInt8](repeating: 0, count: 256)
        for pid in pids.prefix(Int(found)) where pid > 0 {
            let length = proc_name(pid, &buffer, UInt32(buffer.count))
            if length > 0 { names.insert(String(decoding: buffer.prefix(Int(length)), as: UTF8.self)) }
        }
        return names
    }

    static func openTrackpadSettings() { open("x-apple.systempreferences:com.apple.Trackpad-Settings.extension") }

    static func openDesktopSettings() { open("x-apple.systempreferences:com.apple.Desktop-Settings.extension") }

    private static func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    /// Syncs first, since another process writes these domains and the cached copy goes stale.
    private static func read(_ keys: [String], in domain: String) -> [String: Int] {
        CFPreferencesAppSynchronize(domain as CFString)
        var values: [String: Int] = [:]
        for key in keys {
            if let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? Int { values[key] = value }
        }
        return values
    }
}
