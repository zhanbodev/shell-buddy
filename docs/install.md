# Install Shell Buddy

[简体中文](install.zh-CN.md) · [Project](../README.md)

Install a prebuilt [v0.1.0 release](https://github.com/zhanbodev/shell-buddy/releases/tag/v0.1.0), or build from source with Zig 0.17.0.

## From this checkout

macOS / Linux, with Zig 0.17.0:

```sh
zig build -Doptimize=small
sh scripts/install-local.sh
export PATH="$HOME/.local/bin:$PATH"
```

Windows, with Zig 0.17.0 and PowerShell 7.4+:

```powershell
zig build -Doptimize=small
pwsh -File .\scripts\install-local.ps1
$env:PATH = "$env:LOCALAPPDATA\Programs\ShellBuddy\bin;$env:PATH"
```

Both installers copy the executable and bundled **Shell Buddy Icons** font for the current user. They do not change PATH, shell startup files, terminal settings, or model configuration. No administrator access is needed for the default directories.

## From a published release

The download installer chooses the current OS and architecture, downloads a release bundle and its `SHA256SUMS`, verifies the archive, then runs its installer. A prebuilt installation requires neither Zig nor Python. The POSIX download step requires `curl` or `wget`; the executable itself does not.

macOS / Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/zhanbodev/shell-buddy/v0.1.0/install.sh -o /tmp/shell-buddy-install.sh
sh /tmp/shell-buddy-install.sh --version v0.1.0
export PATH="$HOME/.local/bin:$PATH"
```

Windows PowerShell 7.4+:

```powershell
$installer = Join-Path ([IO.Path]::GetTempPath()) 'shell-buddy-install.ps1'
Invoke-WebRequest https://raw.githubusercontent.com/zhanbodev/shell-buddy/v0.1.0/install.ps1 -OutFile $installer
pwsh -File $installer -Version v0.1.0
$env:PATH = "$env:LOCALAPPDATA\Programs\ShellBuddy\bin;$env:PATH"
```

Review the downloaded script before running it if desired. The scripts also accept `latest` to select the latest public release. Archives and checksums are served from the same GitHub release; checksums detect corrupt or mismatched downloads, not a compromised publisher. Initial binaries are unsigned and macOS builds are not notarized.

For offline installation, download the matching archive and `SHA256SUMS` from [Releases](https://github.com/zhanbodev/shell-buddy/releases), verify its SHA-256, extract it, and run the installer **inside** the extracted `shell-buddy` directory:

| Platform | Archive | Installer |
| --- | --- | --- |
| macOS Apple Silicon | `shell-buddy-macos-aarch64.tar.gz` | `sh install.sh` |
| macOS Intel | `shell-buddy-macos-x86_64.tar.gz` | `sh install.sh` |
| Linux x86_64 | `shell-buddy-linux-x86_64.tar.gz` | `sh install.sh` |
| Windows x86_64 | `shell-buddy-windows-x86_64.zip` | `pwsh -File .\install.ps1` |

Linux ARM and Windows ARM are not included in the initial release matrix. Linux uses musl. Test reports from native release jobs must be reviewed before publishing.

## Locations and options

| Item | Default location |
| --- | --- |
| macOS / Linux executable | `~/.local/bin/shell-buddy` |
| macOS font | `~/Library/Fonts/ShellBuddyIcons.ttf` |
| Linux font | `${XDG_DATA_HOME:-~/.local/share}/fonts/shell-buddy/ShellBuddyIcons.ttf` |
| Windows executable | `%LOCALAPPDATA%\Programs\ShellBuddy\bin\shell-buddy.exe` |
| Windows font | `%LOCALAPPDATA%\Microsoft\Windows\Fonts\ShellBuddyIcons.ttf` (current-user registration) |

The POSIX installers accept `--bin-dir <directory>`, `--font-dir <directory>`, and `--no-font`. When using the download installer, put these after `--`:

```sh
sh /tmp/shell-buddy-install.sh --version v0.1.0 -- --bin-dir "$HOME/.local/bin" --no-font
```

PowerShell installers accept `-BinDir`, `-FontDir`, and `-NoFont`. Local installations can additionally use `-SkipFontRegistration` for a file-only font copy.

## Enable in your shell

Once the binary directory is on PATH:

| Shell | Current-session initialization |
| --- | --- |
| Zsh 5.8+ | `eval "$(shell-buddy init zsh)"` |
| Bash 5+ | `eval "$(shell-buddy init bash)"` |
| PowerShell 7.4+ / PSReadLine 2.3.6+ | `shell-buddy init powershell \| Out-String \| Invoke-Expression` |

For persistence, add the PATH entry and initialization command to your own shell startup file. `eval` loads the printed functions and bindings into the current shell; it does not write your startup file. Building, installing, or running `restart` alone does not load these bindings.

Run `shell-buddy init` to configure a local/cloud model, credentials, and icon preference. This wizard **downloads nothing**. Rules and existing cache still work without a model.

## Enable the lizard

The default icon remains `✦`, even when the font is installed. Installing a font cannot guarantee that a terminal uses it. Configure a per-character mapping or patch a copy of your usual monospace font, following the [font guide](../fonts/README.md), then choose `lizard` in `shell-buddy init` or set `"icon": "lizard"` and run `shell-buddy restart`.

Do not select the symbol-only font as your main text font. Fonts are rendered on the local terminal machine, including when the program runs over SSH.

## Upgrade or remove

To upgrade, run the installer for a newer published version, then re-run your shell initialization command in existing sessions. Configuration and credentials are preserved. Run `shell-buddy restart` to validate and reload configuration.

To remove, delete the installed executable, remove your own PATH/init entries, and uninstall **Shell Buddy Icons** through your OS font manager. Remove `~/.config/shell-buddy` separately only if you also want to erase configuration, credentials, and cache.
