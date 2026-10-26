# Shell Buddy 使用指南

[程序与字体组合安装指南](install.zh-CN.md)。安装器默认安装字体；`init` 只配置程序，不下载或安装字体。

[English reference](reference.md) · [中文首页](../README.zh-CN.md)

用自然语言生成 Shell 命令。Zig 0.17.0 编写，单个可执行文件，无第三方运行时，仅在 `//` 输入模式期间运行。

```text
❯  创建 hello.txt 文件
   touch './hello.txt'
```

完整命令在描述下方独立显示，流式预览使用较淡文字，描述和命令均按当前终端宽度自动折行。Tab 清空下方显示，提示符播放 480ms 明暗变化，然后显示其他候选；切换期间不能接受隐藏的旧候选。Enter 将建议替换为当前行，供继续编辑；再按 Enter 由当前 Shell 执行。macOS 的 Cmd+Enter、Windows/Linux 的 Ctrl+Enter 可接受完整候选并直接执行。Esc 保留描述并退出，Ctrl+C 清空退出。流式输出完成前不能接受或执行。

## 构建与启用

需要 **Zig 0.17.0**。0.17 的体积优化选项为 `small`，对应之前的 ReleaseSmall。

```sh
zig build -Doptimize=small
export PATH="$PWD/zig-out/bin:$PATH"
```

Zsh 5.8+：

```sh
eval "$(shell-buddy init zsh)"
```

没有加入 PATH 时，可在项目目录直接初始化：

```sh
eval "$(./zig-out/bin/shell-buddy init zsh)"
```

`init` 会将正在运行的二进制的绝对路径保存到 `SHELL_BUDDY_BIN`，切换工作目录后也可继续使用 `//`。编译和运行 `start`、`restart` 只会更新程序状态；首次使用仍需在当前 Shell 执行初始化语句，以安装按键绑定。尚未初始化时，这两个命令会输出可复制的初始化命令。

Bash 5+（Ubuntu 24.04 默认版本适用；macOS 自带 Bash 3.2 不支持）：

```sh
eval "$(shell-buddy init bash)"
```

Windows 使用 PowerShell 7.4+、PSReadLine 2.3.6+ 和 Windows Terminal：

```powershell
zig build -Doptimize=small
$env:PATH = "$PWD\zig-out\bin;$env:PATH"
shell-buddy init powershell | Out-String | Invoke-Expression
```

把对应初始化语句放入自己的 Shell 配置可持久启用。程序不会修改 `.zshrc`、`.bashrc` 或 PowerShell profile。初始化会自动设置 `SHELL_BUDDY_BIN`；需要使用其他二进制时，可在初始化后覆盖该变量。

持久化时请使用可执行文件的绝对路径，例如 Zsh 配置中的 `eval "$(/absolute/path/to/shell-buddy init zsh)"`。`shell-buddy doctor` 的 `shell integration` 显示继承的初始化标记。若显示 `not loaded`，应先执行初始化；若其他插件覆盖了按键绑定，需要在相关插件之后初始化 Shell Buddy。

`init` 同时注册原生 Tab 补全。输入 `shell-buddy ` 后按 Tab 查看带说明的子命令，输入 `shell-buddy llm ` 后按 Tab 查看模型服务选项；输入部分名称再按 Tab 补全。Bash 在空参数处逐行展示选项，Zsh 和 PowerShell 使用原生补全列表。补全也支持 `init` 的 Shell 名称、`--shell`、`suggest` 和 `edit` 的参数。补全过程不启动额外进程，程序运行提示统一使用英文。

```text
usage: shell-buddy llm <profile>

  - local  Use the local model service
  - cloud  Use the cloud model service
```

行首键入 `//` 后，程序临时接管当前输入行，统一显示一个金色 `❯` 和低对比度底色，兼容原提示符为 `$`、`%`、`>` 或主题自定义文本的情况。上方多行主题的路径/Git 信息保留；单行主题所在行在 AI 模式中临时替换，退出后由 Shell 恢复原样。程序不修改提示符函数或 Shell 配置。

空输入显示 `What do you need?`，不进入真实输入缓冲区。输入描述后占位提示消失；生成和 Tab 换版仅改变提示符亮度。未完成的结果显示较淡，完整命令使用终端前景色，足够宽的窗口会显示 `Tab another  Enter accept`。描述和候选按终端宽度换行，窗口较矮时保持光标可见，接受始终返回完整命令。支持中文、基础编辑、括号粘贴和终端恢复。

更新二进制后，可重新执行 `eval "$(shell-buddy init zsh)"` 来更新当前会话的绑定；该命令不会写入 `.zshrc`。如果仍在旧版生成界面中，先按 Ctrl+C 退出，再执行初始化。

Zsh 集成兼容 `zsh-autosuggestions` 与 `zsh-syntax-highlighting`。如果旧版初始化后 Enter 不再提交命令，请先打开一个新终端，再初始化新版；旧会话的按键绑定不会因为二进制更新而自动恢复。

## 输入样式

`input_style` 默认 `"square"`，无需字体依赖。`"rounded"` 使用 **Shell Buddy Icons 1.1+** 的 U+F5001–U+F5006 端帽字形模拟圆角；多行输入使用顶部/底部圆角和直边。先配置终端字体，再开启圆角；旧 `icon`、`nerd_font` 设置忽略，向导保存时清理。

`init` 在密钥步骤后提供 square/rounded 选择，Tab 切换、Enter 确认。首次默认 square，已有明确选择会保留。手动修改 JSON 后运行 `shell-buddy restart`，`doctor` 显示有效值。程序无法自动检测字体覆盖，缺字时请回到 square。[字体配置与升级 →](../fonts/README.zh-CN.md)

## 模型配置

无需配置即可使用创建文件、创建目录、列出目录、显示当前路径等明确意图规则。例如 `创建 hello.txt 文件`、`创建 工作文档 目录`、`当前路径`，以及 `create file hello.txt`。

推荐通过交互向导配置：

```sh
./zig-out/bin/shell-buddy init
# 已加入 PATH 后：shell-buddy init
```

向导逐行展示 `local`、`cloud` 和说明，Tab 切换选择，Enter 确认；随后填写兼容接口的 Base URL、模型名称与 API key，最后选择输入样式 `square` 或 `rounded`。已有地址和模型会预填，可直接编辑。密钥输入隐藏；已有密钥时按 Enter 保留，本地无鉴权服务可留空。Esc、Ctrl+C 或 Ctrl+D 在保存前取消，不改动配置。向导不自动调用模型或验证密钥是否有效；可用 `suggest --generate` 检查服务。

配置和密钥分开保存：

```text
~/.config/shell-buddy/config.json       # 地址、模型、默认服务
~/.config/shell-buddy/credentials.json  # 按 local/cloud 保存的 API key
```

凭据文件位于实际 `config.json` 的同一目录，遵循下面的配置路径设置。**密钥以明文保存**，macOS/Linux 的专用配置目录权限为 `0700`，新写入的配置、凭据文件权限为 `0600`；Windows 使用仅授予当前用户访问权限的 ACL。更新使用文件锁与原子替换，保留另一服务的密钥。凭据不出现在终端画面、日志或 Shell 历史中。

向导保存所选服务并设为默认值，自动通知已打开的生成界面重新加载，无需再运行 `restart`；程序原来已停止时仍保持停止。可重复运行向导修改配置或更换密钥。它不会写入 Shell 启动文件；首次使用 `//` 仍需执行对应的 `init zsh`、`init bash` 或 `init powershell` 初始化语句。

`shell-buddy init`（原 `onboard`）打开配置向导；`init zsh/bash/powershell` 继续输出 Shell 集成脚本。首次运行 `start`、`restart` 或 `init <shell>` 会创建配置模板，已有配置保持原样；配置向导仅在完成输入后保存。配置路径：

- macOS/Linux：`$XDG_CONFIG_HOME/shell-buddy/config.json`，默认 `~/.config/shell-buddy/config.json`。
- Windows：`%USERPROFILE%\.config\shell-buddy\config.json`，也支持 `XDG_CONFIG_HOME`。
- `SHELL_BUDDY_CONFIG` 可指定其他路径；`shell-buddy doctor` 显示实际位置。

运行 `shell-buddy config-example` 输出 [配置示例](../examples/config.json)。`default` 选择 `"local"` 或 `"cloud"`，初始为 `"local"`。填写所选服务的模型名称和地址，再运行 `shell-buddy restart`。示例中的占位模型尚未配置时，只使用规则和已有缓存；程序不会自动切换云端与本地服务。

```sh
shell-buddy start     # 创建初始配置并启用
shell-buddy stop      # 停用，取消所有终端中正在进行的生成
shell-buddy restart   # 校验配置、重新加载并启用
shell-buddy status    # 查看启停状态和配置路径
shell-buddy init      # 交互配置服务并保存密钥，自动重新加载
shell-buddy llm       # 查看当前选择和逐项说明
shell-buddy llm local # 切换到本地模型
shell-buddy llm cloud # 切换到云端模型
```

这些命令控制按需运行的生成器，无需常驻服务；Shell 按键集成仍需执行对应的 `init zsh`、`init bash` 或 `init powershell` 初始化语句。启停状态保存在配置目录的 `state.json`，在使用同一配置目录的终端间共享，重新打开 Shell 后也会保留。`init` 不改变启停状态。

`llm` 切换会校验目标 profile，以带锁的原子更新保存 `default`，保留其他配置，并通知所有已打开的生成界面重新加载，无需再执行 `restart`。程序已停止时，切换服务保持停止状态。未找到目标 profile 或配置无效时，切换失败，配置和启停状态保持原样。旧配置的 `active_profile` 仍可读取；存在 `default` 时优先使用 `default`，通过 `llm` 保存选择时会移除旧字段。

`stop` 保留正在输入的描述并恢复终端，普通 Shell 命令继续照常使用。`restart` 让已打开的生成界面在约 100ms 内取消旧请求，按新配置重新生成；校验失败时返回非零退出码，当前启停状态和已打开的生成界面保持原样。运行中的单次 `suggest --generate` 在停止或重启时取消并返回非零退出码，可重新运行。每个新输入会话也会重新读取配置。

```json
{
  "default": "local",
  "profiles": {
    "local": {
      "base_url": "http://localhost:11434/v1",
      "model": "YOUR_LOCAL_MODEL"
    },
    "cloud": {
      "base_url": "https://YOUR_PROVIDER/v1",
      "model": "YOUR_CLOUD_MODEL",
      "api_key_env": "SHELL_BUDDY_API_KEY"
    }
  },
  "input_style": "square",
  "debounce_ms": 150,
  "max_tokens": 2048,
  "timeout_ms": 8000
}
```

模型名称填写服务已提供的模型。支持流式 `/chat/completions` 的 OpenAI 兼容服务，包括 Ollama 的 `/v1` 接口；程序不负责安装、启动或下载模型。`api_key_env` 填写环境变量名称，例如 `SHELL_BUDDY_API_KEY`，不要填写密钥本身。读取顺序为：该环境变量 → 当前服务在 `credentials.json` 中的密钥；显式设置为空或无效的环境变量会报错。通过向导保存后，无需每次手动 `export`。`llm local`、`llm cloud` 会使用各自的凭据。

所有模型请求固定发送 `reasoning_effort: "none"`，不提供开启思考的选项。DeepSeek 与 Ollama 的兼容接口均提供该控制：[DeepSeek 文档](https://api-docs.deepseek.com/guides/thinking_mode/)、[Ollama 文档](https://docs.ollama.com/api/openai-compatibility)。其他兼容服务也须支持非思考请求；不支持该参数时明确报告请求被拒绝，不自动删除参数或退回思考模式。流中仍返回非空 `reasoning_content`、`reasoning` 或 `thinking` 时，立即拒绝该结果，提示选择非思考模型。服务内部未公开的计算无法由客户端验证。

`max_tokens` 是全局输出预算，默认 `2048`，允许整数 `1`–`32768`，发送给所选模型。旧配置省略时同样使用默认值；向导保存时补入缺省值，并保留已有预算。修改 JSON 后运行 `shell-buddy restart` 生效，`doctor` 显示有效预算与非思考请求策略。缓存按预算隔离。单条命令的长度限制仍为 4096 字节，且必须是单行。

错误分别显示：输出预算耗尽（`OutputLimitReached`）、流缺少正常结束事件（`IncompleteStream`）、传输中断（`StreamDisconnected`）、服务内容过滤、模型拒绝、空响应、工具调用、响应格式错误、未关闭思考，以及 HTTP 鉴权、余额不足、无权限、模型/端点不存在、参数错误、限流、服务不可用、DNS 与 TLS 失败。CLI 同时打印英文说明和错误类别；不输出原始服务错误正文或思考内容。任何未完成或失败的结果都不能接受、执行或写入确认缓存。

仅发送描述、OS、Shell、当前路径和生成替代版本所需的当前候选。不读取历史、项目文件、目录清单或其他环境变量内容。输入修改后取消旧请求，不复用过期结果。

流式请求明确发送 `Accept-Encoding: identity`，让服务返回未压缩的 SSE 文本，避免声明支持未实现的 gzip/deflate。服务忽略协商并强制压缩时，会显示 `Unsupported response compression`；限流单独显示 `Rate limited`。默认防抖为停止输入后 150ms，最多保留一个有效请求；两种错误不能仅凭输入速度混为一谈。

缓存优先于规则，规则优先于 LLM。Tab 请求新版本时会隐藏旧候选；请求失败或结果重复时，在动效结束后恢复已有完整候选并显示原因。命中本地结果不会自动请求模型；Tab 才按需请求替代版本，没有预生成循环。重复候选会提示重试。网络错误不会清空描述或已有建议。

仅用户接受的命令写入本地缓存，按描述、OS、Shell、工作目录和模型配置隔离。缓存最多 256 条，采用单独锁文件和原子替换；它记录接受行为，不代表命令已成功执行。macOS/Linux 默认在 `~/.cache/shell-buddy/cache.json`，遵循 `XDG_CACHE_HOME`；Windows 在 `%LOCALAPPDATA%\shell-buddy\cache.json`。可用 `SHELL_BUDDY_CACHE` 覆盖位置，`shell-buddy cache-clear` 清空。

## 执行组合键

终端需要发送独立序列来区分普通 Enter 和组合键。参考 [按键配置](../examples/terminal-keys.md) 与 [Windows Terminal 示例](../examples/windows-terminal.json)。未配置的终端可能把 Ctrl+Enter 当作普通 Enter。

接受后执行由 ZLE、Readline 或 PSReadLine 完成，所以 `cd`、`Set-Location`、变量赋值和作业控制作用于当前 Shell。Shell Buddy 本身不启动子 Shell 执行命令。

## CLI 与验证

```sh
shell-buddy suggest --shell zsh --intent '创建 hello.txt 文件'
shell-buddy suggest --shell powershell --intent '当前路径'
shell-buddy suggest --shell bash --intent '查找当前目录的大文件' --generate
shell-buddy suggest --shell bash --intent '查找当前目录的大文件' --generate --timings
shell-buddy doctor
shell-buddy init --help
shell-buddy llm --help

zig build test
python3 tests/integration.py
python3 tests/benchmark.py
```

`suggest` 输出建议而不执行、也不写入确认缓存。`--generate` 跳过本地预测以检查所选模型，`--timings` 在 stderr 另行输出模型 `first_token_ms` 与 `complete_ms`，包含请求构造与网络耗时。`edit` 是适配器接口：stdout 只输出回填文本，退出码 `0` 为接受、`10` 为执行、`20` 为取消；其他退出码为失败。终端画面通过独立 TTY/Console 句柄输出。

集成测试临时监听 `127.0.0.1` 并创建伪终端，不使用真实模型或密钥。测试包含慢流、截断、鉴权错误、超时、取消、终端恢复、缓存、当前会话执行、配置初始化与并发更新、多终端停止和热重载、LLM 切换与缓存隔离，以及原生 Tab 补全。向导测试覆盖隐藏输入、取消不落盘、独立凭据存储、重新配置、密钥轮换、环境变量优先级与实际 Authorization 请求头。Bash 测试需要本机 Bash 5+；Windows 使用 `tests/windows_terminal.py` 与测试依赖 `pywinpty`。

```sh
zig build -Dtarget=x86_64-linux-musl -Doptimize=small --prefix zig-out/linux
zig build -Dtarget=x86_64-windows -Doptimize=small --prefix zig-out/windows
```

体积目标 ≤5 MiB，峰值 RSS ≤20 MiB，本地预测端到端 p95 ≤30ms。基准单独记录本地进程开销；远端模型与网络延迟不包含在本地预测指标内。原生三平台测试由 [CI](../.github/workflows/ci.yml) 定义，交叉编译不能代替 Windows 原生交互验收。

## 验收边界

本机为 macOS arm64，已验证真实 Bash 5 和 Zsh 的输入、换行、窗口缩放、Tab 换版、取消与恢复、当前会话执行，以及离线模拟模型的错误、超时和并发行为。Linux/Windows 已交叉构建，原生 CI 任务已定义；交叉构建不代表原生交互验收通过。Ollama 和修复后完整云端请求仍需独立验收。

最新本地性能数据见[英文参考文档](reference.md#performance)。模型延迟独立测量，不包含在本地预测性能中。
