import AppKit
import Foundation

/// Reads the focused / most recent Composer transcript from Cursor's local SQLite.
struct CursorChatContextProvider: ChatContextProviding {
    let id = "cursor"

    private static let maxChars = 4_000
    private static let maxBubbles = 24

    func canHandle(app: NSRunningApplication) -> Bool {
        AppConst.cursorBundleIDs.contains(app.bundleIdentifier ?? "")
    }

    func fetch(app: NSRunningApplication) async -> ChatContext {
        let appName = app.localizedName ?? "Cursor"
        let bundleID = app.bundleIdentifier ?? ""
        return await Task.detached(priority: .userInitiated) {
            Self.load(appName: appName, bundleID: bundleID)
        }.value
    }

    nonisolated private static func load(appName: String, bundleID: String) -> ChatContext {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cursor/User", isDirectory: true)
        let globalDB = support.appendingPathComponent("globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: globalDB.path),
              let db = ReadOnlySQLite(url: globalDB) else {
            return ChatContext(
                appName: appName,
                bundleID: bundleID,
                source: "cursor",
                title: nil,
                text: "",
                note: "读不到 Cursor 本地会话库。"
            )
        }

        guard let composer = resolveComposer(db: db, userRoot: support) else {
            return ChatContext(
                appName: appName,
                bundleID: bundleID,
                source: "cursor",
                title: nil,
                text: "",
                note: "Cursor 里没有找到当前会话。"
            )
        }

        let raw = db.string(
            sql: "SELECT value FROM cursorDiskKV WHERE key = ?",
            params: ["composerData:\(composer.id)"]
        )
        guard let raw, let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ChatContext(
                appName: appName,
                bundleID: bundleID,
                source: "cursor",
                title: composer.name,
                text: "",
                note: "当前会话没有可读的聊天内容。"
            )
        }

        let title = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? composer.name
        let headers = json["fullConversationHeadersOnly"] as? [[String: Any]] ?? []
        let lines = transcript(db: db, composerId: composer.id, headers: headers)
        let joined = lines.joined(separator: "\n")
        let text = joined.count > maxChars ? String(joined.suffix(maxChars)) : joined
        return ChatContext(
            appName: appName,
            bundleID: bundleID,
            source: "cursor",
            title: title,
            text: text,
            note: text.isEmpty ? "当前会话没有可读的聊天内容。" : nil
        )
    }

    nonisolated private static func resolveComposer(db: ReadOnlySQLite, userRoot: URL) -> (id: String, name: String?)? {
        let latest = db.rows(
            sql: """
            SELECT composerId, workspaceId, value FROM composerHeaders
            WHERE IFNULL(isArchived, 0) = 0 AND IFNULL(isSubagent, 0) = 0
            ORDER BY lastUpdatedAt DESC LIMIT 1
            """
        ).first
        guard let latest, let latestID = latest.first, !latestID.isEmpty else { return nil }
        let workspaceID = latest.count > 1 ? latest[1] : ""
        let headerName = composerName(from: latest.count > 2 ? latest[2] : "")

        if !workspaceID.isEmpty {
            let wsDB = userRoot
                .appendingPathComponent("workspaceStorage/\(workspaceID)/state.vscdb")
            if let selected = selectedComposerID(workspaceDB: wsDB),
               db.string(sql: "SELECT key FROM cursorDiskKV WHERE key = ?", params: ["composerData:\(selected)"]) != nil {
                return (selected, headerName)
            }
        }
        return (latestID, headerName)
    }

    nonisolated private static func selectedComposerID(workspaceDB: URL) -> String? {
        guard FileManager.default.fileExists(atPath: workspaceDB.path),
              let db = ReadOnlySQLite(url: workspaceDB),
              let raw = db.string(sql: "SELECT value FROM ItemTable WHERE key = 'composer.composerData'"),
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let selected = json["selectedComposerIds"] as? [String]
        let focused = json["lastFocusedComposerIds"] as? [String]
        return selected?.first ?? focused?.first
    }

    nonisolated private static func composerName(from value: String) -> String? {
        guard let data = value.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String, !name.isEmpty else {
            return nil
        }
        return name
    }

    nonisolated private static func transcript(
        db: ReadOnlySQLite,
        composerId: String,
        headers: [[String: Any]]
    ) -> [String] {
        var candidates: [String] = []
        for header in headers {
            let grouping = header["grouping"] as? [String: Any]
            let hasText = grouping?["hasText"] as? Bool ?? false
            let type = header["type"] as? Int ?? 0
            guard hasText || type == 1 else { continue }
            guard let bubbleId = header["bubbleId"] as? String, !bubbleId.isEmpty else { continue }
            candidates.append(bubbleId)
        }
        let recent = Array(candidates.suffix(maxBubbles))
        var lines: [String] = []
        for bubbleId in recent {
            let raw = db.string(
                sql: "SELECT value FROM cursorDiskKV WHERE key = ?",
                params: ["bubbleId:\(composerId):\(bubbleId)"]
            )
            guard let raw, let data = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let text = (json["text"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { continue }
            let role = (json["type"] as? Int) == 1 ? "用户" : "助手"
            lines.append("\(role)：\(text)")
        }
        return lines
    }
}
