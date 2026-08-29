import Foundation

struct SentMessage: Identifiable, Codable, Hashable {
    var id: UUID
    var text: String
    var appBundleID: String
    var appName: String
    var createdAt: Date
    var summarized: Bool

    init(
        id: UUID = UUID(),
        text: String,
        appBundleID: String,
        appName: String,
        createdAt: Date = Date(),
        summarized: Bool = false
    ) {
        self.id = id
        self.text = text
        self.appBundleID = appBundleID
        self.appName = appName
        self.createdAt = createdAt
        self.summarized = summarized
    }
}
