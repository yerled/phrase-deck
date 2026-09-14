import Foundation

enum AIUsageKind: String, Codable, CaseIterable {
    case summarize
    /// Kept for decoding older `token-usage.json` entries.
    case smartReply

    var title: String {
        switch self {
        case .summarize: return "全量总结"
        case .smartReply: return "智能回复（已移除）"
        }
    }
}

struct AgentTokenUsage: Codable, Equatable, Hashable {
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
    }

    var hasAny: Bool {
        totalTokens > 0
    }

    static let zero = AgentTokenUsage(
        inputTokens: 0,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheWriteTokens: 0
    )

    mutating func merge(_ other: AgentTokenUsage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheWriteTokens += other.cacheWriteTokens
    }

    static func + (lhs: AgentTokenUsage, rhs: AgentTokenUsage) -> AgentTokenUsage {
        var copy = lhs
        copy.merge(rhs)
        return copy
    }
}

struct TokenUsageEvent: Identifiable, Codable, Hashable {
    var id: UUID
    var createdAt: Date
    var kind: AIUsageKind
    var usage: AgentTokenUsage
    var model: String?
    var sessionId: String?
    var durationMs: Int?
    var success: Bool
    var note: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        kind: AIUsageKind,
        usage: AgentTokenUsage = .zero,
        model: String? = nil,
        sessionId: String? = nil,
        durationMs: Int? = nil,
        success: Bool = true,
        note: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.usage = usage
        self.model = model
        self.sessionId = sessionId
        self.durationMs = durationMs
        self.success = success
        self.note = note
    }
}

enum TokenUsagePeriod: String, CaseIterable, Identifiable {
    case day
    case week
    case month
    case total

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return "今日"
        case .week: return "本周"
        case .month: return "本月"
        case .total: return "总量"
        }
    }
}

struct TokenUsageSummary: Equatable {
    var callCount: Int = 0
    var successCount: Int = 0
    var usage: AgentTokenUsage = .zero

    var averageTotalTokens: Int {
        guard callCount > 0 else { return 0 }
        return usage.totalTokens / callCount
    }
}
