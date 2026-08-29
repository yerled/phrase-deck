import AppKit
import SwiftUI

@MainActor
final class OverlayPanelController: NSObject {
    static let shared = OverlayPanelController()

    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var localMonitor: Any?

    private override init() {
        super.init()
    }

    func toggle() {
        if panel?.isVisible == true {
            dismiss()
        } else {
            show()
        }
    }

    func show() {
        dismiss()

        let phrases = PhraseStore.shared.topPhrases(limit: 10)
        let hosting = NSHostingView(
            rootView: OverlayView(
                phrases: phrases,
                onSelect: { [weak self] phrase, _ in
                    self?.insert(phrase)
                },
                onDismiss: { [weak self] in
                    self?.dismiss()
                }
            )
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 420, height: max(120, 44 + phrases.count * 44))

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
        panel.contentView = hosting
        panel.isMovableByWindowBackground = true

        positionNearMouse(panel)
        panel.orderFrontRegardless()
        self.panel = panel

        installKeyMonitors(phrases: phrases)
    }

    func dismiss() {
        removeKeyMonitors()
        panel?.orderOut(nil)
        panel = nil
    }

    private func insert(_ phrase: Phrase) {
        dismiss()
        // Slight delay so panel resigns and focus returns to previous app
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            PhraseStore.shared.markUsed(phrase.id)
            _ = TextInserter.insert(phrase.text)
        }
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

    private func installKeyMonitors(phrases: [Phrase]) {
        removeKeyMonitors()

        let handler: (NSEvent) -> NSEvent? = { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { // Esc
                    self.dismiss()
                    return nil
                }
                if let index = Self.indexForKey(event) {
                    if index < phrases.count {
                        self.insert(phrases[index])
                        return nil
                    }
                }
            }
            return event
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            _ = handler(event)
        }
    }

    private func removeKeyMonitors() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    /// Maps keys 1…9,0 → indices 0…9
    private static func indexForKey(_ event: NSEvent) -> Int? {
        // Prefer characters ignoring modifiers
        guard let chars = event.charactersIgnoringModifiers, let ch = chars.first else { return nil }
        switch ch {
        case "1": return 0
        case "2": return 1
        case "3": return 2
        case "4": return 3
        case "5": return 4
        case "6": return 5
        case "7": return 6
        case "8": return 7
        case "9": return 8
        case "0": return 9
        default: return nil
        }
    }
}
