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

        let phrases = PhraseStore.shared.phrases
        let messages = MessageLogStore.shared.messages
        guard !messages.isEmpty || force else {
            lastStatus = "没有发送日志，跳过"
            return
        }
        guard !messages.isEmpty || !phrases.isEmpty else {
            lastStatus = "没有短语和日志，跳过"
            return
        }

        isRunning = true
        lastStatus = "正在全量总结（\(phrases.count) 条短语 + \(messages.count) 条日志，\(reason)）…"
        defer { isRunning = false }

        do {
            let suggestions = try await runCursorAgent(phrases: phrases, messages: messages)
            guard !suggestions.isEmpty else {
                throw NSError(domain: "PhraseDeck", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Agent 返回空短语列表，已保留现有短语库",
                ])
            }
            PhraseStore.shared.replaceAll(with: suggestions)
            let now = Date()
            lastRunAt = now
            UserDefaults.standard.set(now, forKey: Keys.lastRun)
            lastStatus = "成功：短语库更新为 \(suggestions.count) 条（基于 \(phrases.count) 条原短语 + \(messages.count) 条日志）"
        } catch {
            for msg in messages {
                for candidate in PhraseMiner.extractCandidates(from: msg.text) {
                    _ = PhraseStore.shared.record(candidate, source: .mined)
                }
            }
            lastStatus = "Cursor AI 失败，已本地提炼（未替换短语库）：\(error.localizedDescription)"
            NSLog("PhraseDeck AI summarize failed: \(error)")
        }
    }

    private func runCursorAgent(phrases: [Phrase], messages: [SentMessage]) async throws -> [AIPhraseSuggestion] {
        let agentPath = Self.resolveAgentPath()
        guard FileManager.default.isExecutableFile(atPath: agentPath) else {
            throw NSError(domain: "PhraseDeck", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "未找到 agent CLI（\(agentPath)）。请安装 Cursor Agent 或配置 PATH。",
            ])
        }

        try writeWorkspaceInputs(phrases: phrases, messages: messages)
        let prompt = Self.buildPrompt(phrases: phrases, messages: messages)

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

    private func writeWorkspaceInputs(phrases: [Phrase], messages: [SentMessage]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let phrasePayload = phrases.map {
            WorkspacePhrase(text: $0.text, count: $0.count, source: $0.source.rawValue)
        }
        let messagePayload = messages.map {
            WorkspaceMessage(text: $0.text, appName: $0.appName, createdAt: $0.createdAt)
        }

        try encoder.encode(phrasePayload).write(
            to: workDir.appendingPathComponent("input-phrases.json"),
            options: [.atomic]
        )
        try encoder.encode(messagePayload).write(
            to: workDir.appendingPathComponent("input-messages.json"),
            options: [.atomic]
        )
    }

    private static func buildPrompt(phrases: [Phrase], messages: [SentMessage]) -> String {
        var lines: [String] = []
        lines.append("你是个人常用语库维护助手。每次都是全量重建：根据「当前短语库」和「全部发送日志」，输出更新后的完整短语库。")
        lines.append("工作区文件（全量，必须读完，禁止抽样）：")
        lines.append("- input-phrases.json：当前短语库")
        lines.append("- input-messages.json：全部发送日志")
        lines.append("要求：")
        lines.append("1. 只保留工作、生活里可直接粘贴复用的话（打招呼、确认、约时间、致谢、催进度、请假、回复收到、同步进展等）。")
        lines.append("2. 丢弃：一次性上下文、人名、具体链接、验证码、密码、代码、无意义碎片、过长不可复用的整段、纯数字/邮箱/URL、明显是调试或命令输出的内容。")
        lines.append("3. 合并近义重复，保留更自然、更短、可直接发送的写法。")
        lines.append("4. source=manual 的有用短语应保留，除非明显无意义。")
        lines.append("5. 必须完整覆盖全部日志与现有短语，不要只输出 Top N，没有数量上限。有多少条真正可复用就输出多少条。不要编造日志和短语库里都没有依据的句子。")
        lines.append("6. 只输出 JSON 数组，不要 markdown，不要解释。格式：")
        lines.append("[{\"text\":\"收到，我这边确认一下。\",\"weight\":8},{\"text\":\"LGTM\",\"weight\":6}]")
        lines.append("weight 为正整数，表示常用程度（可按日志出现次数 + 原 count 估计，不设上限）。")

        let inline = compactCorpus(phrases: phrases, messages: messages)
        if inline.utf8.count <= 80_000 {
            lines.append("")
            lines.append(inline)
        } else {
            lines.append("")
            lines.append("语料较大，请直接读取工作区里的两个 JSON 文件，不要只根据下面摘要判断。")
            lines.append("当前短语 \(phrases.count) 条，发送日志 \(messages.count) 条。")
        }
        return lines.joined(separator: "\n")
    }

    private static func compactCorpus(phrases: [Phrase], messages: [SentMessage]) -> String {
        var lines: [String] = []
        lines.append("当前短语库：")
        if phrases.isEmpty {
            lines.append("（空）")
        } else {
            for (i, phrase) in phrases.enumerated() {
                lines.append("\(i + 1). [count=\(phrase.count), source=\(phrase.source.rawValue)] \(oneLine(phrase.text))")
            }
        }
        lines.append("")
        lines.append("发送日志：")
        if messages.isEmpty {
            lines.append("（空）")
        } else {
            for (i, msg) in messages.enumerated() {
                lines.append("\(i + 1). [\(msg.appName)] \(oneLine(msg.text))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
    }

    private static func parseSuggestions(from raw: String) throws -> [AIPhraseSuggestion] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
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
        return items.filter { PhraseMiner.isEligiblePhrase($0.text) }
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

private struct WorkspacePhrase: Encodable {
    var text: String
    var count: Int
    var source: String
}

private struct WorkspaceMessage: Encodable {
    var text: String
    var appName: String
    var createdAt: Date
}
