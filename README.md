<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-wordmark-dark.svg">
    <img src="assets/logo-wordmark-light.svg" width="640" alt="Shell Buddy — the mango-gold lizard and wordmark">
  </picture>
</p>
<p align="center"><strong>From intent to command.</strong></p>
<p align="center"><strong>English</strong> · <a href="README.zh-CN.md">简体中文</a></p>

Type `//`, describe what you need, and get a command right below your input. Review it, accept it, and keep working in your shell.

<p align="center">
  <img src="assets/demo.gif" width="960" alt="Shell Buddy in action: creating a file, checking disk usage, reviewing Git changes, and creating a directory">
</p>

- **Stay in your shell.** Commands run in your current session, preserving directories, environment variables, and shell state.
- **Choose your model.** Use a local or cloud OpenAI-compatible endpoint. Explicit intent rules and accepted-command cache work without a model.
- **Keep it small.** One executable built with Zig 0.17.0. No daemon or external runtime.

## Get started

Supports **Zsh 5.8+**, **Bash 5+**, and **PowerShell 7.4+** with PSReadLine 2.3.6+. macOS's bundled Bash 3.2 is unsupported; its default Zsh works out of the box.

Download **[v0.2.0](https://github.com/zhanbodev/shell-buddy/releases/tag/v0.2.0)** for macOS (Apple Silicon / Intel), Linux x86_64, or Windows x86_64. Bundles include the executable, mascot font, and installer. [Prebuilt installation →](docs/install.md#from-a-published-release)

To build and install from this checkout with Zig 0.17.0:

```sh
zig build -Doptimize=small
sh scripts/install-local.sh
export PATH="$HOME/.local/bin:$PATH"
```

On Windows:

```powershell
zig build -Doptimize=small
pwsh -File .\scripts\install-local.ps1
$env:PATH = "$env:LOCALAPPDATA\Programs\ShellBuddy\bin;$env:PATH"
```

Enable Shell Buddy in your current session:

| Shell | Initialize |
| --- | --- |
| Zsh | `eval "$(shell-buddy init zsh)"` |
| Bash | `eval "$(shell-buddy init bash)"` |
| PowerShell | `shell-buddy init powershell \| Out-String \| Invoke-Expression` |

Then configure your endpoint, model, hidden API key, and input style:

```sh
shell-buddy init
```

The wizard downloads nothing. Local rules for creating files and directories, listing files, and showing the current path work without a model.

For persistence, add the initialization command to your shell startup file using an absolute binary path. The installers do not edit startup files or terminal settings. [Installation and supported platforms →](docs/install.md)

## At your fingertips

Only input beginning with `//` activates Shell Buddy. Your description stays above the suggestion; both wrap to fit split panes.

| Key | Action |
| --- | --- |
| Tab | Show another suggestion, with a short brightness pulse on the prompt |
| Enter | Put the complete command on your command line for review or editing |
| Enter again | Execute through your shell |
| Cmd+Enter on macOS / Ctrl+Enter on Windows and Linux | Accept and execute, with [terminal key configuration](examples/terminal-keys.md) |
| Esc | Leave AI mode; keep a nonempty description, or clear `//` if empty |
| Ctrl+C | Clear the input and leave AI mode |

Incomplete streams and hidden old suggestions cannot be accepted. If a Tab refresh fails, the previous complete suggestion returns with a short explanation.

## AI input

Typing `//` temporarily hands the current input row to Shell Buddy: one gold `❯`, a subtle background, and an empty-input placeholder that disappears as you type. Generation and Tab refresh pulse the prompt without adding another icon. A complete command reveals the acceptance hint. Accepting or canceling restores your original shell prompt; context above a multiline prompt stays visible.

The default `"input_style": "square"` needs no extra font. Configure **Shell Buddy Icons 1.1+**, then select `rounded` in `shell-buddy init`, or set `"input_style": "rounded"` and run `restart`. Legacy `icon` and `nerd_font` settings no longer add an icon. [Rounded font setup →](fonts/README.md)

These input styles are included in v0.2.0. The recording above shows the earlier v0.1.0 icon interface.

## Your model, your choice

Use an OpenAI-compatible streaming Chat Completions endpoint, including Ollama's `/v1` interface. Switching between local and cloud is explicit:

```sh
shell-buddy llm local
shell-buddy llm cloud
shell-buddy doctor
```

Configuration defaults to `~/.config/shell-buddy/`. The wizard saves keys separately in `credentials.json`, in plaintext with private file permissions. Environment-based keys are also supported. [Configuration and credentials →](docs/reference.md#configuration)

| Command | Purpose |
| --- | --- |
| `shell-buddy init` | Configure a model, credentials, and input style |
| `shell-buddy start` / `stop` | Enable suggestions, or disable them and cancel generation |
| `shell-buddy restart` | Validate and reload configuration, then enable suggestions |
| `shell-buddy status` | Show state and configuration path |
| `shell-buddy cache-clear` | Remove accepted-command cache |

No background service is required. State changes apply across terminals sharing the same configuration directory.

## Built to stay out of the way

Shell Buddy checks accepted-command cache, then explicit intent rules, then your selected model. It starts one process per AI editing session and uses standard-library HTTP/TLS and streaming, with cancellation and stale-response rejection. Only accepted commands enter the cache, capped at 256 entries.

Performance targets: binary **≤5 MiB**, editor peak RSS **≤20 MiB**, local suggestion p95 **≤30 ms**. These are targets; model and network latency are separate. [Measurements and platform status →](docs/reference.md#performance)

## Develop

```sh
zig build -Doptimize=small
zig build test
python3 tests/integration.py
python3 tests/benchmark.py
python3 tests/release.py
```

The binary is written to `zig-out/bin/`. Integration tests use local mock servers and pseudo terminals, without real credentials. Native Windows PowerShell checks live in `tests/windows_terminal.py`; [CI](.github/workflows/ci.yml) defines the platform checks.

[Reference](docs/reference.md) · [Installation](docs/install.md) · [Brand and mascot](docs/brand/README.md) · [简体中文](README.zh-CN.md)
