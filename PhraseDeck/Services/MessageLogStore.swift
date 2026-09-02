import Foundation
import AppKit

@MainActor
final class MessageLogStore: ObservableObject {
    static let shared = MessageLogStore()

    @Published private(set) var messages: [SentMessage] = []

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
        fileURL = dir.appendingPathComponent("sent-messages.json")
        load()
    }

    @discardableResult
    func append(text: String, appBundleID: String, appName: String) -> SentMessage? {
        let normalized = PhraseMiner.normalize(text)
        guard !PhraseMiner.looksLikeUIChrome(normalized) else { return nil }
        guard PhraseMiner.isEligiblePhrase(normalized) || isChatLike(normalized) else { return nil }
        guard !looksLikeCode(normalized) else { return nil }

        // Debounce identical send within 2s
        if let last = messages.last,
           last.text == normalized,
           Date().timeIntervalSince(last.createdAt) < 2 {
            return nil
        }

        let msg = SentMessage(text: normalized, appBundleID: appBundleID, appName: appName)
        messages.append(msg)
        trim()
        persist()

        // Immediate frequency signal so Top10 works before first AI pass
        _ = PhraseStore.shared.record(normalized, source: .appSend)
        return msg
    }

    func clear() {
        messages = []
        persist()
    }

    private func trim() {
        if messages.count > AppConst.maxLoggedMessages {
            messages = Array(messages.suffix(AppConst.maxLoggedMessages))
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            messages = try decoder.decode([SentMessage].self, from: data)
            let before = messages.count
            messages.removeAll { PhraseMiner.looksLikeUIChrome($0.text) }
            if messages.count != before { persist() }
        } catch {
            NSLog("MessageLogStore load failed: \(error)")
        }
    }

    private func persist() {
        do {
            let data = try encoder.encode(messages)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("MessageLogStore persist failed: \(error)")
        }
    }

    private func isChatLike(_ text: String) -> Bool {
        text.count >= 2 && text.count <= 500 && text.split(separator: "\n").count <= 8
    }

    private func looksLikeCode(_ text: String) -> Bool {
        let lower = text.lowercased()
        let codeHints = ["func ", "import ", "const ", "let ", "var ", "class ", "struct ", "{", "};", "=>", "</", "#!/"]
        let hits = codeHints.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
        if hits >= 2 { return true }
        if text.contains("\n"), text.filter({ $0 == "{" || $0 == "}" }).count >= 4 { return true }
        return false
    }
}
