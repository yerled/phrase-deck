import SwiftUI

struct SettingsView: View {
    @ObservedObject private var store = PhraseStore.shared
    @ObservedObject private var appSend = AppSendCollector.shared
    @ObservedObject private var messageLog = MessageLogStore.shared
    @ObservedObject private var ai = CursorAISummarizer.shared
    @State private var draft = ""
    @State private var accessibilityOK = PermissionManager.hasAccessibility

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("快捷键") {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("常用回复：连按两次 ⌘", systemImage: "keyboard")
                        Label("智能回复：连按三次 ⌘", systemImage: "sparkles")
                        Text("约 0.4 秒内连按；第三次会从常用语升级为智能回复。浮层内按数字插入，Esc 关闭。")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                GroupBox("权限") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: accessibilityOK ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(accessibilityOK ? .green : .orange)
                            Text(accessibilityOK ? "辅助功能已授权" : "需要辅助功能（采集发送 + 粘贴）")
                            Spacer()
                            if !accessibilityOK {
                                Button("去授权") {
                                    PermissionManager.requestAccessibility()
                                    PermissionManager.openAccessibilitySettings()
                                }
                            }
                        }
                        Button("刷新权限") {
                            accessibilityOK = PermissionManager.hasAccessibility
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
                        SecureField("CURSOR_API_KEY（智能回复 / 总结必填）", text: $ai.apiKey)
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
        .frame(width: 580, height: 720)
        .onAppear {
            accessibilityOK = PermissionManager.hasAccessibility
        }
    }
}
