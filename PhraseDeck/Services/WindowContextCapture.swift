import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

struct WindowContext {
    var appName: String
    var bundleID: String
    var source: String
    var axText: String = ""
    var windowFrame: CGRect?
    var screenshotPixels: CGSize?
    var screenshotURL: URL?

    var hasScreenshot: Bool { screenshotURL != nil }
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
    static func capture(
        app: NSRunningApplication?,
        debugDir: URL? = nil,
        onProgress: ((String) -> Void)? = nil
    ) async -> WindowContext {
        guard let app,
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else {
            onProgress?("没有可用的目标 App")
            return WindowContext(appName: "", bundleID: "", source: "none")
        }

        let pid = app.processIdentifier
        let appName = app.localizedName ?? bundleID
        onProgress?("读取辅助功能文本…")
        let ax = readAXText(pid: pid)
        let axText = ax.text
        onProgress?("辅助功能：\(axText.count) 字（仅作补充，不替代截图）")

        var source = axText.isEmpty ? "none" : "ax"
        var windowFrame = ax.windowFrame
        var screenshotPixels: CGSize?
        var screenshotURL: URL?
        var shotNote = "未截图"

        if !PermissionManager.hasScreenRecording {
            onProgress?("尚未授权屏幕录制，正在请求…")
            PermissionManager.requestScreenRecording()
        }
        onProgress?("截取窗口原图…")
        if let shot = await screenshotWindow(pid: pid) {
            windowFrame = shot.frame
            screenshotPixels = CGSize(width: shot.image.width, height: shot.image.height)
            shotNote = "\(shot.method) \(shot.image.width)×\(shot.image.height)px  窗口 \(fmt(shot.frame))  标题 \(shot.title)"
            onProgress?("截图窗口 \(fmt(shot.frame))，像素 \(shot.image.width)×\(shot.image.height)")
            source = axText.isEmpty ? "screenshot" : "ax+screenshot"
            if let debugDir {
                DebugSessionLog.write(debugDir, "sck-windows.txt", shot.candidates)
                if let url = DebugSessionLog.writeImage(debugDir, "screenshot.png", shot.image) {
                    screenshotURL = url
                }
            }
            if screenshotURL == nil {
                screenshotURL = DebugSessionLog.writeCapturePNG(shot.image)
            }
            if screenshotURL == nil {
                source += "+png-write-fail"
                shotNote += "（PNG 写入失败）"
                onProgress?("截图已拍到，但 PNG 写入失败")
            }
        } else {
            source += "+shot-fail"
            shotNote = "截图失败"
            onProgress?("截图失败，不调用 agent")
        }

        if let debugDir {
            DebugSessionLog.write(debugDir, "ax.txt", axText.isEmpty ? "(empty)\n" : axText)
            var summary: [String] = []
            summary.append("app: \(appName)")
            summary.append("bundle: \(bundleID)")
            summary.append("pid: \(pid)")
            summary.append("source: \(source)")
            summary.append("ax_window: \(ax.windowFrame.map(fmt) ?? "none")")
            summary.append("ax_chars: \(axText.count)")
            summary.append("shot: \(shotNote)")
            summary.append("screenshot_url: \(screenshotURL?.path ?? "none")")
            summary.append("call_agent: \(screenshotURL == nil ? "no" : "yes")")
            DebugSessionLog.write(debugDir, "summary.txt", summary.joined(separator: "\n") + "\n")
        }

        NSLog("PhraseDeck context app=\(appName) source=\(source) shot=\(screenshotURL != nil)")
        return WindowContext(
            appName: appName,
            bundleID: bundleID,
            source: source,
            axText: String(axText.suffix(maxChars)),
            windowFrame: windowFrame,
            screenshotPixels: screenshotPixels,
            screenshotURL: screenshotURL
        )
    }

    private static func fmt(_ rect: CGRect) -> String {
        String(format: "%.0f×%.0f @ (%.0f, %.0f)", rect.width, rect.height, rect.origin.x, rect.origin.y)
    }

    // MARK: - Accessibility

    private static func readAXText(pid: pid_t) -> (text: String, windowFrame: CGRect?) {
        var chunks: [String] = []
        var seen = Set<String>()
        var windowFrame: CGRect?

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

        if let window = focusedWindow(pid: pid) {
            windowFrame = axFrame(window)
            if !axLooksUseful(chunks.joined(separator: "\n")) {
                var items: [(y: CGFloat, text: String)] = []
                var visited = 0
                collect(window, items: &items, seen: &seen, visited: &visited)
                items.sort { $0.y > $1.y }
                chunks.append(contentsOf: items.map(\.text))
            }
        }

        return (chunks.joined(separator: "\n"), windowFrame)
    }

    private static func axLooksUseful(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let alnum = trimmed.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || (0x4E00...0x9FFF).contains($0.value)
        }
        return alnum.count >= 8
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

    private struct WindowShot {
        var image: CGImage
        var frame: CGRect
        var method: String
        var title: String
        var candidates: String
    }

    private static func screenshotWindow(pid: pid_t) async -> WindowShot? {
        if #available(macOS 14.0, *) {
            if let shot = await screenshotWithSCK(pid: pid) {
                return shot
            }
        }
        return screenshotLegacy(pid: pid)
    }

    @available(macOS 14.0, *)
    private static func screenshotWithSCK(pid: pid_t) async -> WindowShot? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let allForPid = content.windows.filter { $0.owningApplication?.processID == pid }
            let windows = allForPid.filter { window in
                window.isOnScreen
                    && window.frame.width >= 200
                    && window.frame.height >= 200
            }
            let candidateLines = allForPid.map { window in
                let on = window.isOnScreen ? "on" : "off"
                return "- [\(on)] \(fmt(window.frame))  \(window.title ?? "(no title)")"
            }
            let candidates = "SCK windows for pid \(pid):\n" + (candidateLines.isEmpty ? "(none)\n" : candidateLines.joined(separator: "\n") + "\n")

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
            return WindowShot(
                image: image,
                frame: window.frame,
                method: "sck",
                title: window.title ?? "(no title)",
                candidates: candidates + "picked: \(fmt(window.frame)) \(window.title ?? "")\n"
            )
        } catch {
            NSLog("PhraseDeck SCK capture failed: \(error)")
            return nil
        }
    }

    private static func screenshotLegacy(pid: pid_t) -> WindowShot? {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let windows = raw.filter { info in
            windowPID(info) == pid
                && (info[kCGWindowLayer as String] as? Int) == 0
                && (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05
        }
        func bounds(_ info: [String: Any]) -> CGRect {
            guard let dict = info[kCGWindowBounds as String] as? [String: Any] else { return .zero }
            let x = dict["X"] as? CGFloat ?? CGFloat(dict["X"] as? Int ?? 0)
            let y = dict["Y"] as? CGFloat ?? CGFloat(dict["Y"] as? Int ?? 0)
            let w = dict["Width"] as? CGFloat ?? CGFloat(dict["Width"] as? Int ?? 0)
            let h = dict["Height"] as? CGFloat ?? CGFloat(dict["Height"] as? Int ?? 0)
            return CGRect(x: x, y: y, width: w, height: h)
        }
        func area(_ info: [String: Any]) -> CGFloat {
            let r = bounds(info)
            return r.width * r.height
        }
        let candidates = windows.map { info in
            let name = info[kCGWindowName as String] as? String ?? "(no title)"
            return "- \(fmt(bounds(info)))  \(name)"
        }.joined(separator: "\n")
        guard let best = windows.max(by: { area($0) < area($1) }),
              let windowID = windowID(best),
              let image = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                windowID,
                [.boundsIgnoreFraming, .bestResolution]
              ) else { return nil }

        let frame = bounds(best)
        let title = best[kCGWindowName as String] as? String ?? "(no title)"
        return WindowShot(
            image: image,
            frame: frame,
            method: "legacy",
            title: title,
            candidates: "legacy windows for pid \(pid):\n\(candidates)\npicked: \(fmt(frame)) \(title)\n"
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
}
