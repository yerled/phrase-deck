import Foundation

enum SmartReplyOrigin: String {
    case canned
    case enhanced
    case added
}

struct SmartReplySuggestion: Identifiable, Equatable {
    var id: UUID
    var direction: String
    var text: String
    var slot: String?
    var origin: SmartReplyOrigin

    init(
        id: UUID = UUID(),
        direction: String,
        text: String,
        slot: String? = nil,
        origin: SmartReplyOrigin = .canned
    ) {
        self.id = id
        self.direction = direction
        self.text = text
        self.slot = slot
        self.origin = origin
    }

    var badge: String {
        switch origin {
        case .canned: return direction
        case .enhanced: return "\(direction)·增强"
        case .added: return "\(direction)·新增"
        }
    }
}

private struct AIReplyDraft: Decodable {
    var direction: String
    var text: String
    var action: String?
    var base: String?
}

enum SmartReplyGenerator {
    static let defaults: [SmartReplySuggestion] = [
        SmartReplySuggestion(direction: "收到", text: "收到，我看一下。", slot: "收到"),
        SmartReplySuggestion(direction: "确认处理", text: "好的，这个我来处理。", slot: "确认处理"),
        SmartReplySuggestion(direction: "要信息", text: "方便再补一下具体细节吗？", slot: "要信息"),
        SmartReplySuggestion(direction: "稍后回", text: "现在不太方便，稍后回复你。", slot: "稍后回"),
        SmartReplySuggestion(direction: "约时间", text: "今天方便同步一下吗？", slot: "约时间"),
    ]

    private static let defaultSlots: [String] = defaults.compactMap(\.slot)

    @MainActor
    static func generate(
        from context: ChatContext,
        debugDir: URL? = nil,
        onProgress: ((String) -> Void)? = nil
    ) async -> (suggestions: [SmartReplySuggestion], note: String?) {
        guard context.isUseful else {
            onProgress?("没有聊天原文，不调用 agent")
            let fallback = context.note ?? "无法获取到聊天文本。"
            return ([], fallback + " 默认回复仍可直接用。")
        }

        let style = PhraseStore.shared.topPhrases(limit: 5).map(\.text)
        let apiKey = CursorAISummarizer.shared.apiKey
        let resolved = AgentCLI.resolvedAPIKey(apiKey)
        if resolved.isEmpty {
            onProgress?("没有 API Key")
        } else {
            onProgress?("API Key 已就绪（末尾 \(resolved.suffix(4))）")
        }

        do {
            let prompt = buildPrompt(context: context, style: style)
            if let debugDir {
                DebugSessionLog.write(debugDir, "prompt.txt", prompt)
                DebugSessionLog.write(debugDir, "style.txt", style.isEmpty ? "(none)\n" : style.joined(separator: "\n") + "\n")
            }
            onProgress?("Prompt \(prompt.count) 字，聊天原文交给 agent…")
            let workspace = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("PhraseDeck/ai-workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

            let raw = try await AgentCLI.runAsk(
                prompt: prompt,
                apiKey: apiKey,
                workspace: workspace,
                debugDir: debugDir,
                onProgress: onProgress
            )
            onProgress?("agent 返回 \(raw.count) 字，解析 JSON…")
            if let debugDir {
                DebugSessionLog.write(debugDir, "agent-raw.txt", raw)
            }
            let data = try AgentCLI.extractJSONArray(from: raw)
            if let debugDir {
                DebugSessionLog.write(debugDir, "drafts.json", String(data: data, encoding: .utf8) ?? "")
            }
            let drafts = try JSONDecoder().decode([AIReplyDraft].self, from: data)
            let merged = merge(defaults: defaults, drafts: drafts)
            let replaced = merged.filter { $0.origin == .enhanced }.count
            let added = merged.filter { $0.origin == .added }.count
            onProgress?("合并完成：增强 \(replaced) 条，新增 \(added) 条")
            if let debugDir {
                let lines = merged.map { "\($0.origin.rawValue)\t\($0.direction)\t\($0.text)" }.joined(separator: "\n")
                DebugSessionLog.write(debugDir, "merged.txt", lines + "\n")
            }
            if replaced == 0 && added == 0 {
                return ([], "模型没有给出可合并的回复，默认 5 条保持不变。")
            }
            return (merged, nil)
        } catch {
            onProgress?("失败：\(error.localizedDescription)")
            if let debugDir {
                DebugSessionLog.write(debugDir, "error.txt", error.localizedDescription + "\n")
            }
            return ([], "生成失败，默认回复仍可直接用：\(error.localizedDescription)")
        }
    }

    private static func merge(defaults: [SmartReplySuggestion], drafts: [AIReplyDraft]) -> [SmartReplySuggestion] {
        var merged = defaults
        var addedCount = 0

        for draft in drafts {
            let text = PhraseMiner.normalize(draft.text)
            let direction = draft.direction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !direction.isEmpty, (2...240).contains(text.count) else { continue }

            let action = (draft.action ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let base = normalizeSlot(draft.base ?? "")
            let wantsReplace = action == "replace" || action == "enhance" || action == "增强"
            let slot = base.isEmpty ? normalizeSlot(direction) : base

            if wantsReplace || (!base.isEmpty && defaultSlots.contains(slot)) {
                if let idx = merged.firstIndex(where: { $0.slot == slot }) {
                    merged[idx].text = text
                    merged[idx].direction = String(direction.prefix(12))
                    merged[idx].origin = .enhanced
                    continue
                }
            }

            guard addedCount < 5 else { continue }
            merged.append(
                SmartReplySuggestion(
                    direction: String(direction.prefix(12)),
                    text: text,
                    origin: .added
                )
            )
            addedCount += 1
        }

        return Array(merged.prefix(10))
    }

    private static func normalizeSlot(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for slot in defaultSlots where trimmed == slot || trimmed.contains(slot) {
            return slot
        }
        return trimmed
    }

    private static func buildPrompt(context: ChatContext, style: [String]) -> String {
        var lines: [String] = []
        lines.append("用户已经能看到下面 5 条默认快捷回复，可立刻按数字发送。你只输出增量：增强其中某条，或追加新方向。")
        lines.append("默认回复（base 必须用这里的原名）：")
        for item in defaults {
            lines.append("- base=\(item.slot ?? item.direction)｜\(item.direction)：\(item.text)")
        }
        lines.append("规则：")
        lines.append("1. 用户已经决定要回复，不要分析背景，不要复述原文。")
        lines.append("2. 若某条默认方向适合当前对话，按语境改写得更贴切：action=replace，base=默认名。")
        lines.append("3. 若默认里没有的方向（拒绝、致谢、给方案、要文件等），action=append，不要填 base，不要改默认 5 条。")
        lines.append("4. 默认已经够用的句子不要再输出。每条 1～2 句，可直接粘贴。")
        lines.append("5. 只输出 JSON 数组，不要 markdown：")
        lines.append("[{\"direction\":\"收到\",\"text\":\"收到，我这边先看一下文档。\",\"action\":\"replace\",\"base\":\"收到\"},{\"direction\":\"要文件\",\"text\":\"方便把相关文件发我吗？\",\"action\":\"append\"}]")
        if !style.isEmpty {
            lines.append("用户常用语气（可模仿，不要无关照抄）：")
            for s in style {
                lines.append("- \(s)")
            }
        }
        if !context.appName.isEmpty || !context.bundleID.isEmpty {
            var window = "当前窗口：\(context.appName)（\(context.bundleID)）来源 \(context.source)"
            if let title = context.title, !title.isEmpty {
                window += " 会话 \(title)"
            }
            lines.append(window)
        }
        lines.append("当前聊天原文：")
        lines.append(context.text)
        return lines.joined(separator: "\n")
    }
}
