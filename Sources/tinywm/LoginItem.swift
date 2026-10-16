import AppKit
import ServiceManagement
import WindowCore
import StripEngine

/// Open at Login through the app's own login item. It only exists for an installed .app.
@MainActor
enum LoginItem {
    static var inBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static let unavailableNote = "Available in the installed app"

    static var state: LoginItemState {
        guard inBundle else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        case .notRegistered, .notFound: return .off
        @unknown default: return .off
        }
    }

    /// Flips the setting. A fresh registration that macOS holds for approval opens Login Items.
    static func toggle() {
        switch state.action {
        case .register:
            do { try SMAppService.mainApp.register() } catch { Log.note("login", "could not add tinywm to Login Items: \(error)") }
            if state == .needsApproval { SMAppService.openSystemSettingsLoginItems() }
        case .unregister:
            do { try SMAppService.mainApp.unregister() } catch { Log.note("login", "could not remove tinywm from Login Items: \(error)") }
        case .openSettings: SMAppService.openSystemSettingsLoginItems()
        case .none: break
        }
    }
}

/// The status-menu entry for Open at Login, checked while the login item is on.
@MainActor
final class LoginMenuItem: NSObject {
    let item = NSMenuItem(title: "Open at Login", action: nil, keyEquivalent: "")

    override init() {
        super.init()
        item.action = #selector(clicked)
        item.target = self
        refresh()
    }

    func refresh() {
        let state = LoginItem.state
        item.isEnabled = state != .unavailable
        item.state = state.isChecked ? .on : .off
        item.toolTip = state == .unavailable ? LoginItem.unavailableNote
            : state == .needsApproval ? "Allow tinywm in System Settings → Login Items" : nil
    }

    @objc private func clicked() {
        LoginItem.toggle()
        refresh()
    }
}
