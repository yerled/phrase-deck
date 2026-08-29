import AppKit
import ApplicationServices

enum TextInserter {
    /// Copy text then synthesize ⌘V into the frontmost app.
    @MainActor
    static func insert(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        let ok = pasteCommandV()
        // Restore previous clipboard after a short delay so paste can consume current
        if let previous {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                let current = NSPasteboard.general
                // Only restore if still our phrase (user may have copied something else)
                if current.string(forType: .string) == text {
                    current.clearContents()
                    current.setString(previous, forType: .string)
                }
            }
        }
        return ok
    }

    private static func pasteCommandV() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyVDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyVUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyVDown?.flags = .maskCommand
        keyVUp?.flags = .maskCommand

        guard let keyVDown, let keyVUp else { return false }
        keyVDown.post(tap: .cghidEventTap)
        keyVUp.post(tap: .cghidEventTap)
        return true
    }

    static func isTextInputFocused() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let focused else { return false }

        let element = focused as! AXUIElement
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let roleStr = role as? String ?? ""

        let textRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            "AXWebArea",
            "AXSearchField",
        ]
        if textRoles.contains(roleStr) { return true }

        // Editable via AX
        var editable: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editable) == .success,
           let editable = editable as? Bool, editable {
            return true
        }
        return false
    }
}
