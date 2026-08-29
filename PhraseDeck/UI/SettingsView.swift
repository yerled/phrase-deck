import SwiftUI

struct SettingsView: View {
    @ObservedObject private var store = PhraseStore.shared
    @ObservedObject private var clipboard = ClipboardCollector.shared
    @State private var draft = ""
    @State private var accessibilityOK = PermissionManager.hasAccessibility

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("快捷键") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("唤起浮层：连按两次 ⌘（Command）", systemImage: "keyboard")
                    Text("约 0.4 秒内双击左或右 Command；浮层内按 1–9、0 插入，Esc 关闭。")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox("权限") {
                HStack {
                    Image(systemName: accessibilityOK ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(accessibilityOK ? .green : .orange)
                    Text(accessibilityOK ? "辅助功能已授权（可粘贴到其它 App）" : "需要辅助功能权限才能粘贴")
                    Spacer()
                    if !accessibilityOK {
                        Button("去授权") {
                            PermissionManager.requestAccessibility()
                            PermissionManager.openAccessibilitySettings()
                        }
                    }
                    Button("刷新") {
                        accessibilityOK = PermissionManager.hasAccessibility
                    }
                }
                .padding(4)
            }

            GroupBox("采集") {
                Toggle("从剪贴板学习常用短语（推荐，比全键盘记录更安全）", isOn: $clipboard.isEnabled)
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

            GroupBox("权重 Top 短语") {
                List {
                    ForEach(store.topPhrases(limit: 30)) { phrase in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(phrase.text)
                                Text("次数 \(phrase.count) · 分数 \(String(format: "%.1f", phrase.score)) · \(phrase.source.rawValue)")
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
                .frame(minHeight: 220)
            }

            HStack {
                Button("清空全部短语", role: .destructive) {
                    store.clearAll()
                }
                Spacer()
                Text("数据保存在 ~/Library/Application Support/PhraseDeck/")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(20)
        .frame(width: 560, height: 640)
        .onAppear {
            accessibilityOK = PermissionManager.hasAccessibility
        }
    }
}
