import SwiftUI

struct SettingsView: View {
    @ObservedObject private var store = PhraseStore.shared
    @ObservedObject private var appSend = AppSendCollector.shared
    @ObservedObject private var messageLog = MessageLogStore.shared
    @ObservedObject private var ai = CursorAISummarizer.shared
    @ObservedObject private var permissions = PermissionManager.shared
    @State private var draft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("快捷键") {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("常用回复：连按两次 ⌘", systemImage: "keyboard")
                        Text("约 0.4 秒内连按两次。浮层内按数字插入，Esc 关闭。")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                GroupBox("权限") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: permissions.accessibilityTrusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(permissions.accessibilityTrusted ? .green : .orange)
                            Text(permissions.accessibilityTrusted ? "辅助功能已授权" : "需要辅助功能（采集发送 + 粘贴）")
                            Spacer()
                            if !permissions.accessibilityTrusted {
                                Button("去授权") {
                                    PermissionManager.requestAccessibility()
                                    PermissionManager.openAccessibilitySettings()
                                }
                            }
                        }
                        HStack {
                            Image(systemName: permissions.hotKeyTapActive ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(permissions.hotKeyTapActive ? .green : .orange)
                            Text(permissions.hotKeyTapActive ? "双击 ⌘ 监听已生效" : "双击 ⌘ 监听未生效")
                        }
                        if permissions.needsRelaunch {
                            Text("授权已经记下，但当前这次运行里事件监听仍然建不起来。macOS 经常要完全退出后再打开才会生效。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("重新启动 PhraseDeck") {
                                PermissionManager.shared.relaunch()
                            }
                        }
                        Button("刷新并重新注册监听") {
                            PermissionManager.shared.refreshFromSettings()
                        }
                    }
                    .padding(4)
                }

                GroupBox("自动采集（飞书 / Cursor）") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("采集飞书、Cursor 里按下 Enter / ⌘Enter 发送的内容", isOn: Binding(
                            get: { appSend.isEnabled },
                            set: { newValue in
                                appSend.isEnabled = newValue
                                if newValue { appSend.start() } else { appSend.stop() }
                            }
                        ))
                        if let last = appSend.lastCaptured {
                            Text("最近采集自 \(appSend.lastAppName ?? "?")：\(last)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Text("已记录 \(messageLog.messages.count) 条发送日志 · 短语库 \(store.phrases.count) 条")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(4)
                }

                GroupBox("Cursor AI 全量总结（每 30 分钟）") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("启用定时总结", isOn: Binding(
                            get: { ai.isEnabled },
                            set: { newValue in
                                ai.isEnabled = newValue
                                if newValue { ai.start() } else { ai.stop() }
                            }
                        ))
                        SecureField("CURSOR_API_KEY（AI 总结必填）", text: $ai.apiKey)
                            .textFieldStyle(.roundedBorder)
                        Link("打开 Cursor Dashboard 创建 User API Key", destination: URL(string: "https://cursor.com/dashboard/integrations")!)
                            .font(.caption)
                        Text("菜单栏 App 读不到终端里的 agent login。无头模式必须把 Key 填在这里。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button(ai.isRunning ? "总结中…" : "立即总结一次") {
                                Task { await ai.summarizeNow() }
                            }
                            .disabled(ai.isRunning)
                            Spacer()
                            if let last = ai.lastRunAt {
                                Text("上次：\(last.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(ai.lastStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(4)
                }

                GroupBox("Token 用量") {
                    TokenUsageStatsView()
                        .padding(4)
                }

                GroupBox("手动添加") {
                    HStack {
                        TextField("输入一句常用语…", text: $draft)
                            .textFieldStyle(.roundedBorder)
                        Button("添加") {
                            let text = draft
                            draft = ""
                            _ = store.record(text, source: .manual)
                        }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(4)
                }

                GroupBox("短语库") {
                    List {
                        ForEach(store.phrases.sorted { $0.score > $1.score }) { phrase in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(phrase.text)
                                    Text("发送 \(phrase.count) 次 · 分数 \(String(format: "%.1f", phrase.score)) · \(phrase.source.rawValue)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    store.delete(phrase.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .frame(minHeight: 200)
                }

                HStack {
                    Button("清空短语库", role: .destructive) {
                        store.clearAll()
                    }
                    Button("清空采集消息", role: .destructive) {
                        messageLog.clear()
                    }
                    Spacer()
                    Text("~/Library/Application Support/PhraseDeck/")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(20)
        }
        .frame(width: 620, height: 780)
        .onAppear {
            PermissionManager.shared.syncTaps(force: true)
        }
    }
}

private struct TokenUsageStatsView: View {
    @ObservedObject private var usageStore = TokenUsageStore.shared
    @State private var period: TokenUsagePeriod = .day

    var body: some View {
        let summary = usageStore.summary(for: period)
        VStack(alignment: .leading, spacing: 10) {
            Picker("统计维度", selection: $period) {
                ForEach(TokenUsagePeriod.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
            ], spacing: 8) {
                metric("调用", "\(summary.callCount)")
                metric("成功", "\(summary.successCount)")
                metric("输入", formatTokens(summary.usage.inputTokens))
                metric("输出", formatTokens(summary.usage.outputTokens))
                metric("缓存读", formatTokens(summary.usage.cacheReadTokens))
                metric("缓存写", formatTokens(summary.usage.cacheWriteTokens))
                metric("合计", formatTokens(summary.usage.totalTokens))
                metric("次均", formatTokens(summary.averageTotalTokens))
            }

            // Compact comparison across all periods
            VStack(alignment: .leading, spacing: 4) {
                ForEach(TokenUsagePeriod.allCases) { item in
                    let s = usageStore.summary(for: item)
                    HStack {
                        Text(item.title)
                            .frame(width: 36, alignment: .leading)
                        Text("\(s.callCount) 次")
                            .frame(width: 52, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        Text(formatTokens(s.usage.totalTokens))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .fontWeight(item == period ? .semibold : .regular)
                    }
                    .font(.caption.monospacedDigit())
                }
            }
            .padding(.top, 2)

            if let last = usageStore.lastEvent {
                Text(lastEventLine(last))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text("尚无本地记录。AI 总结成功后会写入 token-usage.json。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("自然日 / 周（周一至周日）/ 月按 Asia/Shanghai。合计 = 输入 + 输出 + 缓存读写。")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack {
                Link("Cursor Usage Dashboard", destination: URL(string: "https://cursor.com/dashboard/usage")!)
                    .font(.caption)
                Spacer()
                Button("清空用量统计", role: .destructive) {
                    usageStore.clear()
                }
                .disabled(usageStore.events.isEmpty)
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospacedDigit().weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func lastEventLine(_ event: TokenUsageEvent) -> String {
        let when = event.createdAt.formatted(date: .abbreviated, time: .shortened)
        let ok = event.success ? "成功" : "失败"
        let tokens = event.usage.hasAny ? formatTokens(event.usage.totalTokens) : "未知"
        let model = event.model.map { " · \($0)" } ?? ""
        return "最近：\(when) · \(event.kind.title) · \(ok) · \(tokens)\(model)"
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        }
        if n >= 10_000 {
            return String(format: "%.1fK", Double(n) / 1_000)
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
