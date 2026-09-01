import AppKit
import Foundation
import ImageIO
import Vision

struct WindowContext {
    var appName: String
    var bundleID: String
    var source: String
    var ocrText: String = ""
    var screenshotPixels: CGSize?
    var screenshotURL: URL?

    var hasScreenshot: Bool { screenshotURL != nil }

    var isUseful: Bool {
        Self.isUseful(ocrText)
    }

    static func isUseful(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let alnum = trimmed.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || (0x4E00...0x9FFF).contains($0.value)
        }
        return alnum.count >= 8
    }
}

enum WindowContextCapture {
    private static let maxChars = 4_000

    static func targetApplication() -> NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            return front
        }
        let running = NSWorkspace.shared.runningApplications
        if let watched = running.first(where: {
            AppConst.watchedBundleIDs.contains($0.bundleIdentifier ?? "") && $0.isActive
        }) {
            return watched
        }
        return running.first { AppConst.watchedBundleIDs.contains($0.bundleIdentifier ?? "") }
    }

    static func selectRegion(onProgress: ((String) -> Void)? = nil) async -> (image: CGImage, url: URL)? {
        if !PermissionManager.hasScreenRecording {
            onProgress?("尚未授权屏幕录制，正在请求…")
            await MainActor.run {
                PermissionManager.requestScreenRecording()
            }
        }
        onProgress?("请拖选要识别的区域，Esc 取消")
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
        }
        return await interactiveSelection()
    }

    static func recognize(
        image: CGImage,
        screenshotURL: URL?,
        app: NSRunningApplication?,
        debugDir: URL?,
        onProgress: ((String) -> Void)? = nil
    ) async -> WindowContext {
        let appName = app?.localizedName ?? ""
        let bundleID = app?.bundleIdentifier ?? ""
        let pixels = CGSize(width: image.width, height: image.height)
        onProgress?("框选 \(image.width)×\(image.height)，OCR 中…")

        var screenshotURL = screenshotURL
        if let debugDir {
            screenshotURL = DebugSessionLog.writeImage(debugDir, "screenshot.png", image) ?? screenshotURL
        }
        if screenshotURL == nil {
            screenshotURL = DebugSessionLog.writeCapturePNG(image)
        }

        let result = await Task.detached(priority: .userInitiated) {
            ocr(image)
        }.value
        var text = result.text
        onProgress?("OCR：\(text.count) 字，识别图 \(result.input.width)×\(result.input.height)")

        if let debugDir {
            DebugSessionLog.writeImage(debugDir, "ocr-input.png", result.input)
            DebugSessionLog.write(debugDir, "ocr.txt", text.isEmpty ? "(empty)\n" : text)
        }

        let rawCount = text.count
        if text.count > maxChars {
            text = String(text.suffix(maxChars))
        }
        let useful = WindowContext.isUseful(text)
        let source: String
        if text.isEmpty {
            source = "ocr-empty"
        } else if useful {
            source = "ocr"
        } else {
            source = "ocr-weak"
        }

        if let debugDir {
            var summary: [String] = []
            summary.append("app: \(appName.isEmpty ? "?" : appName)")
            summary.append("bundle: \(bundleID.isEmpty ? "?" : bundleID)")
            summary.append("source: \(source)")
            summary.append("shot: selection \(image.width)×\(image.height)px")
            summary.append("ocr_chars: \(rawCount)")
            summary.append("ai_text_chars: \(text.count) (raw \(rawCount), cap \(maxChars), keep suffix)")
            summary.append("call_agent: \(useful ? "yes" : "no")")
            summary.append("screenshot_url: \(screenshotURL?.path ?? "none")")
            DebugSessionLog.write(debugDir, "summary.txt", summary.joined(separator: "\n") + "\n")
            DebugSessionLog.write(debugDir, "context.txt", text.isEmpty ? "(empty)\n" : text)
        }

        NSLog("PhraseDeck region OCR source=\(source) chars=\(text.count)")
        return WindowContext(
            appName: appName,
            bundleID: bundleID,
            source: source,
            ocrText: text,
            screenshotPixels: pixels,
            screenshotURL: screenshotURL
        )
    }

    // MARK: - Interactive selection

    nonisolated private static func interactiveSelection() async -> (image: CGImage, url: URL)? {
        await Task.detached(priority: .userInitiated) {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PhraseDeck/capture", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("selection.png")
            try? FileManager.default.removeItem(at: url)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-s", "-x", url.path]
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                NSLog("PhraseDeck screencapture failed: \(error)")
                return nil
            }
            guard process.terminationStatus == 0,
                  FileManager.default.fileExists(atPath: url.path),
                  let image = loadPNG(url) else {
                return nil
            }
            return (image, url)
        }.value
    }

    nonisolated private static func loadPNG(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    // MARK: - OCR

    nonisolated private static func ocr(_ image: CGImage) -> (text: String, input: CGImage) {
        let scaled = scaleForOCR(image)
        if let text = runOCR(scaled, level: .accurate, languages: ["zh-Hans", "zh-Hant", "en-US"]),
           WindowContext.isUseful(text) {
            return (text, scaled)
        }
        if let text = runOCR(scaled, level: .accurate, languages: nil), !text.isEmpty {
            return (text, scaled)
        }
        return (runOCR(scaled, level: .fast, languages: nil) ?? "", scaled)
    }

    nonisolated private static func scaleForOCR(_ image: CGImage) -> CGImage {
        let maxSide = 1600
        let width = image.width
        let height = image.height
        let longest = max(width, height)
        guard longest > maxSide else { return image }
        let scale = CGFloat(maxSide) / CGFloat(longest)
        let newW = Int(CGFloat(width) * scale)
        let newH = Int(CGFloat(height) * scale)
        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? image
    }

    nonisolated private static func runOCR(
        _ image: CGImage,
        level: VNRequestTextRecognitionLevel,
        languages: [String]?
    ) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = false
        if let languages {
            request.recognitionLanguages = languages
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            NSLog("PhraseDeck OCR failed: \(error)")
            return nil
        }
        let lines = (request.results ?? []).compactMap { observation -> String? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count >= 2 ? trimmed : nil
        }
        var seen = Set<String>()
        let joined = lines.filter { seen.insert($0).inserted }.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }
}
