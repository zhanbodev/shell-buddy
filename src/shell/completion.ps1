Register-ArgumentCompleter -Native -CommandName shell-buddy -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    $wordToComplete = [string]$wordToComplete
    $elements = @($commandAst.CommandElements | Where-Object { $_.Extent.StartOffset -lt $cursorPosition })
    $position = $elements.Count - 1
    if ([string]::IsNullOrEmpty($wordToComplete)) { $position++ }
    $command = if ($elements.Count -gt 1) { $elements[1].Extent.Text } else { '' }
    $previous = if ($position -gt 0) { $elements[$position - 1].Extent.Text } else { '' }
    $entries = @()
    if ($position -eq 1) {
        $entries = @(
            @('init', 'Configure models or initialize shell integration'),
            @('start', 'Enable command suggestions'),
            @('stop', 'Disable suggestions and cancel active requests'),
            @('restart', 'Reload configuration and enable suggestions'),
            @('status', 'Show state and configuration path'),
            @('llm', 'Select an LLM profile'),
            @('suggest', 'Print a suggestion without executing it'),
            @('edit', 'Open the inline editor'),
            @('doctor', 'Check configuration'),
            @('config-example', 'Print an example configuration'),
            @('cache-clear', 'Clear accepted command cache'),
            @('help', 'Show command help')
        )
        if ($wordToComplete.StartsWith('-')) {
            $entries = @(@('--help', 'Show command help'), @('--version', 'Show version'))
        }
    } elseif ($command -eq 'llm' -and $position -eq 2) {
        $entries = @(@('local', 'Use the local model service'), @('cloud', 'Use the cloud model service'))
    } elseif (($command -eq 'init' -and $position -eq 2) -or $previous -eq '--shell') {
        $entries = @(@('bash', 'Bash 5 or later'), @('zsh', 'Zsh 5.8 or later'), @('powershell', 'PowerShell 7.4 or later'))
    } elseif ($previous -in '--intent', '--initial') {
        return
    } elseif ($command -in 'suggest', 'edit') {
        $entries = @(@('--shell', 'Select the target shell'), @('--help', 'Show command help'))
        if ($command -eq 'suggest') {
            $entries += @(@('--intent', 'Describe the command'), @('--generate', 'Request the selected model'), @('--timings', 'Print model latency'))
        } else {
            $entries += ,@('--initial', 'Set the initial description')
        }
    } else {
        $entries = ,@('--help', 'Show command help')
    }
    foreach ($entry in $entries) {
        if ($entry[0].StartsWith($wordToComplete, [StringComparison]::OrdinalIgnoreCase)) {
            [System.Management.Automation.CompletionResult]::new($entry[0], ($entry[0] + ' - ' + $entry[1]), 'ParameterValue', $entry[1])
        }
    }
}

