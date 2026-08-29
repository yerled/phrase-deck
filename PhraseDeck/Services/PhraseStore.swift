import Foundation
import AppKit

@MainActor
final class PhraseStore: ObservableObject {
    static let shared = PhraseStore()

    @Published private(set) var phrases: [Phrase] = []

    private let fileURL: URL
    private let maxStored = 500
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
    }

    func topPhrases(limit: Int = 10) -> [Phrase] {
        phrases.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    @discardableResult
    func record(_ text: String, source: PhraseSource) -> Phrase? {
        let normalized = PhraseMiner.normalize(text)
        guard PhraseMiner.isEligiblePhrase(normalized) else { return nil }

        if let idx = phrases.firstIndex(where: { $0.text == normalized }) {
            phrases[idx].count += 1
            phrases[idx].lastUsedAt = Date()
            persist()
            return phrases[idx]
        }

        let phrase = Phrase(text: normalized, source: source)
        phrases.insert(phrase, at: 0)
        trimIfNeeded()
        persist()
        return phrase
    }

    func markUsed(_ id: UUID) {
        guard let idx = phrases.firstIndex(where: { $0.id == id }) else { return }
        phrases[idx].count += 1
        phrases[idx].lastUsedAt = Date()
        persist()
    }

    func delete(_ id: UUID) {
        phrases.removeAll { $0.id == id }
        persist()
    }

    func clearAll() {
        phrases = []
        persist()
    }

    func remineFromClipboardHistory(_ texts: [String]) {
        for text in texts {
            _ = record(text, source: .mined)
        }
    }

    func applyAISuggestions(_ items: [AIPhraseSuggestion]) {
        for item in items {
            let normalized = PhraseMiner.normalize(item.text)
            guard !normalized.isEmpty else { continue }
            let weight = max(1, min(item.weight ?? 5, 10))

            if let idx = phrases.firstIndex(where: { $0.text == normalized }) {
                phrases[idx].count = max(phrases[idx].count, weight)
                phrases[idx].lastUsedAt = Date()
                phrases[idx].source = .ai
            } else {
                phrases.insert(
                    Phrase(text: normalized, count: weight, source: .ai),
                    at: 0
                )
            }
        }
        trimIfNeeded()
        persist()
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            phrases = try decoder.decode([Phrase].self, from: data)
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

    private func trimIfNeeded() {
        guard phrases.count > maxStored else { return }
        phrases = phrases.sorted { $0.score > $1.score }.prefix(maxStored).map { $0 }
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
