# Shell Buddy icon font

[简体中文](README.zh-CN.md) · [Project README](../README.md)

[ShellBuddyIcons.ttf](ShellBuddyIcons.ttf) contains **our selected lizard mascot**, converted to a monochrome outline with its eyes, tongue and curled tail. It is not a stock animal symbol. The character is private-use **U+F5000**; family **Shell Buddy Icons**, style **Regular**. The color comes from terminal text styling.

Shell Buddy defaults to `"icon": "star"`, which displays `✦` without installing anything. The former `nerd_font` setting is ignored; it never enables the custom character. Font installation and terminal font selection are separate steps. The application cannot reliably inspect terminal font coverage, including in remote sessions, so only select `lizard` after configuring your terminal.

[Combined program + font installation](../docs/install.md) installs this font by default. `shell-buddy init` only configures the app and downloads nothing. The commands below are for installing the font separately.

## Install the symbol font

From the repository root, on macOS or Linux:

```sh
sh fonts/install.sh
```

This installs only for your user, in `~/Library/Fonts` on macOS or `${XDG_DATA_HOME:-~/.local/share}/fonts/shell-buddy` on Linux. On Linux it refreshes the font cache if `fc-cache` is available.

Windows PowerShell:

```powershell
pwsh -File .\fonts\install.ps1
```

This copies the TTF into your local application-data font directory and registers it for the current user. Alternatively, open `ShellBuddyIcons.ttf` and choose **Install**. Restart the terminal application after installing. Windows installer behavior still requires native Windows acceptance.

## Select it in your terminal

For **Kitty**, keep your existing text font and add this to `kitty.conf`:

```conf
symbol_map U+F5000 Shell Buddy Icons
```

Reload the configuration or restart Kitty. This mapping only affects the mascot codepoint. [Kitty's symbol_map documentation](https://sw.kovidgoyal.net/kitty/conf/#opt-kitty.symbol_map)

For **iTerm2, Terminal.app, Windows Terminal, or another terminal without a per-codepoint font mapping**, the recommended approach is to add the glyph to a copy of the static TrueType monospace font you already use. Installing the symbol-only font alone is not a guarantee that these terminals will pick it as a fallback. Do not select a symbol-only font as the primary text font.

## Add the mascot to your existing font

This optional development utility requires Python and `fonttools`. Shell Buddy itself still has no Python dependency.

macOS/Linux:

```sh
python3 -m venv .font-tools
.font-tools/bin/python -m pip install -r tools/font-requirements.txt
.font-tools/bin/python tools/patch_icon_font.py "/path/to/YourMono-Regular.ttf" "/path/to/YourMono-ShellBuddy.ttf"
```

Windows:

```powershell
py -m venv .font-tools
.\.font-tools\Scripts\python.exe -m pip install -r tools\font-requirements.txt
.\.font-tools\Scripts\python.exe tools\patch_icon_font.py "C:\path\YourMono-Regular.ttf" "C:\path\YourMono-ShellBuddy.ttf"
```

Use a **static TrueType `.ttf`**, not a `.ttc` collection, variable font, or CFF `.otf`. The utility preserves the original file, text glyphs, license records, and one-cell advance; it creates a distinct family ending in **Shell Buddy** and prints its exact name. The modified copy drops any obsolete source digital-signature table. Existing output files and an already-occupied U+F5000 slot are rejected. If you use separate bold or italic files, patch those styles into distinct output files too.

Install the resulting TTF: open it in macOS Font Book or Windows and choose Install; on Linux copy it into `~/.local/share/fonts` and run `fc-cache -f`. Select the newly printed family as your terminal's text font. [iTerm2 font settings](https://iterm2.com/documentation-fonts.html) · [Windows Terminal font face](https://learn.microsoft.com/windows/terminal/customize-settings/profile-appearance#font-face)

## Enable the lizard

In your existing `config.json`, set:

```json
"icon": "lizard"
```

Then run:

```sh
shell-buddy restart
```

Or use `shell-buddy init`: the terminal-icon step lists `star` and `lizard`, defaults to `star`, and keeps an existing explicit selection. `doctor` reports the effective setting.

To preview the actual character in a configured terminal:

```sh
printf '\363\265\200\200\n'
```

PowerShell:

```powershell
[char]::ConvertFromUtf32(0xF5000)
```

If the character is missing, restore `"icon": "star"` and restart. A font installed on the remote host does not change the font rendered by your local terminal. A small full-body mascot naturally loses detail at tiny text sizes; it remains a single-cell symbol.

## Source and verification

[lizard.svg](lizard.svg) is the monochrome contour derived from the approved [mascot](../assets/logo.png); it retains negative-space eyes and tongue. The font contains only that project artwork and a space, with no redistributed third-party text font.

Regenerate and verify with a Python environment containing `fonttools`:

```sh
python tools/build_icon_font.py
python tests/fonts.py
```

The asset build is reproducible. Font tests check the private cmap, outline, source preservation, original text advances, renamed family, collision/output protection, and deterministic font generation. These checks do not replace native visual acceptance in every terminal.
