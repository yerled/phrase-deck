import Foundation

enum AppConst {
    /// Feishu / Lark
    static let feishuBundleIDs: Set<String> = [
        "com.electron.lark",
        "com.larksuite.lark.macos",
        "com.bytedance.macos.feishu",
    ]

    /// Cursor IDE
    static let cursorBundleIDs: Set<String> = [
        "com.todesktop.230313mzl4w4u92",
        "com.cursor",
    ]

    static var watchedBundleIDs: Set<String> {
        feishuBundleIDs.union(cursorBundleIDs)
    }

    static let summarizeIntervalSeconds: TimeInterval = 30 * 60
    static let maxLoggedMessages = 3000
}
