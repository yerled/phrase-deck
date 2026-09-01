# PhraseDeck

macOS 菜单栏工具：从飞书 / Cursor 的发送内容学习常用短语，**连按两次 ⌘** 唤起浮层，用 `1…0` 一键粘贴。

> 不做全键盘记录。采集范围限于：飞书/Cursor 发送框（Enter）、手动添加。

## 功能（与代码一致）

| 能力 | 实现 |
|------|------|
| 飞书 / Cursor 发送采集 | `AppSendCollector`：前台为白名单 Bundle ID 时，监听 Enter / 小键盘 Enter，用 Accessibility 读取焦点控件文本 |
| AI 全量总结 | `CursorAISummarizer`：默认每 30 分钟；启动约 45s 后也会跑一次。输入为**当前短语库 + 全部发送日志**，输出替换整个短语库；只保留工作/生活可复用短句，丢弃一次性和无意义内容。失败则本地 `PhraseMiner` 提炼（不替换现有库） |
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

日常开发和热更新不一样：Swift 没有 Vite 那种保存即刷新，但**不必每次打包安装**。

```bash
make dev      # Debug 编译并重启（日常改代码用这个）
make logs     # 看 NSLog（智能回复采词、OCR 失败原因）
make open     # 打开 Xcode，⌘R 运行，断点/控制台更完整
make package  # 只在要分发/装到 dist 时才打 Release 包
```

`make dev` 和 Xcode 跑的是同一个 Bundle ID，辅助功能 / 屏幕录制授权会保留。

首次：

```bash
make open     # 生成工程并打开 Xcode，⌘R
```

## 使用

1. 菜单栏出现 `text.badge.plus` 图标（无 Dock 图标，`LSUIElement`）
2. 在飞书 / Cursor 里发送消息 → 写入 `sent-messages.json`，并立刻按频次进入短语库；也可等定时 / 手动全量 AI 总结
3. 约 0.4s 内连按两次 **⌘** → 浮层显示权重 Top10（空库时会有演示短语）
4. **1–9 / 0** 或点击插入；**Esc** 关闭
5. 菜单 →「设置…」管理开关与短语；「立即 AI 总结」用当前短语 + 全部日志重建短语库

## 数据

目录：`~/Library/Application Support/PhraseDeck/`

| 文件 | 用途 |
|------|------|
| `phrases.json` | 短语库（由全量 AI 总结维护，无条数上限） |
| `sent-messages.json` | 发送采集日志（最多约 3000 条） |
| `ai-workspace/` | Cursor Agent 工作目录 |

## 架构

```
AppSendCollector ──► MessageLogStore ──► CursorAISummarizer
       │                    │              │ 输入：当前短语 + 全部日志
       │                    │              │ 输出：replaceAll（工作/生活可复用短句）
       │                    │  (立即 record .appSend)
       │                    └──────────────┤
手动添加 ──────────────────► PhraseStore (.manual) ┘
                                      │ topPhrases(10)
HotKeyManager（双击 ⌘）──► OverlayPanelController
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
