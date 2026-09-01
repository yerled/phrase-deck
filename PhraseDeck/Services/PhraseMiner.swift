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

    static func normalize(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    }

    static func isEligiblePhrase(_ text: String) -> Bool {
        let t = normalize(text)
        guard t.count >= minLength, t.count <= maxLength else { return false }
        if t.contains("\t") { return false }
        if matches(passwordLike, t) { return false }
        if matches(mostlyDigits, t) { return false }
        if matches(emailOnly, t) { return false }
        if matches(urlOnly, t) { return false }
        // Skip single punctuation / emoji-only noise
        let alnum = t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || (0x4E00...0x9FFF).contains($0.value) }
        return alnum.count >= 2
    }

    /// Extract candidate phrases from a longer blob (sent message).
    static func extractCandidates(from text: String) -> [String] {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return [] }

        if isEligiblePhrase(normalized) && !normalized.contains("\n") {
            return [normalized]
        }

        var results: [String] = []
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        for line in lines {
            let trimmed = normalize(line)
            if isEligiblePhrase(trimmed) {
                results.append(trimmed)
            }
        }

        // Simple sentence split for Chinese / English
        let sentenceParts = normalized
            .components(separatedBy: CharacterSet(charactersIn: "。！？.!?\n"))
            .map { normalize($0) }
            .filter { isEligiblePhrase($0) }
        results.append(contentsOf: sentenceParts)

        // Dedup preserve order
        var seen = Set<String>()
        return results.filter { seen.insert($0).inserted }
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}
