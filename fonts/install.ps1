param([string]$Destination, [switch]$SkipRegistration)
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'ShellBuddyIcons.ttf'
if (-not $Destination) { $Destination = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts' }
New-Item -ItemType Directory -Path $destination -Force | Out-Null
$destination = (Resolve-Path -LiteralPath $destination).Path
$target = Join-Path $destination 'ShellBuddyIcons.ttf'
Copy-Item -LiteralPath $source -Destination $target -Force
if (-not $SkipRegistration) {
    $registry = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    if (-not (Test-Path -LiteralPath $registry)) {
        New-Item -Path $registry -Force | Out-Null
    }
    New-ItemProperty -Path $registry -Name 'Shell Buddy Icons (TrueType)' -Value $target -PropertyType String -Force | Out-Null
}
Write-Output "Installed for current user: $target"
Write-Output 'Restart your terminal. Configure a patched primary font before enabling input_style: rounded.'
