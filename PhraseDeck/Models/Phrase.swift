import Foundation

struct Phrase: Identifiable, Codable, Hashable {
    var id: UUID
    var text: String
    var count: Int
    var lastUsedAt: Date
    var createdAt: Date
    var source: PhraseSource

    init(
        id: UUID = UUID(),
        text: String,
        count: Int = 1,
        lastUsedAt: Date = Date(),
        createdAt: Date = Date(),
        source: PhraseSource = .manual
    ) {
        self.id = id
        self.text = text
        self.count = count
        self.lastUsedAt = lastUsedAt
        self.createdAt = createdAt
        self.source = source
    }

    /// score = frequency × 0.7 + recency × 3
    /// Recency uses China natural weeks (Mon–Sun, Asia/Shanghai).
    /// This week and last week do not decay; older weeks decay with τ = 1 week.
    var score: Double {
        Double(count) * 0.7 + recencyWeight() * 10.0 * 0.3
    }

    func recencyWeight(asOf now: Date = Date()) -> Double {
        let weeksAgo = ChineseNaturalWeek.weeksElapsed(from: lastUsedAt, to: now)
        let decayWeeks = max(0, weeksAgo - 1)
        return exp(-Double(decayWeeks))
    }
}

/// Monday–Sunday weeks in China Standard Time (Asia/Shanghai).
enum ChineseNaturalWeek {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")
            ?? TimeZone(secondsFromGMT: 8 * 3600)!
        calendar.firstWeekday = 2
        return calendar
    }

    static func startOfDay(containing date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    static func startOfWeek(containing date: Date) -> Date {
        let calendar = Self.calendar
        let dayStart = startOfDay(containing: date)
        let weekday = calendar.component(.weekday, from: dayStart)
        let daysFromMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysFromMonday, to: dayStart) ?? dayStart
    }

    static func startOfMonth(containing date: Date) -> Date {
        let calendar = Self.calendar
        let comps = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: comps) ?? startOfDay(containing: date)
    }

    /// Whole China natural weeks between the two dates. Same week → 0; last week → 1.
    static func weeksElapsed(from: Date, to: Date) -> Int {
        let calendar = Self.calendar
        let fromStart = startOfWeek(containing: from)
        let toStart = startOfWeek(containing: to)
        let days = calendar.dateComponents([.day], from: fromStart, to: toStart).day ?? 0
        return max(0, days / 7)
    }
}

enum PhraseSource: String, Codable {
    case clipboard
    case manual
    case mined
    case appSend
    case ai
}
