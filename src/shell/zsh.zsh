# Source with: eval "$(shell-buddy init zsh)"
if [[ -o interactive ]]; then

function _shell_buddy_edit() {
  local result rc
  zle -R
  if result=$("${SHELL_BUDDY_BIN:-shell-buddy}" edit --shell zsh --initial "$BUFFER" --inline-left "$LBUFFER"); then
    rc=0
  else
    rc=$?
  fi
  case $rc in
    0|10|20)
      BUFFER=$result
      CURSOR=${#BUFFER}
      ;;
    *) zle -M 'shell-buddy failed to start; input preserved' ;;
  esac
  # ZLE normally owns bracketed-paste mode; restore its configured start sequence.
  (( ${#zle_bracketed_paste} )) && print -rn -- "$zle_bracketed_paste[1]"
  zle .redisplay
  if (( rc == 10 )); then zle orig-shell-buddy-accept
  else zle -R
  fi
}
function _shell_buddy_insert() {
  zle .self-insert
  [[ $BUFFER == '//' ]] && _shell_buddy_edit
  return 0
}
function _shell_buddy_accept() {
  if [[ $BUFFER =~ '^[[:space:]]*//' ]]; then _shell_buddy_edit
  else zle orig-shell-buddy-accept
  fi
}
# Autosuggestions excludes orig-* widgets from its precmd rebinding. An alias
# to its accept-line wrapper under any other name gets rewrapped with no valid
# original target, which makes Enter silently stop submitting commands.
if (( ! ${+widgets[orig-shell-buddy-accept]} )); then
  zle -A accept-line orig-shell-buddy-accept
fi
# Remove the unsafe alias from older initialization scripts when upgrading.
if (( ${+widgets[shell-buddy-original-accept]} )); then
  zle -D shell-buddy-original-accept
fi
zle -N shell-buddy-insert _shell_buddy_insert
zle -N shell-buddy-accept _shell_buddy_accept
for _shell_buddy_map in emacs viins; do
  bindkey -M "$_shell_buddy_map" '/' shell-buddy-insert
  bindkey -M "$_shell_buddy_map" '^M' shell-buddy-accept
  bindkey -M "$_shell_buddy_map" '^J' shell-buddy-accept
  bindkey -M "$_shell_buddy_map" '^[[13;9u' shell-buddy-accept
  bindkey -M "$_shell_buddy_map" '^[[13;5u' shell-buddy-accept
done
unset _shell_buddy_map
export SHELL_BUDDY_SHELL=zsh
fi
