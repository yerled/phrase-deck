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

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    nonisolated(unsafe) private var tapPort: CFMachPort?

    private enum Keys {
        static let enabled = "appSendCollector.enabled"
    }

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true
    }

    func start() {
        stop()
        guard isEnabled else { return }

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
            return
        }

        eventTap = tap
        tapPort = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
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
    }

    nonisolated private func handleKeyDown(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isReturn = keyCode == Int64(kVK_Return) || keyCode == Int64(kVK_ANSI_KeypadEnter)
        guard isReturn else { return }

        let flags = event.flags
        DispatchQueue.main.async { [weak self] in
            self?.captureIfNeeded(flags: flags)
        }
    }

    private func captureIfNeeded(flags: CGEventFlags) {
        guard isEnabled else { return }
        guard !OverlayPanelController.shared.isVisible else { return }

        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              AppConst.watchedBundleIDs.contains(bundleID) else { return }

        // Ignore pure modifier-less? Capture both Enter and ⌘Enter
        _ = flags

        guard let text = Self.readFocusedText(), !text.isEmpty else { return }
        let name = app.localizedName ?? bundleID
        if let msg = MessageLogStore.shared.append(text: text, appBundleID: bundleID, appName: name) {
            lastCaptured = msg.text
            lastAppName = name
            NSLog("PhraseDeck captured from \(name): \(msg.text.prefix(80))")
        }
    }

    private static func readFocusedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return nil }
        let focused = focusedRef as! AXUIElement

        if let value = axString(focused, kAXValueAttribute as String), !value.isEmpty {
            return value
        }
        // Some Electron fields expose selected text / placeholder differently
        if let selected = axString(focused, kAXSelectedTextAttribute as String), !selected.isEmpty {
            return selected
        }
        // Walk up a few parents looking for a text value
        var current: AXUIElement? = focused
        for _ in 0..<5 {
            guard let el = current else { break }
            if let value = axString(el, kAXValueAttribute as String), value.count >= 2 {
                return value
            }
            var parent: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parent) == .success,
               let parent {
                current = (parent as! AXUIElement)
            } else {
                break
            }
        }
        return nil
    }

    private static func axString(_ element: AXUIElement, _ attr: String) -> String? {
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
