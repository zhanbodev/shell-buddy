#!/bin/sh
set -eu
font_source=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/ShellBuddyIcons.ttf
font_destination=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --font-dir) [ "$#" -ge 2 ] || exit 2; font_destination=$2; shift 2 ;;
        --help) printf '%s\n' 'usage: sh fonts/install.sh [--font-dir <directory>]'; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done
system=$(uname -s)
if [ -z "$font_destination" ]; then
    case "$system" in
        Darwin) font_destination="$HOME/Library/Fonts" ;;
        Linux) font_destination="${XDG_DATA_HOME:-$HOME/.local/share}/fonts/shell-buddy" ;;
        *) printf '%s\n' 'Use install.ps1 on Windows.' >&2; exit 1 ;;
    esac
fi
mkdir -p "$font_destination"
cp "$font_source" "$font_destination/ShellBuddyIcons.ttf"
if [ "$system" = Linux ] && command -v fc-cache >/dev/null 2>&1; then fc-cache -f "$font_destination"; fi
printf '%s\n' "Font installed: $font_destination/ShellBuddyIcons.ttf" 'Configure U+F5001-U+F5006 font mapping before choosing input_style: rounded. Default: square.'
