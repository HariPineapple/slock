# slock shell logger — source from ~/.zshrc.
# Appends: ts \t cwd \t exit_code \t duration_ms \t command   to ~/.slock/shell.log
zmodload zsh/datetime 2>/dev/null
typeset -g _slock_cmd="" _slock_start=0 _slock_cwd=""

_slock_preexec() {
  _slock_cmd="$1"
  _slock_start=$EPOCHREALTIME
  _slock_cwd="$PWD"
}

_slock_precmd() {
  local ec=$?
  [[ -z "$_slock_cmd" ]] && return
  [[ -e "$HOME/.slock/paused" ]] && { _slock_cmd=""; return }
  local dur=$(( (EPOCHREALTIME - _slock_start) * 1000 ))
  local cmd="${_slock_cmd//$'\n'/\\n}"
  cmd="${cmd//$'\t'/ }"
  print -r -- "${_slock_start}	${_slock_cwd//$'\t'/ }	${ec}	${dur%.*}	${cmd}" >> "$HOME/.slock/shell.log" 2>/dev/null
  _slock_cmd=""
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _slock_preexec
add-zsh-hook precmd _slock_precmd
