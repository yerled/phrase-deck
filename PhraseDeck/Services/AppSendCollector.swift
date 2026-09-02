import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Captures outbound messages in Feishu / Cursor when the user presses Enter (or ⌘Enter).
@MainActor
final class AppSendCollector: ObservableObject {
    static let shared = AppSendCollector()

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled) }
    }

    @Published private(set) var lastCaptured: String?
    @Published private(set) var lastAppName: String?
    @Published private(set) var isTapActive = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    nonisolated(unsafe) private var tapPort: CFMachPort?

    private enum Keys {
        static let enabled = "appSendCollector.enabled"
    }

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true
    }

    func start(force: Bool = false) {
        guard isEnabled else {
            stop()
            return
        }
        if isTapActive && !force { return }
        stop()

        let mask = (1 << CGEventType.keyDown.rawValue)
        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let collector = Unmanaged<AppSendCollector>.fromOpaque(userInfo).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let port = collector.tapPort {
                        CGEvent.tapEnable(tap: port, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                collector.handleKeyDown(event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            NSLog("PhraseDeck: AppSendCollector tap failed — need Accessibility")
            isTapActive = false
            return
        }

        eventTap = tap
        tapPort = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        isTapActive = true
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        tapPort = nil
        runLoopSource = nil
        isTapActive = false
    }

    nonisolated private func handleKeyDown(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isReturn = keyCode == Int64(kVK_Return) || keyCode == Int64(kVK_ANSI_KeypadEnter)
        guard isReturn else { return }

        // Read before the target app handles Enter and clears the composer.
        // Async capture after send often sees the empty-field placeholder instead.
        let text = Self.readFocusedText()
        DispatchQueue.main.async { [weak self] in
            self?.captureIfNeeded(text: text)
        }
    }

    private func captureIfNeeded(text: String?) {
        guard isEnabled else { return }
        guard !OverlayPanelController.shared.isVisible else { return }

        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              AppConst.watchedBundleIDs.contains(bundleID) else { return }

        guard let text, !text.isEmpty, !PhraseMiner.looksLikeUIChrome(text) else { return }
        let name = app.localizedName ?? bundleID
        if let msg = MessageLogStore.shared.append(text: text, appBundleID: bundleID, appName: name) {
            lastCaptured = msg.text
            lastAppName = name
            NSLog("PhraseDeck captured from \(name): \(msg.text.prefix(80))")
        }
    }

    nonisolated private static let chromeRoles: Set<String> = [
        kAXButtonRole as String,
        kAXStaticTextRole as String,
        kAXMenuItemRole as String,
        kAXMenuRole as String,
        kAXMenuBarItemRole as String,
        kAXPopUpButtonRole as String,
        kAXCheckBoxRole as String,
        kAXRadioButtonRole as String,
        kAXTabGroupRole as String,
        kAXImageRole as String,
        "AXLink",
        "AXToolbar",
        "AXTab",
    ]

    nonisolated private static func readFocusedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return nil }
        let focused = focusedRef as! AXUIElement

        guard let element = resolveTextElement(from: focused) else { return nil }

        let raw: String?
        if let value = axString(element, kAXValueAttribute as String), !value.isEmpty {
            raw = value
        } else if let selected = axString(element, kAXSelectedTextAttribute as String), !selected.isEmpty {
            raw = selected
        } else {
            return nil
        }
        guard let raw else { return nil }

        // Electron often surfaces the placeholder as AXValue when the field is empty.
        if let placeholder = axString(element, kAXPlaceholderValueAttribute as String),
           !placeholder.isEmpty,
           raw == placeholder {
            return nil
        }
        if PhraseMiner.looksLikeUIChrome(raw) {
            return nil
        }
        return raw
    }

    /// Prefer the focused text field. Do not take AXValue from buttons / labels
    /// (Cursor's "Send follow-up" and similar chrome).
    nonisolated private static func resolveTextElement(from focused: AXUIElement) -> AXUIElement? {
        if isChromeRole(focused) {
            var current: AXUIElement? = focused
            for _ in 0..<5 {
                guard let el = current else { break }
                if !isChromeRole(el), axString(el, kAXValueAttribute as String)?.isEmpty == false {
                    return el
                }
                current = axParent(el)
            }
            return nil
        }
        return focused
    }

    nonisolated private static func isChromeRole(_ element: AXUIElement) -> Bool {
        chromeRoles.contains(axString(element, kAXRoleAttribute as String) ?? "")
    }

    nonisolated private static func axParent(_ element: AXUIElement) -> AXUIElement? {
        var parent: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
              let parent else { return nil }
        return (parent as! AXUIElement)
    }

    nonisolated private static func axString(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
              let ref else { return nil }
        if let s = ref as? String { return s }
        if CFGetTypeID(ref) == CFAttributedStringGetTypeID() {
            return CFAttributedStringGetString(unsafeBitCast(ref, to: CFAttributedString.self)) as String
        }
        return nil
    }
}
