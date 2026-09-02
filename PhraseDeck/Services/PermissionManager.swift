import AppKit
import ApplicationServices

/// Tracks Accessibility and re-installs event taps after the user grants it.
/// `AXIsProcessTrusted()` can flip to true while the process is running, but a tap created
/// (or attempted) before the grant stays dead until we call `CGEvent.tapCreate` again.
@MainActor
final class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    @Published private(set) var accessibilityTrusted = false
    @Published private(set) var hotKeyTapActive = false
    @Published private(set) var sendTapActive = false
    @Published private(set) var needsRelaunch = false

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    private var pollTimer: Timer?
    private var started = false

    private init() {}

    func startWatching() {
        guard !started else { return }
        started = true
        listenForAccessibilityChange()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncTaps(force: false)
            }
        }
        requestMissingPermissions()
        syncTaps(force: true)
        startPoll()
    }

    func refreshFromSettings() {
        requestMissingPermissions()
        syncTaps(force: true)
        startPoll()
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func relaunch() {
        let path = Bundle.main.bundlePath
        let quoted = "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \(quoted)"]
        try? task.run()
        NSApp.terminate(nil)
    }

    func syncTaps(force: Bool) {
        accessibilityTrusted = AXIsProcessTrusted()

        if accessibilityTrusted {
            HotKeyManager.shared.register(force: force)
            AppSendCollector.shared.start(force: force)
        }

        hotKeyTapActive = HotKeyManager.shared.isTapActive
        sendTapActive = AppSendCollector.shared.isTapActive
        // Grant is recorded, but this process still cannot create a tap until a full relaunch.
        needsRelaunch = accessibilityTrusted && !hotKeyTapActive
        startPoll()
    }

    private func requestMissingPermissions() {
        if !AXIsProcessTrusted() {
            Self.requestAccessibility()
        }
    }

    private func startPoll() {
        pollTimer?.invalidate()
        let interval: TimeInterval = (hotKeyTapActive && !needsRelaunch) ? 5.0 : 1.0
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.syncTaps(force: false)
            }
        }
    }

    private func listenForAccessibilityChange() {
        let name = "com.apple.accessibility.api" as CFString
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    PermissionManager.shared.syncTaps(force: false)
                }
            },
            name,
            nil,
            .deliverImmediately
        )
    }
}
