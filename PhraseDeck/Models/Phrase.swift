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

    /// score = frequency * 0.7 + recency * 0.3
    var score: Double {
        let now = Date()
        let days = max(0, now.timeIntervalSince(lastUsedAt) / 86_400)
        let recency = exp(-days / 7.0) // half-life ~ week
        return Double(count) * 0.7 + recency * 10.0 * 0.3
    }
}

enum PhraseSource: String, Codable {
    case clipboard
    case manual
    case mined
    case appSend
    case ai
}
