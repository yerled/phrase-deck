# PhraseDeck

macOS 菜单栏工具：从**剪贴板**安全学习你的常用短语，全局快捷键唤起浮层，用 `1…0` 一键插入。

> MVP 刻意不做全键盘记录（隐私风险高）。剪贴板 + 手动添加已能覆盖大部分日常短语场景。

## 功能

| 能力 | 状态 |
|------|------|
| 剪贴板采集 → 短语库（过滤密码/验证码/纯数字等） | ✅ |
| 权重排序 Top10（频次 × 近因） | ✅ |
| 全局热键 `⌥⌘Space` 唤起浮层 | ✅ |
| 按键 `1–9`、`0` 插入对应短语 | ✅ |
| 模拟 ⌘V 粘贴到当前输入框 | ✅ |
| 设置页：开关采集 / 手动添加 / 删改 | ✅ |
| 全键盘采集 + 本地 LLM 聚类 | ⏳ 后续可选 |

## 要求

- macOS 13+
- Xcode 15+
- 首次运行需授予 **辅助功能（Accessibility）** 权限，才能往其它 App 粘贴

## 快速开始

```bash
# 生成 Xcode 工程
xcodegen generate

# 编译并打开
open PhraseDeck.xcodeproj
# 在 Xcode 里 Run（⌘R）
```

或：

```bash
make run
```

## 使用

1. 运行后菜单栏出现 `text.badge.plus` 图标  
2. 日常复制常用句子 → 自动进入短语库  
3. 在任意输入框按 **⌥⌘Space** → 浮层显示 Top10  
4. 按 **1–9 / 0** 插入；**Esc** 关闭  
5. 菜单 →「设置…」可手动添加、删除、开关剪贴板学习  

数据路径：`~/Library/Application Support/PhraseDeck/phrases.json`

## 架构

```
ClipboardCollector ──► PhraseMiner ──► PhraseStore
                                         │
HotKeyManager ──► OverlayPanelController ◄┘
                         │
                   TextInserter (⌘V)
```

## 路线图

- [ ] 可配置热键
- [ ] 白名单 App 的「发送框」采样（仍非全键记录）
- [ ] 本地 LLM（Ollama）合并近义短语
- [ ] Sparkle 自动更新

## License

MIT
