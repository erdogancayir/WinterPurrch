import Carbon

/// A system-wide keyboard shortcut. Carbon's hot keys need no Accessibility permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var actions: [UInt32: () -> Void] = [:]
    private static var installed = false

    init(keyCode: UInt32, modifiers: UInt32, id: UInt32, action: @escaping () -> Void) {
        Self.actions[id] = action
        if !Self.installed {
            Self.installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hotKey = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
                DispatchQueue.main.async { HotKey.actions[hotKey.id]?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x5750_5243), id: id)   // "WPRC"
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }
}
