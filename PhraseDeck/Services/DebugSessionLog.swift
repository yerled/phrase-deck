import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Per-run dump of smart-reply capture / prompt / agent I/O.
/// Overlay only shows summaries; inspect files in `~/Library/Application Support/PhraseDeck/debug/`.
enum DebugSessionLog {
    static var currentDirectory: URL?

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhraseDeck/debug", isDirectory: true)
    }

    static var latest: URL {
        root.appendingPathComponent("latest", isDirectory: true)
    }

    @discardableResult
    static func begin() -> URL {
        let stamp = Self.stampFormatter.string(from: Date())
        let dir = root.appendingPathComponent(stamp, isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        replaceLatest(with: dir)
        pruneOldSessions(keeping: 15)
        currentDirectory = dir
        write(dir, "summary.txt", "started \(stamp)\n")
        return dir
    }

    private static let io = DispatchQueue(label: "com.yerled.PhraseDeck.debug-log")

    static func write(_ dir: URL, _ name: String, _ text: String) {
        io.sync {
            let url = dir.appendingPathComponent(name)
            try? text.data(using: .utf8)?.write(to: url, options: .atomic)
            mirrorToLatestUnlocked(name, from: dir)
        }
    }

    static func append(_ dir: URL, _ name: String, _ text: String) {
        io.sync {
            let url = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            if let data = text.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
            mirrorToLatestUnlocked(name, from: dir)
        }
    }

    @discardableResult
    static func writeImage(_ dir: URL, _ name: String, _ image: CGImage) -> URL? {
        io.sync {
            let url = dir.appendingPathComponent(name)
            guard writePNGUnlocked(image, to: url) else { return nil }
            mirrorToLatestUnlocked(name, from: dir)
            return url
        }
    }

    static func writeCapturePNG(_ image: CGImage) -> URL? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhraseDeck/capture", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("screenshot.png")
        return io.sync {
            writePNGUnlocked(image, to: url) ? url : nil
        }
    }

    private static func writePNGUnlocked(_ image: CGImage, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    static func openFolder() {
        let fm = FileManager.default
        try? fm.createDirectory(at: latest, withIntermediateDirectories: true)
        NSWorkspace.shared.open(latest)
    }

    private static func replaceLatest(with dir: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: latest)
        try? fm.createDirectory(at: latest, withIntermediateDirectories: true)
        if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for item in items {
                let dest = latest.appendingPathComponent(item.lastPathComponent)
                try? fm.copyItem(at: item, to: dest)
            }
        }
    }

    private static func mirrorToLatestUnlocked(_ name: String, from dir: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: latest, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent(name)
        let dest = latest.appendingPathComponent(name)
        guard fm.fileExists(atPath: src.path) else { return }
        try? fm.removeItem(at: dest)
        try? fm.copyItem(at: src, to: dest)
    }

    private static func pruneOldSessions(keeping limit: Int) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let sessions = items.filter { url in
            url.lastPathComponent != "latest"
                && ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
        }
        .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for extra in sessions.dropFirst(limit) {
            try? fm.removeItem(at: extra)
        }
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()
}
