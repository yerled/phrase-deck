import Foundation

enum PhraseMiner {
    private static let minLength = 2
    private static let maxLength = 120
    private static let passwordLike = try! NSRegularExpression(
        pattern: #"(?i)(password|passwd|otp|verify.?code|验证码|密码)\s*[:=]?\s*\S+"#
    )
    private static let mostlyDigits = try! NSRegularExpression(pattern: #"^\d[\d\s\-.]{3,}$"#)
    private static let emailOnly = try! NSRegularExpression(pattern: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#)
    private static let urlOnly = try! NSRegularExpression(pattern: #"^https?://\S+$"#)
    private static let percentEncoded = try! NSRegularExpression(pattern: #"%[0-9A-Fa-f]{2}"#)
    private static let domainWithPath = try! NSRegularExpression(pattern: #"(?i)[a-z0-9.-]+\.[a-z]{2,}/"#)
    private static let hexToken = try! NSRegularExpression(pattern: #"^[A-Za-z]*[_-]?[0-9A-Fa-f]{16,}$"#)
    private static let queryPair = try! NSRegularExpression(pattern: #"^[A-Za-z0-9_.%]+=\S+$"#)

    /// Cursor / Electron chrome that Accessibility often exposes as the focused value.
    private static let uiChromeExact: Set<String> = [
        "Plan, Build, / for skills, @ for context",
        "Send follow-up",
        "Ask a follow-up",
        "Add a follow-up",
        "Ask, Plan, Agent dropdown, @ for context",
    ]

    static func normalize(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    }

    /// Collapse whitespace, case, and common punctuation for frequency matching.
    static func compactForMatch(_ text: String) -> String {
        String(normalize(text).lowercased().compactMap { ch -> Character? in
            if ch.isWhitespace { return nil }
            switch ch {
            case ",", ".", "!", "?", ";", ":", "，", "。", "！", "？", "、", "；", "：":
                return nil
            default:
                return ch
            }
        })
    }

    /// Count a send only when the phrase is the whole message or a whole line.
    /// Substring / sentence-slice matching inflates URL fragments and paragraph pieces.
    static func messageSupportsPhrase(_ phrase: String, message: String) -> Bool {
        let p = normalize(phrase)
        let m = normalize(message)
        guard !p.isEmpty, !m.isEmpty else { return false }

        let pc = compactForMatch(p)
        guard !pc.isEmpty else { return false }
        if compactForMatch(m) == pc { return true }

        for line in m.split(separator: "\n", omittingEmptySubsequences: true) {
            if compactForMatch(String(line)) == pc { return true }
        }
        return false
    }

    static func occurrenceCount(of phrase: String, in texts: [String]) -> Int {
        texts.reduce(0) { $0 + (messageSupportsPhrase(phrase, message: $1) ? 1 : 0) }
    }

    /// Editor placeholders, button titles, and other UI copy — not user-authored text.
    static func looksLikeUIChrome(_ text: String) -> Bool {
        let t = normalize(text)
        if t.isEmpty { return false }
        if uiChromeExact.contains(t) { return true }
        let lower = t.lowercased()
        if lower.contains("/ for skills") && lower.contains("@ for context") { return true }
        if lower == "send follow-up" || lower == "ask a follow-up" || lower == "add a follow-up" {
            return true
        }
        return false
    }

    static func isEligiblePhrase(_ text: String) -> Bool {
        let t = normalize(text)
        guard t.count >= minLength, t.count <= maxLength else { return false }
        if looksLikeUIChrome(t) { return false }
        if looksLikeTechnicalJunk(t) { return false }
        if t.contains("\t") { return false }
        if matches(passwordLike, t) { return false }
        if matches(mostlyDigits, t) { return false }
        if matches(emailOnly, t) { return false }
        if matches(urlOnly, t) { return false }
        // Skip single punctuation / emoji-only noise
        let alnum = t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || (0x4E00...0x9FFF).contains($0.value) }
        return alnum.count >= 2
    }

    private static func looksLikeTechnicalJunk(_ text: String) -> Bool {
        if matches(percentEncoded, text) { return true }
        if text.hasPrefix("/") || text.hasPrefix("~") { return true }
        if text.contains("/Users/") || text.contains("/Downloads/") { return true }
        if matches(domainWithPath, text) { return true }
        if matches(hexToken, text) { return true }
        if matches(queryPair, text), !containsCJK(text) { return true }
        let slashCount = text.filter { $0 == "/" }.count
        if slashCount >= 2 && !containsCJK(text) { return true }
        return false
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}
