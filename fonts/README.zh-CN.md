# Shell Buddy 自定义字体图标

[English](README.md) · [项目首页](../README.zh-CN.md)

[ShellBuddyIcons.ttf](ShellBuddyIcons.ttf) 使用我们选定的蜥蜴形象，提取为保留大眼睛、吐舌和卷尾的单色轮廓。字体族为 **Shell Buddy Icons**，字符位为私有区 **U+F5000**，颜色由终端文字样式控制。

默认配置为 `"icon": "star"`，无需安装字体就显示 `✦`。旧的 `nerd_font` 字段不再启用图标。安装字体后仍需设置终端的字体映射或主字体，再主动选择 `lizard`。程序无法可靠检测终端字体，SSH 场景也一样。

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
symbol_map U+F5000 Shell Buddy Icons
```

重新加载配置或重启 Kitty。该映射只影响蜥蜴字符。[Kitty 官方说明](https://sw.kovidgoyal.net/kitty/conf/#opt-kitty.symbol_map)

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

输入应为**静态 TrueType `.ttf` 等宽字体**，不支持 `.ttc` 字体集合、可变字体或 CFF `.otf`。工具保留原文件、文字字形、许可证记录和单字符宽度，生成名称以 **Shell Buddy** 结尾的新字体族，并打印准确名称。修改后的副本会移除不再有效的源数字签名表。已有输出文件或 U+F5000 已被占用时会拒绝写入。使用独立粗体或斜体文件时，分别生成对应样式副本。

安装生成的新 TTF：macOS / Windows 打开文件后选择安装；Linux 复制到 `~/.local/share/fonts` 后执行 `fc-cache -f`。随后在终端字体设置中选择工具打印的新字体族。[iTerm2 字体设置](https://iterm2.com/documentation-fonts.html) · [Windows Terminal 字体设置](https://learn.microsoft.com/windows/terminal/customize-settings/profile-appearance#font-face)

## 启用蜥蜴

在现有 `config.json` 中设置：

```json
"icon": "lizard"
```

然后运行：

```sh
shell-buddy restart
```

也可以运行 `shell-buddy init`，在图标步骤选择 `lizard`。向导默认选择 `star`，已有明确选择则保留；`doctor` 显示当前有效值。

在已配置好字体的终端中测试字符：

```sh
printf '\363\265\200\200\n'
```

PowerShell：

```powershell
[char]::ConvertFromUtf32(0xF5000)
```

显示缺字时，改回 `"icon": "star"` 并重新加载。远程主机安装字体不会改变本地终端的渲染字体。完整蜥蜴缩到一个字符时会减少细节，属于正常的单色字体图标表现。

## 源文件与验证

[lizard.svg](lizard.svg) 来自已确认的[蜥蜴 Logo](../assets/logo.png)的单色轮廓，眼睛和舌头使用留白。随项目提供的字体只包含本项目图形和空格，不打包第三方文字字体。

在安装了 `fonttools` 的 Python 环境中运行：

```sh
python tools/build_icon_font.py
python tests/fonts.py
```

字体构建可复现。测试覆盖私有区映射、有效轮廓、原文件保留、文字宽度、新字体族命名、覆盖与冲突保护、确定性生成；这些检查不代表所有终端的原生视觉验收已经完成。
