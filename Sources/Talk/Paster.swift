import AppKit
import ApplicationServices

/// Inserts text into the currently focused field of any app by placing it on
/// the pasteboard and synthesizing a Command+V keystroke.
///
/// Posting synthetic events into other apps requires Accessibility permission
/// (System Settings → Privacy & Security → Accessibility).
enum Paster {
    /// Puts `text` on the clipboard and synthesizes ⌘V into the focused field.
    /// Returns false if Accessibility isn't granted (the text is left on the
    /// clipboard so the user can paste it manually). Call on the main thread.
    @discardableResult
    static func paste(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Posting synthetic events requires Accessibility trust. Without it the
        // event is silently dropped, so don't pretend it worked — and leave the
        // transcript on the clipboard (don't restore) so it isn't lost.
        guard AXIsProcessTrusted() else {
            return false
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09 // 'v'

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cgSessionEventTap)
        keyUp?.post(tap: .cgSessionEventTap)

        // Restore the previous clipboard once the paste has landed.
        if let saved = saved {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                pasteboard.clearContents()
                pasteboard.setString(saved, forType: .string)
            }
        }
        return true
    }

    /// Returns whether the app is trusted for Accessibility; prompts the user
    /// (and offers to open System Settings) on the first call if it isn't.
    @discardableResult
    static func ensureAccessibility() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
