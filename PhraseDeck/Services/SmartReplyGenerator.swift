import Foundation

struct SmartReplySuggestion: Identifiable, Equatable, Decodable {
    var id: UUID
    var direction: String
    var text: String

    init(id: UUID = UUID(), direction: String, text: String) {
        self.id = id
        self.direction = direction
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case direction, text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        direction = try c.decode(String.self, forKey: .direction)
        text = try c.decode(String.self, forKey: .text)
    }
}

enum SmartReplyGenerator {
    private static let fallback: [SmartReplySuggestion] = [
        SmartReplySuggestion(direction: "收到", text: "收到，我看一下。"),
        SmartReplySuggestion(direction: "确认处理", text: "好的，这个我来处理。"),
        SmartReplySuggestion(direction: "要信息", text: "方便再补一下具体细节吗？"),
        SmartReplySuggestion(direction: "稍后回", text: "现在不太方便，稍后回复你。"),
        SmartReplySuggestion(direction: "约时间", text: "今天方便同步一下吗？"),
    ]

    @MainActor
    static func generate(from context: WindowContext) async -> (suggestions: [SmartReplySuggestion], note: String?) {
        guard context.isUseful else {
            return (fallback, "没读到足够的窗口文字（\(context.source)，\(context.text.count) 字，\(context.appName.isEmpty ? "无目标窗口" : context.appName)）。飞书需屏幕录制才能识别对话。")
        }

        let style = PhraseStore.shared.topPhrases(limit: 5).map(\.text)
        let apiKey = CursorAISummarizer.shared.apiKey

        do {
            let prompt = buildPrompt(context: context, style: style)
            let workspace = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("PhraseDeck/ai-workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

            let raw = try await AgentCLI.runAsk(
                prompt: prompt,
                apiKey: apiKey,
                workspace: workspace
            )
            let data = try AgentCLI.extractJSONArray(from: raw)
            let decoded = try JSONDecoder().decode([SmartReplySuggestion].self, from: data)
            let cleaned = decoded.compactMap(sanitize).prefix(6)
            if cleaned.isEmpty {
                return (fallback, "模型没有给出可用回复，已用通用方向。")
            }
            return (Array(cleaned), nil)
        } catch {
            return (fallback, "生成失败，已用通用方向：\(error.localizedDescription)")
        }
    }

    private static func sanitize(_ item: SmartReplySuggestion) -> SmartReplySuggestion? {
        let direction = item.direction.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = PhraseMiner.normalize(item.text)
        guard !direction.isEmpty, (2...240).contains(text.count) else { return nil }
        return SmartReplySuggestion(direction: String(direction.prefix(12)), text: text)
    }

    private static func buildPrompt(context: WindowContext, style: [String]) -> String {
        var lines: [String] = []
        lines.append("根据当前窗口里看到的对话，给用户 5 条可直接发送的快捷回复。")
        lines.append("用户已经决定要回复，不要分析背景，不要复述原文，不要提问。")
        lines.append("每条必须是不同方向（同意、先确认、要补充信息、委婉拒绝、约时间、收到稍后回等），只保留和上下文相关的方向。")
        lines.append("每条 1～2 句，口语，可直接粘贴到飞书或 Cursor。")
        lines.append("只输出 JSON 数组，不要 markdown，不要解释：")
        lines.append("[{\"direction\":\"同意\",\"text\":\"好的，这个我来处理。\"}]")
        if !style.isEmpty {
            lines.append("用户常用语气（可模仿，不要无关照抄）：")
            for s in style {
                lines.append("- \(s)")
            }
        }
        lines.append("当前窗口：\(context.appName)（\(context.bundleID)）来源 \(context.source)")
        lines.append("窗口可见文字：")
        lines.append(context.text)
        return lines.joined(separator: "\n")
    }
}
