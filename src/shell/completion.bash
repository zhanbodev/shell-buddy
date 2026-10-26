# Native completion: no shell-buddy process is started while completing words.
if [[ $- == *i* ]] && (( BASH_VERSINFO[0] >= 5 )); then
__shell_buddy_complete() {
  local current=${COMP_WORDS[COMP_CWORD]} command=${COMP_WORDS[1]} previous=${COMP_WORDS[COMP_CWORD-1]}
  local entry name description
  local -a entries=() matches=() descriptions=()
  COMPREPLY=()
  if (( COMP_CWORD == 1 )); then
    entries=(
      'init:Configure models or initialize shell integration'
      'start:Enable command suggestions'
      'stop:Disable suggestions and cancel active requests'
      'restart:Reload configuration and enable suggestions'
      'status:Show state and configuration path'
      'update:Upgrade to the latest stable release'
      'llm:Select an LLM profile'
      'suggest:Print a suggestion without executing it'
      'edit:Open the inline editor'
      'doctor:Check configuration'
      'config-example:Print an example configuration'
      'cache-clear:Clear accepted command cache'
      'help:Show command help'
    )
    [[ $current == -* ]] && entries=('--help:Show command help' '--version:Show version')
  elif [[ $command == llm ]] && (( COMP_CWORD == 2 )); then
    entries=('local:Use the local model service' 'cloud:Use the cloud model service')
  elif { [[ $command == init ]] && (( COMP_CWORD == 2 )); } || [[ $previous == --shell ]]; then
    entries=('bash:Bash 5 or later' 'zsh:Zsh 5.8 or later' 'powershell:PowerShell 7.4 or later')
  elif [[ $previous == --intent || $previous == --initial ]]; then
    return 0
  elif [[ $command == update ]]; then
    entries=('--check:Check for updates without changing files' '--no-font:Skip updating the bundled symbol font' '--help:Show command help')
  elif [[ $command == suggest ]]; then
    entries=('--shell:Select the target shell' '--intent:Describe the command' '--generate:Request the selected model' '--timings:Print model latency' '--help:Show command help')
  elif [[ $command == edit ]]; then
    entries=('--shell:Select the target shell' '--initial:Set the initial description' '--help:Show command help')
  else
    entries=('--help:Show command help')
  fi
  for entry in "${entries[@]}"; do
    name=${entry%%:*}; description=${entry#*:}
    if [[ $name == "$current"* ]]; then
      matches+=("$name"); descriptions+=("$description")
    fi
  done
  if (( ${#matches[@]} > 1 )) && [[ -z $current ]]; then
    # Bash lacks Zsh's described matches. Display one entry per line, retaining
    # the word so the user can type a prefix and press Tab to insert a match.
    printf '\n' >&2
    for ((entry=0; entry<${#matches[@]}; entry++)); do
      printf '  - %-16s %s\n' "${matches[entry]}" "${descriptions[entry]}" >&2
    done
    COMPREPLY=("$current")
    compopt -o nospace
  else
    COMPREPLY=("${matches[@]}")
  fi
}
complete -F __shell_buddy_complete shell-buddy
fi

