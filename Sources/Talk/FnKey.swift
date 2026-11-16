import AppKit

/// Watches one or more *modifier* keys globally for push-to-talk. `onPress`
/// fires when the first watched key goes down; `onRelease` fires when the last
/// watched key comes back up. Holding any single watched key (e.g. fn OR
/// control) records; the choice of keys is configurable, down to one side of
/// a modifier (e.g. only the right option key).
///
/// Uses NSEvent monitors for `.flagsChanged`, which requires the app to be
/// trusted for Accessibility (already needed for pasting). Modifier keys report
/// their press/release as `.flagsChanged` events with a virtual key code and a
/// corresponding modifier flag.
final class ModifierKeyMonitor {
    /// A watchable push-to-talk key: the physical key codes it covers and a
    /// human-readable label for the menu.
    private struct ModKey {
        let keyCodes: Set<UInt16>
        let label: String
    }

    /// Known push-to-talk keys, by normalized name (lowercase letters only, so
    /// "right_option", "Right Option" and "rightoption" all match). Every
    /// modifier also has a side-specific form: "leftoption", "rightcommand", …
    private static let known: [String: ModKey] = {
        let fn = ModKey(keyCodes: [63], label: "fn")
        var table: [String: ModKey] = ["fn": fn, "function": fn, "globe": fn]
        // (names, label, left key code, right key code)
        let modifiers: [([String], String, UInt16, UInt16)] = [
            (["control", "ctrl"], "control", 59, 62),
            (["option", "alt"], "option", 58, 61),
            (["command", "cmd"], "command", 55, 54),
            (["shift"], "shift", 56, 60),
        ]
        for (names, label, left, right) in modifiers {
            for name in names {
                table[name] = ModKey(keyCodes: [left, right], label: label)
                table["left" + name] = ModKey(keyCodes: [left], label: "left " + label)
                table["right" + name] = ModKey(keyCodes: [right], label: "right " + label)
            }
        }
        return table
    }()

    /// Device-dependent modifier bits (IOKit's NX_DEVICE*KEYMASK), which say
    /// which *side* of a modifier is down. The device-independent flags
    /// (.option, …) can't: with left option held, releasing right option still
    /// reports .option set, which would leave the recording running.
    private static let deviceMasks: [UInt16: UInt] = [
        59: 0x0001, 62: 0x2000, // left / right control
        56: 0x0002, 60: 0x0004, // left / right shift
        55: 0x0008, 54: 0x0010, // left / right command
        58: 0x0020, 61: 0x0040, // left / right option
    ]

    private static func normalize(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter }
    }

    /// Whether the key that sent this `.flagsChanged` event is now down.
    private static func isDown(_ event: NSEvent) -> Bool {
        if let mask = deviceMasks[event.keyCode] {
            return event.modifierFlags.rawValue & mask != 0
        }
        return event.modifierFlags.contains(.function) // fn has no side
    }

    /// Menu label for a configured key name ("right option"), or nil if unknown.
    static func label(for name: String) -> String? {
        known[normalize(name)]?.label
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private let keys: [ModKey]
    /// Key codes currently held down among the watched keys.
    private var held = Set<UInt16>()

    /// - Parameter keyNames: modifier key names to use as push-to-talk, e.g.
    ///   `["fn", "control"]` or `["rightoption"]`. Unknown names are ignored;
    ///   falls back to fn.
    init(keyNames: [String], onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
        let resolved = keyNames.compactMap { Self.known[Self.normalize($0)] }
        self.keys = resolved.isEmpty ? [Self.known["fn"]!] : resolved

        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self = self else { return }
            // Find which watched key this modifier event belongs to.
            guard self.keys.contains(where: { $0.keyCodes.contains(event.keyCode) }) else { return }
            let down = Self.isDown(event)
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
