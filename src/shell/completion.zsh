if [[ -o interactive ]]; then
if (( ! ${+functions[compdef]} )); then
  autoload -Uz compinit
  compinit -D -i
fi
function _shell_buddy_complete() {
  local -a commands profiles shells options
  commands=(
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
  profiles=('local:Use the local model service' 'cloud:Use the cloud model service')
  shells=('bash:Bash 5 or later' 'zsh:Zsh 5.8 or later' 'powershell:PowerShell 7.4 or later')
  options=('--help:Show command help' '--version:Show version')
  if (( CURRENT == 2 )); then
    if [[ $PREFIX == -* ]]; then
      _describe 'option' options
    else
      _describe 'command' commands
    fi
  elif [[ $words[2] == llm ]] && (( CURRENT == 3 )); then
    _describe 'profile' profiles
  elif { [[ $words[2] == init ]] && (( CURRENT == 3 )); } || [[ $words[CURRENT-1] == --shell ]]; then
    _describe 'shell' shells
  else
    case $words[2] in
      update)
        local -a words=("${words[@]:1}")
        local CURRENT=$(( CURRENT - 1 ))
        _arguments '--check[Check for updates without changing files]' '--no-font[Skip updating the bundled symbol font]' '--help[Show command help]'
        ;;
      suggest)
        _arguments '--shell[Select the target shell]:shell:((bash zsh powershell))' '--intent[Describe the command]:description:' '--generate[Request the selected model]' '--timings[Print model latency]' '--help[Show command help]'
        ;;
      edit)
        _arguments '--shell[Select the target shell]:shell:((bash zsh powershell))' '--initial[Set the initial description]:description:' '--help[Show command help]'
        ;;
      *) _arguments '--help[Show command help]' ;;
    esac
  fi
}
compdef _shell_buddy_complete shell-buddy
fi

