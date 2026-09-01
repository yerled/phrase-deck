import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit
import Vision

struct WindowContext {
    var appName: String
    var bundleID: String
    var text: String
    var source: String

    var isUseful: Bool {
        Self.isUseful(text)
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
    private static let maxNodes = 500
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

    @MainActor
    static func capture(app: NSRunningApplication?) async -> WindowContext {
        guard let app,
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else {
            return WindowContext(appName: "", bundleID: "", text: "", source: "none")
        }

        let pid = app.processIdentifier
        let appName = app.localizedName ?? bundleID
        let axText = readAXText(pid: pid)

        var text = axText
        var source = axText.isEmpty ? "none" : "ax"

        if !WindowContext.isUseful(axText) {
            if !PermissionManager.hasScreenRecording {
                PermissionManager.requestScreenRecording()
            }
            if let image = await screenshotWindow(pid: pid) {
                let ocrText = await Task.detached(priority: .userInitiated) {
                    ocr(image)
                }.value
                if ocrText.count > text.count {
                    text = ocrText
                    source = axText.isEmpty ? "ocr" : "ax+ocr"
                } else if !ocrText.isEmpty {
                    source += "+ocr-weak"
                } else {
                    source += "+ocr-empty"
                }
            } else {
                source += "+shot-fail"
            }
        }

        if text.count > maxChars {
            text = String(text.suffix(maxChars))
        }
        NSLog("PhraseDeck context app=\(appName) source=\(source) chars=\(text.count)")
        return WindowContext(appName: appName, bundleID: bundleID, text: text, source: source)
    }

    // MARK: - Accessibility

    private static func readAXText(pid: pid_t) -> String {
        var chunks: [String] = []
        var seen = Set<String>()

        func append(_ raw: String?) {
            guard let raw else { return }
            let normalized = PhraseMiner.normalize(raw)
            guard normalized.count >= 2, seen.insert(normalized).inserted else { return }
            chunks.append(normalized)
        }

        let system = AXUIElementCreateSystemWide()
        if let focused = copyElement(system, kAXFocusedUIElementAttribute as String),
           elementPid(focused) == pid {
            append(axString(focused, kAXSelectedTextAttribute as String))
            append(axString(focused, kAXValueAttribute as String))

            var current: AXUIElement? = focused
            var chain: [AXUIElement] = []
            for _ in 0..<8 {
                guard let el = current else { break }
                chain.append(el)
                current = copyElement(el, kAXParentAttribute as String)
            }

            let seed = chain.first(where: { el in
                guard let frame = axFrame(el) else { return false }
                return frame.height >= 180 && frame.width >= 200
            }) ?? chain.last

            if let seed {
                var items: [(y: CGFloat, text: String)] = []
                var visited = 0
                collect(seed, items: &items, seen: &seen, visited: &visited)
                items.sort { $0.y > $1.y }
                chunks.append(contentsOf: items.map(\.text))
            }
        }

        if !WindowContext.isUseful(chunks.joined(separator: "\n")), let window = focusedWindow(pid: pid) {
            var items: [(y: CGFloat, text: String)] = []
            var visited = 0
            collect(window, items: &items, seen: &seen, visited: &visited)
            items.sort { $0.y > $1.y }
            chunks.append(contentsOf: items.map(\.text))
        }

        return chunks.joined(separator: "\n")
    }

    private static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(pid)
        if let window = copyElement(axApp, kAXFocusedWindowAttribute as String) {
            return window
        }
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement] {
            return windows.first
        }
        return nil
    }

    private static func collect(
        _ element: AXUIElement,
        items: inout [(y: CGFloat, text: String)],
        seen: inout Set<String>,
        visited: inout Int
    ) {
        guard visited < maxNodes else { return }
        visited += 1

        let role = axString(element, kAXRoleAttribute as String) ?? ""
        if skippedRoles.contains(role) { return }

        if role != (kAXWindowRole as String), let raw = usefulText(element, role: role) {
            let normalized = PhraseMiner.normalize(raw)
            if normalized.count >= 2, seen.insert(normalized).inserted {
                items.append((y: axFrame(element)?.minY ?? 0, text: normalized))
            }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children.prefix(60) {
            collect(child, items: &items, seen: &seen, visited: &visited)
            if visited >= maxNodes { return }
        }
    }

    private static let skippedRoles: Set<String> = [
        kAXMenuBarRole as String,
        kAXMenuRole as String,
        kAXMenuItemRole as String,
        kAXToolbarRole as String,
        "AXScrollBar",
        "AXSplitter",
        kAXImageRole as String,
    ]

    private static func usefulText(_ element: AXUIElement, role: String) -> String? {
        if let value = axString(element, kAXValueAttribute as String), (2...800).contains(value.count) {
            return value
        }
        if let selected = axString(element, kAXSelectedTextAttribute as String), (2...800).contains(selected.count) {
            return selected
        }
        if let title = axString(element, kAXTitleAttribute as String), (2...800).contains(title.count) {
            return title
        }
        if role == (kAXStaticTextRole as String) || role == "AXUnknown" || role == "AXGroup" {
            if let desc = axString(element, kAXDescriptionAttribute as String), (2...800).contains(desc.count) {
                return desc
            }
        }
        return nil
    }

    private static func elementPid(_ element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    private static func copyElement(_ element: AXUIElement, _ attr: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success, let ref else { return nil }
        return (ref as! AXUIElement)
    }

    private static func axString(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success, let ref else { return nil }
        if let s = ref as? String { return s }
        if CFGetTypeID(ref) == CFAttributedStringGetTypeID() {
            return CFAttributedStringGetString(unsafeBitCast(ref, to: CFAttributedString.self)) as String
        }
        return nil
    }

    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    // MARK: - Screenshot / OCR

    private static func screenshotWindow(pid: pid_t) async -> CGImage? {
        if #available(macOS 14.0, *) {
            if let image = await screenshotWithSCK(pid: pid) {
                return image
            }
        }
        return screenshotLegacy(pid: pid)
    }

    @available(macOS 14.0, *)
    private static func screenshotWithSCK(pid: pid_t) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let windows = content.windows.filter { window in
                window.owningApplication?.processID == pid
                    && window.isOnScreen
                    && window.frame.width >= 200
                    && window.frame.height >= 200
            }
            guard let window = windows.max(by: {
                $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
            }) else {
                NSLog("PhraseDeck SCK: no window for pid \(pid)")
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let scale = max(NSScreen.main?.backingScaleFactor ?? 2, 1)
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            config.capturesAudio = false

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            NSLog("PhraseDeck SCK shot \(image.width)x\(image.height)")
            return image
        } catch {
            NSLog("PhraseDeck SCK capture failed: \(error)")
            return nil
        }
    }

    private static func screenshotLegacy(pid: pid_t) -> CGImage? {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let windows = raw.filter { info in
            windowPID(info) == pid
                && (info[kCGWindowLayer as String] as? Int) == 0
                && (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05
        }
        func area(_ info: [String: Any]) -> CGFloat {
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any] else { return 0 }
            let w = bounds["Width"] as? CGFloat ?? CGFloat(bounds["Width"] as? Int ?? 0)
            let h = bounds["Height"] as? CGFloat ?? CGFloat(bounds["Height"] as? Int ?? 0)
            return w * h
        }
        guard let best = windows.max(by: { area($0) < area($1) }),
              let windowID = windowID(best) else { return nil }

        return CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        )
    }

    private static func windowPID(_ info: [String: Any]) -> pid_t {
        if let v = info[kCGWindowOwnerPID as String] as? pid_t { return v }
        if let v = info[kCGWindowOwnerPID as String] as? Int { return pid_t(v) }
        return -1
    }

    private static func windowID(_ info: [String: Any]) -> CGWindowID? {
        if let v = info[kCGWindowNumber as String] as? CGWindowID { return v }
        if let v = info[kCGWindowNumber as String] as? Int { return CGWindowID(v) }
        if let v = info[kCGWindowNumber as String] as? UInt32 { return v }
        return nil
    }

    nonisolated private static func ocr(_ image: CGImage) -> String {
        let scaled = scaleForOCR(image)
        if let text = runOCR(scaled, level: .accurate, languages: ["zh-Hans", "zh-Hant", "en-US"]),
           WindowContext.isUseful(text) {
            return text
        }
        if let text = runOCR(scaled, level: .accurate, languages: nil), !text.isEmpty {
            return text
        }
        return runOCR(scaled, level: .fast, languages: nil) ?? ""
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

    nonisolated private static func runOCR(_ image: CGImage, level: VNRequestTextRecognitionLevel, languages: [String]?) -> String? {
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
