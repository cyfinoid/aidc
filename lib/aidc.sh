#!/usr/bin/env bash

if [[ -n "${AIDC_LIB_LOADED:-}" ]]; then
  return 0
fi
export AIDC_LIB_LOADED=1

AIDC_VERSION="${AIDC_VERSION:-0.1.0}"
AIDC_CONTAINER_USER="${AIDC_CONTAINER_USER:-vscode}"
AIDC_CONTAINER_HOME="${AIDC_CONTAINER_HOME:-/home/vscode}"
AIDC_HOST_CONFIG_ROOT="${AIDC_HOST_CONFIG_ROOT:-$HOME/.config/aidc}"
AIDC_EMPTY_ROOT="${AIDC_EMPTY_ROOT:-$AIDC_HOST_CONFIG_ROOT/empty}"
AIDC_PROVIDER_ROOT="${AIDC_PROVIDER_ROOT:-$AIDC_HOST_CONFIG_ROOT/providers/claude}"
AIDC_CLAUDE_PROFILE_ROOT="${AIDC_CLAUDE_PROFILE_ROOT:-$AIDC_PROVIDER_ROOT}"
AIDC_BIN_DIR="${AIDC_BIN_DIR:-${AIDC_INSTALL_DIR:-$HOME/.local/bin}}"
AIDC_CORE_ROOT_DEFAULT="${AIDC_CORE_ROOT_DEFAULT:-$HOME/CORE_LOGICS}"
AIDC_CORE_WORKTREE_ROOT="${AIDC_CORE_WORKTREE_ROOT:-$HOME/.local/share/aidc/core-worktrees}"
AIDC_MANAGED_CLAUDE_ALIAS_MARKER="# aidc-managed claude-alias"
AIDC_MANAGED_PATHS=(
  ".devcontainer/Dockerfile"
  ".devcontainer/compose.yaml"
  ".devcontainer/devcontainer.json"
  ".devcontainer/scripts/bootstrap-state.sh"
  ".devcontainer/scripts/init-firewall.sh"
  ".ai-container/project.env"
  ".cursor/rules/00-core-logics.mdc"
)
AIDC_MERGE_PATHS=(
  "CLAUDE.md"
  "AGENTS.md"
)
AIDC_MERGE_MARKER_START="<!-- aidc:core-logics:start -->"
AIDC_MERGE_MARKER_END="<!-- aidc:core-logics:end -->"
AIDC_EXEC_ENV_ARGS=()
AIDC_PASSTHROUGH_ENV_KEYS=(
  "ANTHROPIC_API_KEY"
  "CLAUDE_CODE_OAUTH_TOKEN"
  "OPENAI_API_KEY"
  "CURSOR_API_KEY"
  "OPENROUTER_API_KEY"
  "OPENAI_BASE_URL"
)

aidc::main() {
  local cmd="${1:-help}"
  if [[ $# -gt 0 ]]; then
    shift
  fi

  case "$cmd" in
    init)
      aidc::cmd_init "$@"
      ;;
    up)
      aidc::cmd_up "$@"
      ;;
    down)
      aidc::cmd_down
      ;;
    rebuild)
      aidc::cmd_rebuild "$@"
      ;;
    status)
      aidc::cmd_status "$@"
      ;;
    destroy)
      aidc::cmd_destroy "$@"
      ;;
    shell)
      aidc::cmd_shell
      ;;
    exec)
      aidc::cmd_exec "$@"
      ;;
    claude)
      aidc::cmd_claude "$@"
      ;;
    codex)
      aidc::cmd_codex "$@"
      ;;
    opencode)
      aidc::cmd_opencode "$@"
      ;;
    cursor-agent)
      aidc::cmd_cursor_agent "$@"
      ;;
    cursor)
      aidc::cmd_cursor
      ;;
    sync-claude-aliases)
      aidc::cmd_sync_claude_aliases
      ;;
    sync-config)
      aidc::cmd_sync_config "$@"
      ;;
    sync-sessions)
      aidc::cmd_sync_sessions "$@"
      ;;
    help|-h|--help)
      aidc::cmd_help
      ;;
    *)
      aidc::die "unknown command: $cmd"
      ;;
  esac
}

aidc::cmd_help() {
  cat <<'EOF'
aidc - AI devcontainer bootstrapper

Usage:
  aidc init [path]
  aidc up [--clipboard] [--isolate-vm]
  aidc down
  aidc rebuild [--clipboard] [--isolate-vm]
  aidc status [--global]
  aidc destroy [-f] [--purge-worktree] [--purge-scaffold]
  aidc shell
  aidc exec -- <command>...
  aidc claude [--profile NAME] [--provider NAME] [--list-profiles] [-- ...]
  aidc codex [-- ...]
  aidc opencode [-- ...]
  aidc cursor-agent [-- ...]
  aidc cursor
  aidc sync-claude-aliases
  aidc sync-config <claude|codex|opencode|all>
  aidc sync-sessions [claude|codex|opencode|all]

Notes:
  - Run commands from the repo root you want to isolate.
  - Tool commands auto-bootstrap the repo and container if needed.
  - Plain 'aidc claude' keeps the default Anthropic path.
  - aidc cursor opens the host Cursor app; reopen the repo in the devcontainer.
  - aidc destroy removes the container, named volumes, and image by default.
    Worktree and scaffold removal are opt-in via the listed flags.
  - aidc sync-sessions pulls in-container session logs back to host
    ~/.claude/projects so '/insights' on the host can see them.
  - The host-clipboard bridge is off by default. Enable it at (re)create time
    with 'aidc up --clipboard' or 'aidc rebuild --clipboard'.
  - Per-project VM isolation is off by default due to resource cost. Enable it
    with 'aidc up --isolate-vm' or persist AIDC_ISOLATE_VM=1 in
    .ai-container/project.env. See README "Isolation modes".
EOF
}

aidc::cmd_init() {
  local workspace
  workspace="$(aidc::resolve_workspace_arg "${1:-}")"

  aidc::need_cmd docker git
  aidc::ensure_host_config_dirs
  aidc::ensure_claude_profile_examples
  aidc::sync_claude_aliases
  aidc::check_init_conflicts "$workspace"

  local repo_slug
  repo_slug="$(aidc::repo_slug "$workspace")"

  aidc::ensure_core_repo
  local core_root
  core_root="$(aidc::core_root)"
  local core_branch
  core_branch="project/$repo_slug"
  local core_worktree
  core_worktree="$(aidc::ensure_core_worktree "$repo_slug" "$core_branch")"

  aidc::refresh_scaffold "$workspace" "$repo_slug" "$core_root" "$core_branch" "$core_worktree"
  aidc::ensure_local_git_excludes "$workspace"

  aidc::log "initialized $workspace"
  aidc::log "repo slug: $repo_slug"
  aidc::log "CORE_LOGICS branch: $core_branch"
  aidc::log "next: run 'aidc up' or 'aidc claude'"
}

aidc::refresh_scaffold() {
  local workspace="$1"
  local repo_slug="$2"
  local core_root="$3"
  local core_branch="$4"
  local core_worktree="$5"

  mkdir -p \
    "$workspace/.devcontainer/scripts" \
    "$workspace/.ai-container" \
    "$workspace/.cursor/rules"

  aidc::copy_template "templates/devcontainer/Dockerfile.tmpl" "$workspace/.devcontainer/Dockerfile" "0755"
  aidc::copy_template "templates/devcontainer/compose.yaml.tmpl" "$workspace/.devcontainer/compose.yaml" "0644"
  aidc::copy_template "templates/devcontainer/devcontainer.json.tmpl" "$workspace/.devcontainer/devcontainer.json" "0644"
  aidc::copy_template "templates/devcontainer/scripts/bootstrap-state.sh.tmpl" "$workspace/.devcontainer/scripts/bootstrap-state.sh" "0755"
  aidc::copy_template "templates/devcontainer/scripts/init-firewall.sh.tmpl" "$workspace/.devcontainer/scripts/init-firewall.sh" "0755"
  # User-owned. Created once, never refreshed; edits drive per-project image layers.
  aidc::copy_template_once "templates/devcontainer/project-setup.sh.tmpl" "$workspace/.devcontainer/project-setup.sh" "0755"
  aidc::merge_template "templates/CLAUDE.md.tmpl" "$workspace/CLAUDE.md"
  aidc::merge_template "templates/AGENTS.md.tmpl" "$workspace/AGENTS.md"
  aidc::copy_template "templates/cursor-rules/00-core-logics.mdc.tmpl" "$workspace/.cursor/rules/00-core-logics.mdc" "0644"

  # project.env is preserved if it already exists, so user-added settings
  # (e.g. AIDC_ENABLE_EGRESS_FIREWALL=1) survive scaffold refreshes.
  if [[ ! -f "$workspace/.ai-container/project.env" ]]; then
    aidc::write_project_env "$workspace/.ai-container/project.env" "$workspace" "$repo_slug" "$core_root" "$core_branch" "$core_worktree"
  fi
}

aidc::cmd_up() {
  local workspace
  aidc::parse_up_flags "$@"
  workspace="$(aidc::default_workspace)"
  aidc::ensure_workspace_ready "$workspace"

  if [[ "${AIDC_ISOLATE_VM:-0}" == "1" ]]; then
    aidc::vm_ensure "$workspace"
  fi

  aidc::compose "$workspace" up -d --build workspace
  aidc::log "container is ready for $(basename "$workspace")"
}

aidc::cmd_rebuild() {
  local workspace
  aidc::parse_up_flags "$@"
  workspace="$(aidc::default_workspace)"
  aidc::ensure_workspace_ready "$workspace"

  if [[ "${AIDC_ISOLATE_VM:-0}" == "1" ]]; then
    aidc::vm_ensure "$workspace"
  fi

  aidc::compose "$workspace" up -d --build --force-recreate workspace
  aidc::log "container rebuilt for $(basename "$workspace")"
}

# Parse flags shared by 'up' and 'rebuild'.
# --clipboard: opt-in host-clipboard bridge. Off by default; can also be
#   persisted as AIDC_ENABLE_CLIPBOARD=1 in .ai-container/project.env.
# --isolate-vm: opt-in per-project VM isolation (Lima on macOS, Firecracker
#   on Linux). Off by default due to resource cost; can also be persisted as
#   AIDC_ISOLATE_VM=1 in .ai-container/project.env. See docs/security.md.
aidc::parse_up_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --clipboard) export AIDC_ENABLE_CLIPBOARD=1 ;;
      --isolate-vm) export AIDC_ISOLATE_VM=1 ;;
      *) aidc::die "unknown flag: $1" ;;
    esac
    shift
  done
}

aidc::cmd_down() {
  local workspace
  workspace="$(aidc::default_workspace)"
  if [[ ! -f "$workspace/.ai-container/project.env" ]]; then
    aidc::die "no aidc project in $workspace (run 'aidc init' first)"
  fi
  aidc::load_project_env "$workspace"
  aidc::compose "$workspace" down

  if [[ "${AIDC_ISOLATE_VM:-0}" == "1" ]]; then
    aidc::vm_stop "$workspace"
  fi

  aidc::log "container stopped for $(basename "$workspace")"
}

aidc::cmd_status() {
  local global=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --global|-g) global=1 ;;
      *) aidc::die "unknown status flag: $1" ;;
    esac
    shift
  done

  if [[ "$global" -eq 1 ]]; then
    aidc::cmd_status_global
    return
  fi

  local workspace
  workspace="$(aidc::default_workspace)"

  if [[ ! -f "$workspace/.ai-container/project.env" ]]; then
    printf 'no aidc project in %s (run '\''aidc init'\'' first)\n' "$workspace"
    return
  fi

  aidc::load_project_env "$workspace"
  aidc::export_compose_env "$workspace"

  local C_HDR='' C_LBL='' C_OK='' C_WARN='' C_DIM='' C_RST=''
  if [[ -t 1 ]]; then
    C_HDR=$'\033[1;36m'
    C_LBL=$'\033[2m'
    C_OK=$'\033[1;32m'
    C_WARN=$'\033[1;33m'
    C_DIM=$'\033[2m'
    C_RST=$'\033[0m'
  fi

  local cid_running cid_all
  cid_running="$(aidc::compose_capture "$workspace" ps -q workspace 2>/dev/null || true)"
  cid_all="$(aidc::compose_capture "$workspace" ps -aq workspace 2>/dev/null || true)"

  aidc::status_header "container" "$C_HDR" "$C_RST"
  aidc::status_container "$cid_running" "$cid_all" "$C_OK" "$C_WARN" "$C_DIM" "$C_LBL" "$C_RST"

  printf '\n'
  aidc::status_header "config & mounts" "$C_HDR" "$C_RST"
  aidc::status_config "$workspace" "$C_LBL" "$C_DIM" "$C_RST"
}

aidc::status_header() {
  local label="$1" c_hdr="$2" c_rst="$3"
  local width=64
  local prefix="── $label "
  local pad=$((width - ${#prefix}))
  (( pad < 4 )) && pad=4
  local dashes=''
  local i
  for ((i = 0; i < pad; i++)); do dashes+='─'; done
  printf '%s%s%s%s\n' "$c_hdr" "$prefix" "$dashes" "$c_rst"
}

aidc::status_kv() {
  local label="$1" value="$2" c_lbl="$3" c_rst="$4"
  printf '  %s%-10s%s  %s\n' "$c_lbl" "$label" "$c_rst" "$value"
}

aidc::status_container() {
  local cid_running="$1" cid_all="$2"
  local c_ok="$3" c_warn="$4" c_dim="$5" c_lbl="$6" c_rst="$7"

  if [[ -n "$cid_running" ]]; then
    local started size stats cpu mem pids
    started="$(docker inspect --format '{{.State.StartedAt}}' "$cid_running" 2>/dev/null || true)"
    started="$(aidc::status_fmt_ts "$started")"
    size="$(docker container ls --size --all --filter "id=$cid_running" --format '{{.Size}}' 2>/dev/null || true)"
    # Single docker stats call: cpu | mem usage | pids
    stats="$(docker stats --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}|{{.PIDs}}' "$cid_running" 2>/dev/null || true)"
    cpu="${stats%%|*}"
    mem="${stats#*|}"; mem="${mem%|*}"
    pids="${stats##*|}"

    aidc::status_kv "state" "${c_ok}● running${c_rst}" "$c_lbl" "$c_rst"
    aidc::status_kv "id" "${cid_running:0:12}" "$c_lbl" "$c_rst"
    [[ -n "$started" ]] && aidc::status_kv "uptime" "since $started" "$c_lbl" "$c_rst"
    [[ -n "$size" ]] && aidc::status_kv "disk" "$size" "$c_lbl" "$c_rst"
    [[ -n "$cpu" ]] && aidc::status_kv "cpu" "$cpu" "$c_lbl" "$c_rst"
    [[ -n "$mem" ]] && aidc::status_kv "memory" "$mem" "$c_lbl" "$c_rst"
    [[ -n "$pids" ]] && aidc::status_kv "pids" "$pids" "$c_lbl" "$c_rst"
  elif [[ -n "$cid_all" ]]; then
    local state exited size
    state="$(docker inspect --format '{{.State.Status}}' "$cid_all" 2>/dev/null || echo unknown)"
    exited="$(docker inspect --format '{{.State.FinishedAt}}' "$cid_all" 2>/dev/null || true)"
    exited="$(aidc::status_fmt_ts "$exited")"
    size="$(docker container ls --size --all --filter "id=$cid_all" --format '{{.Size}}' 2>/dev/null || true)"

    aidc::status_kv "state" "${c_warn}● ${state}${c_rst}" "$c_lbl" "$c_rst"
    aidc::status_kv "id" "${cid_all:0:12}" "$c_lbl" "$c_rst"
    [[ -n "$exited" ]] && aidc::status_kv "exited" "$exited" "$c_lbl" "$c_rst"
    [[ -n "$size" ]] && aidc::status_kv "disk" "$size" "$c_lbl" "$c_rst"
    printf '  %shint%s        run %s'\''aidc up'\''%s to start\n' "$c_lbl" "$c_rst" "$c_dim" "$c_rst"
  else
    aidc::status_kv "state" "${c_dim}○ not created${c_rst}" "$c_lbl" "$c_rst"
    printf '  %shint%s        run %s'\''aidc up'\''%s to build and start\n' "$c_lbl" "$c_rst" "$c_dim" "$c_rst"
  fi
}

aidc::status_config() {
  local workspace="$1" c_lbl="$2" c_dim="$3" c_rst="$4"

  aidc::status_kv "workspace" "$workspace" "$c_lbl" "$c_rst"
  aidc::status_kv "slug" "$AIDC_REPO_SLUG" "$c_lbl" "$c_rst"
  aidc::status_kv "compose" "$COMPOSE_PROJECT_NAME" "$c_lbl" "$c_rst"
  aidc::status_kv "branch" "$AIDC_CORE_BRANCH" "$c_lbl" "$c_rst"
  aidc::status_kv "worktree" "$AIDC_CORE_WORKTREE" "$c_lbl" "$c_rst"

  printf '\n  %smounts%s\n' "$c_lbl" "$c_rst"
  aidc::status_mount_row "/workspace" "$workspace" "$c_dim" "$c_rst"
  aidc::status_mount_row "/opt/CORE_LOGICS" "$AIDC_CORE_WORKTREE" "$c_dim" "$c_rst"
  aidc::status_mount_row "/host-seed/claude" "$AIDC_HOST_SEED_CLAUDE" "$c_dim" "$c_rst"
  aidc::status_mount_row "/host-seed/codex" "$AIDC_HOST_SEED_CODEX" "$c_dim" "$c_rst"
  aidc::status_mount_row "/host-seed/opencode" "$AIDC_HOST_SEED_OPENCODE" "$c_dim" "$c_rst"
  aidc::status_mount_row "/host-seed/gitconfig" "$AIDC_GITCONFIG_SOURCE" "$c_dim" "$c_rst"
  aidc::status_mount_row "/host-clipboard" "$AIDC_CLIPBOARD_DIR_SOURCE" "$c_dim" "$c_rst"

  local vols
  vols="$(docker volume ls --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" --format '{{.Name}}' 2>/dev/null | sed "s/^${COMPOSE_PROJECT_NAME}_//" | sort | tr '\n' ' ')"
  if [[ -n "$vols" ]]; then
    printf '\n  %svolumes%s   %s\n' "$c_lbl" "$c_rst" "$vols"
  fi
}

aidc::status_mount_row() {
  local target="$1" source="$2" c_dim="$3" c_rst="$4"
  local annotated="$source"
  if [[ -n "${AIDC_EMPTY_ROOT:-}" && "$source" == "$AIDC_EMPTY_ROOT"/* ]]; then
    annotated="${c_dim}(empty placeholder)${c_rst}"
  fi
  printf '    %-22s %s←%s %s\n' "$target" "$c_dim" "$c_rst" "$annotated"
}

aidc::status_fmt_ts() {
  local ts="$1"
  [[ -z "$ts" || "$ts" == 0001-01-01* ]] && return
  ts="${ts%.*}"
  ts="${ts/T/ }"
  ts="${ts%Z}"
  printf '%s UTC' "$ts"
}

aidc::cmd_status_global() {
  local C_HDR='' C_LBL='' C_OK='' C_WARN='' C_DIM='' C_RST=''
  if [[ -t 1 ]]; then
    C_HDR=$'\033[1;36m'
    C_LBL=$'\033[2m'
    C_OK=$'\033[1;32m'
    C_WARN=$'\033[1;33m'
    C_DIM=$'\033[2m'
    C_RST=$'\033[0m'
  fi

  # All compose-managed containers, filtered to aidc_* projects.
  local rows
  rows="$(docker ps -a \
    --filter 'label=com.docker.compose.project' \
    --format '{{.ID}}|{{.Label "com.docker.compose.project"}}|{{.State}}|{{.Label "com.docker.compose.project.working_dir"}}' \
    2>/dev/null \
    | awk -F'|' '$2 ~ /^aidc_/ {print}')"

  aidc::status_header "aidc global" "$C_HDR" "$C_RST"

  if [[ -z "$rows" ]]; then
    printf '  no aidc containers found\n'
    return
  fi

  # One-shot disk and stats lookups so we don't fork docker per container.
  local size_map stats_map running_ids
  size_map="$(docker container ls --all --size --format '{{.ID}}|{{.Size}}' 2>/dev/null)"
  running_ids="$(printf '%s\n' "$rows" | awk -F'|' '$3=="running" {printf "%s ", $1}')"
  stats_map=''
  if [[ -n "$running_ids" ]]; then
    # shellcheck disable=SC2086
    stats_map="$(docker stats --no-stream --format '{{.ID}}|{{.CPUPerc}}|{{.MemUsage}}|{{.PIDs}}' $running_ids 2>/dev/null)"
  fi

  local total=0 running=0 stopped=0
  printf '\n'
  while IFS='|' read -r id project state working_dir; do
    [[ -z "$id" ]] && continue
    total=$((total + 1))
    local slug="${project#aidc_}"
    local workspace="${working_dir%/.devcontainer*}"
    [[ -z "$workspace" ]] && workspace='(unknown)'

    local size
    size="$(printf '%s\n' "$size_map" | awk -F'|' -v id="$id" 'index($1,id)==1 {print $2; exit}')"

    if [[ "$state" == "running" ]]; then
      running=$((running + 1))
      local stat_row cpu mem pids started
      stat_row="$(printf '%s\n' "$stats_map" | awk -F'|' -v id="$id" 'index($1,id)==1 {print; exit}')"
      cpu="$(printf '%s' "$stat_row" | awk -F'|' '{print $2}')"
      mem="$(printf '%s' "$stat_row" | awk -F'|' '{print $3}')"
      pids="$(printf '%s' "$stat_row" | awk -F'|' '{print $4}')"
      started="$(docker inspect --format '{{.State.StartedAt}}' "$id" 2>/dev/null || true)"
      started="$(aidc::status_fmt_ts "$started")"

      printf '  %s● running%s  %s\n' "$C_OK" "$C_RST" "$slug"
      printf '              %s%s%s\n' "$C_DIM" "$workspace" "$C_RST"
      printf '              %sdisk%s %s   %scpu%s %s   %smem%s %s   %spids%s %s\n' \
        "$C_LBL" "$C_RST" "${size:-?}" \
        "$C_LBL" "$C_RST" "${cpu:-?}" \
        "$C_LBL" "$C_RST" "${mem:-?}" \
        "$C_LBL" "$C_RST" "${pids:-?}"
      [[ -n "$started" ]] && printf '              %ssince%s %s\n' "$C_LBL" "$C_RST" "$started"
    else
      stopped=$((stopped + 1))
      local exited
      exited="$(docker inspect --format '{{.State.FinishedAt}}' "$id" 2>/dev/null || true)"
      exited="$(aidc::status_fmt_ts "$exited")"

      printf '  %s○ %s%s  %s\n' "$C_WARN" "$state" "$C_RST" "$slug"
      printf '              %s%s%s\n' "$C_DIM" "$workspace" "$C_RST"
      printf '              %sdisk%s %s\n' "$C_LBL" "$C_RST" "${size:-?}"
      [[ -n "$exited" ]] && printf '              %sexited%s %s\n' "$C_LBL" "$C_RST" "$exited"
    fi
    printf '\n'
  done <<<"$rows"

  aidc::status_header "totals" "$C_HDR" "$C_RST"
  printf '  %scontainers%s   %d  (%s%d running%s, %s%d stopped%s)\n' \
    "$C_LBL" "$C_RST" "$total" \
    "$C_OK" "$running" "$C_RST" \
    "$C_WARN" "$stopped" "$C_RST"
}

aidc::cmd_destroy() {
  local workspace
  workspace="$(aidc::default_workspace)"
  if [[ ! -f "$workspace/.ai-container/project.env" ]]; then
    aidc::die "no aidc project in $workspace (run 'aidc init' first)"
  fi

  local force=0
  local purge_worktree=0
  local purge_scaffold=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--force)
        force=1
        ;;
      --purge-worktree)
        purge_worktree=1
        ;;
      --purge-scaffold)
        purge_scaffold=1
        ;;
      *)
        aidc::die "unknown destroy flag: $1"
        ;;
    esac
    shift
  done

  aidc::load_project_env "$workspace"

  local prompt
  prompt="destroy container, named volumes, and image for $(basename "$workspace")"
  [[ "$purge_worktree" -eq 1 ]] && prompt+=" + CORE_LOGICS worktree '$AIDC_CORE_BRANCH'"
  [[ "$purge_scaffold" -eq 1 ]] && prompt+=" + scaffold files"
  if [[ "$force" -ne 1 ]]; then
    printf '[aidc] %s? [y/N] ' "$prompt"
    local reply
    read -r reply
    case "$reply" in
      y|Y|yes|YES) ;;
      *) aidc::log "destroy aborted"; return ;;
    esac
  fi

  aidc::compose "$workspace" down -v --rmi local --remove-orphans

  if [[ "${AIDC_ISOLATE_VM:-0}" == "1" ]]; then
    aidc::vm_destroy "$workspace"
  fi

  if [[ "$purge_worktree" -eq 1 ]]; then
    aidc::destroy_core_worktree "$AIDC_REPO_SLUG" "$AIDC_CORE_BRANCH"
  fi

  if [[ "$purge_scaffold" -eq 1 ]]; then
    aidc::destroy_scaffold "$workspace"
  fi

  aidc::log "destroyed $(basename "$workspace")"
}

aidc::destroy_core_worktree() {
  local repo_slug="$1"
  local branch="$2"
  local core_root
  core_root="$(aidc::core_root)"
  local worktree="$AIDC_CORE_WORKTREE_ROOT/$repo_slug"

  if [[ -e "$worktree" ]]; then
    git -C "$core_root" worktree remove --force "$worktree" 2>/dev/null || rm -rf "$worktree"
    aidc::log "removed worktree $worktree"
  fi
  if git -C "$core_root" rev-parse --verify "$branch" >/dev/null 2>&1; then
    git -C "$core_root" branch -D "$branch" >/dev/null
    aidc::log "deleted branch $branch in $core_root"
  fi
}

aidc::destroy_scaffold() {
  local workspace="$1"
  local path
  for path in "${AIDC_MANAGED_PATHS[@]}"; do
    rm -rf "${workspace:?}/${path:?}"
  done
  for path in "${AIDC_MERGE_PATHS[@]}"; do
    aidc::strip_merge_block "$workspace/$path"
  done
  rmdir "$workspace/.devcontainer/scripts" 2>/dev/null || true
  rmdir "$workspace/.devcontainer" 2>/dev/null || true
  rmdir "$workspace/.ai-container" 2>/dev/null || true
  rmdir "$workspace/.cursor/rules" 2>/dev/null || true
  rmdir "$workspace/.cursor" 2>/dev/null || true

  if git -C "$workspace" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local exclude_file
    exclude_file="$(git -C "$workspace" rev-parse --git-path info/exclude)"
    if [[ "$exclude_file" != /* ]]; then
      exclude_file="$workspace/$exclude_file"
    fi
    if [[ -f "$exclude_file" ]]; then
      local tmp
      tmp="$(mktemp)"
      grep -Fvx -e ".devcontainer/" -e ".ai-container/" -e ".cursor/rules/00-core-logics.mdc" -e "CLAUDE.md" -e "AGENTS.md" "$exclude_file" >"$tmp" || true
      mv "$tmp" "$exclude_file"
    fi
  fi
  aidc::log "removed scaffold files from $workspace"
}

aidc::cmd_shell() {
  local workspace
  workspace="$(aidc::default_workspace)"
  aidc::ensure_container_running "$workspace"
  aidc::compose "$workspace" exec workspace zsh -l
}

aidc::cmd_exec() {
  local workspace
  workspace="$(aidc::default_workspace)"
  aidc::ensure_container_running "$workspace"

  if [[ $# -gt 0 && "$1" == "--" ]]; then
    shift
  fi
  [[ $# -gt 0 ]] || aidc::die "usage: aidc exec [--] <command> [args...]"

  AIDC_EXEC_ENV_ARGS=()
  aidc::append_passthrough_env_args
  aidc::compose "$workspace" exec "${AIDC_EXEC_ENV_ARGS[@]}" workspace "$@"
}

aidc::cmd_claude() {
  local profile=""
  local list_profiles=0
  local args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile)
        [[ $# -ge 2 ]] || aidc::die "missing value for --profile"
        profile="$2"
        shift 2
        ;;
      --provider)
        [[ $# -ge 2 ]] || aidc::die "missing value for --provider"
        profile="$2"
        shift 2
        ;;
      -l|--list|--list-profiles)
        list_profiles=1
        shift
        ;;
      --)
        shift
        args+=("$@")
        break
        ;;
      *)
        args+=("$1")
        shift
        ;;
    esac
  done

  if [[ "$list_profiles" -eq 1 ]]; then
    aidc::list_claude_profiles
    return
  fi

  aidc::run_tool "claude" "$profile" "${args[@]}"
}

aidc::cmd_codex() {
  aidc::run_tool "codex" "" "$@"
}

aidc::cmd_opencode() {
  aidc::run_tool "opencode" "" "$@"
}

aidc::cmd_cursor_agent() {
  aidc::run_tool "cursor-agent" "" "$@"
}

aidc::cmd_cursor() {
  local workspace
  workspace="$(aidc::default_workspace)"
  aidc::need_cmd cursor
  aidc::ensure_workspace_ready "$workspace"
  cursor "$workspace"
  aidc::log "opened Cursor on $workspace"
  aidc::log "reopen the repo in the devcontainer using the Remote Containers extension"
}

aidc::cmd_sync_claude_aliases() {
  aidc::ensure_host_config_dirs
  aidc::ensure_claude_profile_examples
  aidc::sync_claude_aliases
}

aidc::cmd_sync_config() {
  local workspace
  workspace="$(aidc::default_workspace)"
  local tool="${1:-}"
  [[ -n "$tool" ]] || aidc::die "usage: aidc sync-config <claude|codex|opencode|all>"
  aidc::ensure_container_running "$workspace"
  aidc::compose "$workspace" exec workspace /workspace/.devcontainer/scripts/bootstrap-state.sh sync "$tool"
  aidc::log "synced $tool config into the container volume"
}

aidc::cmd_sync_sessions() {
  local workspace
  workspace="$(aidc::default_workspace)"
  local tool="${1:-claude}"
  aidc::ensure_container_running "$workspace"

  case "$tool" in
    claude|codex|opencode|all) ;;
    *) aidc::die "usage: aidc sync-sessions [claude|codex|opencode|all]" ;;
  esac

  if [[ "$tool" == "all" ]]; then
    aidc::sync_session_tool "$workspace" claude
    aidc::sync_session_tool "$workspace" codex
    aidc::sync_session_tool "$workspace" opencode
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

aidc::run_tool() {
  local tool="$1"
  local profile="$2"
  shift 2

  local workspace
  workspace="$(aidc::default_workspace)"
  aidc::ensure_container_running "$workspace"

  AIDC_EXEC_ENV_ARGS=()
  aidc::append_passthrough_env_args
  if [[ "$tool" == "claude" && -n "$profile" ]]; then
    aidc::load_claude_profile_env "$profile"
  fi

  if [[ "$tool" == "claude" && -z "$profile" && -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
    aidc::compose "$workspace" exec -T -e CLAUDE_CODE_OAUTH_TOKEN workspace aidc-bootstrap-claude || \
      aidc::warn "Claude OAuth bootstrap failed; falling through to interactive login"
  fi

  local -a command
  case "$tool" in
    claude)
      command=("claude" "--dangerously-skip-permissions")
      ;;
    codex)
      command=("codex" "--dangerously-bypass-approvals-and-sandbox")
      ;;
    opencode)
      command=("opencode")
      ;;
    cursor-agent)
      command=("cursor-agent" "--sandbox" "disabled" "-f")
      ;;
    *)
      aidc::die "unsupported tool: $tool"
      ;;
  esac

  if [[ $# -gt 0 ]]; then
    command+=("$@")
  fi

  aidc::compose "$workspace" exec "${AIDC_EXEC_ENV_ARGS[@]}" workspace "${command[@]}"
}

aidc::need_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || aidc::die "required command not found: $cmd"
  done
}

# ─── VM isolation backend (Lima on macOS, Firecracker on Linux) ───
#
# When AIDC_ISOLATE_VM=1 each project gets its own lightweight VM instead of
# sharing the host Docker daemon.  The compose stack still runs unchanged —
# we just point DOCKER_HOST at the per-project VM's Docker socket.

aidc::vm_name() {
  local workspace="$1"
  local slug
  slug="$(aidc::repo_slug "$workspace")"
  printf 'aidc-%s\n' "$slug"
}

aidc::vm_socket_dir() {
  printf '%s/aidc-vm\n' "$AIDC_HOST_CONFIG_ROOT"
}

aidc::vm_socket_path() {
  local vm_name="$1"
  printf '%s/%s.sock\n' "$(aidc::vm_socket_dir)" "$vm_name"
}

# Detect which VM backend to use based on the host OS.
aidc::vm_backend() {
  local uname_s
  uname_s="$(uname -s)"
  case "$uname_s" in
    Darwin) printf 'lima' ;;
    Linux)  printf 'firecracker' ;;
    *)      aidc::die "VM isolation is not supported on $uname_s" ;;
  esac
}

# Ensure the per-project VM is running.  Creates it on first use.
aidc::vm_ensure() {
  local workspace="$1"
  local backend
  backend="$(aidc::vm_backend)"
  aidc::log "VM isolation enabled (backend: $backend)"

  case "$backend" in
    lima)        aidc::lima_ensure "$workspace" ;;
    firecracker) aidc::firecracker_ensure "$workspace" ;;
  esac
}

# Stop the per-project VM (called from 'aidc down').
aidc::vm_stop() {
  local workspace="$1"
  local backend
  backend="$(aidc::vm_backend)"

  case "$backend" in
    lima)        aidc::lima_stop "$workspace" ;;
    firecracker) aidc::firecracker_stop "$workspace" ;;
  esac
}

# Destroy the per-project VM (called from 'aidc destroy').
aidc::vm_destroy() {
  local workspace="$1"
  local backend
  backend="$(aidc::vm_backend)"

  case "$backend" in
    lima)        aidc::lima_destroy "$workspace" ;;
    firecracker) aidc::firecracker_destroy "$workspace" ;;
  esac
}

# ─── Lima backend (macOS) ──────────────────────────────────────────

AIDC_LIMA_CONFIG_DIR="${AIDC_HOST_CONFIG_ROOT}/lima-configs"

# Resource defaults for the Lima VM.  Override via AIDC_LIMA_CPUS /
# AIDC_LIMA_MEMORY / AIDC_LIMA_DISK in .ai-container/project.env.
AIDC_LIMA_CPUS="${AIDC_LIMA_CPUS:-2}"
AIDC_LIMA_MEMORY="${AIDC_LIMA_MEMORY:-2GiB}"
AIDC_LIMA_DISK="${AIDC_LIMA_DISK:-10GiB}"

aidc::lima_config_path() {
  local vm_name="$1"
  printf '%s/%s.yaml\n' "$AIDC_LIMA_CONFIG_DIR" "$vm_name"
}

aidc::lima_generate_config() {
  local vm_name="$1"
  local workspace="$2"
  local config_path
  config_path="$(aidc::lima_config_path "$vm_name")"

  # Pick an SSH port that won't collide.  Hash the vm_name to get a port
  # in 4200–4299 range.
  local ssh_port
  ssh_port=$((4200 + ($(printf '%s' "$vm_name" | cksum | cut -d' ' -f1) % 100)))

  mkdir -p "$AIDC_LIMA_CONFIG_DIR"
  cat >"$config_path" <<LIMAEOF
# aidc-managed Lima config for $vm_name
# DO NOT EDIT — regenerated from 'aidc up --isolate-vm'

vmType: qemu
os: Linux
arch: $(uname -m | sed 's/arm64/aarch64/')
images:
  - location: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-\$(uname -m | sed 's/arm64/aarch64/').img"
    digest: "sha256:auto"

cpus: $AIDC_LIMA_CPUS
memory: $AIDC_LIMA_MEMORY
disk: $AIDC_LIMA_DISK

firmware:
  legacyBIOS: false

ssh:
  localPort: $ssh_port
  loadDotSSHPubKeys: false
  forwardAgent: false

containerd:
  system: false
  user: false

# Install Docker inside the VM so we can use the standard compose stack.
provision:
  - mode: system
    script: |
      #!/bin/bash
      set -euo pipefail
      if command -v docker >/dev/null 2>&1; then
        exit 0
      fi
      apt-get update -qq
      apt-get install -y -qq ca-certificates curl gnupg
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(. /etc/os-release && echo "\$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
      apt-get update -qq
      apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      usermod -aG docker "${AIDC_CONTAINER_USER}"

mounts:
  - location: "$workspace"
    writable: true
  - location: "~/.config/aidc/empty/claude"
    mountPoint: "/host-seed/claude"
    writable: false
  - location: "~/.config/aidc/empty/codex"
    mountPoint: "/host-seed/codex"
    writable: false

networks:
  - lima: shared

message: |
  aidc Lima VM "{{.Name}}" — managed by aidc. Do not edit manually.
LIMAEOF

  printf '%s\n' "$config_path"
}

aidc::lima_ensure() {
  local workspace="$1"
  aidc::need_cmd limactl

  local vm_name
  vm_name="$(aidc::vm_name "$workspace")"

  # Already running?
  if limactl list --format '{{.Name}}' 2>/dev/null | grep -qxF "$vm_name"; then
    local vm_state
    vm_state="$(limactl list --format '{{.Name}} {{.Status}}' 2>/dev/null | awk -v n="$vm_name" '$1==n {print $2}')"
    if [[ "$vm_state" == "Running" ]]; then
      aidc::log "Lima VM $vm_name is already running"
      aidc::lima_export_docker_host "$vm_name"
      return
    fi
    # Stopped — start it.
    aidc::log "starting Lima VM $vm_name ..."
    limactl start "$vm_name"
    aidc::lima_export_docker_host "$vm_name"
    return
  fi

  # First time — generate config and create the VM.
  aidc::log "creating Lima VM $vm_name (this may take a few minutes on first run) ..."
  aidc::log "  CPUs: $AIDC_LIMA_CPUS  Memory: $AIDC_LIMA_MEMORY  Disk: $AIDC_LIMA_DISK"
  aidc::log "  ⚠ Each isolated VM uses significant CPU/RAM/disk. See README 'Isolation modes'."

  local config_path
  config_path="$(aidc::lima_generate_config "$vm_name" "$workspace")"
  limactl start --tty=false "$config_path"
  aidc::lima_export_docker_host "$vm_name"
  aidc::log "Lima VM $vm_name is ready"
}

aidc::lima_export_docker_host() {
  local vm_name="$1"
  # Lima exposes the guest Docker socket via a Unix socket under ~/.lima/<name>/sock/
  local lima_socket="$HOME/.lima/${vm_name}/sock/docker.sock"
  if [[ -S "$lima_socket" ]]; then
    export DOCKER_HOST="unix://$lima_socket"
    aidc::log "DOCKER_HOST set to Lima VM: $DOCKER_HOST"
  else
    # Fallback: use limactl to copy the socket context
    local socket_dir
    socket_dir="$(aidc::vm_socket_dir)"
    mkdir -p "$socket_dir"
    limactl copy "$vm_name:/var/run/docker.sock" "$(aidc::vm_socket_path "$vm_name")" 2>/dev/null || true
    if [[ -S "$(aidc::vm_socket_path "$vm_name")" ]]; then
      export DOCKER_HOST="unix://$(aidc::vm_socket_path "$vm_name")"
      aidc::log "DOCKER_HOST set to Lima VM: $DOCKER_HOST"
    else
      aidc::warn "could not locate Docker socket for Lima VM $vm_name"
    fi
  fi
}

aidc::lima_stop() {
  local workspace="$1"
  local vm_name
  vm_name="$(aidc::vm_name "$workspace")"

  if ! limactl list --format '{{.Name}}' 2>/dev/null | grep -qxF "$vm_name"; then
    return
  fi

  aidc::log "stopping Lima VM $vm_name ..."
  limactl stop "$vm_name"
  unset DOCKER_HOST
  aidc::log "Lima VM $vm_name stopped"
}

aidc::lima_destroy() {
  local workspace="$1"
  local vm_name
  vm_name="$(aidc::vm_name "$workspace")"

  if ! limactl list --format '{{.Name}}' 2>/dev/null | grep -qxF "$vm_name"; then
    return
  fi

  aidc::log "destroying Lima VM $vm_name ..."
  limactl delete --force "$vm_name"

  local config_path
  config_path="$(aidc::lima_config_path "$vm_name")"
  rm -f "$config_path"

  unset DOCKER_HOST
  aidc::log "Lima VM $vm_name destroyed"
}

# ─── Firecracker backend (Linux) ──────────────────────────────────
#
# Firecracker runs a lightweight microVM per project.  This backend is
# included for future Linux support — the scaffold is here but requires
# kernel/rootfs images and is not yet enabled by default.

AIDC_FIRECRACKER_KERNEL="${AIDC_FIRECRACKER_KERNEL:-/var/lib/aidc/vmlinux}"
AIDC_FIRECRACKER_ROOTFS="${AIDC_FIRECRACKER_ROOTFS:-/var/lib/aidc/rootfs.ext4}"
AIDC_FIRECRACKER_SOCKET_DIR="${AIDC_HOST_CONFIG_ROOT}/firecracker-sockets"

aidc::firecracker_ensure() {
  local workspace="$1"
  aidc::need_cmd firecracker

  if [[ ! -f "$AIDC_FIRECRACKER_KERNEL" ]]; then
    aidc::die "Firecracker kernel not found at $AIDC_FIRECRACKER_KERNEL. " \
      "Set AIDC_FIRECRACKER_KERNEL in .ai-container/project.env or place a kernel there."
  fi
  if [[ ! -f "$AIDC_FIRECRACKER_ROOTFS" ]]; then
    aidc::die "Firecracker rootfs not found at $AIDC_FIRECRACKER_ROOTFS. " \
      "Set AIDC_FIRECRACKER_ROOTFS in .ai-container/project.env or place a rootfs there."
  fi

  local vm_name
  vm_name="$(aidc::vm_name "$workspace")"
  local socket_dir="$AIDC_FIRECRACKER_SOCKET_DIR"
  local fc_socket="$socket_dir/$vm_name.sock"
  mkdir -p "$socket_dir"

  # Already running?  Check the socket.
  if [[ -S "$fc_socket" ]] && curl -s --unix-socket "$fc_socket" http://localhost/ >/dev/null 2>&1; then
    aidc::log "Firecracker VM $vm_name is already running"
    return
  fi

  aidc::log "creating Firecracker VM $vm_name ..."
  aidc::log "  Kernel: $AIDC_FIRECRACKER_KERNEL  Rootfs: $AIDC_FIRECRACKER_ROOTFS"
  aidc::log "  ⚠ Each isolated VM uses significant CPU/RAM/disk. See README 'Isolation modes'."

  # Generate a unique VMID for the jailer (if using jailer) or direct launch.
  local vmid="$vm_name"

  # Create a per-VM copy-on-write rootfs overlay so the base image stays clean.
  local vm_rootfs="$socket_dir/$vm_name-rootfs.ext4"
  if [[ ! -f "$vm_rootfs" ]]; then
    cp --reflink=auto "$AIDC_FIRECRACKER_ROOTFS" "$vm_rootfs" 2>/dev/null || \
      cp "$AIDC_FIRECRACKER_ROOTFS" "$vm_rootfs"
  fi

  # Firecracker config via API socket.
  rm -f "$fc_socket"
  firecracker --api-sock "$fc_socket" &
  local fc_pid=$!

  # Give Firecracker a moment to create the socket.
  local tries=0
  while [[ ! -S "$fc_socket" ]] && [[ $tries -lt 20 ]]; do
    sleep 0.25
    tries=$((tries + 1))
  done
  [[ -S "$fc_socket" ]] || aidc::die "Firecracker failed to start (socket not created)"

  # Configure the microVM via the API.
  local kernel_boot_args="console=ttyS0 reboot=k panic=1 pci=off"
  curl -s --unix-socket "$fc_socket" -X PUT "http://localhost/boot-source" \
    -H "Content-Type: application/json" \
    -d "{\"kernel_image_path\":\"$AIDC_FIRECRACKER_KERNEL\",\"boot_args\":\"$kernel_boot_args\"}" || true

  curl -s --unix-socket "$fc_socket" -X PUT "http://localhost/drives/rootfs" \
    -H "Content-Type: application/json" \
    -d "{\"drive_id\":\"rootfs\",\"path_on_host\":\"$vm_rootfs\",\"is_root_device\":true,\"is_read_only\":false}" || true

  # Network: use a TAP device.  Create one if it doesn't exist.
  local tap_name="aidc-${vm_name:0:12}"
  if ! ip link show "$tap_name" >/dev/null 2>&1; then
    ip tuntap add dev "$tap_name" mode tap 2>/dev/null || true
    ip addr add 172.30.0.1/24 dev "$tap_name" 2>/dev/null || true
    ip link set "$tap_name" up 2>/dev/null || true
  fi
  curl -s --unix-socket "$fc_socket" -X PUT "http://localhost/network-interfaces/eth0" \
    -H "Content-Type: application/json" \
    -d "{\"iface_id\":\"eth0\",\"host_dev_name\":\"$tap_name\",\"guest_mac\":\"AA:FC:00:00:00:01\"}" 2>/dev/null || true

  curl -s --unix-socket "$fc_socket" -X PUT "http://localhost/machine-config" \
    -H "Content-Type: application/json" \
    -d "{\"vcpu_count\":${AIDC_LIMA_CPUS},\"mem_size_mib\":$(( ${AIDC_LIMA_MEMORY%[^0-9]*} * 1024 ))}" 2>/dev/null || \
    curl -s --unix-socket "$fc_socket" -X PUT "http://localhost/machine-config" \
      -H "Content-Type: application/json" \
      -d '{"vcpu_count":2,"mem_size_mbibytes":2048}' 2>/dev/null || true

  curl -s --unix-socket "$fc_socket" -X PUT "http://localhost/actions" \
    -H "Content-Type: application/json" \
    -d '{"action_type":"InstanceStart"}' || true

  aidc::log "Firecracker VM $vm_name started (pid $fc_pid)"
  aidc::warn "Firecracker backend is experimental — Docker inside the microVM is not yet automated"
  aidc::warn "You will need to SSH into the VM and run 'docker compose up' manually for now"
}

aidc::firecracker_stop() {
  local workspace="$1"
  local vm_name
  vm_name="$(aidc::vm_name "$workspace")"
  local fc_socket="$AIDC_FIRECRACKER_SOCKET_DIR/$vm_name.sock"

  if [[ -S "$fc_socket" ]]; then
    curl -s --unix-socket "$fc_socket" -X PUT "http://localhost/actions" \
      -H "Content-Type: application/json" \
      -d '{"action_type":"InstanceHalt"}' 2>/dev/null || true
    rm -f "$fc_socket"
    aidc::log "Firecracker VM $vm_name stopped"
  fi
}

aidc::firecracker_destroy() {
  local workspace="$1"
  local vm_name
  vm_name="$(aidc::vm_name "$workspace")"
  local socket_dir="$AIDC_FIRECRACKER_SOCKET_DIR"

  # Halt if running.
  local fc_socket="$socket_dir/$vm_name.sock"
  if [[ -S "$fc_socket" ]]; then
    curl -s --unix-socket "$fc_socket" -X PUT "http://localhost/actions" \
      -H "Content-Type: application/json" \
      -d '{"action_type":"InstanceHalt"}' 2>/dev/null || true
  fi

  rm -f "$fc_socket" "$socket_dir/$vm_name-rootfs.ext4"
  aidc::log "Firecracker VM $vm_name destroyed"
}

aidc::resolve_workspace_arg() {
  local maybe_path="${1:-}"
  if [[ -n "$maybe_path" ]]; then
    aidc::abs_path "$maybe_path"
  else
    aidc::default_workspace
  fi
}

aidc::default_workspace() {
  if git -C "$PWD" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$PWD" rev-parse --show-toplevel
  else
    pwd -P
  fi
}

aidc::abs_path() {
  local path="$1"
  if [[ -d "$path" ]]; then
    (
      cd "$path" || exit
      pwd -P
    )
    return
  fi

  local dir
  dir="$(dirname "$path")"
  local base
  base="$(basename "$path")"
  (
    cd "$dir" || exit
    printf '%s/%s\n' "$(pwd -P)" "$base"
  )
}

aidc::copy_template() {
  local source_rel="$1"
  local target="$2"
  local mode="$3"
  local source="$AIDC_ROOT/$source_rel"

  [[ -f "$source" ]] || aidc::die "missing template: $source"
  mkdir -p "$(dirname "$target")"
  cp "$source" "$target"
  chmod "$mode" "$target"
}

aidc::copy_template_once() {
  local source_rel="$1"
  local target="$2"
  local mode="$3"
  [[ -e "$target" ]] && return 0
  aidc::copy_template "$source_rel" "$target" "$mode"
}

aidc::_strip_block_to() {
  # Write the contents of $1 to $2, removing any aidc merge block and
  # trimming trailing blank lines.
  local src="$1"
  local dst="$2"
  awk -v start="$AIDC_MERGE_MARKER_START" -v end="$AIDC_MERGE_MARKER_END" '
    $0 == start { skip = 1; next }
    $0 == end   { skip = 0; next }
    skip { next }
    NF { while (blank-- > 0) print ""; blank = 0; print; next }
    { blank++ }
  ' "$src" >"$dst"
}

aidc::merge_template() {
  local source_rel="$1"
  local target="$2"
  local source="$AIDC_ROOT/$source_rel"

  [[ -f "$source" ]] || aidc::die "missing template: $source"
  mkdir -p "$(dirname "$target")"

  if [[ ! -f "$target" ]]; then
    cp "$source" "$target"
    chmod 0644 "$target"
    return
  fi

  local tmp
  tmp="$(mktemp)"
  aidc::_strip_block_to "$target" "$tmp"
  [[ -s "$tmp" ]] && printf '\n' >>"$tmp"
  cat "$source" >>"$tmp"
  mv "$tmp" "$target"
  chmod 0644 "$target"
}

aidc::strip_merge_block() {
  local target="$1"
  [[ -f "$target" ]] || return 0
  grep -Fq "$AIDC_MERGE_MARKER_START" "$target" || return 0

  local tmp
  tmp="$(mktemp)"
  aidc::_strip_block_to "$target" "$tmp"

  if ! grep -q '[^[:space:]]' "$tmp"; then
    rm -f "$target" "$tmp"
  else
    mv "$tmp" "$target"
  fi
}

aidc::write_project_env() {
  local target="$1"
  local workspace="$2"
  local repo_slug="$3"
  local core_root="$4"
  local core_branch="$5"
  local core_worktree="$6"

  cat >"$target" <<EOF
# aidc-managed
AIDC_VERSION=$AIDC_VERSION
AIDC_WORKSPACE=$(aidc::shell_escape "$workspace")
AIDC_REPO_SLUG=$repo_slug
AIDC_CORE_ROOT=$(aidc::shell_escape "$core_root")
AIDC_CORE_BRANCH=$core_branch
AIDC_CORE_WORKTREE=$(aidc::shell_escape "$core_worktree")
EOF
}

aidc::shell_escape() {
  printf '%q' "$1"
}

aidc::check_init_conflicts() {
  local workspace="$1"
  local project_env="$workspace/.ai-container/project.env"
  if [[ -f "$project_env" ]]; then
    return
  fi

  local path
  for path in "${AIDC_MANAGED_PATHS[@]}"; do
    if [[ -e "$workspace/$path" ]]; then
      aidc::die "refusing to overwrite existing file: $workspace/$path"
    fi
  done
}

aidc::ensure_local_git_excludes() {
  local workspace="$1"
  if ! git -C "$workspace" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    aidc::log "skipping git exclude update because $workspace is not a git repo"
    return
  fi

  local exclude_file
  exclude_file="$(git -C "$workspace" rev-parse --git-path info/exclude)"
  if [[ "$exclude_file" != /* ]]; then
    exclude_file="$workspace/$exclude_file"
  fi
  mkdir -p "$(dirname "$exclude_file")"
  touch "$exclude_file"

  local pattern
  for pattern in ".devcontainer/" ".ai-container/" ".cursor/rules/00-core-logics.mdc" "CLAUDE.md" "AGENTS.md"; do
    if ! grep -Fxq "$pattern" "$exclude_file"; then
      printf '%s\n' "$pattern" >>"$exclude_file"
    fi
  done
}

aidc::ensure_workspace_ready() {
  local workspace="$1"
  if [[ ! -f "$workspace/.ai-container/project.env" ]]; then
    aidc::cmd_init "$workspace"
    return
  fi

  aidc::ensure_host_config_dirs
  aidc::ensure_claude_profile_examples
  aidc::load_project_env "$workspace"
  aidc::ensure_core_repo
  aidc::ensure_core_worktree "$AIDC_REPO_SLUG" "$AIDC_CORE_BRANCH" >/dev/null
  # Always re-copy scaffold from current aidc templates so template edits
  # (e.g. Dockerfile changes) flow into existing workspaces on next 'up'.
  aidc::refresh_scaffold "$workspace" "$AIDC_REPO_SLUG" "$AIDC_CORE_ROOT" "$AIDC_CORE_BRANCH" "$AIDC_CORE_WORKTREE"
}

aidc::ensure_container_running() {
  local workspace="$1"
  aidc::ensure_workspace_ready "$workspace"

  if [[ "${AIDC_ISOLATE_VM:-0}" == "1" ]]; then
    aidc::vm_ensure "$workspace"
  fi

  if [[ -z "$(aidc::compose_capture "$workspace" ps -q workspace)" ]]; then
    aidc::compose "$workspace" up -d --build workspace
  fi
}

aidc::load_project_env() {
  local workspace="$1"
  local env_file="$workspace/.ai-container/project.env"
  [[ -f "$env_file" ]] || aidc::die "missing project env: $env_file"
  # shellcheck disable=SC1090
  . "$env_file"
}

aidc::repo_slug() {
  local workspace="$1"
  local name
  name="$(basename "$workspace")"
  local normalized
  normalized="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')"
  normalized="${normalized#-}"
  normalized="${normalized%-}"
  local hash
  hash="$(printf '%s' "$workspace" | shasum -a 256 | awk '{print substr($1,1,8)}')"
  printf '%s-%s\n' "$normalized" "$hash"
}

aidc::core_root() {
  printf '%s\n' "$AIDC_CORE_ROOT_DEFAULT"
}

aidc::ensure_core_repo() {
  local core_root
  core_root="$(aidc::core_root)"
  mkdir -p "$core_root"

  if ! git -C "$core_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [[ -n "$(find "$core_root" -mindepth 1 -maxdepth 1 ! -name .git -print -quit 2>/dev/null)" ]]; then
      aidc::die "$core_root exists and is not an empty git repository"
    fi
    git -C "$core_root" init -b main >/dev/null
  fi

  local wrote=0
  if [[ ! -f "$core_root/README.md" ]]; then
    cat >"$core_root/README.md" <<'EOF'
# CORE_LOGICS

Shared reusable guidance discovered across isolated coding sessions.
EOF
    wrote=1
  fi

  if [[ ! -f "$core_root/patternlist.md" ]]; then
    cat >"$core_root/patternlist.md" <<'EOF'
# Pattern List

- Add durable, reusable guidance here when it is broadly applicable beyond one repo.
EOF
    wrote=1
  fi

  if ! git -C "$core_root" rev-parse HEAD >/dev/null 2>&1; then
    wrote=1
  fi

  if [[ "$wrote" -eq 1 ]]; then
    git -C "$core_root" add README.md patternlist.md
    GIT_AUTHOR_NAME="aidc" \
      GIT_AUTHOR_EMAIL="aidc@local" \
      GIT_COMMITTER_NAME="aidc" \
      GIT_COMMITTER_EMAIL="aidc@local" \
      git -C "$core_root" commit -m "Initialize CORE_LOGICS" >/dev/null
  fi
}

aidc::ensure_core_worktree() {
  local repo_slug="$1"
  local branch="$2"
  local core_root
  core_root="$(aidc::core_root)"
  local worktree="$AIDC_CORE_WORKTREE_ROOT/$repo_slug"

  if [[ -e "$worktree/.git" || -d "$worktree/.git" ]]; then
    printf '%s\n' "$worktree"
    return
  fi

  if [[ -e "$worktree" && ! -e "$worktree/.git" && ! -d "$worktree/.git" ]]; then
    aidc::die "worktree path exists but is not a git worktree: $worktree"
  fi

  mkdir -p "$AIDC_CORE_WORKTREE_ROOT"
  if ! git -C "$core_root" rev-parse --verify "$branch" >/dev/null 2>&1; then
    git -C "$core_root" branch "$branch" HEAD >/dev/null
  fi

  git -C "$core_root" worktree add "$worktree" "$branch" >/dev/null
  printf '%s\n' "$worktree"
}

aidc::ensure_host_config_dirs() {
  mkdir -p "$AIDC_HOST_CONFIG_ROOT" "$AIDC_EMPTY_ROOT" "$AIDC_CLAUDE_PROFILE_ROOT"
  mkdir -p "$AIDC_EMPTY_ROOT/claude" "$AIDC_EMPTY_ROOT/codex" "$AIDC_EMPTY_ROOT/opencode" "$AIDC_EMPTY_ROOT/clipboard"
  touch "$AIDC_EMPTY_ROOT/gitconfig"
}

aidc::ensure_claude_profile_examples() {
  local zai="$AIDC_CLAUDE_PROFILE_ROOT/zai.env.example"
  local openrouterfree="$AIDC_CLAUDE_PROFILE_ROOT/openrouterfree.env.example"
  local localhost_example="$AIDC_CLAUDE_PROFILE_ROOT/localhost.env.example"
  local localnetwork="$AIDC_CLAUDE_PROFILE_ROOT/localnetwork.env.example"

  if [[ ! -f "$zai" ]]; then
    cat >"$zai" <<'EOF'
# aidc Claude profile example
# Copy to zai.env and replace the placeholder values on the host.
AIDC_CLAUDE_DESCRIPTION="Z.ai Anthropic-compatible profile"
ZAI_API_KEY="replace-me"
ANTHROPIC_AUTH_TOKEN="$ZAI_API_KEY"
ANTHROPIC_BASE_URL="https://api.z.ai/api/anthropic"
ANTHROPIC_MODEL="GLM-5.1"
EOF
  fi

  if [[ ! -f "$openrouterfree" ]]; then
    cat >"$openrouterfree" <<'EOF'
# aidc Claude profile example
# Copy to openrouterfree.env and fill in the provider-specific values on the host.
AIDC_CLAUDE_DESCRIPTION="OpenRouter free-tier profile"
OPENROUTER_API_KEY="replace-me"
ANTHROPIC_AUTH_TOKEN="$OPENROUTER_API_KEY"
# Set this to your Anthropic-compatible OpenRouter endpoint.
ANTHROPIC_BASE_URL="replace-me"
ANTHROPIC_MODEL="replace-me"
EOF
  fi

  if [[ ! -f "$localhost_example" ]]; then
    cat >"$localhost_example" <<'EOF'
# aidc Claude profile example
# Copy to localhost.env. Targets an Anthropic-compatible server running on
# this Mac (LM Studio, LiteLLM in Anthropic mode, etc.).
# host.docker.internal resolves to the host on Docker Desktop / OrbStack.
AIDC_CLAUDE_DESCRIPTION="Localhost Anthropic-compatible profile"
LOCAL_LLM_API_KEY="replace-me"
ANTHROPIC_AUTH_TOKEN="$LOCAL_LLM_API_KEY"
ANTHROPIC_BASE_URL="http://host.docker.internal:PORT"
ANTHROPIC_MODEL="replace-me"
EOF
  fi

  if [[ ! -f "$localnetwork" ]]; then
    cat >"$localnetwork" <<'EOF'
# aidc Claude profile example
# Copy to localnetwork.env (or localnetwork-<engine>.env for multiple peers;
# any *.env in this dir is discovered as a profile).
# Use the Tailscale MagicDNS name or 100.x.y.z address of the peer.
AIDC_CLAUDE_DESCRIPTION="Local-network Anthropic-compatible profile"
LOCAL_LLM_API_KEY="replace-me"
ANTHROPIC_AUTH_TOKEN="$LOCAL_LLM_API_KEY"
ANTHROPIC_BASE_URL="http://hostname.your-tailnet.ts.net:PORT"
ANTHROPIC_MODEL="replace-me"
EOF
  fi
}

aidc::compose() {
  local workspace="$1"
  shift
  aidc::export_compose_env "$workspace"
  docker compose -f "$workspace/.devcontainer/compose.yaml" "$@"
}

aidc::compose_capture() {
  local workspace="$1"
  shift
  aidc::export_compose_env "$workspace"
  docker compose -f "$workspace/.devcontainer/compose.yaml" "$@"
}

aidc::export_compose_env() {
  local workspace="$1"
  # Capture any CLI/ambient overrides before project.env is sourced, so
  # an explicit flag (e.g. 'aidc up --clipboard --isolate-vm') wins over
  # whatever project.env defaults to.
  local clipboard_override="${AIDC_ENABLE_CLIPBOARD:-}"
  local isolate_vm_override="${AIDC_ISOLATE_VM:-}"
  aidc::load_project_env "$workspace"
  [[ -n "$clipboard_override" ]] && AIDC_ENABLE_CLIPBOARD="$clipboard_override"
  [[ -n "$isolate_vm_override" ]] && AIDC_ISOLATE_VM="$isolate_vm_override"

  export COMPOSE_PROJECT_NAME="aidc_${AIDC_REPO_SLUG}"
  export AIDC_WORKSPACE="$workspace"
  export AIDC_DEVCONTAINER_DIR="$workspace/.devcontainer"
  export AIDC_CORE_LOGICS_WORKTREE="$AIDC_CORE_WORKTREE"
  export AIDC_HOST_SEED_CLAUDE
  AIDC_HOST_SEED_CLAUDE="$(aidc::mount_dir_or_empty "$HOME/.claude" "claude")"
  export AIDC_HOST_SEED_CODEX
  AIDC_HOST_SEED_CODEX="$(aidc::mount_dir_or_empty "$HOME/.codex" "codex")"
  export AIDC_HOST_SEED_OPENCODE
  AIDC_HOST_SEED_OPENCODE="$(aidc::mount_dir_or_empty "$HOME/.config/opencode" "opencode")"
  export AIDC_GITCONFIG_SOURCE
  AIDC_GITCONFIG_SOURCE="$(aidc::mount_file_or_empty "$HOME/.gitconfig" "gitconfig")"
  # Host-clipboard bridge is opt-in (off by default). When disabled, mount an
  # empty dir so no host clipboard socket is ever exposed to the container.
  # Enable per (re)create with 'aidc up --clipboard' / 'aidc rebuild --clipboard'
  # or persist AIDC_ENABLE_CLIPBOARD=1 in .ai-container/project.env.
  export AIDC_CLIPBOARD_DIR_SOURCE
  if [[ "${AIDC_ENABLE_CLIPBOARD:-0}" == "1" ]]; then
    AIDC_CLIPBOARD_DIR_SOURCE="$(aidc::mount_dir_or_empty "$HOME/.config/aidc/clipboard" "clipboard")"
  else
    AIDC_CLIPBOARD_DIR_SOURCE="$(aidc::mount_dir_or_empty "" "clipboard")"
  fi
  export AIDC_TOOLCHAINS
  AIDC_TOOLCHAINS="$(aidc::compute_toolchains "$workspace")"
  # Opt-in security tools (semgrep/gitleaks/trufflehog are always-on in the
  # base image; this layer adds grype/syft/checkov/bandit when requested).
  export AIDC_SECURITY_TOOLS
  AIDC_SECURITY_TOOLS="${AIDC_SECURITY_TOOLS:-}"

  # VM isolation: when active, point DOCKER_HOST at the per-project VM's
  # Docker daemon so all compose commands run inside the VM transparently.
  if [[ "${AIDC_ISOLATE_VM:-0}" == "1" ]]; then
    local backend
    backend="$(aidc::vm_backend)"
    local vm_name
    vm_name="$(aidc::vm_name "$workspace")"
    case "$backend" in
      lima)
        local lima_socket="$HOME/.lima/${vm_name}/sock/docker.sock"
        if [[ -S "$lima_socket" ]]; then
          export DOCKER_HOST="unix://$lima_socket"
        fi
        ;;
      firecracker)
        # Firecracker backend: DOCKER_HOST would point at the microVM's
        # Docker socket forwarded via the TAP network. Not yet automated.
        ;;
    esac
  fi
}

aidc::detect_toolchains() {
  local workspace="$1"
  local -a detected=()
  [[ -f "$workspace/go.mod" ]] && detected+=("go")
  if [[ -f "$workspace/Cargo.toml" || -f "$workspace/rust-toolchain.toml" || -f "$workspace/rust-toolchain" ]]; then
    detected+=("rust")
  fi
  [[ -f "$workspace/Gemfile" ]] && detected+=("ruby")
  if [[ -f "$workspace/pom.xml" || -f "$workspace/build.gradle" || -f "$workspace/build.gradle.kts" ]]; then
    detected+=("java")
  fi
  [[ -f "$workspace/composer.json" ]] && detected+=("php")
  if [[ -f "$workspace/package.json" || -f "$workspace/package-lock.json" || -f "$workspace/pnpm-lock.yaml" || -f "$workspace/yarn.lock" || -f "$workspace/bun.lockb" ]]; then
    detected+=("node")
  fi
  if [[ -f "$workspace/requirements.txt" || -f "$workspace/uv.lock" || -f "$workspace/pyproject.toml" || -f "$workspace/Pipfile" || -f "$workspace/Pipfile.lock" || -f "$workspace/poetry.lock" ]]; then
    detected+=("python")
  fi
  # Join with commas without touching the global IFS.
  local out="" item
  for item in "${detected[@]}"; do
    out+="${out:+,}$item"
  done
  printf '%s' "$out"
}

aidc::compute_toolchains() {
  local workspace="$1"
  # Explicit override in project.env wins (even when set to empty).
  if [[ -n "${AIDC_TOOLCHAINS+x}" ]]; then
    printf '%s' "$AIDC_TOOLCHAINS"
    return
  fi
  aidc::detect_toolchains "$workspace"
}

aidc::mount_dir_or_empty() {
  local source_dir="$1"
  local fallback_name="$2"
  if [[ -d "$source_dir" ]]; then
    aidc::abs_path "$source_dir"
  else
    local fallback="$AIDC_EMPTY_ROOT/$fallback_name"
    mkdir -p "$fallback"
    aidc::abs_path "$fallback"
  fi
}

aidc::mount_file_or_empty() {
  local source_file="$1"
  local fallback_name="$2"
  if [[ -f "$source_file" ]]; then
    aidc::abs_path "$source_file"
  else
    local fallback="$AIDC_EMPTY_ROOT/$fallback_name"
    mkdir -p "$(dirname "$fallback")"
    touch "$fallback"
    aidc::abs_path "$fallback"
  fi
}

aidc::append_passthrough_env_args() {
  local key
  for key in "${AIDC_PASSTHROUGH_ENV_KEYS[@]}"; do
    if [[ -n "${!key:-}" ]]; then
      AIDC_EXEC_ENV_ARGS+=("-e" "$key")
    fi
  done
}

aidc::validate_claude_profile_name() {
  local profile="$1"
  [[ "$profile" =~ ^[a-z0-9][a-z0-9-]*$ ]] || aidc::die "invalid Claude profile name: $profile"
}

aidc::validate_claude_alias_name() {
  local alias_name="$1"
  [[ "$alias_name" =~ ^claude-[a-z0-9][a-z0-9-]*$ ]] || aidc::die "invalid Claude alias name: $alias_name"
}

aidc::claude_profile_env_file() {
  local profile="$1"
  aidc::validate_claude_profile_name "$profile"
  printf '%s/%s.env\n' "$AIDC_CLAUDE_PROFILE_ROOT" "$profile"
}

aidc::claude_profile_metadata() {
  local profile="$1"
  local env_file
  env_file="$(aidc::claude_profile_env_file "$profile")"
  [[ -f "$env_file" ]] || aidc::die "missing Claude profile: $env_file"
  aidc::warn_if_loose_permissions "$env_file"

  local metadata
  metadata="$(
    unset AIDC_CLAUDE_ALIAS AIDC_CLAUDE_DESCRIPTION
    set -a
    # shellcheck disable=SC1090
    . "$env_file"
    set +a
    printf '%s\t%s\n' "${AIDC_CLAUDE_ALIAS:-claude-$profile}" "${AIDC_CLAUDE_DESCRIPTION:-}"
  )"

  local alias_name="${metadata%%$'\t'*}"
  aidc::validate_claude_alias_name "$alias_name"
  printf '%s\n' "$metadata"
}

aidc::find_claude_profiles() {
  [[ -d "$AIDC_CLAUDE_PROFILE_ROOT" ]] || return 0

  local env_file profile
  while IFS= read -r env_file; do
    [[ -n "$env_file" ]] || continue
    profile="$(basename "$env_file" .env)"
    if [[ ! "$profile" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
      aidc::warn "ignoring invalid Claude profile filename: $(basename "$env_file")"
      continue
    fi
    printf '%s\n' "$profile"
  done < <(find "$AIDC_CLAUDE_PROFILE_ROOT" -maxdepth 1 -type f -name '*.env' -print | sort)
}

aidc::list_claude_profiles() {
  aidc::ensure_host_config_dirs
  aidc::ensure_claude_profile_examples

  local found=0
  local profile metadata alias_name description
  while IFS= read -r profile; do
    [[ -n "$profile" ]] || continue
    found=1
    metadata="$(aidc::claude_profile_metadata "$profile")"
    alias_name="${metadata%%$'\t'*}"
    description="${metadata#*$'\t'}"
    if [[ "$description" == "$metadata" ]]; then
      description=""
    fi

    if [[ -n "$description" ]]; then
      printf '%-20s %-24s %s\n' "$profile" "$alias_name" "$description"
    else
      printf '%-20s %-24s\n' "$profile" "$alias_name"
    fi
  done < <(aidc::find_claude_profiles)

  if [[ "$found" -eq 0 ]]; then
    aidc::log "no Claude profiles found in $AIDC_CLAUDE_PROFILE_ROOT"
  fi
}

aidc::claude_alias_is_managed() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  grep -Fq "$AIDC_MANAGED_CLAUDE_ALIAS_MARKER" "$path"
}

aidc::array_contains() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

aidc::write_claude_alias_wrapper() {
  local target="$1"
  local profile="$2"

  cat >"$target" <<EOF
#!/usr/bin/env bash
$AIDC_MANAGED_CLAUDE_ALIAS_MARKER
exec aidc claude --profile $profile "\$@"
EOF
  chmod 0755 "$target"
}

aidc::remove_stale_claude_aliases() {
  local desired_aliases=("$@")
  [[ -d "$AIDC_BIN_DIR" ]] || return 0

  local path alias_name
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if ! aidc::claude_alias_is_managed "$path"; then
      continue
    fi

    alias_name="$(basename "$path")"
    if ! aidc::array_contains "$alias_name" "${desired_aliases[@]}"; then
      rm -f "$path"
      aidc::log "removed stale Claude alias $alias_name"
    fi
  done < <(find "$AIDC_BIN_DIR" -maxdepth 1 \( -type f -o -type l \) -name 'claude-*' -print 2>/dev/null | sort)
}

aidc::sync_claude_aliases() {
  mkdir -p "$AIDC_BIN_DIR"

  local desired_aliases=()
  local profile metadata alias_name target
  while IFS= read -r profile; do
    [[ -n "$profile" ]] || continue
    metadata="$(aidc::claude_profile_metadata "$profile")"
    alias_name="${metadata%%$'\t'*}"
    desired_aliases+=("$alias_name")
    target="$AIDC_BIN_DIR/$alias_name"

    if [[ -e "$target" ]] && ! aidc::claude_alias_is_managed "$target"; then
      aidc::warn "skipping Claude alias $alias_name because $target already exists and is not aidc-managed"
      continue
    fi

    aidc::write_claude_alias_wrapper "$target" "$profile"
    aidc::log "synced Claude alias $alias_name"
  done < <(aidc::find_claude_profiles)

  aidc::remove_stale_claude_aliases "${desired_aliases[@]}"
}

aidc::load_claude_profile_env() {
  local profile="$1"
  local env_file
  env_file="$(aidc::claude_profile_env_file "$profile")"
  [[ -f "$env_file" ]] || aidc::die "missing Claude profile: $env_file"
  aidc::warn_if_loose_permissions "$env_file"

  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  set +a

  local metadata alias_name
  metadata="$(aidc::claude_profile_metadata "$profile")"
  alias_name="${metadata%%$'\t'*}"
  aidc::validate_claude_alias_name "$alias_name"

  local key
  while IFS= read -r key; do
    if [[ "$key" == "AIDC_CLAUDE_ALIAS" || "$key" == "AIDC_CLAUDE_DESCRIPTION" ]]; then
      continue
    fi
    if aidc::var_is_set "$key"; then
      AIDC_EXEC_ENV_ARGS+=("-e" "$key")
    fi
  done < <(aidc::env_file_keys "$env_file")
}

aidc::var_is_set() {
  local key="$1"
  local is_set=""
  eval "is_set=\${${key}+x}"
  [[ "$is_set" == "x" ]]
}

aidc::env_file_keys() {
  local env_file="$1"
  local line key
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] || continue
    if [[ "$line" == export\ * ]]; then
      line="${line#export }"
    fi
    key="${line%%=*}"
    if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      printf '%s\n' "$key"
    fi
  done <"$env_file"
}

aidc::file_permissions() {
  local path="$1"
  local perms=""
  perms="$(stat -f "%OLp" "$path" 2>/dev/null || true)"
  if [[ -z "$perms" ]]; then
    perms="$(stat -c "%a" "$path" 2>/dev/null || true)"
  fi
  printf '%s\n' "$perms"
}

aidc::warn_if_loose_permissions() {
  local path="$1"
  local perms
  perms="$(aidc::file_permissions "$path")"
  if [[ -z "$perms" ]]; then
    return 0
  fi
  case "$perms" in
    400|600)
      ;;
    *)
      aidc::warn "profile file has loose permissions ($perms): $path"
      ;;
  esac
}

aidc::log() {
  printf '[aidc] %s\n' "$*"
}

aidc::warn() {
  printf '[aidc] warn: %s\n' "$*" >&2
}

aidc::die() {
  printf '[aidc] error: %s\n' "$*" >&2
  exit 1
}
