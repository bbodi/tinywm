import Foundation
import WindowCore

/// Every global shortcut. A feature calls `register` once per action in `install`, and
/// `setDefaultShortcuts` replaces the keys when the config file changes.
///
///     ShortcutRegistry.shared.register(action: "overview.toggle", title: "Show overview",
///         defaultKey: kVK_ANSI_O, defaultModifiers: controlKey | optionKey) { ... }
@MainActor
public final class ShortcutRegistry {
    public static let shared = ShortcutRegistry()

    public struct Entry {
        public let action: String
        public let title: String
        public internal(set) var defaultShortcut: Shortcut?
        public let handler: () -> Void
    }

    public private(set) var entries: [Entry] = []
    private var hotkeys: Hotkeys?
    private var boundIDs: [UInt32] = []
    private var suspended = false
    public var listeners: [() -> Void] = []

    private init() {}

    /// Replaces every listed action's default shortcut at once, then rebinds a single time.
    public func setDefaultShortcuts(_ shortcuts: [String: Shortcut?]) {
        for i in entries.indices {
            if let s = shortcuts[entries[i].action] { entries[i].defaultShortcut = s }
        }
        changed()
    }

    /// Idempotent. Registrations made before this call are bound as soon as it happens.
    public func attach(_ hotkeys: Hotkeys) {
        guard self.hotkeys == nil else { return }
        self.hotkeys = hotkeys
        rebind()
    }

    public func register(action: String, title: String? = nil, defaultKey: Int?, defaultModifiers: Int = 0,
                  handler: @escaping () -> Void) {
        let fallback = defaultKey.map { Shortcut(keyCode: $0, modifiers: defaultModifiers) }
        entries.removeAll { $0.action == action }
        entries.append(Entry(action: action, title: title ?? action, defaultShortcut: fallback, handler: handler))
        changed()
    }

    /// Drops every action the predicate matches, for shortcuts that come and go with the config.
    public func unregister(where matches: (String) -> Bool) {
        entries.removeAll { matches($0.action) }
        changed()
    }

    /// Runs `body`, then rebinds and tells the listeners once, however many actions it registered.
    /// Each rebind clears and re-registers every system hotkey.
    public func batch(_ body: () -> Void) {
        batching += 1
        body()
        batching -= 1
        if batching == 0, pendingChange {
            pendingChange = false
            changed()
        }
    }
    private var batching = 0
    private var pendingChange = false

    private func changed() {
        guard batching == 0 else { pendingChange = true; return }
        rebind()
        for l in listeners { l() }
    }

    public func shortcut(for action: String) -> Shortcut? {
        guard let entry = entries.first(where: { $0.action == action }) else { return nil }
        return entry.defaultShortcut
    }

    /// Turns the Carbon hotkeys off or back on and keeps every registration. Right ⌘ mode reads
    /// keys through its own event tap and turns them off.
    public func setSuspended(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value
        rebind()
    }

    private func rebind() {
        guard let hotkeys else { return }
        for id in boundIDs { hotkeys.unregister(id) }
        boundIDs = []
        guard !suspended else { return }
        for e in entries {
            guard let s = e.defaultShortcut,
                  let id = hotkeys.register(key: s.keyCode, modifiers: s.modifiers, e.handler) else { continue }
            boundIDs.append(id)
        }
    }
}
