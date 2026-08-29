# PhraseDeck

macOS 菜单栏工具：从飞书 / Cursor 的发送内容和剪贴板学习常用短语，**连按两次 ⌘** 唤起浮层，用 `1…0` 一键粘贴。

> 不做全键盘记录。采集范围限于：飞书/Cursor 发送框（Enter）、系统剪贴板、手动添加。

## 功能（与代码一致）

| 能力 | 实现 |
|------|------|
| 飞书 / Cursor 发送采集 | `AppSendCollector`：前台为白名单 Bundle ID 时，监听 Enter / 小键盘 Enter，用 Accessibility 读取焦点控件文本 |
| 剪贴板学习 | `ClipboardCollector`：约 0.6s 轮询，经 `PhraseMiner` 过滤后入库 |
| AI 总结常用语 | `CursorAISummarizer`：默认每 30 分钟；启动约 45s 后若有待总结消息也会跑一次；调用本机 `agent` CLI（可填 `CURSOR_API_KEY`）；失败则本地 `PhraseMiner` 提炼 |
| 唤起浮层 | `HotKeyManager`：约 0.4s 内连按两次 ⌘（左右均可；中间按了别的键不算） |
| 选择并插入 | 浮层 Top10（按 `score`）；`1–9` / `0` 或点击；`Esc` 关闭；`TextInserter` 模拟 ⌘V |
| 设置与菜单 | 开关采集 / AI、API Key、手动添加、删改、清空；菜单含「立即 AI 总结」 |

分数：`score = count × 0.7 + 近因衰减 × 3`（近因半衰期约 7 天）。

## 要求

- macOS 13+
- Xcode（`project.yml` 目标为 16）+ [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- **辅助功能**权限：双击 ⌘、发送采集、粘贴到其它 App 都依赖它
- AI 总结：本机可执行 `agent`（常见路径 `~/.local/bin/agent`）；需 `agent login` 或设置里的 `CURSOR_API_KEY`

白名单 Bundle ID 见 `AppConst`（飞书/Lark 若干、`com.todesktop.230313mzl4w4u92` / `com.cursor`）。

## 快速开始

```bash
xcodegen generate
open PhraseDeck.xcodeproj   # Xcode 里 ⌘R
```

或：

```bash
make run      # Release 打包到 dist/PhraseDeck.app 并启动
make open     # 仅生成工程并打开
make package  # 只打包
```

## 使用

1. 菜单栏出现 `text.badge.plus` 图标（无 Dock 图标，`LSUIElement`）
2. 在飞书 / Cursor 里发送消息 → 写入 `sent-messages.json`，并立刻按频次进入短语库；也可等定时 / 手动 AI 总结
3. 复制文本 → 剪贴板学习（可在设置关闭）
4. 约 0.4s 内连按两次 **⌘** → 浮层显示权重 Top10（空库时会有演示短语）
5. **1–9 / 0** 或点击插入；**Esc** 关闭
6. 菜单 →「设置…」管理开关与短语；「立即 AI 总结」强制跑一轮

## 数据

目录：`~/Library/Application Support/PhraseDeck/`

| 文件 | 用途 |
|------|------|
| `phrases.json` | 短语库（最多约 500 条） |
| `sent-messages.json` | 发送采集日志（最多约 3000 条） |
| `ai-workspace/` | Cursor Agent 工作目录 |

## 架构

```
AppSendCollector ──► MessageLogStore ──► CursorAISummarizer ──┐
       │                    │  (立即 record .appSend)          │ applyAISuggestions / 失败则 mined
       │                    └──────────────────────────────────┤
ClipboardCollector ──► PhraseMiner ──► PhraseStore (.clipboard) ┤
手动添加 ──────────────────────────────────► PhraseStore (.manual) ┘
                                                      │ topPhrases(10)
HotKeyManager（双击 ⌘）──► OverlayPanelController ◄───┘
                                   │
                             TextInserter (⌘V)
```

## 路线图

- [ ] 可配置热键
- [ ] 扩展更多 App 的发送框白名单
- [ ] 本地 LLM（Ollama）合并近义短语
- [ ] Sparkle 自动更新

## License

MIT
