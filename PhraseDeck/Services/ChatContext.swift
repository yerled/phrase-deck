import AppKit
import Foundation

struct ChatContext {
    var appName: String
    var bundleID: String
    /// Provider id, e.g. `cursor`, `unsupported`, `none`.
    var source: String
    var title: String?
    var text: String
    var note: String?

    var isUseful: Bool {
        Self.isUseful(text)
    }

    static func isUseful(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let alnum = trimmed.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || (0x4E00...0x9FFF).contains($0.value)
        }
        return alnum.count >= 8
    }
}

/// Per-app strategy for reading the chat currently on screen.
protocol ChatContextProviding {
    var id: String { get }
    func canHandle(app: NSRunningApplication) -> Bool
    func fetch(app: NSRunningApplication) async -> ChatContext
}

enum ChatContextResolver {
    /// Register a new app here when it has a dedicated reader.
    private static let providers: [ChatContextProviding] = [
        CursorChatContextProvider(),
    ]

    static func frontmostApp() -> NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            return front
        }
        let running = NSWorkspace.shared.runningApplications
        if let watched = running.first(where: {
            AppConst.watchedBundleIDs.contains($0.bundleIdentifier ?? "") && $0.isActive
        }) {
            return watched
        }
        return running.first { AppConst.watchedBundleIDs.contains($0.bundleIdentifier ?? "") }
    }

    static func fetch(app: NSRunningApplication?) async -> ChatContext {
        guard let app else {
            return ChatContext(
                appName: "",
                bundleID: "",
                source: "none",
                title: nil,
                text: "",
                note: "没有找到前台窗口。"
            )
        }
        let appName = app.localizedName ?? app.bundleIdentifier ?? "?"
        let bundleID = app.bundleIdentifier ?? ""
        if let provider = providers.first(where: { $0.canHandle(app: app) }) {
            return await provider.fetch(app: app)
        }
        return unsupported(appName: appName, bundleID: bundleID)
    }

    static func unsupported(appName: String, bundleID: String) -> ChatContext {
        let hint: String
        if AppConst.feishuBundleIDs.contains(bundleID) {
            hint = "飞书暂未实现聊天原文读取，无法获取到聊天文本。"
        } else {
            hint = "当前是 \(appName)，暂无对应实现，无法获取到聊天文本。"
        }
        return ChatContext(
            appName: appName,
            bundleID: bundleID,
            source: "unsupported",
            title: nil,
            text: "",
            note: hint
        )
    }
}
