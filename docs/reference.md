# Shell Buddy reference

[English](../README.md) · [简体中文](guide.zh-CN.md)

## Shell integration

Requires Bash 5+, Zsh 5.8+, or PowerShell 7.4+ with PSReadLine 2.3.6+. Source builds require Zig 0.17.0. Build with `zig build -Doptimize=small`. [Installation and bundled fonts](install.md) · [Release checklist](releasing.md).

`init` opens the model setup wizard. `init bash`, `init zsh`, and `init powershell` print integration scripts. Shell Buddy never writes shell startup files. `eval` loads bindings into the current shell; exporting `PATH` only makes the executable discoverable.

From the repository root, without changing `PATH`:

```sh
eval "$(./zig-out/bin/shell-buddy init zsh)"
```

The adapter pins the binary's absolute path in `SHELL_BUDDY_BIN`, so suggestions continue after changing directories. Use an absolute path when putting initialization in `.zshrc`, `.bashrc`, or a PowerShell profile. If plugins override bindings, initialize Shell Buddy after them. Zsh regression tests include `zsh-autosuggestions` and `zsh-syntax-highlighting`.

Only a leading `//` activates AI mode. Pasting an entire `// description` and pressing Enter also enters the editor. Ordinary input keeps native shell behavior. UTF-8 Chinese, bracketed paste, arrows, Home/End, Backspace/Delete, and Ctrl+A/E/U/W are supported. Descriptions and suggestions wrap to the terminal width; tall input keeps the insertion cursor in the viewport. A visual ellipsis never truncates the accepted command.

Tab clears the output region and plays one eight-frame rotation over 480ms in the icon cell, then restores the configured icon. Character terminals use rotating glyphs rather than a transformed image. A pending request is reused when Tab is pressed again. Hidden previous candidates and unfinished streams cannot be accepted. Failed or duplicate alternatives restore the previous complete result and show the reason. Editing the description cancels the transition and the stale request. Normal generation uses a slow brightness pulse.

Enter fills the native command buffer. A second Enter executes it. Modified Enter accepts and submits through the native editor: [terminal sequences](../examples/terminal-keys.md), [Windows Terminal example](../examples/windows-terminal.json). This preserves current-session `cd`, variables, and shell state.

## Configuration

Run `shell-buddy init` for guided setup, or print a template with `shell-buddy config-example`.

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
  "icon": "star",
  "debounce_ms": 150,
  "max_tokens": 2048,
  "timeout_ms": 8000
}
```

`default` explicitly selects `local` or `cloud`. Legacy `active_profile` is read when `default` is absent. `llm local` and `llm cloud` validate the selected profile, atomically save the choice, and notify active editors. Switching never falls back to another provider and preserves a stopped state.

The wizard supports Tab to choose a profile, prefilled editable endpoint/model values, and hidden key input. Enter keeps an existing key; local unauthenticated services may leave it empty. Esc, Ctrl+C, or Ctrl+D cancel without saving. Saving reloads active editors and preserves the current enabled/stopped state. Setup does not send a test model request.

Paths:

| Data | Default location |
| --- | --- |
| Configuration, macOS/Linux | `$XDG_CONFIG_HOME/shell-buddy/config.json`, falling back to `~/.config/shell-buddy/config.json` |
| Configuration, Windows | `%USERPROFILE%\.config\shell-buddy\config.json`; `XDG_CONFIG_HOME` is also supported |
| Credentials | `credentials.json` beside the actual config file |
| Shared enabled state | `state.json` beside the actual config file |
| Cache, macOS/Linux | `$XDG_CACHE_HOME/shell-buddy/cache.json`, falling back to `~/.cache/shell-buddy/cache.json` |
| Cache, Windows | `%LOCALAPPDATA%\shell-buddy\cache.json` |

Override paths with `SHELL_BUDDY_CONFIG` and `SHELL_BUDDY_CACHE`. `doctor` reports the resolved paths, active profile, token budget, and inherited shell-integration marker.

Credentials are stored **in plaintext**. Dedicated configuration directories use mode `0700` and newly written config/credential files use `0600` on macOS/Linux. Windows uses a current-user-only ACL. Writes use locking and atomic replacement. Keys are not shown in the wizard, logs, or shell history.

`api_key_env` is an environment variable **name**, never a key value. Resolution checks that variable before the selected profile's saved key. An explicitly empty or invalid variable fails instead of silently falling back. Each profile has separate stored credentials.

## Terminal icon

`icon` is an independent global enum: `star` (default) or `lizard`. Missing settings and older configs containing only `nerd_font` use `star`. The obsolete boolean is ignored and removed when the wizard saves a configuration. Invalid `icon` values fail validation; there is no stock animal glyph.

`star` displays the ordinary `✦`. `lizard` displays the project's own monochrome mascot at private-use **U+F5000**. Install and configure the [custom font](../fonts/README.md) before selecting it. The symbol font is approximately 3.4 KiB, separate from the executable. A font patch utility supports static TrueType monospace fonts without overwriting the source or changing ordinary text advances.

The wizard lists `star` and `lizard` after the key step, defaults to `star`, and preserves an explicit existing choice. Cancellation saves nothing. Model switching preserves the icon, and `restart` applies it to active editors without changing cache identity. `doctor` reports the effective enum.

The client cannot reliably inspect terminal font coverage, especially over SSH. The safe default is always the star; installing a font never silently enables the icon. No font or terminal setting is installed or modified by `init` or the editor.

## Models and failures

A profile must provide an OpenAI-compatible streaming `/chat/completions` endpoint. [Ollama documents a `/v1` compatibility interface](https://docs.ollama.com/api/openai-compatibility). Shell Buddy does not install models or start a model server.

All requests send `reasoning_effort: "none"`; there is no thinking-mode switch. The provider must accept this setting. Unsupported parameters fail explicitly; the client never removes the setting and silently enables thinking. Nonempty exposed `reasoning_content`, `reasoning`, or `thinking` is rejected. Undisclosed internal model computation cannot be verified by the client.

`max_tokens` defaults to **2048**, including for older configurations that omit it. Valid values are integers from **1 to 32768**. The wizard adds the default when missing and preserves an existing value. Change the JSON and run `restart` to reload. The command itself must still be one line and at most 4096 bytes.

Requests contain the description, OS, shell, and current directory. They do not upload repository contents or shell history. Only one model request is valid at a time; editing cancels it, and input revisions reject stale results. The default debounce is 150ms and timeout is 8 seconds. Local predictions remain stable until Tab requests an alternative.

Failures distinguish output-token exhaustion, incomplete completion, disconnected transport, filtering, refusal, empty output, unsupported tools, invalid response format, exposed thinking, authentication, insufficient balance, permission denial, missing endpoint/model, invalid parameters, rate limiting, server failure, DNS, TLS, and timeout. CLI generation includes a category and a short English explanation. Raw provider error bodies and reasoning text are not printed. Failed or incomplete output cannot be accepted.

To explicitly send a diagnostic request to your configured provider:

```sh
shell-buddy suggest --shell zsh --intent 'find large files in this directory' --generate --timings
```

This prints a command without executing it. `--timings` reports `first_token_ms` and `complete_ms` on stderr separately from command stdout. Diagnostics never add to the accepted-command cache.

## State and cache

`start`, `stop`, and `restart` control on-demand editors rather than a daemon. State is shared across terminals using the same config directory and persists across shell sessions. Model setup and switching preserve a stopped state.

`stop` cancels active requests and restores the entered description. `restart` validates config, enables suggestions, and notifies active editors within roughly 100ms. Invalid config returns a failure and preserves active state. An in-flight `suggest --generate` is canceled on stop/restart; rerun explicitly if needed.

Prediction order is accepted cache → explicit rules → LLM. Local results do not trigger speculative model requests. Tab requests alternatives on demand. Only accepted commands are cached, capped at 256 entries, using a separate lock and atomic replacement. Acceptance is not evidence of successful execution.

Cache identity includes description, OS, shell, working directory, selected model configuration, and output budget. Clear it with `shell-buddy cache-clear`.

## Adapter protocol

`edit --shell <shell>` hosts the terminal editor. Its stdout contains only the command or preserved description; rendering uses a separate TTY/Console handle.

| Exit code | Meaning |
| --- | --- |
| `0` | Accept into the native buffer |
| `10` | Accept and submit through the native shell |
| `20` | Cancel |
| Other | Failure |

## Performance

Targets: binary ≤5 MiB, editor peak RSS ≤20 MiB, local suggestion p95 ≤30ms. Model latency is separate.

macOS arm64, Zig 0.17.0, small build; measurements after wrapped rendering, icon spacing, and release packaging were added (2026-10-24):

| Metric | Measured |
| --- | --- |
| Binary | ~642 KiB |
| Local rule CLI p95, 100 measured runs | 5.03ms |
| Standalone editor first suggestion p95 | 7.34ms |
| Native Zsh input to suggestion p95 | 6.22ms |
| Full 256-entry cache CLI p95 | 8.14ms |
| Editor peak RSS with full cache | 4.91 MiB |

Reproduce with `python3 tests/benchmark.py`; machine load affects results. Brand images are documentation assets and are not embedded in the executable.

## Validation

```sh
zig build test
zig build -Doptimize=small
python3 tests/integration.py
python3 tests/benchmark.py
python3 tests/release.py
zig build -Dtarget=x86_64-linux-musl -Doptimize=small --prefix zig-out/linux
zig build -Dtarget=x86_64-windows -Doptimize=small --prefix zig-out/windows
```

Tests use local mock servers and dummy credentials. Native macOS Bash 5/Zsh checks cover editing, wrapping, resize, Tab refresh, hidden/partial acceptance, cancellation, cleanup, actual shell execution, plugin integration, setup, lifecycle, and configuration concurrency. Use `SHELL_BUDDY_TEST_BASH` to select a Bash 5+ test binary when macOS's default Bash is too old.

macOS Intel, Linux and Windows cross-builds pass. Release archives include the custom font, current-user installers and SHA-256 manifests. Offline installation tests verify program/font installation, font opt-out, checksum rejection and target validation. The [release workflow](../.github/workflows/release.yml) creates a draft only after its native jobs pass. Native platform jobs are defined in [CI](../.github/workflows/ci.yml); they must run before native support is considered accepted. Windows PowerShell/ConPTY checks require the test-only `pywinpty` package. Cloud-provider end-to-end generation and Ollama generation require separate acceptance; offline mocks do not establish provider compatibility.
