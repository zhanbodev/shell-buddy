"""Create a binary + font release bundle and its SHA-256 manifests (stdlib only)."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FILES = [
    'LICENSE',
    'fonts/ShellBuddyIcons.ttf', 'fonts/install.sh', 'fonts/install.ps1',
    'fonts/README.md', 'fonts/README.zh-CN.md', 'fonts/lizard.svg',
    'tools/patch_icon_font.py', 'tools/build_icon_font.py', 'tools/font-requirements.txt', 'tests/fonts.py',
    'docs/install.md', 'docs/install.zh-CN.md',
]


def checksums(directory):
    archives = sorted([*directory.glob('shell-buddy-*.tar.gz'), *directory.glob('shell-buddy-*.zip')])
    lines = []
    for archive in archives:
        line = hashlib.sha256(archive.read_bytes()).hexdigest() + '  ' + archive.name + '\n'
        archive.with_name(archive.name + '.sha256').write_text(line)
        lines.append(line)
    (directory / 'SHA256SUMS').write_text(''.join(lines))


def package(binary, platform, architecture, output, version=None):
    version = version or (ROOT / 'src/version.txt').read_text().strip()
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?', version):
        raise ValueError('Invalid version')
    if (platform, architecture) not in [('macos', 'aarch64'), ('macos', 'x86_64'), ('linux', 'x86_64'), ('windows', 'x86_64')]:
        raise ValueError('Unsupported release target')
    data = binary.read_bytes()
    if not data: raise ValueError('Empty binary')
    if platform == 'windows' and not data.startswith(b'MZ'): raise ValueError('Expected a Windows PE binary')
    if platform == 'linux' and not data.startswith(b'\x7fELF'): raise ValueError('Expected a Linux ELF binary')
    if platform == 'macos' and data[:4] not in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf'): raise ValueError('Expected a Mach-O binary')
    import struct
    if platform == 'linux' and (len(data) < 20 or int.from_bytes(data[18:20], 'little') != 62):
        raise ValueError('Expected Linux x86_64')
    if platform == 'macos':
        expected_cpu = 0x100000c if architecture == 'aarch64' else 0x1000007
        endian = 'little' if data[:4] == b'\xcf\xfa\xed\xfe' else 'big'
        if int.from_bytes(data[4:8], endian) != expected_cpu: raise ValueError('Mach-O architecture mismatch')
    if platform == 'windows':
        if len(data) < 64: raise ValueError('Invalid PE header')
        offset = struct.unpack_from('<I', data, 60)[0]
        if len(data) < offset+6 or data[offset:offset+4] != b'PE\0\0' or int.from_bytes(data[offset+4:offset+6], 'little') != 0x8664:
            raise ValueError('Expected Windows x86_64')
    output.mkdir(parents=True, exist_ok=True)
    entries = {name: (ROOT / name).read_bytes() for name in FILES}
    entries['bin/shell-buddy' + ('.exe' if platform == 'windows' else '')] = data
    entries['install.sh'] = (ROOT / 'scripts/install-local.sh').read_bytes()
    entries['install.ps1'] = (ROOT / 'scripts/install-local.ps1').read_bytes()
    entries['src/version.txt'] = (version + '\n').encode()
    # Keep source-art links useful without adding documentation PNGs to a CLI bundle.
    for name in ('fonts/README.md', 'fonts/README.zh-CN.md', 'docs/install.md', 'docs/install.zh-CN.md'):
        text = entries[name].decode().replace('../assets/logo.png', f'https://github.com/zhanbodev/shell-buddy/blob/v{version}/assets/logo.png')
        text = text.replace('../README.zh-CN.md', '../README.md')
        entries[name] = text.encode()
    entries['release.json'] = (json.dumps({'version': version, 'platform': platform, 'architecture': architecture, 'font': 'ShellBuddyIcons.ttf', 'default_input_style': 'square'}, indent=2) + '\n').encode()
    entries['README.md'] = f'''# Shell Buddy {version}

This bundle includes the executable, custom symbol font, font tools and installers.

macOS/Linux: `sh install.sh`
Windows PowerShell 7.4+: `pwsh -File .\\install.ps1`

Both installers install the binary and the bundled font for the current user by default.
Use `--no-font` (POSIX) or `-NoFont` (PowerShell) to skip the font.
Add the printed binary directory to PATH, then load the shell integration:

- Zsh: `eval "$(shell-buddy init zsh)"`
- Bash 5+: `eval "$(shell-buddy init bash)"`
- PowerShell: `shell-buddy init powershell | Out-String | Invoke-Expression`

Configure a model with `shell-buddy init`. Setup downloads nothing.
Default input style: square. Installing a font does not select it in your terminal.
See [font setup](fonts/README.md) or [中文字体指南](fonts/README.zh-CN.md) before enabling `input_style: rounded`.

Licensed under the [MIT License](LICENSE).

[Project documentation](https://github.com/zhanbodev/shell-buddy/tree/v{version})
'''.encode()
    name = f'shell-buddy-{platform}-{architecture}'
    archive = output / (name + ('.zip' if platform == 'windows' else '.tar.gz'))
    def mode(path): return 0o755 if path.startswith('bin/') or path.endswith('.sh') else 0o644
    if platform == 'windows':
        with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as file:
            for path, contents in sorted(entries.items()):
                info = zipfile.ZipInfo('shell-buddy/' + path, date_time=(1980, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.external_attr = (0o100000 | mode(path)) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                file.writestr(info, contents)
    else:
        with archive.open('wb') as raw:
            with gzip.GzipFile(fileobj=raw, mode='wb', filename='', mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode='w') as file:
                    for path, contents in sorted(entries.items()):
                        info = tarfile.TarInfo('shell-buddy/' + path)
                        info.size, info.mode, info.mtime = len(contents), mode(path), 0
                        file.addfile(info, io.BytesIO(contents))
    checksums(output)
    return archive


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--platform', choices=['macos', 'linux', 'windows'])
    parser.add_argument('--architecture', choices=['aarch64', 'x86_64'])
    parser.add_argument('--output', type=Path, default=ROOT / 'dist')
    parser.add_argument('--version')
    parser.add_argument('--checksums-only', action='store_true')
    args = parser.parse_args()
    if args.checksums_only:
        checksums(args.output)
    else:
        if not (args.binary and args.platform and args.architecture): parser.error('binary, platform and architecture are required')
        print(package(args.binary, args.platform, args.architecture, args.output, args.version))
