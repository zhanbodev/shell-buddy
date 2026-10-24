# Source with: shell-buddy init powershell | Out-String | Invoke-Expression
if ($PSVersionTable.PSVersion -lt [version]'7.4') { throw 'shell-buddy requires PowerShell 7.4+' }
Import-Module PSReadLine -MinimumVersion 2.3.6 -ErrorAction Stop

function Invoke-ShellBuddyEdit {
    param([string]$Line, [int]$Cursor)
    $binary = if ($env:SHELL_BUDDY_BIN) { $env:SHELL_BUDDY_BIN } else { 'shell-buddy' }
    $PSNativeCommandUseErrorActionPreference = $false
    $savedEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $result = & $binary edit --shell powershell --initial $Line --inline-left ($Line.Substring(0, $Cursor))
        $code = $LASTEXITCODE
    } finally {
        [Console]::OutputEncoding = $savedEncoding
    }
    if ($code -in 0, 10, 20) {
        [Microsoft.PowerShell.PSConsoleReadLine]::Replace(0, $Line.Length, ($result -join "`n"))
        if ($code -eq 10) { [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine() }
    }
}
Set-PSReadLineKeyHandler -Key '/' -ScriptBlock {
    [Microsoft.PowerShell.PSConsoleReadLine]::Insert('/')
    $line = $null; $cursor = 0
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    if ($line -eq '//') { Invoke-ShellBuddyEdit -Line $line -Cursor $cursor }
}
$shellBuddyAccept = {
    $line = $null; $cursor = 0
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    if ($line -match '^\s*//') { Invoke-ShellBuddyEdit -Line $line -Cursor $cursor }
    else { [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine() }
}
Set-PSReadLineKeyHandler -Key Enter -ScriptBlock $shellBuddyAccept
Set-PSReadLineKeyHandler -Key Ctrl+Enter -ScriptBlock $shellBuddyAccept
Remove-Variable shellBuddyAccept
$env:SHELL_BUDDY_SHELL = 'powershell'
