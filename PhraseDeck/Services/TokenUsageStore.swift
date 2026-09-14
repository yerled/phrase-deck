import Foundation

@MainActor
final class TokenUsageStore: ObservableObject {
    static let shared = TokenUsageStore()

    @Published private(set) var events: [TokenUsageEvent] = []

    private let fileURL: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PhraseDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("token-usage.json")
        load()
    }

    @discardableResult
    func record(
        kind: AIUsageKind,
        usage: AgentTokenUsage = .zero,
        model: String? = nil,
        sessionId: String? = nil,
        durationMs: Int? = nil,
        success: Bool = true,
        note: String? = nil
    ) -> TokenUsageEvent {
        let event = TokenUsageEvent(
            kind: kind,
            usage: usage,
            model: model,
            sessionId: sessionId,
            durationMs: durationMs,
            success: success,
            note: note
        )
        events.append(event)
        trim()
        persist()
        return event
    }

    func summary(for period: TokenUsagePeriod, now: Date = Date()) -> TokenUsageSummary {
        let filtered = events(in: period, now: now)
        var summary = TokenUsageSummary()
        for event in filtered {
            summary.callCount += 1
            if event.success { summary.successCount += 1 }
            summary.usage.merge(event.usage)
        }
        return summary
    }

    func events(in period: TokenUsagePeriod, now: Date = Date()) -> [TokenUsageEvent] {
        guard let start = periodStart(period, now: now) else { return events }
        return events.filter { $0.createdAt >= start }
    }

    var lastEvent: TokenUsageEvent? { events.last }

    func clear() {
        events = []
        persist()
    }

    private func periodStart(_ period: TokenUsagePeriod, now: Date) -> Date? {
        switch period {
        case .day: return ChineseNaturalWeek.startOfDay(containing: now)
        case .week: return ChineseNaturalWeek.startOfWeek(containing: now)
        case .month: return ChineseNaturalWeek.startOfMonth(containing: now)
        case .total: return nil
        }
    }

    private func trim() {
        let maxEvents = 5_000
        if events.count > maxEvents {
            events = Array(events.suffix(maxEvents))
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            events = try decoder.decode([TokenUsageEvent].self, from: data)
        } catch {
            NSLog("TokenUsageStore load failed: \(error)")
        }
    }

    private func persist() {
        do {
            let data = try encoder.encode(events)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("TokenUsageStore persist failed: \(error)")
        }
    }
}
