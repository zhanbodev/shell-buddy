# Shell Buddy 自定义字体图标

[English](README.md) · [项目首页](../README.zh-CN.md)

[ShellBuddyIcons.ttf](ShellBuddyIcons.ttf) 字体族为 **Shell Buddy Icons**，当前版本 **1.1**。包含自有蜥蜴轮廓 U+F5000，以及圆角输入需要的 U+F5001–U+F5006 六个端帽字形。

AI 输入只显示一个金色 `❯`，不再追加星星或蜥蜴。默认 `"input_style": "square"` 无需自定义字体；选择 `"rounded"` 前先配置终端的字体映射或补丁字体。旧版仅含蜥蜴的字体需要重新安装/打补丁。程序无法自动检测终端字体，SSH 场景也一样。

[程序与字体组合安装](../docs/install.zh-CN.md)会默认安装字体。`shell-buddy init` 只负责程序配置，不下载文件。下方命令用于单独安装字体。

## 安装符号字体

在项目根目录执行，macOS / Linux：

```sh
sh fonts/install.sh
```

仅安装到当前用户目录：macOS 为 `~/Library/Fonts`，Linux 为 `${XDG_DATA_HOME:-~/.local/share}/fonts/shell-buddy`；Linux 存在 `fc-cache` 时会刷新缓存。

Windows PowerShell：

```powershell
pwsh -File .\fonts\install.ps1
```

脚本复制到当前用户字体目录，并注册当前用户字体。也可以直接打开 TTF 文件，选择“安装”。完成后重新启动终端应用。Windows 安装脚本尚需原生 Windows 验收。

## 在终端中启用字体

**Kitty** 可以保留原有文字字体，在 `kitty.conf` 中加入：

```conf
symbol_map U+F5000-U+F5006 Shell Buddy Icons
```

重新加载配置或重启 Kitty。该映射只影响 Shell Buddy 的私有字符。[Kitty 官方说明](https://sw.kovidgoyal.net/kitty/conf/#opt-kitty.symbol_map)

**iTerm2、Terminal.app、Windows Terminal 等没有按字符映射字体的终端**，推荐将图标加入正在使用的等宽字体副本，再选择这个新字体。仅安装符号字体并不保证终端会自动选它作为回退字体；不要把只有符号的字体当作主文字字体。

## 为现有等宽字体添加蜥蜴

这一步是可选开发工具，需要 Python 和 `fonttools`。运行 Shell Buddy 本身仍无需 Python。

macOS / Linux：

```sh
python3 -m venv .font-tools
.font-tools/bin/python -m pip install -r tools/font-requirements.txt
.font-tools/bin/python tools/patch_icon_font.py "/path/to/YourMono-Regular.ttf" "/path/to/YourMono-ShellBuddy.ttf"
```

Windows：

```powershell
py -m venv .font-tools
.\.font-tools\Scripts\python.exe -m pip install -r tools\font-requirements.txt
.\.font-tools\Scripts\python.exe tools\patch_icon_font.py "C:\path\YourMono-Regular.ttf" "C:\path\YourMono-ShellBuddy.ttf"
```

输入应为**静态 TrueType `.ttf` 等宽字体**，不支持 `.ttc` 字体集合、可变字体或 CFF `.otf`。工具保留原文件、文字字形、许可证记录和单字符宽度，生成名称以 **Shell Buddy** 结尾的新字体族，并打印准确名称。修改后的副本会移除不再有效的源数字签名表。已有输出文件或 U+F5000–U+F5006 已被占用时会拒绝写入。使用独立粗体或斜体文件时，分别生成对应样式副本。

安装生成的新 TTF：macOS / Windows 打开文件后选择安装；Linux 复制到 `~/.local/share/fonts` 后执行 `fc-cache -f`。随后在终端字体设置中选择工具打印的新字体族。[iTerm2 字体设置](https://iterm2.com/documentation-fonts.html) · [Windows Terminal 字体设置](https://learn.microsoft.com/windows/terminal/customize-settings/profile-appearance#font-face)

## 启用圆角

在现有 `config.json` 中设置：

```json
"input_style": "rounded"
```

然后运行：

```sh
shell-buddy restart
```

也可以运行 `shell-buddy init`，在 Input style 步骤选择 rounded。首次默认 square，已有明确选择会保留；`doctor` 显示有效设置。旧 icon/nerd_font 字段不再启用图标，向导保存时移除。

在已配置好字体的终端中测试字符：

```sh
printf '\363\265\200\201\363\265\200\202 \363\265\200\203\363\265\200\204 \363\265\200\205\363\265\200\206\n'
```

PowerShell：

```powershell
0xF5001..0xF5006 | ForEach-Object { [char]::ConvertFromUtf32($_) }
```

程序将端帽前景色与输入底色设为同色。补丁中的端帽铺满原字体单字符宽度及 hhea 上升/下降范围，原文字形和指标保持不变。终端额外行距可能使边缘留白，建议默认行高。出现缺字或接缝时，切回 `"input_style": "square"` 并重新加载。SSH 字体在本地终端渲染；符号字体不要作为主文字字体。

## 源文件与验证

[lizard.svg](lizard.svg) 来自已确认的[蜥蜴 Logo](../assets/logo.png)的单色轮廓，眼睛和舌头使用留白。随项目提供的字体只包含本项目图形、圆角形状和空格，不打包第三方文字字体。

在安装了 `fonttools` 的 Python 环境中运行：

```sh
python tools/build_icon_font.py
python tests/fonts.py
```

字体构建可复现。测试覆盖私有区映射、有效轮廓、原文件保留、文字宽度、新字体族命名、覆盖与冲突保护、确定性生成；这些检查不代表所有终端的原生视觉验收已经完成。
