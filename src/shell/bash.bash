# Source with: eval "$(shell-buddy init bash)"
if [[ $- == *i* ]] && (( BASH_VERSINFO[0] < 5 )); then
  printf 'shell-buddy: Bash 5+ required\n' >&2
fi
if [[ $- == *i* ]] && (( BASH_VERSINFO[0] >= 5 )); then

__shell_buddy_dispatch() {
  # Bash 5 exposes READLINE_POINT as a character offset in the current locale.
  # Keep that locale so slicing does not split UTF-8 before an ordinary '/'.
  local kind=$1 result rc=0 next=redraw-current-line map line_prompt
  if [[ $kind == slash ]]; then
    READLINE_LINE=${READLINE_LINE:0:READLINE_POINT}/${READLINE_LINE:READLINE_POINT}
    (( READLINE_POINT += 1 ))
  fi
  if [[ $READLINE_LINE =~ ^[[:space:]]*// ]] && { [[ $kind == enter ]] || [[ $READLINE_LINE == // ]]; }; then
    # bind -x clears Readline's visible line before invoking us. Restore only
    # the final prompt line, omitting Readline's nonprinting marker bytes.
    line_prompt=${PS1@P}
    line_prompt=${line_prompt##*$'\n'}
    line_prompt=${line_prompt//$'\001'/}
    line_prompt=${line_prompt//$'\002'/}
    printf '%s' "$line_prompt" >&2
    if result=$("${SHELL_BUDDY_BIN:-shell-buddy}" edit --shell bash --initial "$READLINE_LINE" --inline-left ""); then
      rc=0
    else
      rc=$?
    fi
    case $rc in
      0|10|20) READLINE_LINE=$result; READLINE_POINT=${#READLINE_LINE} ;;
      *) printf '\nshell-buddy failed to start; input preserved\n' >&2 ;;
    esac
    (( rc == 10 )) && next=accept-line
    [[ $(bind -v) == *'set enable-bracketed-paste on'* ]] && printf '\e[?2004h' >&2
    # Readline's bind -x return path redraws its last prompt line from column 0.
    printf '\r' >&2
  elif [[ $kind == enter ]]; then
    next=accept-line
  fi
  # The second macro stage is resolved after this callback returns. This lets
  # Readline itself submit the line, preserving cwd, history, jobs and exit status.
  for map in emacs-standard vi-insert; do
    bind -m "$map" "\"\C-x\C-]\":$next"
  done
  return 0
}
for __shell_buddy_map in emacs-standard vi-insert; do
  bind -m "$__shell_buddy_map" -x '"\C-x\C-_":__shell_buddy_dispatch slash'
  bind -m "$__shell_buddy_map" -x '"\C-x\C-^":__shell_buddy_dispatch enter'
  bind -m "$__shell_buddy_map" '"\C-x\C-]":redraw-current-line'
  bind -m "$__shell_buddy_map" '"/":"\C-x\C-_\C-x\C-]"'
  bind -m "$__shell_buddy_map" '"\C-m":"\C-x\C-^\C-x\C-]"'
  bind -m "$__shell_buddy_map" '"\C-j":"\C-x\C-^\C-x\C-]"'
  bind -m "$__shell_buddy_map" '"\e[13;9u":"\C-x\C-^\C-x\C-]"'
  bind -m "$__shell_buddy_map" '"\e[13;5u":"\C-x\C-^\C-x\C-]"'
done
unset __shell_buddy_map
export SHELL_BUDDY_SHELL=bash
fi
