import SwiftUI
import AppKit

@main
struct PhraseDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        ClipboardCollector.shared.start()
        AppSendCollector.shared.start()
        CursorAISummarizer.shared.start()

        HotKeyManager.shared.onHotKey = {
            OverlayPanelController.shared.toggle()
        }
        HotKeyManager.shared.register()

        if !PermissionManager.hasAccessibility {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                PermissionManager.requestAccessibility()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if PermissionManager.hasAccessibility {
                HotKeyManager.shared.register()
                AppSendCollector.shared.start()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyManager.shared.unregister()
        ClipboardCollector.shared.stop()
        AppSendCollector.shared.stop()
        CursorAISummarizer.shared.stop()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "text.badge.plus", accessibilityDescription: "PhraseDeck")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "显示常用短语（连按两次 ⌘）", action: #selector(showOverlay), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "立即 AI 总结", action: #selector(runAI), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "请求辅助功能权限", action: #selector(requestAccess), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 PhraseDeck", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func showOverlay() {
        OverlayPanelController.shared.show()
    }

    @objc private func runAI() {
        Task { await CursorAISummarizer.shared.summarizeNow() }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView()
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "PhraseDeck 设置"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 580, height: 720))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func requestAccess() {
        PermissionManager.requestAccessibility()
        PermissionManager.openAccessibilitySettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
