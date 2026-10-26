param([string]$BinDir, [string]$FontDir, [switch]$NoFont, [switch]$SkipFontRegistration)
$ErrorActionPreference = 'Stop'
$bundle = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'fonts')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
if (-not $BinDir) { $BinDir = Join-Path $env:LOCALAPPDATA 'Programs\ShellBuddy\bin' }
$binary = Join-Path $bundle 'bin\shell-buddy.exe'
if (-not (Test-Path -LiteralPath $binary)) { $binary = Join-Path $bundle 'zig-out\bin\shell-buddy.exe' }
if (-not (Test-Path -LiteralPath $binary)) { throw 'Binary missing. Extract the full bundle or build from source.' }
if (-not $NoFont -and -not (Test-Path -LiteralPath (Join-Path $bundle 'fonts\ShellBuddyIcons.ttf'))) { throw 'Bundled font missing.' }
$version = & $binary --version
if ($LASTEXITCODE -ne 0) { throw 'This binary cannot run on your platform.' }
New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
$temporary = Join-Path $BinDir ('.shell-buddy-' + [guid]::NewGuid().ToString('N') + '.exe')
try {
    Copy-Item -LiteralPath $binary -Destination $temporary
    Move-Item -LiteralPath $temporary -Destination (Join-Path $BinDir 'shell-buddy.exe') -Force
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
}
if (-not $NoFont) {
    $fontArgs = @{}
    if ($FontDir) { $fontArgs.Destination = $FontDir }
    if ($SkipFontRegistration) { $fontArgs.SkipRegistration = $true }
    & (Join-Path $bundle 'fonts\install.ps1') @fontArgs
}
Write-Output "Shell Buddy $version installed: $BinDir\shell-buddy.exe"
Write-Output 'Add that directory to PATH, then: shell-buddy init powershell | Out-String | Invoke-Expression'
Write-Output 'Configure models: shell-buddy init'
Write-Output 'Shell profiles and terminal settings were not modified. Default input style: square.'
