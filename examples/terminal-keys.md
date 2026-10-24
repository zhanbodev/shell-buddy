# 执行组合键

Enter 的序列是 `CR`。生成模式只回填完整候选。执行键需要另发 CSI 序列：

| 平台 | 按键 | 发送文本 |
|---|---|---|
| macOS | Cmd+Enter | `ESC [ 13 ; 9 u` |
| Windows/Linux | Ctrl+Enter | `ESC [ 13 ; 5 u` |

在生成模式外，这两个序列也可提交普通命令。进入模式后，只有完整候选可执行；生成期间按下执行键不会排队自动执行。

## iTerm2

在 Settings → Profiles → Keys → Key Mappings 添加 Cmd+Enter，选择 **Send Escape Sequence**，输入 `[13;9u`（不再填写 ESC）。

也可使用 Send Hex Codes：`0x1b 0x5b 0x31 0x33 0x3b 0x39 0x75`。

## Windows Terminal

把 [windows-terminal.json](windows-terminal.json) 中的 action 与 keybinding 合并到 `settings.json` 的对应数组。该 action 使用 `sendInput` 发送 `\u001b[13;5u`。

## 其他终端、WSL 和 SSH

在终端自己的快捷键配置中发送同样的序列。WSL 使用 Linux 二进制与 bash/zsh 适配器。SSH 会话需要远端安装 Shell Buddy 并加载对应适配器。tmux 或其他终端复用器需要传递此序列；首版不自动配置复用器。

参考：[iTerm2 Keys](https://iterm2.com/documentation-preferences-keys.html)、[Windows Terminal sendInput](https://learn.microsoft.com/en-us/windows/terminal/customize-settings/actions#send-input)。
