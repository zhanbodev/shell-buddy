# Shell Buddy icon font

[简体中文](README.zh-CN.md) · [Project README](../README.md)

[ShellBuddyIcons.ttf](ShellBuddyIcons.ttf), family **Shell Buddy Icons**, version **1.1**, contains our own lizard outline at U+F5000 and six rounded-input cap glyphs at U+F5001–U+F5006.

AI input uses one gold `❯`, with no extra star or mascot. `"input_style": "square"` is the default and needs no custom font. Configure terminal mapping or a patched text font before selecting `"rounded"`. Update older mascot-only fonts by reinstalling or patching a fresh copy of the original text font. Font coverage cannot be reliably detected, including over SSH.

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
symbol_map U+F5000-U+F5006 Shell Buddy Icons
```

Reload the configuration or restart Kitty. This mapping only affects Shell Buddy private-use symbols. [Kitty's symbol_map documentation](https://sw.kovidgoyal.net/kitty/conf/#opt-kitty.symbol_map)

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

Use a **static TrueType `.ttf`**, not a `.ttc` collection, variable font, or CFF `.otf`. The utility preserves the original file, text glyphs, license records, and one-cell advance; it creates a distinct family ending in **Shell Buddy** and prints its exact name. The modified copy drops any obsolete source digital-signature table. Existing output files and an already-occupied Shell Buddy private-use slot are rejected. If you use separate bold or italic files, patch those styles into distinct output files too.

Install the resulting TTF: open it in macOS Font Book or Windows and choose Install; on Linux copy it into `~/.local/share/fonts` and run `fc-cache -f`. Select the newly printed family as your terminal's text font. [iTerm2 font settings](https://iterm2.com/documentation-fonts.html) · [Windows Terminal font face](https://learn.microsoft.com/windows/terminal/customize-settings/profile-appearance#font-face)

## Enable rounded input

After installing and configuring the font, set this in your existing `config.json`:

```json
"input_style": "rounded"
```

Run `shell-buddy restart`, or select rounded at the Input style step of `shell-buddy init`. The first-use default is square; explicit choices are preserved. `doctor` shows the effective setting. Legacy icon/nerd_font settings no longer enable an icon and are removed when the wizard saves.

Check the new symbols (single-line, top and bottom pairs):

```sh
printf '\363\265\200\201\363\265\200\202 \363\265\200\203\363\265\200\204 \363\265\200\205\363\265\200\206\n'
```

PowerShell:

```powershell
0xF5001..0xF5006 | ForEach-Object { [char]::ConvertFromUtf32($_) }
```

The application sets cap foreground and body background to the same color. Patched caps fill the original font's one-cell advance and hhea ascent/descent, without altering its text glyphs or metrics. Additional terminal line spacing can leave seams; default line height is recommended. If caps are missing or misaligned, select `"input_style": "square"` and reload.

Fonts render on your local terminal machine, even over SSH. Do not select the symbol-only font as the primary text font.

## Source and verification

[lizard.svg](lizard.svg) is the monochrome contour derived from the approved [mascot](../assets/logo.png); it retains negative-space eyes and tongue. The font contains only project artwork, cap shapes and a space, with no redistributed third-party text font.

Regenerate and verify with a Python environment containing `fonttools`:

```sh
python tools/build_icon_font.py
python tests/fonts.py
```

The asset build is reproducible. Font tests check the private cmap, outline, source preservation, original text advances, renamed family, collision/output protection, and deterministic font generation. These checks do not replace native visual acceptance in every terminal.
