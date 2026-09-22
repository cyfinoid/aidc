#!/usr/bin/env bash
# aidc module: Read-only reporting: status, doctor, version, update.
# Sourced by lib/aidc.sh — never directly. Functions moved verbatim from
# the former monolith; behavior changes ride their own commits.

aidc::cmd_version() {
  local root="${AIDC_ROOT:-}" sha=""
  if [[ -n "$root" ]] && command -v git >/dev/null 2>&1 \
     && git -C "$root" rev-parse --short HEAD >/dev/null 2>&1; then
    sha=" ($(git -C "$root" rev-parse --short HEAD))"
  fi
  printf 'aidc %s%s\n' "$AIDC_VERSION" "$sha"
}

# ─── doctor ───
# One line per check: OK / WARN / FAIL + a fix-it hint. Read-only. Exits
# non-zero only when something is actually broken (FAIL), never for
# informational or by-design states.

aidc::doctor_report() {
  local status="$1" label="$2" message="$3"
  case "$status" in
    ok)   printf '  OK    %-12s %s\n' "$label" "$message" ;;
    warn) printf '  WARN  %-12s %s\n' "$label" "$message"; AIDC_DOCTOR_WARNS=$((AIDC_DOCTOR_WARNS + 1)) ;;
    fail) printf '  FAIL  %-12s %s\n' "$label" "$message"; AIDC_DOCTOR_FAILS=$((AIDC_DOCTOR_FAILS + 1)) ;;
  esac
}

aidc::doctor_check_git() {
  if command -v git >/dev/null 2>&1; then
    aidc::doctor_report ok git "$(git --version 2>/dev/null | head -1)"
  else
    aidc::doctor_report fail git "not found — install git"
  fi
}

aidc::doctor_check_docker() {
  if [[ "${AIDC_DOCKER_PROVIDER:-docker}" == "apple" ]]; then
    aidc::doctor_check_apple_container
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    aidc::doctor_report fail docker "CLI not found — install Docker Desktop / OrbStack / Colima (or set AIDC_DOCKER_PROVIDER=apple; see docs/apple-container.md)"
    return 0
  fi
  if docker info >/dev/null 2>&1; then
    aidc::doctor_report ok docker "CLI + daemon responding"
  else
    aidc::doctor_report fail docker "daemon not responding — start Docker Desktop / OrbStack / Colima"
    # Auto-provider (AIDC_DOCKER_PROVIDER unset): if an alternative engine is
    # ready, aidc will offer it on the next container command — surface that here.
    local alts
    alts="$(aidc::detect_alt_providers)"
    if [[ -n "$alts" ]]; then
      aidc::doctor_report warn provider "alternative engine available: $alts — aidc will offer it on the next container command, or set AIDC_DOCKER_PROVIDER (see docs/apple-container.md)"
    fi
  fi
}

# EXPERIMENTAL: Apple `container` reached via socktainer's Docker-API socket
# (macOS 26 + Apple Silicon; socktainer must match the `container` version).
# See docs/apple-container.md.
aidc::doctor_check_apple_container() {
  local socket="${AIDC_APPLE_CONTAINER_SOCKET:-$HOME/.socktainer/container.sock}"
  aidc::doctor_report warn provider "AIDC_DOCKER_PROVIDER=apple — experimental/unverified (docs/apple-container.md)"
  if command -v container >/dev/null 2>&1; then
    aidc::doctor_report ok apple-container "'container' CLI present"
  else
    aidc::doctor_report fail apple-container "'container' CLI not found — install github.com/apple/container (macOS 26 + Apple Silicon)"
  fi
  if [[ -S "$socket" ]]; then
    aidc::doctor_report ok socktainer "socket present: $socket"
  else
    aidc::doctor_report fail socktainer "no socket at $socket — start socktainer (version-matched to 'container')"
  fi
  if ! command -v docker >/dev/null 2>&1; then
    aidc::doctor_report fail docker "CLI not found — socktainer still needs the docker CLI + compose plugin"
  elif DOCKER_HOST="unix://$socket" docker info >/dev/null 2>&1; then
    aidc::doctor_report ok docker "Docker API responds via socktainer"
  else
    aidc::doctor_report warn docker "Docker API not responding via $socket — start/version-match socktainer"
  fi
}

aidc::doctor_check_path() {
  local bin_dir="${AIDC_BIN_DIR:-$HOME/.local/bin}"
  case ":$PATH:" in
    *":$bin_dir:"*) aidc::doctor_report ok path "$bin_dir on PATH" ;;
    *) aidc::doctor_report warn path "$bin_dir not on PATH — add it in your shell rc" ;;
  esac
}

aidc::doctor_check_install() {
  if ! git -C "$AIDC_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    aidc::doctor_report ok install "not a git checkout — 'aidc update' unavailable"
    return 0
  fi
  local behind
  behind="$(git -C "$AIDC_ROOT" rev-list --count HEAD..origin/main 2>/dev/null || printf '')"
  if [[ -z "$behind" ]]; then
    aidc::doctor_report ok install "git checkout at $(git -C "$AIDC_ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')"
  elif [[ "$behind" -gt 0 ]]; then
    aidc::doctor_report warn install "$behind commit(s) behind origin/main (as of last fetch) — run 'aidc update'"
  else
    aidc::doctor_report ok install "up to date with origin/main (as of last fetch)"
  fi
}

aidc::doctor_check_keychain() {
  if ! command -v security >/dev/null 2>&1; then
    aidc::doctor_report ok keychain "no macOS Keychain on this host — Claude auth via CLAUDE_CODE_OAUTH_TOKEN or interactive login"
    return 0
  fi
  local svc="${AIDC_CLAUDE_OAUTH_KEYCHAIN_SERVICE:-claude-code-oauth-token}"
  local account="${USER:-$(id -un 2>/dev/null || true)}"
  local have_tok=0
  aidc::secret_begin
  [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] && have_tok=1
  aidc::secret_end
  if [[ -z "$svc" ]]; then
    aidc::doctor_report ok keychain "lookup disabled (AIDC_CLAUDE_OAUTH_KEYCHAIN_SERVICE empty)"
  elif [[ "$have_tok" -eq 1 ]]; then
    aidc::doctor_report ok keychain "CLAUDE_CODE_OAUTH_TOKEN already set in this shell"
  elif security find-generic-password -a "$account" -s "$svc" >/dev/null 2>&1; then
    aidc::doctor_report ok keychain "Claude OAuth token present (service $svc)"
  else
    aidc::doctor_report warn keychain "no token in Keychain (service $svc) — see README 'Claude authentication'"
  fi
}

aidc::doctor_check_project_env() {
  local workspace="$1"
  if (set -u; . "$workspace/.ai-container/project.env") >/dev/null 2>&1; then
    aidc::doctor_report ok project.env "parses cleanly"
    return 0
  fi
  aidc::doctor_report fail project.env "does not parse — restore it from git or re-run 'aidc init' after 'aidc destroy -f --purge-scaffold'"
  return 1
}

aidc::doctor_check_scaffold_version() {
  local workspace="$1"
  local stamp
  stamp="$(sed -n 's/^AIDC_VERSION=\(.*\)$/\1/p' "$workspace/.ai-container/project.env" | head -1)"
  if [[ -z "$stamp" ]]; then
    aidc::doctor_report warn scaffold "no version stamp in project.env"
  elif [[ "$stamp" == "$AIDC_VERSION" ]]; then
    aidc::doctor_report ok scaffold "scaffolded by current aidc ($stamp)"
  else
    aidc::doctor_report warn scaffold "scaffolded by aidc $stamp, current is $AIDC_VERSION — run 'aidc upgrade'"
  fi
}

aidc::doctor_check_container() {
  local workspace="$1"
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    aidc::doctor_report warn container "docker unavailable — container state unknown"
    return 0
  fi
  local running all
  running="$(aidc::compose_capture "$workspace" ps -q workspace 2>/dev/null || true)"
  all="$(aidc::compose_capture "$workspace" ps -aq workspace 2>/dev/null || true)"
  if [[ -n "$running" ]]; then
    aidc::doctor_report ok container "running"
  elif [[ -n "$all" ]]; then
    aidc::doctor_report ok container "stopped — starts on the next aidc command"
  else
    aidc::doctor_report ok container "not created yet — 'aidc up' builds it"
  fi
}

aidc::doctor_check_firewall() {
  if [[ "${AIDC_ENABLE_EGRESS_FIREWALL:-0}" == "1" ]]; then
    aidc::doctor_report ok firewall "on (default-deny egress allowlist)"
  else
    aidc::doctor_report ok firewall "off (open network, default)"
  fi
}

aidc::doctor_check_isolate_vm() {
  if [[ "${AIDC_ISOLATE_VM:-0}" != "1" ]]; then
    aidc::doctor_report ok isolation "normal mode (shared Docker)"
    return 0
  fi
  if [[ "$(uname -s)" == "Darwin" ]]; then
    if command -v limactl >/dev/null 2>&1; then
      aidc::doctor_report ok isolation "isolate-vm on; limactl present"
    else
      aidc::doctor_report fail isolation "AIDC_ISOLATE_VM=1 but limactl not found — brew install lima"
    fi
  else
    if command -v firecracker >/dev/null 2>&1; then
      aidc::doctor_report ok isolation "isolate-vm on; firecracker present"
    else
      aidc::doctor_report fail isolation "AIDC_ISOLATE_VM=1 but firecracker not found"
    fi
  fi
}

aidc::cmd_doctor() {
  AIDC_DOCTOR_FAILS=0
  AIDC_DOCTOR_WARNS=0

  # Resolve the host-wide Docker provider before the docker check so
  # AIDC_DOCKER_PROVIDER=apple (typically set in the global config) routes the
  # probe at socktainer. project.env (per-folder override) is sourced later.
  aidc::load_global_config
  aidc::apply_docker_provider
  # doctor is report-only: mark the provider resolved so the later
  # doctor_check_container (which reaches export_compose_env) never prompts.
  export AIDC_PROVIDER_RESOLVED=1

  printf '%s\n\n' "$(aidc::cmd_version)"
  printf 'host\n'
  aidc::doctor_check_git
  aidc::doctor_check_docker
  aidc::doctor_check_path
  aidc::doctor_check_install
  aidc::doctor_check_keychain

  local workspace
  workspace="$(aidc::default_workspace)"
  printf '\nproject  %s\n' "$workspace"
  if [[ ! -f "$workspace/.ai-container/project.env" ]]; then
    aidc::doctor_report ok scaffold "not an aidc project — 'aidc init' scaffolds it"
  elif aidc::doctor_check_project_env "$workspace"; then
    aidc::doctor_check_scaffold_version "$workspace"
    aidc::load_project_env "$workspace"
    aidc::doctor_check_container "$workspace"
    aidc::doctor_check_firewall
    aidc::doctor_check_isolate_vm
  fi

  printf '\n'
  if [[ "$AIDC_DOCTOR_FAILS" -gt 0 ]]; then
    printf '%d problem(s), %d warning(s)\n' "$AIDC_DOCTOR_FAILS" "$AIDC_DOCTOR_WARNS"
    return 1
  fi
  printf 'all good (%d warning(s))\n' "$AIDC_DOCTOR_WARNS"
}

# ─── insights ───
# Deterministic, offline summary of synced agent sessions and scan-hook
# outcomes. No LLM calls; v1 covers Claude transcripts (the other agents'
# on-disk formats vary too much to parse blindly).

aidc::cmd_insights() {
  local since=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since)
        since="${2:-}"
        [[ -n "$since" ]] || aidc::die "--since needs a date (e.g. 2026-07-01)"
        shift
        ;;
      *)
        aidc::die "unknown insights flag: $1 (valid: --since DATE)"
        ;;
    esac
    shift
  done

  printf 'aidc insights%s\n' "${since:+ (since $since)}"

  # Synced Claude session transcripts on the host.
  local projects_root="${AIDC_INSIGHTS_CLAUDE_ROOT:-$HOME/.claude/projects}"
  local tmp
  tmp="$(mktemp)"
  if [[ -d "$projects_root" ]]; then
    if [[ -n "$since" ]]; then
      find "$projects_root" -type f -name '*.jsonl' -newermt "$since" 2>/dev/null >"$tmp" \
        || find "$projects_root" -type f -name '*.jsonl' 2>/dev/null >"$tmp"
    else
      find "$projects_root" -type f -name '*.jsonl' 2>/dev/null >"$tmp"
    fi
  fi
  local total
  total="$(wc -l <"$tmp" | tr -d ' ')"
  printf '\nclaude sessions: %s\n' "$total"
  if [[ "$total" -gt 0 ]]; then
    printf 'top projects:\n'
    sed "s|^$projects_root/||; s|/[^/]*$||" "$tmp" | sort | uniq -c | sort -rn | head -5 \
      | while read -r count proj; do printf '  %5d  %s\n' "$count" "$proj"; done
  else
    printf '  none synced yet — sessions sync automatically on container start/exit\n'
  fi
  rm -f "$tmp"

  # Scan-hook outcomes for the current project (bind-mounted log, written by
  # the in-container Stop hook).
  local workspace log
  workspace="$(aidc::default_workspace)"
  log="$workspace/.ai-container/scan-hook.log"
  printf '\nscan-hook outcomes (this project):\n'
  if [[ -f "$log" ]]; then
    local filtered
    filtered="$(mktemp)"
    if [[ -n "$since" ]]; then
      awk -v s="$since" '$1 >= s' "$log" >"$filtered"
    else
      cat "$log" >"$filtered"
    fi
    printf '  clean passes:    %s\n' "$(grep -c ' clean$' "$filtered" || true)"
    printf '  blocked (found): %s\n' "$(grep -c ' findings ' "$filtered" || true)"
    printf '  infra errors:    %s\n' "$(grep -c ' error ' "$filtered" || true)"
    rm -f "$filtered"
  else
    printf '  no scan-hook activity recorded yet\n'
  fi
}

# ─── update ───

aidc::cmd_update() {
  aidc::need_cmd git
  if ! git -C "$AIDC_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    aidc::die "aidc at $AIDC_ROOT is not a git checkout — update it the way it was installed"
  fi

  local old_version="$AIDC_VERSION" old_sha
  old_sha="$(git -C "$AIDC_ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')"

  # ff-only: never merge/rebase a user-modified checkout behind their back.
  if ! git -C "$AIDC_ROOT" pull --ff-only; then
    aidc::die "fast-forward pull failed — $AIDC_ROOT has local commits or diverged; resolve manually (git -C $AIDC_ROOT status)"
  fi

  if [[ -x "$AIDC_ROOT/install.sh" ]]; then
    (cd "$AIDC_ROOT" && ./install.sh)
  fi

  local new_version new_sha
  new_version="$(sed -n 's/^AIDC_VERSION="\${AIDC_VERSION:-\(.*\)}"$/\1/p' "$AIDC_ROOT/lib/aidc/common.sh")"
  new_sha="$(git -C "$AIDC_ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')"
  aidc::log "updated: $old_version ($old_sha) -> ${new_version:-$old_version} ($new_sha)"

  if [[ -f "$(aidc::default_workspace)/.ai-container/project.env" ]]; then
    aidc::log "next: 'aidc upgrade' refreshes this project's scaffold; 'aidc rebuild' rebuilds its image"
  fi
}

aidc::cmd_status() {
  local global=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --global|-g) global=1 ;;
      *) aidc::die "unknown status flag: $1 (valid: --global)" ;;
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
  # Only surface the Docker provider when it's not the default, so normal setups
  # stay uncluttered. 'apple' routes via socktainer (see docs/apple-container.md).
  if [[ "${AIDC_DOCKER_PROVIDER:-docker}" != "docker" ]]; then
    aidc::status_kv "provider" "${AIDC_DOCKER_PROVIDER} (${DOCKER_HOST:-ambient})" "$c_lbl" "$c_rst"
  fi
  aidc::status_kv "branch" "$AIDC_CORE_BRANCH" "$c_lbl" "$c_rst"
  aidc::status_kv "worktree" "$AIDC_CORE_WORKTREE" "$c_lbl" "$c_rst"
  # Passive posture line — the open-network default is by design, not a
  # warning (see docs/security.md).
  if [[ "${AIDC_ENABLE_EGRESS_FIREWALL:-0}" == "1" ]]; then
    aidc::status_kv "firewall" "on (default-deny egress allowlist)" "$c_lbl" "$c_rst"
  else
    aidc::status_kv "firewall" "off (open network, default)" "$c_lbl" "$c_rst"
  fi

  printf '\n  %smounts%s\n' "$c_lbl" "$c_rst"
  aidc::status_mount_row "/workspace" "$workspace" "$c_dim" "$c_rst"
  aidc::status_mount_row "/opt/CORE_LOGICS" "$AIDC_CORE_WORKTREE" "$c_dim" "$c_rst"
  aidc::status_mount_row "/host-seed/claude" "$AIDC_HOST_SEED_CLAUDE" "$c_dim" "$c_rst"
  aidc::status_mount_row "/host-seed/codex" "$AIDC_HOST_SEED_CODEX" "$c_dim" "$c_rst"
  aidc::status_mount_row "/host-seed/opencode" "$AIDC_HOST_SEED_OPENCODE" "$c_dim" "$c_rst"
  aidc::status_mount_row "/host-seed/opencode-data" "$AIDC_HOST_SEED_OPENCODE_DATA" "$c_dim" "$c_rst"
  aidc::status_mount_row "/host-seed/grok" "$AIDC_HOST_SEED_GROK" "$c_dim" "$c_rst"
  aidc::status_mount_row "/host-seed/omp" "$AIDC_HOST_SEED_OMP" "$c_dim" "$c_rst"
  aidc::status_mount_row "/host-seed/cursor" "$AIDC_HOST_SEED_CURSOR" "$c_dim" "$c_rst"
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
  local size_map stats_map running_ids image_map
  size_map="$(docker container ls --all --size --format '{{.ID}}|{{.Size}}' 2>/dev/null)"
  # Image sizes keyed by image ID, so we can show each project's on-disk image
  # footprint from one lookup.
  image_map="$(docker image ls --no-trunc --format '{{.ID}}|{{.Size}}' 2>/dev/null)"
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

    local size image_size cimage
    size="$(printf '%s\n' "$size_map" | awk -F'|' -v id="$id" 'index($1,id)==1 {print $2; exit}')"
    cimage="$(docker inspect --format '{{.Image}}' "$id" 2>/dev/null || true)"
    image_size="$(printf '%s\n' "$image_map" | awk -F'|' -v img="$cimage" 'index($1,img)==1 {print $2; exit}')"

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
      [[ -n "$image_size" ]] && printf '              %simage%s %s\n' "$C_LBL" "$C_RST" "$image_size"
      [[ -n "$started" ]] && printf '              %ssince%s %s\n' "$C_LBL" "$C_RST" "$started"
    else
      stopped=$((stopped + 1))
      local exited
      exited="$(docker inspect --format '{{.State.FinishedAt}}' "$id" 2>/dev/null || true)"
      exited="$(aidc::status_fmt_ts "$exited")"

      printf '  %s○ %s%s  %s\n' "$C_WARN" "$state" "$C_RST" "$slug"
      printf '              %s%s%s\n' "$C_DIM" "$workspace" "$C_RST"
      printf '              %sdisk%s %s\n' "$C_LBL" "$C_RST" "${size:-?}"
      [[ -n "$image_size" ]] && printf '              %simage%s %s\n' "$C_LBL" "$C_RST" "$image_size"
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
