import AppKit
import Carbon.HIToolbox

/// Detects double / triple taps of the ⌘ key (left or right).
final class HotKeyManager {
    static let shared = HotKeyManager()

    var onHotKey: (() -> Void)?
    var onTripleHotKey: (() -> Void)?

    private(set) var isTapActive = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    nonisolated(unsafe) private var tapPort: CFMachPort?

    private var commandIsDown = false
    private var sawOtherKeyWhileCommand = false
    private var lastCleanTapAt: CFAbsoluteTime = 0
    private var consecutiveTaps = 0
    private let tapWindow: CFAbsoluteTime = 0.40

    private init() {}

    func register(force: Bool = false) {
        if isTapActive && !force { return }
        unregister()

        let mask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)

        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userInfo).takeUnretainedValue()
                manager.handle(event: event, type: type)
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            NSLog("PhraseDeck: failed to create event tap — grant Accessibility permission")
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
        NSLog("PhraseDeck: command-tap registered")
    }

    func unregister() {
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
        commandIsDown = false
        sawOtherKeyWhileCommand = false
        lastCleanTapAt = 0
        consecutiveTaps = 0
    }

    deinit {
        unregister()
    }

    // MARK: - Event handling

    private func handle(event: CGEvent, type: CGEventType) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = tapPort {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return
        }

        switch type {
        case .keyDown:
            guard commandIsDown else { return }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if !Self.isCommandKeyCode(keyCode) {
                sawOtherKeyWhileCommand = true
            }
        case .flagsChanged:
            handleFlagsChanged(event)
        default:
            break
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard Self.isCommandKeyCode(keyCode) else { return }

        let flags = event.flags
        let cmdDown = flags.contains(.maskCommand)
        let extraModifiers =
            flags.contains(.maskShift)
            || flags.contains(.maskAlternate)
            || flags.contains(.maskControl)

        if cmdDown && !commandIsDown {
            // ⌘ pressed
            commandIsDown = true
            sawOtherKeyWhileCommand = extraModifiers
            return
        }

        if !cmdDown && commandIsDown {
            // ⌘ released
            commandIsDown = false
            let wasCleanTap = !sawOtherKeyWhileCommand && !extraModifiers
            sawOtherKeyWhileCommand = false

            guard wasCleanTap else {
                lastCleanTapAt = 0
                consecutiveTaps = 0
                return
            }

            let now = CFAbsoluteTimeGetCurrent()
            if lastCleanTapAt > 0, now - lastCleanTapAt <= tapWindow {
                consecutiveTaps += 1
            } else {
                consecutiveTaps = 1
            }
            lastCleanTapAt = now

            if consecutiveTaps == 2 {
                DispatchQueue.main.async { [weak self] in
                    self?.onHotKey?()
                }
            } else if consecutiveTaps >= 3 {
                consecutiveTaps = 0
                lastCleanTapAt = 0
                DispatchQueue.main.async { [weak self] in
                    self?.onTripleHotKey?()
                }
            }
        }
    }

    private static func isCommandKeyCode(_ keyCode: Int64) -> Bool {
        keyCode == Int64(kVK_Command) || keyCode == Int64(kVK_RightCommand)
    }
}
