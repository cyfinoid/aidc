#!/usr/bin/env bash
# aidc module: Session-transcript and agent-config sync between container and host.
# Sourced by lib/aidc.sh — never directly. Functions moved verbatim from
# the former monolith; behavior changes ride their own commits.

aidc::cmd_sync_config() {
  local workspace
  workspace="$(aidc::default_workspace)"
  local tool="${1:-}"
  [[ -n "$tool" ]] || aidc::die "usage: aidc sync-config <claude|codex|opencode|grok|omp|cursor|all>"
  aidc::ensure_container_running "$workspace"
  aidc::compose "$workspace" exec workspace /workspace/.devcontainer/scripts/bootstrap-state.sh sync "$tool"
  aidc::log "synced $tool config into the container volume"
}

aidc::cmd_sync_sessions() {
  local workspace
  workspace="$(aidc::default_workspace)"
  # Default to all agents — partial syncs surprised people (transcripts from
  # codex/opencode/grok silently missing on the host).
  local tool="${1:-all}"
  aidc::ensure_container_running "$workspace"

  case "$tool" in
    claude|codex|opencode|grok|omp|all) ;;
    *) aidc::die "usage: aidc sync-sessions [claude|codex|opencode|grok|omp|all]" ;;
  esac

  if [[ "$tool" == "all" ]]; then
    aidc::sync_session_tool "$workspace" claude
    aidc::sync_session_tool "$workspace" codex
    aidc::sync_session_tool "$workspace" opencode
    aidc::sync_session_tool "$workspace" grok
    aidc::sync_session_tool "$workspace" omp
  else
    aidc::sync_session_tool "$workspace" "$tool"
  fi
}

aidc::sync_session_tool() {
  local workspace="$1"
  local tool="$2"
  local container_src host_dst
  # Per-tool tar excludes (currently only opencode needs any): flags applied
  # to the *creation* side inside the container, so the GNU-tar exclude
  # semantics (dir pattern prunes its contents too) are what matters.
  local -a src_excludes=()
  # Existence probe run inside the container before anything is copied, plus
  # the human-readable reason used in the "nothing to sync" message.
  local -a gate=()
  local gate_desc

  case "$tool" in
    claude)
      container_src="/home/vscode/.claude/projects"
      host_dst="$HOME/.claude/projects"
      ;;
    codex)
      container_src="/home/vscode/.codex/sessions"
      host_dst="$HOME/.codex/sessions"
      ;;
    opencode)
      # opencode keeps sessions in the XDG *data* dir — never under
      # ~/.config/opencode (that is config only). Older builds wrote JSON
      # transcripts to storage/; current builds keep everything in a SQLite
      # opencode.db (+ -wal/-shm sidecars). The host's own opencode uses the
      # same data-dir path, so synced copies MUST land in an aidc-owned
      # subtree — extracting over ~/.local/share/opencode would clobber the
      # host's own database with the container's (data loss, not a merge).
      container_src="/home/vscode/.local/share/opencode"
      host_dst="$HOME/.local/share/aidc/sessions/opencode/$(aidc::repo_slug "${workspace:-/workspace}")"
      # Session artifacts only: credentials never leave the container, and
      # log/repos/snapshot/tool-output/bin are caches, not sessions.
      src_excludes=(
        --exclude=./auth.json
        --exclude=./log
        --exclude=./repos
        --exclude=./snapshot
        --exclude=./tool-output
        --exclude=./bin
      )
      # The data dir itself always exists (named volume mounts there), so
      # probe for actual session artifacts in either on-disk format.
      gate=(test -d "$container_src/storage" -o -f "$container_src/opencode.db")
      gate_desc="no session artifacts in $container_src"
      ;;
    grok)
      container_src="/home/vscode/.grok/sessions"
      host_dst="$HOME/.grok/sessions"
      ;;
    omp)
      # omp (oh-my-pi) stores conversations as JSONL under
      # ~/.omp/agent/sessions/<encoded-cwd>/<ts>_<id>.jsonl.
      container_src="/home/vscode/.omp/agent/sessions"
      host_dst="$HOME/.omp/agent/sessions"
      ;;
    *)
      aidc::die "unknown session tool: $tool"
      ;;
  esac

  if [[ ${#gate[@]} -gt 0 ]]; then
    if ! aidc::compose_capture "$workspace" exec -T workspace "${gate[@]}" >/dev/null 2>&1; then
      aidc::log "no $tool sessions to sync ($gate_desc)"
      return
    fi
  elif ! aidc::compose_capture "$workspace" exec -T workspace test -d "$container_src" >/dev/null 2>&1; then
    aidc::log "no $tool sessions to sync ($container_src missing)"
    return
  fi

  mkdir -p "$host_dst"
  # ${arr[@]+...} guard: empty-array expansion under `set -u` (bash 3.2) errors.
  aidc::compose "$workspace" exec -T workspace \
    tar -C "$container_src" -cf - ${src_excludes[@]+"${src_excludes[@]}"} . \
    | tar -C "$host_dst" --no-same-owner --no-same-permissions -xf -

  # Agent transcripts record absolute paths from inside the container, where the
  # repo is bind-mounted at /workspace (see compose.yaml.tmpl). Copied verbatim,
  # those `/workspace/...` paths do not exist on the host. Rewrite the in-container
  # mount root to the real host workspace path so synced logs/transcripts point at
  # paths that actually exist on this machine.
  if [[ -n "$workspace" && "$workspace" != "/workspace" ]]; then
    local esc_ws f
    esc_ws="$(printf '%s' "$workspace" | sed 's/[&|\\]/\\&/g')"
    while IFS= read -r f; do
      { sed "s|/workspace|${esc_ws}|g" "$f" >"$f.aidc-tmp" && mv "$f.aidc-tmp" "$f"; } \
        || rm -f "$f.aidc-tmp"
    done < <(find "$host_dst" -type f \( -name '*.jsonl' -o -name '*.json' \) 2>/dev/null)
  fi

  aidc::log "synced $tool sessions to $host_dst"
}

# Best-effort session sync wired into the agent/lifecycle paths so transcripts
# land on the host without a manual 'aidc sync-sessions'. Opt out by setting
# AIDC_AUTO_SYNC_SESSIONS=0 in .ai-container/project.env. 'tool' is a single
# tool name or 'all'; tools without a session mapping (e.g. cursor-agent) are
# skipped. Never aborts the caller — sync failures are logged, not fatal.
aidc::auto_sync_sessions() {
  local workspace="$1"
  local tool="$2"
  [[ "${AIDC_AUTO_SYNC_SESSIONS:-1}" == "0" ]] && return 0

  # No container, nothing to pull (e.g. auto-sync after a failed start).
  [[ -n "$(aidc::compose_capture "$workspace" ps -q workspace 2>/dev/null)" ]] || return 0

  if [[ "$tool" == "all" ]]; then
    local t
    for t in claude codex opencode grok omp; do
      aidc::sync_session_tool "$workspace" "$t" || true
    done
    return 0
  fi

  case "$tool" in
    claude|codex|opencode|grok|omp)
      aidc::sync_session_tool "$workspace" "$tool" || true
      ;;
    *)
      # cursor-agent and unknowns have no session volume to sync.
      ;;
  esac
}
