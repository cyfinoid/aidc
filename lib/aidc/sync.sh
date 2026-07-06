#!/usr/bin/env bash
# aidc module: Session-transcript and agent-config sync between container and host.
# Sourced by lib/aidc.sh — never directly. Functions moved verbatim from
# the former monolith; behavior changes ride their own commits.

aidc::cmd_sync_config() {
  local workspace
  workspace="$(aidc::default_workspace)"
  local tool="${1:-}"
  [[ -n "$tool" ]] || aidc::die "usage: aidc sync-config <claude|codex|opencode|grok|all>"
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
    claude|codex|opencode|grok|all) ;;
    *) aidc::die "usage: aidc sync-sessions [claude|codex|opencode|grok|all]" ;;
  esac

  if [[ "$tool" == "all" ]]; then
    aidc::sync_session_tool "$workspace" claude
    aidc::sync_session_tool "$workspace" codex
    aidc::sync_session_tool "$workspace" opencode
    aidc::sync_session_tool "$workspace" grok
  else
    aidc::sync_session_tool "$workspace" "$tool"
  fi
}

aidc::sync_session_tool() {
  local workspace="$1"
  local tool="$2"
  local container_src host_dst

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
      container_src="/home/vscode/.config/opencode/projects"
      host_dst="$HOME/.config/opencode/projects"
      ;;
    grok)
      container_src="/home/vscode/.grok/sessions"
      host_dst="$HOME/.grok/sessions"
      ;;
    *)
      aidc::die "unknown session tool: $tool"
      ;;
  esac

  if ! aidc::compose_capture "$workspace" exec -T workspace test -d "$container_src" >/dev/null 2>&1; then
    aidc::log "no $tool sessions to sync ($container_src missing)"
    return
  fi

  mkdir -p "$host_dst"
  aidc::compose "$workspace" exec -T workspace tar -C "$container_src" -cf - . \
    | tar -C "$host_dst" --no-same-owner --no-same-permissions -xf -
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
    for t in claude codex opencode grok; do
      aidc::sync_session_tool "$workspace" "$t" || true
    done
    return 0
  fi

  case "$tool" in
    claude|codex|opencode|grok)
      aidc::sync_session_tool "$workspace" "$tool" || true
      ;;
    *)
      # cursor-agent and unknowns have no session volume to sync.
      ;;
  esac
}
