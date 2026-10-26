# 安装 Shell Buddy

[English](install.md) · [项目首页](../README.zh-CN.md)

可安装预编译的 [v0.2.0 发布包](https://github.com/zhanbodev/shell-buddy/releases/tag/v0.2.0)，也可使用 Zig 0.17.0 从源码构建。

## 从当前源码安装

macOS / Linux，需要 Zig 0.17.0：

```sh
zig build -Doptimize=small
sh scripts/install-local.sh
export PATH="$HOME/.local/bin:$PATH"
```

Windows，需要 Zig 0.17.0、PowerShell 7.4+：

```powershell
zig build -Doptimize=small
pwsh -File .\scripts\install-local.ps1
$env:PATH = "$env:LOCALAPPDATA\Programs\ShellBuddy\bin;$env:PATH"
```

安装器默认把程序和 **Shell Buddy Icons** 字体一起安装到当前用户目录，无需管理员权限。它不会修改 PATH、Shell 启动文件、终端字体设置或模型配置。

## 从公开发布包安装

下载器会识别系统和架构，下载对应压缩包和 `SHA256SUMS`，校验通过后再解压安装。预编译安装不需要 Zig 或 Python；macOS / Linux 的下载步骤需要 `curl` 或 `wget`，程序本身不依赖它们。

macOS / Linux：

```sh
curl -fsSL https://raw.githubusercontent.com/zhanbodev/shell-buddy/v0.2.0/install.sh -o /tmp/shell-buddy-install.sh
sh /tmp/shell-buddy-install.sh --version v0.2.0
export PATH="$HOME/.local/bin:$PATH"
```

Windows PowerShell 7.4+：

```powershell
$installer = Join-Path ([IO.Path]::GetTempPath()) 'shell-buddy-install.ps1'
Invoke-WebRequest https://raw.githubusercontent.com/zhanbodev/shell-buddy/v0.2.0/install.ps1 -OutFile $installer
pwsh -File $installer -Version v0.2.0
$env:PATH = "$env:LOCALAPPDATA\Programs\ShellBuddy\bin;$env:PATH"
```

可以先查看下载的脚本再运行。版本也可指定为 `latest`，选择最新公开 Release。压缩包与校验文件来自同一个 GitHub Release；校验用于发现损坏或不匹配，不能代替发布者签名。首版二进制尚未签名，macOS 版本尚未公证。

离线安装：从 [Releases](https://github.com/zhanbodev/shell-buddy/releases) 下载匹配的压缩包和 `SHA256SUMS`，校验 SHA-256 后解压，进入解压得到的 `shell-buddy` 目录，运行**包内**安装器：

| 平台 | 压缩包 | 安装命令 |
| --- | --- | --- |
| macOS Apple Silicon | `shell-buddy-macos-aarch64.tar.gz` | `sh install.sh` |
| macOS Intel | `shell-buddy-macos-x86_64.tar.gz` | `sh install.sh` |
| Linux x86_64 | `shell-buddy-linux-x86_64.tar.gz` | `sh install.sh` |
| Windows x86_64 | `shell-buddy-windows-x86_64.zip` | `pwsh -File .\install.ps1` |

首版发布矩阵不包含 Linux ARM 和 Windows ARM；Linux 使用 musl 构建。正式发布前仍需查看原生 CI 验收结果。

## 安装位置与选项

| 项目 | 默认位置 |
| --- | --- |
| macOS / Linux 程序 | `~/.local/bin/shell-buddy` |
| macOS 字体 | `~/Library/Fonts/ShellBuddyIcons.ttf` |
| Linux 字体 | `${XDG_DATA_HOME:-~/.local/share}/fonts/shell-buddy/ShellBuddyIcons.ttf` |
| Windows 程序 | `%LOCALAPPDATA%\Programs\ShellBuddy\bin\shell-buddy.exe` |
| Windows 字体 | `%LOCALAPPDATA%\Microsoft\Windows\Fonts\ShellBuddyIcons.ttf`，注册为当前用户字体 |

POSIX 安装器支持 `--bin-dir <目录>`、`--font-dir <目录>` 和 `--no-font`；使用下载器时放在 `--` 后面：

```sh
sh /tmp/shell-buddy-install.sh --version v0.2.0 -- --bin-dir "$HOME/.local/bin" --no-font
```

PowerShell 对应参数为 `-BinDir`、`-FontDir`、`-NoFont`。本地安装器另提供 `-SkipFontRegistration`，仅复制字体文件而不写注册表。

## 在 Shell 中启用

将程序目录加入 PATH 后：

| Shell | 当前会话初始化 |
| --- | --- |
| Zsh 5.8+ | `eval "$(shell-buddy init zsh)"` |
| Bash 5+ | `eval "$(shell-buddy init bash)"` |
| PowerShell 7.4+、PSReadLine 2.3.6+ | `shell-buddy init powershell \| Out-String \| Invoke-Expression` |

持久启用时，由你将 PATH 和初始化命令写入 Shell 启动文件。`eval` 将输出的函数与按键绑定加载到当前会话，不会写入启动文件。仅构建、安装或执行 `restart` 不会加载这些绑定。

运行 `shell-buddy init` 配置本地/云端模型、凭据与输入样式。该向导**不下载任何文件**。没有模型时，规则与已有缓存仍可使用。

## 启用圆角输入

v0.2.0 使用单个金色 `❯`，默认 `"input_style": "square"`，无需额外字体。圆角需要 **Shell Buddy Icons 1.1+**；按[字体指南](../fonts/README.zh-CN.md)安装并配置 U+F5001–U+F5006，或为现有等宽字体重新生成副本，再在 `shell-buddy init` 选择 `rounded`。已有仅含蜥蜴的旧字体需要更新。v0.1.0 使用此前的图标界面。

不要把只有符号的字体选作主文字字体。SSH 场景中，需要在本地终端机器上配置字体。字体缺失时显式选择 square，程序不会自动检测或修改字体设置。

## 更新与卸载

更新时重新运行新版本安装器，然后在已有会话中重新加载 Shell 初始化命令；配置和凭据会保留。`shell-buddy restart` 用于校验并重新加载配置。

卸载时删除安装的程序、移除自己添加的 PATH/初始化配置，并通过系统字体管理器移除 **Shell Buddy Icons**。只有希望同时删除配置、凭据和缓存时，才另外移除 `~/.config/shell-buddy`。
