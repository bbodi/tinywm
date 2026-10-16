import Carbon.HIToolbox

/// Global shortcuts through Carbon. They need no Accessibility or Input Monitoring grant and
/// they consume the keystroke, so the focused app never sees it.
@MainActor
public final class Hotkeys {
    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?

    public init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let hotkeys = Unmanaged<Hotkeys>.fromOpaque(context!).takeUnretainedValue()
            let id = hk.id
            MainActor.assumeIsolated { hotkeys.actions[id]?() }
            return noErr
        }, 1, &spec, me, &handler)
    }

    /// Returns an ID for `unregister`, or nil when the system refused the combination.
    @discardableResult
    public func register(key: Int, modifiers: Int, _ action: @escaping () -> Void) -> UInt32? {
        let id = nextID
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4652_544C), id: id) // "FRTL"
        guard RegisterEventHotKey(UInt32(key), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr,
              let ref else { return nil }
        nextID += 1
        refs[id] = ref
        actions[id] = action
        return id
    }

    public func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        actions[id] = nil
    }
}
