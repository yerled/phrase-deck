import AppKit
import SwiftUI
import Carbon.HIToolbox

@MainActor
final class OverlayPanelController: NSObject, ObservableObject {
    static let shared = OverlayPanelController()

    @Published private(set) var phrases: [Phrase] = []

    private var panel: NSPanel?
    private var keyTap: CFMachPort?
    private var keyTapSource: CFRunLoopSource?

    /// Snapshot readable from the CGEvent tap thread.
    nonisolated(unsafe) private var activeTexts: [String] = []
    nonisolated(unsafe) private var tapPort: CFMachPort?

    private override init() {
        super.init()
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        if isVisible {
            dismiss()
        } else {
            show()
        }
    }

    func show() {
        phrases = PhraseStore.shared.topPhrases(limit: 10)
        presentPanel()
    }

    func dismiss() {
        removeKeyTap()
        panel?.orderOut(nil)
        panel = nil
        activeTexts = []
    }

    private func presentPanel() {
        if panel == nil {
            let hosting = NSHostingView(rootView: OverlayView(controller: self))
            hosting.sizingOptions = [.intrinsicContentSize]
            hosting.frame = NSRect(x: 0, y: 0, width: panelWidth, height: estimatedHeight)

            let panel = NSPanel(
                contentRect: hosting.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.animationBehavior = .none
            panel.contentView = hosting
            panel.isMovableByWindowBackground = false
            self.panel = panel
            installKeyTap()
        } else {
            relayout()
        }

        activeTexts = phrases.map(\.text)
        if let panel {
            positionNearMouse(panel)
            panel.orderFrontRegardless()
        }
    }

    private func insertText(_ text: String, phrase: Phrase? = nil) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let phrase {
                PhraseStore.shared.markUsed(phrase.id)
            }
            _ = TextInserter.insert(text)
        }
    }

    func selectPhrase(_ phrase: Phrase) {
        insertText(phrase.text, phrase: phrase)
    }

    private var panelWidth: CGFloat { 440 }

    private var estimatedHeight: CGFloat {
        if phrases.isEmpty { return 120 }
        return 52 + 16 + CGFloat(phrases.count) * 48
    }

    private func relayout() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.relayout() }
            return
        }
        guard let panel else { return }
        let size = NSSize(width: panelWidth, height: estimatedHeight)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        panel.setContentSize(size)
        NSAnimationContext.endGrouping()
        positionNearMouse(panel)
    }

    private func positionNearMouse(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let size = panel.frame.size
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 12)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
    }

    // MARK: - Key interception (must swallow digits so they don't reach the focused field)

    private func installKeyTap() {
        removeKeyTap()

        let mask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                let controller = Unmanaged<OverlayPanelController>.fromOpaque(userInfo).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let port = controller.tapPort {
                        CGEvent.tapEnable(tap: port, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }

                if controller.shouldSwallow(event: event, type: type) {
                    return nil
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            NSLog("PhraseDeck: overlay key tap failed — check Accessibility permission")
            return
        }

        keyTap = tap
        tapPort = tap
        keyTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let keyTapSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), keyTapSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeKeyTap() {
        if let keyTap {
            CGEvent.tapEnable(tap: keyTap, enable: false)
        }
        if let keyTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), keyTapSource, .commonModes)
        }
        keyTap = nil
        tapPort = nil
        keyTapSource = nil
    }

    /// Called from the CGEvent tap callback (may be off main).
    nonisolated private func shouldSwallow(event: CGEvent, type: CGEventType) -> Bool {
        guard type == .keyDown || type == .keyUp else { return false }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            return false
        }

        if keyCode == Int64(kVK_Escape) {
            if type == .keyDown {
                DispatchQueue.main.async { [weak self] in
                    self?.dismiss()
                }
            }
            return true
        }

        guard let index = Self.indexForKeyCode(keyCode) else { return false }
        let snapshot = activeTexts

        if type == .keyDown {
            DispatchQueue.main.async { [weak self] in
                guard let self, index < snapshot.count else { return }
                let phrase = self.phrases.first { $0.text == snapshot[index] }
                self.insertText(snapshot[index], phrase: phrase)
            }
        }
        return true
    }

    nonisolated private static func indexForKeyCode(_ keyCode: Int64) -> Int? {
        switch keyCode {
        case Int64(kVK_ANSI_1): return 0
        case Int64(kVK_ANSI_2): return 1
        case Int64(kVK_ANSI_3): return 2
        case Int64(kVK_ANSI_4): return 3
        case Int64(kVK_ANSI_5): return 4
        case Int64(kVK_ANSI_6): return 5
        case Int64(kVK_ANSI_7): return 6
        case Int64(kVK_ANSI_8): return 7
        case Int64(kVK_ANSI_9): return 8
        case Int64(kVK_ANSI_0): return 9
        default: return nil
        }
    }
}
