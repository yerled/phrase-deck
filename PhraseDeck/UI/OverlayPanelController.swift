import AppKit
import SwiftUI
import Carbon.HIToolbox

@MainActor
final class OverlayPanelController: NSObject, ObservableObject {
    static let shared = OverlayPanelController()

    enum Presentation {
        case phrases
        case smartReply
    }

    @Published private(set) var presentation: Presentation = .phrases
    @Published private(set) var phrases: [Phrase] = []
    @Published private(set) var smartStatus: String = ""
    @Published private(set) var smartSuggestions: [SmartReplySuggestion] = []
    @Published private(set) var smartNote: String?
    @Published private(set) var debugLog: [String] = []

    private var panel: NSPanel?
    private var keyTap: CFMachPort?
    private var keyTapSource: CFRunLoopSource?
    private var generation = 0
    private var elapsedTimer: Timer?
    private var smartStartedAt: Date?
    private var relayoutWork: DispatchWorkItem?

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
        generation += 1
        presentation = .phrases
        phrases = PhraseStore.shared.topPhrases(limit: 10)
        smartSuggestions = []
        smartNote = nil
        smartStatus = ""
        debugLog = []
        stopElapsed()
        presentPanel()
    }

    func showSmartReply() {
        if isVisible {
            dismiss()
        }
        let target = ChatContextResolver.frontmostApp()
        generation += 1
        let token = generation

        presentation = .smartReply
        phrases = []
        smartSuggestions = SmartReplyGenerator.defaults
        smartNote = nil
        debugLog = []
        smartStatus = "正在识别当前 App…"
        presentPanel()
        syncActiveTexts()
        let debugDir = DebugSessionLog.begin()
        appendDebug("完整日志：\(debugDir.path)")
        if let target {
            appendDebug("当前 App：\(target.localizedName ?? "?")  \(target.bundleIdentifier ?? "")")
        } else {
            appendDebug("没有找到前台窗口")
        }
        startElapsed(status: "正在读取聊天原文")

        Task { @MainActor in
            guard token == generation else { return }
            let context = await ChatContextResolver.fetch(app: target)
            guard token == generation else { return }
            appendDebug("来源 \(context.source)，标题 \(context.title ?? "无")，\(context.text.count) 字")
            if let note = context.note {
                appendDebug(note)
            }
            if context.isUseful {
                let preview = context.text.replacingOccurrences(of: "\n", with: " ")
                appendDebug("预览：\(preview.suffix(80))")
                DebugSessionLog.write(debugDir, "context.txt", context.text)
                startElapsed(status: "正在调用 Cursor Agent")
            } else {
                startElapsed(status: "无法获取聊天文本，保留默认回复")
            }

            let result = await SmartReplyGenerator.generate(from: context, debugDir: debugDir) { [weak self] line in
                DispatchQueue.main.async { self?.appendDebug(line) }
            }
            guard token == generation else { return }
            stopElapsed()
            if !result.suggestions.isEmpty {
                smartSuggestions = result.suggestions
            }
            smartNote = result.note
            smartStatus = ""
            if let note = result.note, !note.isEmpty {
                appendDebug(note)
            } else {
                let enhanced = smartSuggestions.filter { $0.origin == .enhanced }.count
                let added = smartSuggestions.filter { $0.origin == .added }.count
                appendDebug("完成：增强 \(enhanced) 条，新增 \(added) 条，共 \(smartSuggestions.count) 条")
            }
            syncActiveTexts()
            scheduleRelayout()
        }
    }

    func dismiss() {
        generation += 1
        removeKeyTap()
        panel?.orderOut(nil)
        panel = nil
        activeTexts = []
        smartSuggestions = []
        smartNote = nil
        smartStatus = ""
        debugLog = []
        stopElapsed()
        relayoutWork?.cancel()
        relayoutWork = nil
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

        syncActiveTexts()
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

    func selectSuggestion(_ suggestion: SmartReplySuggestion) {
        insertText(suggestion.text)
    }

    private func syncActiveTexts() {
        switch presentation {
        case .phrases:
            activeTexts = phrases.map(\.text)
        case .smartReply:
            activeTexts = smartSuggestions.map(\.text)
        }
    }

    func appendDebug(_ message: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.appendDebug(message)
            }
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(message)"
        debugLog.append(line)
        if debugLog.count > 40 {
            debugLog.removeFirst(debugLog.count - 40)
        }
        NSLog("PhraseDeck \(message)")
        if let dir = DebugSessionLog.currentDirectory {
            DebugSessionLog.append(dir, "overlay.log", line + "\n")
        }
        scheduleRelayout()
    }

    private func startElapsed(status: String) {
        stopElapsed()
        smartStartedAt = Date()
        smartStatus = "\(status)…"
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let started = self.smartStartedAt else { return }
                let seconds = Int(Date().timeIntervalSince(started))
                self.smartStatus = "\(status)… \(seconds)s"
            }
        }
    }

    private func stopElapsed() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        smartStartedAt = nil
    }

    private var panelWidth: CGFloat {
        presentation == .smartReply ? 520 : 440
    }

    private var estimatedHeight: CGFloat {
        switch presentation {
        case .phrases:
            if phrases.isEmpty { return 120 }
            return 52 + 16 + CGFloat(phrases.count) * 48
        case .smartReply:
            let logH = min(168, 28 + CGFloat(debugLog.count) * 15)
            if !smartSuggestions.isEmpty {
                let note = smartNote == nil ? 0 : 36
                return 52 + 16 + CGFloat(note) + CGFloat(smartSuggestions.count) * 64 + logH
            }
            return 70 + 48 + logH
        }
    }

    private func scheduleRelayout() {
        relayoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async { self?.relayout() }
        }
        relayoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
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
                self.insertText(snapshot[index], phrase: index < self.phrases.count ? self.phrases[index] : nil)
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
