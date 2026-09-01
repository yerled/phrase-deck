import Foundation

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

    static func runAsk(prompt: String, apiKey: String, workspace: URL) async throws -> String {
        let agentPath = resolveAgentPath()
        guard FileManager.default.isExecutableFile(atPath: agentPath) else {
            throw NSError(domain: "PhraseDeck", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "未找到 agent CLI（\(agentPath)）。请安装 Cursor Agent 或配置 PATH。",
            ])
        }

        let key = resolvedAPIKey(apiKey)
        guard !key.isEmpty else {
            throw NSError(domain: "PhraseDeck", code: 401, userInfo: [
                NSLocalizedDescriptionKey: "智能回复需要 CURSOR_API_KEY。打开 https://cursor.com/dashboard/integrations 创建 User API Key，粘贴到 PhraseDeck 设置。仅执行 agent login 不够（无头模式 -p 不认浏览器登录）。",
            ])
        }

        let args = [
            "--api-key", key,
            "-p",
            "--mode", "ask",
            "--output-format", "text",
            "--workspace", workspace.path,
            prompt,
        ]
        return try await runProcess(launchPath: agentPath, arguments: args, environmentAPIKey: key)
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

    private static func runProcess(launchPath: String, arguments: [String], environmentAPIKey: String) async throws -> String {
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

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                let outStr = String(data: outData, encoding: .utf8) ?? ""
                let errStr = String(data: errData, encoding: .utf8) ?? ""

                let combined = (outStr + "\n" + errStr)
                if combined.localizedCaseInsensitiveContains("Authentication required")
                    || combined.localizedCaseInsensitiveContains("CURSOR_API_KEY") {
                    continuation.resume(throwing: NSError(domain: "PhraseDeck", code: 401, userInfo: [
                        NSLocalizedDescriptionKey: "Cursor 无头调用未认证。请到 https://cursor.com/dashboard/integrations 创建 User API Key，填进 PhraseDeck 设置。agent login 对 -p 模式无效。",
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
}
