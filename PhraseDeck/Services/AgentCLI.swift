import Foundation

struct AgentRunResult {
    var text: String
    var usage: AgentTokenUsage
    var model: String?
    var sessionId: String?
    var durationMs: Int?
}

enum AgentCLI {
    static func resolveAgentPath() -> String {
        let candidates = [
            NSString(string: "~/.local/bin/agent").expandingTildeInPath,
            "/usr/local/bin/agent",
            "/opt/homebrew/bin/agent",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return candidates[0]
    }

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: resolveAgentPath())
    }

    static func runAsk(
        prompt: String,
        apiKey: String,
        workspace: URL,
        debugDir: URL? = nil,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> AgentRunResult {
        let agentPath = resolveAgentPath()
        guard FileManager.default.isExecutableFile(atPath: agentPath) else {
            throw NSError(domain: "PhraseDeck", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "未找到 agent CLI（\(agentPath)）。请安装 Cursor Agent 或配置 PATH。",
            ])
        }

        let key = resolvedAPIKey(apiKey)
        guard !key.isEmpty else {
            throw NSError(domain: "PhraseDeck", code: 401, userInfo: [
                NSLocalizedDescriptionKey: "需要 CURSOR_API_KEY。打开 https://cursor.com/dashboard/integrations 创建 User API Key，粘贴到 PhraseDeck 设置。仅执行 agent login 不够（无头模式 -p 不认浏览器登录）。",
            ])
        }

        hopProgress(onProgress, "agent：\(agentPath)")
        hopProgress(onProgress, "工作区：\(workspace.path)")

        let args = [
            "--api-key", key,
            "-p",
            "--trust",
            "--mode", "ask",
            "--model", "auto",
            "--output-format", "stream-json",
            "--workspace", workspace.path,
            prompt,
        ]
        hopProgress(onProgress, "模型：auto · 输出：stream-json（含 token）")
        let raw = try await runProcess(
            launchPath: agentPath,
            arguments: args,
            environmentAPIKey: key,
            debugDir: debugDir,
            onProgress: onProgress
        )
        let parsed = parseRunOutput(raw)
        if parsed.usage.hasAny {
            hopProgress(
                onProgress,
                "token：in \(parsed.usage.inputTokens) / out \(parsed.usage.outputTokens) / cache \(parsed.usage.cacheReadTokens)+\(parsed.usage.cacheWriteTokens) · 合计 \(parsed.usage.totalTokens)"
            )
        } else {
            hopProgress(onProgress, "本次未解析到 token usage（仍已记账）")
        }
        return parsed
    }

    /// Settings first, then process env, then login-shell ~/.zshrc (GUI apps don't inherit Terminal env).
    static func resolvedAPIKey(_ explicit: String) -> String {
        let trimmed = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let env = ProcessInfo.processInfo.environment["CURSOR_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        return loginShellAPIKey()
    }

    private static var cachedShellKey: String?

    private static func loginShellAPIKey() -> String {
        if let cached = cachedShellKey { return cached }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "printenv CURSOR_API_KEY"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            cachedShellKey = ""
            return ""
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        cachedShellKey = value
        return value
    }

    static func extractJSONArray(from raw: String) throws -> Data {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "["),
              let end = trimmed.lastIndex(of: "]"),
              start < end else {
            throw NSError(domain: "PhraseDeck", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Agent 输出里没有 JSON 数组",
            ])
        }
        return Data(String(trimmed[start...end]).utf8)
    }

    /// Prefer stream-json / json envelopes; fall back to raw assistant text.
    static func parseRunOutput(_ raw: String) -> AgentRunResult {
        let lines = raw
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var usage = AgentTokenUsage.zero
        var resultUsage: AgentTokenUsage?
        var textPieces: [String] = []
        var model: String?
        var sessionId: String?
        var durationMs: Int?
        var sawEnvelope = false

        for line in lines {
            guard line.hasPrefix("{"),
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            sawEnvelope = true

            if let m = obj["model"] as? String, !m.isEmpty { model = m }
            if let sid = stringValue(obj["session_id"]) ?? stringValue(obj["sessionId"]) {
                sessionId = sid
            }
            if let ms = intValue(obj["duration_ms"]) ?? intValue(obj["durationMs"]) {
                durationMs = ms
            }

            if let type = obj["type"] as? String {
                switch type {
                case "system":
                    if let m = obj["model"] as? String, !m.isEmpty { model = m }
                case "assistant":
                    if let message = obj["message"] as? [String: Any],
                       let content = message["content"] as? [[String: Any]] {
                        let chunk = content.compactMap { $0["text"] as? String }.joined()
                        if !chunk.isEmpty { textPieces.append(chunk) }
                    }
                    if let nested = obj["usage"] as? [String: Any], let u = parseUsage(from: nested) {
                        usage.merge(u)
                    }
                case "result":
                    if let result = obj["result"] as? String {
                        textPieces = [result]
                    }
                    if let nested = obj["usage"] as? [String: Any], let u = parseUsage(from: nested) {
                        resultUsage = u
                    } else if let u = parseUsage(from: obj) {
                        resultUsage = u
                    }
                case "usage":
                    if let nested = obj["usage"] as? [String: Any], let u = parseUsage(from: nested) {
                        usage.merge(u)
                    } else if let u = parseUsage(from: obj) {
                        usage.merge(u)
                    }
                default:
                    if let nested = obj["usage"] as? [String: Any], let u = parseUsage(from: nested) {
                        usage.merge(u)
                    }
                }
            } else if let nested = obj["usage"] as? [String: Any], let u = parseUsage(from: nested) {
                usage.merge(u)
            } else if let u = parseUsage(from: obj) {
                usage.merge(u)
            }
        }

        if let resultUsage {
            usage = resultUsage
        }

        if !sawEnvelope {
            // Older text-only output, or a single JSON result blob without newlines.
            if let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let result = obj["result"] as? String {
                    textPieces = [result]
                }
                if let u = parseUsage(from: obj["usage"] as? [String: Any] ?? obj) {
                    usage = u
                }
                model = (obj["model"] as? String) ?? model
                sessionId = stringValue(obj["session_id"]) ?? stringValue(obj["sessionId"]) ?? sessionId
                durationMs = intValue(obj["duration_ms"]) ?? intValue(obj["durationMs"]) ?? durationMs
            } else {
                textPieces = [raw]
            }
        }

        let text = textPieces.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? textPieces.last!
            : raw
        return AgentRunResult(
            text: text,
            usage: usage,
            model: model,
            sessionId: sessionId,
            durationMs: durationMs
        )
    }

    private static func parseUsage(from obj: [String: Any]) -> AgentTokenUsage? {
        let input = intValue(obj["inputTokens"])
            ?? intValue(obj["input_tokens"])
            ?? 0
        let output = intValue(obj["outputTokens"])
            ?? intValue(obj["output_tokens"])
            ?? 0
        let cacheRead = intValue(obj["cacheReadTokens"])
            ?? intValue(obj["cache_read_tokens"])
            ?? 0
        let cacheWrite = intValue(obj["cacheWriteTokens"])
            ?? intValue(obj["cache_write_tokens"])
            ?? 0
        let usage = AgentTokenUsage(
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite
        )
        return usage.hasAny ? usage : nil
    }

    private static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let v as Int: return v
        case let v as Int64: return Int(v)
        case let v as Double: return Int(v)
        case let v as NSNumber: return v.intValue
        case let v as String: return Int(v.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }

    private static func stringValue(_ any: Any?) -> String? {
        switch any {
        case let v as String:
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        default:
            return nil
        }
    }

    private static func runProcess(
        launchPath: String,
        arguments: [String],
        environmentAPIKey: String,
        debugDir: URL? = nil,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            if !environmentAPIKey.isEmpty {
                env["CURSOR_API_KEY"] = environmentAPIKey
            }
            env["HOME"] = NSHomeDirectory()
            process.environment = env

            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err

            hopProgress(onProgress, "agent 进程启动，等待模型…")

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            let timeout = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: timeout)

            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                timeout.cancel()
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                let outStr = String(data: outData, encoding: .utf8) ?? ""
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                if let debugDir {
                    DebugSessionLog.write(debugDir, "agent-stdout.txt", outStr)
                    DebugSessionLog.write(debugDir, "agent-stderr.txt", errStr)
                    DebugSessionLog.write(
                        debugDir,
                        "agent-meta.txt",
                        "exit=\(process.terminationStatus)\nstdout_chars=\(outStr.count)\nstderr_chars=\(errStr.count)\n"
                    )
                }

                hopProgress(onProgress, "agent 退出码 \(process.terminationStatus)，stdout \(outStr.count) 字，stderr \(errStr.count) 字")
                if !errStr.isEmpty {
                    let preview = errStr.replacingOccurrences(of: "\n", with: " ")
                    hopProgress(onProgress, "stderr：\(preview.prefix(160))")
                }

                // Only classify CLI/transport errors from stderr + stream-json error
                // envelopes. Never scan full stdout: the prompt/corpus (and model
                // thinking) can legitimately contain strings like CURSOR_API_KEY.
                let authFailure = looksLikeCLIFailure(
                    stderr: errStr,
                    stdout: outStr,
                    needles: ["Authentication required", "CURSOR_API_KEY"]
                )
                if authFailure {
                    continuation.resume(throwing: NSError(domain: "PhraseDeck", code: 401, userInfo: [
                        NSLocalizedDescriptionKey: "Cursor 无头调用未认证。请到 https://cursor.com/dashboard/integrations 创建 User API Key，填进 PhraseDeck 设置。agent login 对 -p 模式无效。",
                    ]))
                    return
                }
                if looksLikeCLIFailure(
                    stderr: errStr,
                    stdout: outStr,
                    needles: ["out of usage", "Increase limits"]
                ) {
                    continuation.resume(throwing: NSError(domain: "PhraseDeck", code: 429, userInfo: [
                        NSLocalizedDescriptionKey: "Cursor 额度用完了。已尝试 Auto；若仍失败，请到 Cursor 切换 Auto 或让管理员提高额度。",
                    ]))
                    return
                }
                if looksLikeCLIFailure(
                    stderr: errStr,
                    stdout: outStr,
                    needles: ["Workspace Trust Required"]
                ) {
                    continuation.resume(throwing: NSError(domain: "PhraseDeck", code: 403, userInfo: [
                        NSLocalizedDescriptionKey: "Cursor Agent 拒绝未信任的工作区。请更新 PhraseDeck 后重试（已自动加 --trust）。",
                    ]))
                    return
                }
                if process.terminationStatus == 15 {
                    continuation.resume(throwing: NSError(domain: "PhraseDeck", code: 15, userInfo: [
                        NSLocalizedDescriptionKey: "agent 超过 90 秒无结果，已终止。",
                    ]))
                    return
                }
                if process.terminationStatus != 0, outStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continuation.resume(throwing: NSError(domain: "PhraseDeck", code: Int(process.terminationStatus), userInfo: [
                        NSLocalizedDescriptionKey: errStr.isEmpty ? "agent 退出码 \(process.terminationStatus)" : errStr,
                    ]))
                    return
                }
                continuation.resume(returning: outStr.isEmpty ? errStr : outStr)
            }
        }
    }

    /// Agent work runs off the main actor. AppKit overlay updates must hop first.
    private static func hopProgress(_ onProgress: ((String) -> Void)?, _ message: String) {
        if Thread.isMainThread {
            onProgress?(message)
        } else {
            DispatchQueue.main.async { onProgress?(message) }
        }
    }

    /// True when stderr mentions a needle, or stream-json has an error result/envelope mentioning it.
    private static func looksLikeCLIFailure(stderr: String, stdout: String, needles: [String]) -> Bool {
        if needles.contains(where: { stderr.localizedCaseInsensitiveContains($0) }) {
            return true
        }
        for line in stdout.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{"),
                  let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let type = obj["type"] as? String
            let isError = (obj["is_error"] as? Bool) == true
                || type == "error"
                || ((obj["subtype"] as? String)?.localizedCaseInsensitiveContains("error") == true)
            guard isError else { continue }
            let blob = trimmed + "\n" + stderr
            if needles.contains(where: { blob.localizedCaseInsensitiveContains($0) }) {
                return true
            }
        }
        return false
    }
}
