param([string]$Version = 'latest', [string]$BinDir, [string]$FontDir, [switch]$NoFont)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Use install.sh on macOS/Linux.' }
$architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
if ($architecture -ne 'X64') { throw 'This release provides Windows x86_64 binaries.' }
if ($Version -eq 'latest') { $base = 'https://github.com/zhanbodev/shell-buddy/releases/latest/download' }
elseif ($Version -match '^v?\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$') { $base = 'https://github.com/zhanbodev/shell-buddy/releases/download/v' + $Version.TrimStart('v') }
else { throw 'Invalid version.' }
$archive = 'shell-buddy-windows-x86_64.zip'
$temporary = Join-Path ([System.IO.Path]::GetTempPath()) ('shell-buddy-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary | Out-Null
try {
    $download = Join-Path $temporary $archive
    Invoke-WebRequest -Uri "$base/$archive" -OutFile $download
    Invoke-WebRequest -Uri "$base/SHA256SUMS" -OutFile (Join-Path $temporary 'SHA256SUMS')
    $lines = @(Get-Content -LiteralPath (Join-Path $temporary 'SHA256SUMS') | Where-Object { $_ -match ('^[0-9a-fA-F]{64}\s+' + [regex]::Escape($archive) + '$') })
    if ($lines.Count -ne 1) { throw 'Missing or invalid release checksum.' }
    $expected = ($lines[0] -split '\s+')[0]
    if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne $expected) { throw 'Release checksum mismatch; nothing installed.' }
    Expand-Archive -LiteralPath $download -DestinationPath $temporary
    $options = @{}
    if ($BinDir) { $options.BinDir = $BinDir }
    if ($FontDir) { $options.FontDir = $FontDir }
    if ($NoFont) { $options.NoFont = $true }
    & (Join-Path $temporary 'shell-buddy\install.ps1') @options
} finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force
}
