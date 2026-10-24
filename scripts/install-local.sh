#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -d "$script_dir/fonts" ]; then bundle=$script_dir; else bundle=$(CDPATH= cd -- "$script_dir/.." && pwd); fi
bin_dir="$HOME/.local/bin"
font_dir=
with_font=true
while [ "$#" -gt 0 ]; do
    case "$1" in
        --bin-dir) [ "$#" -ge 2 ] || exit 2; bin_dir=$2; shift 2 ;;
        --font-dir) [ "$#" -ge 2 ] || exit 2; font_dir=$2; shift 2 ;;
        --no-font) with_font=false; shift ;;
        --help) printf '%s\n' 'usage: sh install.sh [--bin-dir <directory>] [--font-dir <directory>] [--no-font]'; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done
binary="$bundle/bin/shell-buddy"
[ -f "$binary" ] || binary="$bundle/zig-out/bin/shell-buddy"
[ -f "$binary" ] || { printf '%s\n' 'Binary missing. Extract the full release bundle or run zig build -Doptimize=small.' >&2; exit 1; }
if [ "$with_font" = true ]; then
    [ -f "$bundle/fonts/ShellBuddyIcons.ttf" ] || { printf '%s\n' 'Bundled font missing; extract the complete archive.' >&2; exit 1; }
fi
version=$("$binary" --version) || { printf '%s\n' 'This binary cannot run on your platform.' >&2; exit 1; }
mkdir -p "$bin_dir"
temporary="$bin_dir/.shell-buddy.install.$$"
trap 'rm -f "$temporary"' EXIT HUP INT TERM
cp "$binary" "$temporary"
chmod 755 "$temporary"
mv -f "$temporary" "$bin_dir/shell-buddy"
if [ "$with_font" = true ]; then
    if [ -n "$font_dir" ]; then sh "$bundle/fonts/install.sh" --font-dir "$font_dir"; else sh "$bundle/fonts/install.sh"; fi
fi
printf '\nShell Buddy %s installed: %s/shell-buddy\n' "$version" "$bin_dir"
printf '%s\n' 'Add the binary directory to PATH, then load the integration:' '  Zsh:        eval "$(shell-buddy init zsh)"' '  Bash 5+:    eval "$(shell-buddy init bash)"' 'Configure models: shell-buddy init' 'Shell startup files were not modified. Fonts do not change terminal settings automatically.'
