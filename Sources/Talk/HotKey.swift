import Carbon
import Foundation

/// A system-wide hotkey registered via Carbon's RegisterEventHotKey.
///
/// Carbon hotkeys do NOT require Accessibility or Input Monitoring permission,
/// and they do not leak the keystroke into the focused text field. The handler
/// fires on the main run loop.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let callback: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        self.callback = callback

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // Pass `self` to the C callback through userData. The app keeps a
        // strong reference for its whole lifetime, so passUnretained is safe.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, _, userData) -> OSStatus in
                guard let userData = userData else { return noErr }
                let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                hotKey.callback()
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )
        guard installStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x54_41_4C_4B), id: 1) // 'TALK'
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else { return nil }
    }

    deinit {
        if let hotKeyRef = hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef = eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }
}
