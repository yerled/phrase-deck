import Foundation
import AppKit

@MainActor
final class PhraseStore: ObservableObject {
    static let shared = PhraseStore()

    @Published private(set) var phrases: [Phrase] = []

    /// Overlay inserts already incremented `count`; skip the next matching send so paste-then-Enter is one use.
    private var recentOverlayUses: [String: Date] = [:]
    private let overlaySendDedupeInterval: TimeInterval = 120

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
        fileURL = dir.appendingPathComponent("phrases.json")
        load()
        if phrases.isEmpty {
            seedDemoPhrases()
        }
        recomputeCounts(from: MessageLogStore.shared.messages)
    }

    func topPhrases(limit: Int = 10) -> [Phrase] {
        phrases.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    @discardableResult
    func record(_ text: String, source: PhraseSource) -> Phrase? {
        let normalized = PhraseMiner.normalize(text)
        guard PhraseMiner.isEligiblePhrase(normalized) else { return nil }

        if let idx = phrases.firstIndex(where: { $0.text == normalized }) {
            if consumeRecentOverlayUse(normalized) {
                phrases[idx].lastUsedAt = Date()
                persist()
                return phrases[idx]
            }
            phrases[idx].count += 1
            phrases[idx].lastUsedAt = Date()
            persist()
            return phrases[idx]
        }

        let phrase = Phrase(text: normalized, source: source)
        phrases.insert(phrase, at: 0)
        persist()
        return phrase
    }

    /// Shortcut / click insert: bump frequency and recency so score keeps stacking.
    func markUsed(_ id: UUID) {
        guard let idx = phrases.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        phrases[idx].count += 1
        phrases[idx].lastUsedAt = now
        recentOverlayUses[phrases[idx].text] = now
        persist()
    }

    func delete(_ id: UUID) {
        phrases.removeAll { $0.id == id }
        persist()
    }

    func clearAll() {
        phrases = []
        recentOverlayUses = [:]
        persist()
    }

    /// Replace the library with a full AI rebuild. Matching text keeps id / createdAt.
    /// `count` is observed log frequency, but overlay shortcut uses are never discarded.
    func replaceAll(with items: [AIPhraseSuggestion], messages: [SentMessage]) {
        var existingByText: [String: Phrase] = [:]
        for phrase in phrases where existingByText[phrase.text] == nil {
            existingByText[phrase.text] = phrase
        }
        var next: [Phrase] = []
        var seen = Set<String>()

        for item in items {
            let normalized = PhraseMiner.normalize(item.text)
            guard PhraseMiner.isEligiblePhrase(normalized) else { continue }
            guard seen.insert(normalized).inserted else { continue }
            let observed = observedCount(of: normalized, in: messages)

            if let existing = existingByText[normalized] {
                var updated = existing
                updated.count = max(observed, existing.count)
                if let latest = latestOccurrence(of: normalized, in: messages),
                   latest > updated.lastUsedAt {
                    updated.lastUsedAt = latest
                }
                if existing.source != .manual {
                    updated.source = .ai
                }
                next.append(updated)
            } else {
                next.append(
                    Phrase(
                        text: normalized,
                        count: observed,
                        lastUsedAt: latestOccurrence(of: normalized, in: messages) ?? Date(),
                        source: .ai
                    )
                )
            }
        }

        phrases = next
        persist()
    }

    /// Rebuild `count` / recency from the send log. Overlay shortcut uses can only raise the count.
    func recomputeCounts(from messages: [SentMessage]) {
        var changed = false
        for i in phrases.indices {
            let observed = observedCount(of: phrases[i].text, in: messages)
            if observed > phrases[i].count {
                phrases[i].count = observed
                changed = true
            }
            if let latest = latestOccurrence(of: phrases[i].text, in: messages),
               latest > phrases[i].lastUsedAt {
                phrases[i].lastUsedAt = latest
                changed = true
            }
        }
        if changed { persist() }
    }

    private func consumeRecentOverlayUse(_ text: String) -> Bool {
        guard let usedAt = recentOverlayUses.removeValue(forKey: text) else { return false }
        return Date().timeIntervalSince(usedAt) < overlaySendDedupeInterval
    }

    private func observedCount(of phrase: String, in messages: [SentMessage]) -> Int {
        max(1, PhraseMiner.occurrenceCount(of: phrase, in: messages.map(\.text)))
    }

    private func latestOccurrence(of phrase: String, in messages: [SentMessage]) -> Date? {
        messages
            .filter { PhraseMiner.messageSupportsPhrase(phrase, message: $0.text) }
            .map(\.createdAt)
            .max()
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            phrases = try decoder.decode([Phrase].self, from: data)
            let before = phrases.count
            phrases.removeAll { !PhraseMiner.isEligiblePhrase($0.text) }
            if phrases.count != before { persist() }
        } catch {
            NSLog("PhraseStore load failed: \(error)")
        }
    }

    private func persist() {
        do {
            let data = try encoder.encode(phrases)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("PhraseStore persist failed: \(error)")
        }
    }

    private func seedDemoPhrases() {
        let demos = [
            "收到，我这边确认一下。",
            "稍后回复你。",
            "今天可以，约个时间同步一下？",
            "Thanks, looking into it.",
            "LGTM",
            "请帮我看一下这个问题。",
            "已处理，辛苦了。",
            "开会中，稍后回复。",
            "好的，没问题。",
            "麻烦发一下相关链接。",
        ]
        for (i, text) in demos.enumerated() {
            phrases.append(
                Phrase(
                    text: text,
                    count: demos.count - i,
                    lastUsedAt: Date().addingTimeInterval(TimeInterval(-i * 3600)),
                    source: .manual
                )
            )
        }
        persist()
    }
}
