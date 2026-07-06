# bash completion for aidc.
# Installed by install.sh; also sourceable directly:  . completions/aidc.bash
# The command table must stay in sync with the dispatcher in lib/aidc.sh —
# tests/cli-errors.test.sh asserts that.
#
# SC2207: word-splitting compgen output into COMPREPLY is the standard
# completion idiom; all candidate words here are space-free by construction.
# shellcheck disable=SC2207

_aidc_commands="init up down rebuild rescan status destroy shell exec claude codex opencode grok cursor-agent cursor sync-claude-aliases sync-config sync-sessions sbom licenses scan doctor insights update upgrade version help"

_aidc_profiles() {
  local dir="${AIDC_CLAUDE_PROFILE_ROOT:-$HOME/.config/aidc/providers/claude}"
  local f
  for f in "$dir"/*.env; do
    [ -f "$f" ] || continue
    f="${f##*/}"
    printf '%s ' "${f%.env}"
  done
}

_aidc() {
  local cur prev cmd
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  if [ "$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=($(compgen -W "$_aidc_commands" -- "$cur"))
    return
  fi

  cmd="${COMP_WORDS[1]}"
  case "$cmd" in
    up|rebuild)
      COMPREPLY=($(compgen -W "--clipboard --isolate-vm" -- "$cur")) ;;
    status)
      COMPREPLY=($(compgen -W "--global" -- "$cur")) ;;
    destroy)
      COMPREPLY=($(compgen -W "-f --purge-worktree --purge-scaffold" -- "$cur")) ;;
    upgrade)
      COMPREPLY=($(compgen -W "--dry-run --diff -y" -- "$cur")) ;;
    scan)
      COMPREPLY=($(compgen -W "--all --staged --json" -- "$cur")) ;;
    insights)
      COMPREPLY=($(compgen -W "--since" -- "$cur")) ;;
    licenses)
      COMPREPLY=($(compgen -W "--fail" -- "$cur")) ;;
    sync-config|sync-sessions)
      COMPREPLY=($(compgen -W "claude codex opencode grok all" -- "$cur")) ;;
    claude)
      case "$prev" in
        --profile|--provider)
          COMPREPLY=($(compgen -W "$(_aidc_profiles)" -- "$cur")) ;;
        *)
          COMPREPLY=($(compgen -W "--profile --provider --list-profiles" -- "$cur")) ;;
      esac ;;
    init)
      COMPREPLY=($(compgen -d -- "$cur")) ;;
  esac
}

complete -F _aidc aidc
