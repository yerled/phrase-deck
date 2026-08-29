import Foundation
import AppKit

struct AIPhraseSuggestion: Codable {
    var text: String
    var weight: Int?
}

@MainActor
final class CursorAISummarizer: ObservableObject {
    static let shared = CursorAISummarizer()

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled) }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var lastRunAt: Date?
    @Published private(set) var lastStatus: String = "尚未运行"
    @Published var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: Keys.apiKey) }
    }

    private var timer: Timer?
    private let workDir: URL

    private enum Keys {
        static let enabled = "cursorAI.enabled"
        static let apiKey = "cursorAI.apiKey"
        static let lastRun = "cursorAI.lastRunAt"
    }

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true
        apiKey = UserDefaults.standard.string(forKey: Keys.apiKey) ?? ProcessInfo.processInfo.environment["CURSOR_API_KEY"] ?? ""
        if let t = UserDefaults.standard.object(forKey: Keys.lastRun) as? Date {
            lastRunAt = t
        }
        workDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PhraseDeck/ai-workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    func start() {
        stop()
        guard isEnabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: AppConst.summarizeIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.summarizeIfNeeded(reason: "定时 30 分钟")
            }
        }
        // First pass shortly after launch if there is pending data
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            Task { @MainActor in
                await self?.summarizeIfNeeded(reason: "启动后首次")
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func summarizeNow() async {
        await summarizeIfNeeded(reason: "手动触发", force: true)
    }

    private func summarizeIfNeeded(reason: String, force: Bool = false) async {
        guard isEnabled || force else { return }
        guard !isRunning else { return }

        let pending = MessageLogStore.shared.pendingMessages(limit: AppConst.maxMessagesPerSummarize)
        guard pending.count >= 3 || force else {
            lastStatus = "待总结消息不足（\(pending.count)），跳过"
            return
        }
        guard !pending.isEmpty else {
            lastStatus = "没有新消息"
            return
        }

        isRunning = true
        lastStatus = "正在用 Cursor Agent 总结（\(reason)）…"
        defer { isRunning = false }

        do {
            let suggestions = try await runCursorAgent(messages: pending)
            PhraseStore.shared.applyAISuggestions(suggestions)
            MessageLogStore.shared.markSummarized(ids: pending.map(\.id))
            let now = Date()
            lastRunAt = now
            UserDefaults.standard.set(now, forKey: Keys.lastRun)
            lastStatus = "成功：写入 \(suggestions.count) 条短语（基于 \(pending.count) 条消息）"
        } catch {
            // Fallback: local mining so the tool still improves offline
            for msg in pending {
                for candidate in PhraseMiner.extractCandidates(from: msg.text) {
                    _ = PhraseStore.shared.record(candidate, source: .mined)
                }
            }
            MessageLogStore.shared.markSummarized(ids: pending.map(\.id))
            lastStatus = "Cursor AI 失败，已本地提炼：\(error.localizedDescription)"
            NSLog("PhraseDeck AI summarize failed: \(error)")
        }
    }

    private func runCursorAgent(messages: [SentMessage]) async throws -> [AIPhraseSuggestion] {
        let agentPath = Self.resolveAgentPath()
        guard FileManager.default.isExecutableFile(atPath: agentPath) else {
            throw NSError(domain: "PhraseDeck", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "未找到 agent CLI（\(agentPath)）。请安装 Cursor Agent 或配置 PATH。",
            ])
        }

        let prompt = Self.buildPrompt(messages: messages)
        var args = [
            "-p",
            "--mode", "ask",
            "--output-format", "text",
            "--workspace", workDir.path,
            prompt,
        ]
        if !apiKey.isEmpty {
            args.insert(contentsOf: ["--api-key", apiKey], at: 0)
        }

        let output = try await Self.runProcess(launchPath: agentPath, arguments: args, environmentAPIKey: apiKey)
        return try Self.parseSuggestions(from: output)
    }

    private static func buildPrompt(messages: [SentMessage]) -> String {
        var lines: [String] = []
        lines.append("你是个人常用语提炼助手。根据我在飞书(Lark)和 Cursor 里发出的消息，提炼可复用的日常短语。")
        lines.append("要求：")
        lines.append("1. 保留我的语气；去掉一次性上下文（人名、具体链接、一次性数字、代码）。")
        lines.append("2. 每条尽量短，可直接粘贴发送（中英文都可）。")
        lines.append("3. 输出 10~30 条。")
        lines.append("4. 只输出 JSON 数组，不要 markdown，不要解释。格式：")
        lines.append("[{\"text\":\"收到，我这边确认一下。\",\"weight\":8},{\"text\":\"LGTM\",\"weight\":6}]")
        lines.append("weight 为 1~10，表示推荐常用程度。")
        lines.append("")
        lines.append("消息列表：")
        for (i, msg) in messages.enumerated() {
            let oneLine = msg.text.replacingOccurrences(of: "\n", with: " ")
            lines.append("\(i + 1). [\(msg.appName)] \(oneLine)")
        }
        return lines.joined(separator: "\n")
    }

    private static func parseSuggestions(from raw: String) throws -> [AIPhraseSuggestion] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Extract JSON array even if wrapped in prose / fences
        guard let start = trimmed.firstIndex(of: "["),
              let end = trimmed.lastIndex(of: "]"),
              start < end else {
            throw NSError(domain: "PhraseDeck", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Agent 输出里没有 JSON 数组",
            ])
        }
        let json = String(trimmed[start...end])
        let data = Data(json.utf8)
        let items = try JSONDecoder().decode([AIPhraseSuggestion].self, from: data)
        return items.filter { PhraseMiner.isEligiblePhrase($0.text) || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func resolveAgentPath() -> String {
        let candidates = [
            NSString(string: "~/.local/bin/agent").expandingTildeInPath,
            "/usr/local/bin/agent",
            "/opt/homebrew/bin/agent",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return candidates[0]
    }

    private static func runProcess(launchPath: String, arguments: [String], environmentAPIKey: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            if !environmentAPIKey.isEmpty {
                env["CURSOR_API_KEY"] = environmentAPIKey
            }
            // Ensure login agent can find credentials under user home
            env["HOME"] = NSHomeDirectory()
            process.environment = env

            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                let outStr = String(data: outData, encoding: .utf8) ?? ""
                let errStr = String(data: errData, encoding: .utf8) ?? ""

                if process.terminationStatus != 0, outStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continuation.resume(throwing: NSError(domain: "PhraseDeck", code: Int(process.terminationStatus), userInfo: [
                        NSLocalizedDescriptionKey: errStr.isEmpty ? "agent 退出码 \(process.terminationStatus)" : errStr,
                    ]))
                    return
                }
                // Prefer stdout; some errors still print useful JSON on stdout
                let combined = outStr.isEmpty ? errStr : outStr
                if combined.localizedCaseInsensitiveContains("Authentication required") {
                    continuation.resume(throwing: NSError(domain: "PhraseDeck", code: 401, userInfo: [
                        NSLocalizedDescriptionKey: "需要 Cursor 登录：终端执行 agent login，或在设置里填 CURSOR_API_KEY",
                    ]))
                    return
                }
                continuation.resume(returning: combined)
            }
        }
    }
}
