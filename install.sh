#!/bin/sh
set -eu
version=latest
while [ "$#" -gt 0 ]; do
    case "$1" in
        --version) [ "$#" -ge 2 ] || exit 2; version=$2; shift 2 ;;
        --) shift; break ;;
        --help) printf '%s\n' 'usage: sh install.sh [--version <vX.Y.Z|latest>] [-- <local installer options>]'; exit 0 ;;
        *) break ;;
    esac
done
case "$(uname -s)" in Darwin) platform=macos ;; Linux) platform=linux ;; *) printf '%s\n' 'Use install.ps1 on Windows.' >&2; exit 1 ;; esac
case "$(uname -m)" in arm64|aarch64) architecture=aarch64 ;; x86_64|amd64) architecture=x86_64 ;; *) printf '%s\n' 'Unsupported architecture.' >&2; exit 1 ;; esac
if [ "$platform" = linux ] && [ "$architecture" != x86_64 ]; then printf '%s\n' 'Linux ARM binaries are not included in this release.' >&2; exit 1; fi
if [ "$version" = latest ]; then
    base=https://github.com/zhanbodev/shell-buddy/releases/latest/download
else
    printf '%s' "$version" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' || { printf '%s\n' 'Invalid version.' >&2; exit 2; }
    base="https://github.com/zhanbodev/shell-buddy/releases/download/v${version#v}"
fi
archive="shell-buddy-$platform-$architecture.tar.gz"
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
download() {
    if command -v curl >/dev/null 2>&1; then curl --fail --location --retry 3 --proto '=https' --tlsv1.2 --silent --show-error "$1" --output "$2"
    elif command -v wget >/dev/null 2>&1; then wget --https-only -q -O "$2" "$1"
    else printf '%s\n' 'Install curl or wget to download release assets.' >&2; exit 1; fi
}
download "$base/$archive" "$temporary/$archive"
download "$base/SHA256SUMS" "$temporary/SHA256SUMS"
expected=$(awk -v file="$archive" '$2 == file { print $1 }' "$temporary/SHA256SUMS")
[ "${#expected}" -eq 64 ] || { printf '%s\n' 'Missing or invalid release checksum.' >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then actual=$(sha256sum "$temporary/$archive" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then actual=$(shasum -a 256 "$temporary/$archive" | awk '{print $1}')
else printf '%s\n' 'Install sha256sum or shasum for checksum verification.' >&2; exit 1; fi
[ "$expected" = "$actual" ] || { printf '%s\n' 'Release checksum mismatch; nothing installed.' >&2; exit 1; }
tar -xzf "$temporary/$archive" -C "$temporary"
sh "$temporary/shell-buddy/install.sh" "$@"
