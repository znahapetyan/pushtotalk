import AppKit

/// Watches one or more *modifier* keys globally for push-to-talk. `onPress`
/// fires when the first watched key goes down; `onRelease` fires when the last
/// watched key comes back up. Holding any single watched key (e.g. fn OR
/// control) records; the choice of keys is configurable.
///
/// Uses NSEvent monitors for `.flagsChanged`, which requires the app to be
/// trusted for Accessibility (already needed for pasting). Modifier keys report
/// their press/release as `.flagsChanged` events with a virtual key code and a
/// corresponding modifier flag.
final class ModifierKeyMonitor {
    /// A watchable modifier key: the virtual key codes it can report (left and
    /// right variants) and the modifier flag it sets while held.
    private struct ModKey {
        let keyCodes: Set<UInt16>
        let flag: NSEvent.ModifierFlags
    }

    /// Known push-to-talk modifier keys, by lowercase name.
    private static let known: [String: ModKey] = [
        "fn":       ModKey(keyCodes: [63], flag: .function),
        "function": ModKey(keyCodes: [63], flag: .function),
        "globe":    ModKey(keyCodes: [63], flag: .function),
        "control":  ModKey(keyCodes: [59, 62], flag: .control),
        "ctrl":     ModKey(keyCodes: [59, 62], flag: .control),
        "option":   ModKey(keyCodes: [58, 61], flag: .option),
        "alt":      ModKey(keyCodes: [58, 61], flag: .option),
        "command":  ModKey(keyCodes: [55, 54], flag: .command),
        "cmd":      ModKey(keyCodes: [55, 54], flag: .command),
        "shift":    ModKey(keyCodes: [56, 60], flag: .shift),
    ]

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private let keys: [ModKey]
    /// Key codes currently held down among the watched keys.
    private var held = Set<UInt16>()

    /// - Parameter keyNames: modifier key names to use as push-to-talk, e.g.
    ///   `["fn", "control"]`. Unknown names are ignored; falls back to fn.
    init(keyNames: [String], onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
        let resolved = keyNames.compactMap { Self.known[$0.lowercased()] }
        self.keys = resolved.isEmpty ? [Self.known["fn"]!] : resolved

        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self = self else { return }
            // Find which watched key this modifier event belongs to.
            guard let key = self.keys.first(where: { $0.keyCodes.contains(event.keyCode) }) else { return }
            let down = event.modifierFlags.contains(key.flag)
            let wasEmpty = self.held.isEmpty
            if down {
                self.held.insert(event.keyCode)
            } else {
                self.held.remove(event.keyCode)
            }
            if wasEmpty, !self.held.isEmpty {
                self.onPress()
            } else if !wasEmpty, self.held.isEmpty {
                self.onRelease()
            }
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
        }
        // Local monitor covers the case where our own UI (e.g. an alert) is key.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
            return event
        }
    }

    deinit {
        if let globalMonitor = globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor = localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}
