import AppKit
import Carbon

/// A registered shortcut, not a global keyboard monitor; does not record typed input.
@MainActor final class SelectionHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private(set) var isRegistered = false

    init(action: @escaping () -> Void) {
        self.action = action
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                Unmanaged<SelectionHotKey>.fromOpaque(context).takeUnretainedValue().action()
            }
            return noErr
        }, 1, &event, context, &handler)
        guard status == noErr else { return }
        let identifier = EventHotKeyID(signature: 0x50425247, id: 1)
        let modifiers = UInt32(optionKey)
        isRegistered = RegisterEventHotKey(UInt32(kVK_ANSI_T), modifiers, identifier,
                                           GetApplicationEventTarget(), 0, &hotKey) == noErr
        if !isRegistered { stop() }
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        isRegistered = false
    }
}
