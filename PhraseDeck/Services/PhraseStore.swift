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
        reconcile(with: MessageLogStore.shared.messages)
    }

    func topPhrases(limit: Int = 10) -> [Phrase] {
        phrases.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    @discardableResult
    func record(_ text: String, source: PhraseSource) -> Phrase? {
        let normalized = PhraseMiner.normalize(text)
        guard PhraseMiner.isEligiblePhrase(normalized) else { return nil }

        let key = PhraseMiner.compactForMatch(normalized)
        if let idx = phrases.firstIndex(where: { PhraseMiner.compactForMatch($0.text) == key }) {
            if consumeRecentOverlayUse(phrases[idx].text) || consumeRecentOverlayUse(normalized) {
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
    /// Manual, frequently logged, or this/last-week phrases the model omitted are kept.
    func replaceAll(with items: [AIPhraseSuggestion], messages: [SentMessage]) {
        var existingByKey: [String: Phrase] = [:]
        for phrase in phrases {
            let key = PhraseMiner.compactForMatch(phrase.text)
            guard !key.isEmpty, existingByKey[key] == nil else { continue }
            existingByKey[key] = phrase
        }

        var next: [Phrase] = []
        var seen = Set<String>()

        for item in items {
            let normalized = PhraseMiner.normalize(item.text)
            guard PhraseMiner.isEligiblePhrase(normalized) else { continue }
            let key = PhraseMiner.compactForMatch(normalized)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            next.append(makeReplacedPhrase(text: normalized, existing: existingByKey[key], messages: messages))
        }

        for phrase in phrases {
            let key = PhraseMiner.compactForMatch(phrase.text)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            guard PhraseMiner.isEligiblePhrase(phrase.text) else { continue }
            let observed = logOccurrenceCount(of: phrase.text, in: messages)
            // Align with recency score: this China natural week + last week stay fresh.
            let recentlyUsed = ChineseNaturalWeek.weeksElapsed(from: phrase.lastUsedAt, to: Date()) <= 1
            let keep = phrase.source == .manual
                || observed >= 2
                || (phrase.source != .mined && recentlyUsed)
            guard keep else { continue }
            next.append(synced(phrase, messages: messages))
        }

        phrases = next
        persist()
        reconcile(with: messages)
    }

    /// Drop junk, collapse punctuation duplicates, and raise `count` / recency from log matches.
    func reconcile(with messages: [SentMessage]) {
        var bestByKey: [String: Phrase] = [:]
        for phrase in phrases {
            guard PhraseMiner.isEligiblePhrase(phrase.text) else { continue }
            let updated = synced(phrase, messages: messages)
            let observed = logOccurrenceCount(of: updated.text, in: messages)
            if updated.source == .mined && observed == 0 { continue }
            let key = PhraseMiner.compactForMatch(updated.text)
            guard !key.isEmpty else { continue }
            if let existing = bestByKey[key] {
                bestByKey[key] = mergeDuplicates(existing, updated)
            } else {
                bestByKey[key] = updated
            }
        }
        let next = Array(bestByKey.values).sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        if fingerprint(next) != fingerprint(phrases) {
            phrases = next
            persist()
        }
    }

    /// Rebuild `count` / recency from the send log.
    func recomputeCounts(from messages: [SentMessage]) {
        reconcile(with: messages)
    }

    private func consumeRecentOverlayUse(_ text: String) -> Bool {
        guard let usedAt = recentOverlayUses.removeValue(forKey: text) else { return false }
        return Date().timeIntervalSince(usedAt) < overlaySendDedupeInterval
    }

    private func logOccurrenceCount(of phrase: String, in messages: [SentMessage]) -> Int {
        PhraseMiner.occurrenceCount(of: phrase, in: messages.map(\.text))
    }

    private func makeReplacedPhrase(text: String, existing: Phrase?, messages: [SentMessage]) -> Phrase {
        if var updated = existing {
            updated.text = text
            updated = synced(updated, messages: messages)
            if existing?.source != .manual {
                updated.source = .ai
            }
            return updated
        }
        let observed = logOccurrenceCount(of: text, in: messages)
        return Phrase(
            text: text,
            count: max(1, observed),
            lastUsedAt: latestOccurrence(of: text, in: messages) ?? .distantPast,
            source: .ai
        )
    }

    /// Raise `count` / `lastUsedAt` from the send log; never rewind overlay bumps.
    private func synced(_ phrase: Phrase, messages: [SentMessage]) -> Phrase {
        var updated = phrase
        let observed = logOccurrenceCount(of: phrase.text, in: messages)
        let latest = latestOccurrence(of: phrase.text, in: messages)
        if observed > 0 {
            updated.count = max(updated.count, observed)
            if let latest {
                updated.lastUsedAt = max(updated.lastUsedAt, latest)
            }
        } else if updated.count < 1 {
            updated.count = 1
        }
        return updated
    }

    private func mergeDuplicates(_ a: Phrase, _ b: Phrase) -> Phrase {
        func rank(_ source: PhraseSource) -> Int {
            switch source {
            case .manual: return 4
            case .ai: return 3
            case .appSend: return 2
            case .clipboard, .mined: return 1
            }
        }
        var winner = rank(a.source) >= rank(b.source) ? a : b
        winner.count = max(a.count, b.count)
        winner.lastUsedAt = max(a.lastUsedAt, b.lastUsedAt)
        winner.createdAt = min(a.createdAt, b.createdAt)
        if a.source == .manual || b.source == .manual {
            winner.source = .manual
        }
        return winner
    }

    private func fingerprint(_ items: [Phrase]) -> Set<String> {
        Set(items.map {
            "\($0.id.uuidString)|\(PhraseMiner.compactForMatch($0.text))|\($0.count)|\($0.source.rawValue)|\(Int($0.lastUsedAt.timeIntervalSince1970))"
        })
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
