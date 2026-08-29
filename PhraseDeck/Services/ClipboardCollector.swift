import AppKit
import Combine

/// Watches the general pasteboard and records eligible phrases.
@MainActor
final class ClipboardCollector: ObservableObject {
    static let shared = ClipboardCollector()

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled) }
    }

    @Published private(set) var lastCaptured: String?

    private var timer: Timer?
    private var lastChangeCount: Int = -1
    private var lastText: String?

    private enum Keys {
        static let enabled = "clipboardCollector.enabled"
    }

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard isEnabled else { return }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        guard let text = pb.string(forType: .string), text != lastText else { return }
        lastText = text

        let candidates = PhraseMiner.extractCandidates(from: text)
        for candidate in candidates {
            if PhraseStore.shared.record(candidate, source: .clipboard) != nil {
                lastCaptured = candidate
            }
        }
    }
}
