#!/usr/bin/env bash
# aidc module: Container lifecycle: compose invocation, up/down/rebuild/destroy, agent execution.
# Sourced by lib/aidc.sh — never directly. Functions moved verbatim from
# the former monolith; behavior changes ride their own commits.

aidc::cmd_up() {
  local workspace
  aidc::parse_up_flags "$@"
  workspace="$(aidc::default_workspace)"
  aidc::ensure_workspace_ready "$workspace"

  if [[ "${AIDC_ISOLATE_VM:-0}" == "1" ]]; then
    aidc::vm_ensure "$workspace"
  fi

  aidc::ensure_base_image "$workspace"
  aidc::ensure_toolchain_volumes "$workspace"
  aidc::compose_up "$workspace"
  # Catch up the host with any transcripts a prior (possibly ungraceful) session
  # left in the volume — the recovery case the on-exit hooks can't cover.
  aidc::auto_sync_sessions "$workspace" all
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

  aidc::ensure_base_image "$workspace"
  aidc::ensure_toolchain_volumes "$workspace"
  aidc::compose "$workspace" up -d --build --force-recreate workspace
  aidc::auto_sync_sessions "$workspace" all
  aidc::log "container rebuilt for $(basename "$workspace")"
}

# Re-detect project languages and rebuild so newly-applicable toolchains and
# their security scanners get installed. Useful when a repo that started empty
# (or single-language) later gains code aidc didn't see at first build.
aidc::cmd_rescan() {
  local workspace
  workspace="$(aidc::default_workspace)"
  aidc::ensure_workspace_ready "$workspace"

  local detected effective
  detected="$(aidc::detect_toolchains "$workspace")"
  effective="$(aidc::compute_toolchains "$workspace")"

  aidc::log "detected toolchains: ${detected:-none}"
  if [[ "$effective" != "$detected" ]]; then
    # project.env pins AIDC_TOOLCHAINS, so detection is informational only.
    aidc::log "effective toolchains (AIDC_TOOLCHAINS override): ${effective:-none}"
  fi

  if [[ "${AIDC_ISOLATE_VM:-0}" == "1" ]]; then
    aidc::vm_ensure "$workspace"
  fi

  aidc::ensure_base_image "$workspace"
  aidc::ensure_toolchain_volumes "$workspace"
  # --build picks up the changed AIDC_TOOLCHAINS build arg and reinstalls.
  aidc::compose "$workspace" up -d --build workspace
  aidc::log "rescan complete for $(basename "$workspace")"
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
      *) aidc::die "unknown flag: $1 (valid: --clipboard, --isolate-vm)" ;;
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
  # Pull session transcripts to the host while the container is still up.
  aidc::auto_sync_sessions "$workspace" all
  aidc::compose "$workspace" down

  if [[ "${AIDC_ISOLATE_VM:-0}" == "1" ]]; then
    aidc::vm_stop "$workspace"
  fi

  aidc::log "container stopped for $(basename "$workspace")"
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
        aidc::die "unknown destroy flag: $1 (valid: -f, --purge-worktree, --purge-scaffold)"
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

  # Last chance to pull session transcripts before '-v' wipes the volumes.
  aidc::auto_sync_sessions "$workspace" all
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

aidc::cmd_shell() {
  local workspace
  workspace="$(aidc::default_workspace)"
  aidc::ensure_container_running "$workspace"
  aidc::compose "$workspace" exec workspace zsh -l
}

# Run a command in the workspace container with the collected passthrough env
# args. Centralizes the `${AIDC_EXEC_ENV_ARGS[@]+...}` guard so empty-array
# expansion under `set -u` (bash 3.2) can't be reintroduced at a call site.
aidc::compose_exec() {
  local workspace="$1"
  shift
  aidc::compose "$workspace" exec ${AIDC_EXEC_ENV_ARGS[@]+"${AIDC_EXEC_ENV_ARGS[@]}"} workspace "$@"
}

# The `aidc-scan` PATH shim is created by bootstrap-state.sh's init dispatch,
# which runs asynchronously and only at container (re)creation. That leaves two
# gaps: (1) a race — `compose up -d` returns before bootstrap finishes, so on a
# first run a shell/agent can enter before the symlink exists; and (2) staleness
# — a container reused from before the scaffold gained aidc-scan.sh never gets
# the link at all. ensure_container_running calls this on every container-entering
# command (shell, exec, agents, sbom, …) so `aidc-scan` (and the Stop-hook
# guardrail that invokes it) is always on PATH. Idempotent; non-fatal on failure.
aidc::ensure_scan_link() {
  local workspace="$1"
  local home="${AIDC_CONTAINER_HOME:-/home/vscode}"
  aidc::compose "$workspace" exec -T workspace sh -c '
    script=/workspace/.devcontainer/scripts/aidc-scan.sh
    [ -f "$script" ] || exit 0
    mkdir -p "$1/.local/bin" && ln -sf "$script" "$1/.local/bin/aidc-scan"
  ' aidc-ensure-scan-link "$home" >/dev/null 2>&1 || true
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
  aidc::compose_exec "$workspace" "$@"
}

aidc::append_sbom_env_args() {
  local key
  for key in "${AIDC_SBOM_ENV_KEYS[@]}"; do
    if [[ -n "${!key:-}" ]]; then
      AIDC_EXEC_ENV_ARGS+=("-e" "$key")
    fi
  done
}

# Generate the full SBOM pipeline (code + build-time + diff + license check)
# inside the container by running the same CI-agnostic scripts any CI calls.
aidc::cmd_sbom() {
  local workspace
  workspace="$(aidc::default_workspace)"
  aidc::ensure_container_running "$workspace"
  if [[ $# -gt 0 && "$1" == "--" ]]; then
    shift
  fi
  AIDC_EXEC_ENV_ARGS=()
  aidc::append_sbom_env_args
  aidc::compose_exec "$workspace" bash /workspace/scripts/ci/aidc-sbom-all.sh "$@"
}

# Run the changed-file-scoped scanner suite inside the container. All logic
# lives in the scaffolded .devcontainer/scripts/aidc-scan.sh (also on the
# container PATH as `aidc-scan`), so agents and CI can call it directly.
aidc::cmd_scan() {
  local workspace
  workspace="$(aidc::default_workspace)"
  aidc::ensure_container_running "$workspace"
  if [[ $# -gt 0 && "$1" == "--" ]]; then
    shift
  fi
  AIDC_EXEC_ENV_ARGS=()
  aidc::compose_exec "$workspace" bash /workspace/.devcontainer/scripts/aidc-scan.sh "$@"
}

# Run just the license-conflict check. Defaults to warn; --fail gates (exit 1).
aidc::cmd_licenses() {
  local workspace
  workspace="$(aidc::default_workspace)"
  aidc::ensure_container_running "$workspace"

  local mode=""
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fail) mode="fail"; shift ;;
      --warn) mode="warn"; shift ;;
      --) shift; args+=("$@"); break ;;
      *) args+=("$1"); shift ;;
    esac
  done

  AIDC_EXEC_ENV_ARGS=()
  aidc::append_sbom_env_args
  if [[ -n "$mode" ]]; then
    AIDC_EXEC_ENV_ARGS+=("-e" "AIDC_LICENSE_MODE=$mode")
  fi
  aidc::compose_exec "$workspace" bash /workspace/scripts/ci/aidc-license-check.sh ${args[@]+"${args[@]}"}
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

  aidc::run_tool "claude" "$profile" ${args[@]+"${args[@]}"}
}

aidc::cmd_codex() {
  aidc::run_tool "codex" "" "$@"
}

aidc::cmd_opencode() {
  aidc::run_tool "opencode" "" "$@"
}

aidc::cmd_grok() {
  aidc::run_tool "grok" "" "$@"
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

aidc::run_tool() {
  local tool="$1"
  local profile="$2"
  shift 2

  local workspace
  workspace="$(aidc::default_workspace)"

  # Agent selection is NOT seeded from the tool: the shared base image (issue #7)
  # amortizes all agents across every project, so the default bakes in all of
  # them (one shared base, no per-project agent cost). Set AIDC_AGENTS explicitly
  # in .ai-container/project.env to build a slim single/few-agent base variant —
  # the base is content-hashed on the selection and the thin image rebuilds when
  # it changes (see aidc::image_base_is_current).

  aidc::ensure_container_running "$workspace"

  if [[ "$tool" == "claude" ]]; then
    aidc::resolve_claude_oauth_token
  fi

  # Snapshot "is an OAuth token present" once, xtrace-suppressed, so the token
  # value never reaches a --debug trace via the delivery/bootstrap conditionals
  # below (which would otherwise expand it inside [[ -n "$TOKEN" ]]).
  local have_oauth=0
  aidc::secret_begin
  [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] && have_oauth=1
  aidc::secret_end

  # Claude OAuth token delivery. Default "file": the token travels over the
  # exec's stdin into a 0600 tmpfs file (/dev/shm) and is read — then deleted —
  # inside the container, so it never appears in docker exec metadata or in
  # any argv. AIDC_TOKEN_DELIVERY=env restores the legacy -e passthrough.
  local token_delivery="${AIDC_TOKEN_DELIVERY:-file}"
  local claude_token_via_file=0
  if [[ "$tool" == "claude" && "$token_delivery" != "env" && "$have_oauth" -eq 1 ]]; then
    claude_token_via_file=1
  fi

  AIDC_EXEC_ENV_ARGS=()
  # shellcheck disable=SC2034  # consumed by profiles.sh append_passthrough_env_args
  AIDC_PASSTHROUGH_SKIP_KEY=""
  [[ "$claude_token_via_file" -eq 1 ]] && AIDC_PASSTHROUGH_SKIP_KEY="CLAUDE_CODE_OAUTH_TOKEN"
  aidc::append_passthrough_env_args
  # shellcheck disable=SC2034  # consumed by profiles.sh append_passthrough_env_args
  AIDC_PASSTHROUGH_SKIP_KEY=""
  if [[ "$tool" == "claude" && -n "$profile" ]]; then
    aidc::load_claude_profile_env "$profile"
  fi

  if [[ "$claude_token_via_file" -eq 1 ]]; then
    if ! aidc::deliver_claude_token "$workspace"; then
      aidc::warn "file token delivery failed; falling back to env delivery"
      claude_token_via_file=0
      AIDC_EXEC_ENV_ARGS+=("-e" "CLAUDE_CODE_OAUTH_TOKEN")
    fi
  fi

  if [[ "$tool" == "claude" && -z "$profile" && "$have_oauth" -eq 1 ]]; then
    if [[ "$claude_token_via_file" -eq 1 ]]; then
      aidc::compose "$workspace" exec -T workspace \
        bash -c "$AIDC_CLAUDE_TOKEN_SNIPPET; exec aidc-bootstrap-claude" || \
        aidc::warn "Claude OAuth bootstrap failed; falling through to interactive login"
    else
      aidc::compose "$workspace" exec -T -e CLAUDE_CODE_OAUTH_TOKEN workspace aidc-bootstrap-claude || \
        aidc::warn "Claude OAuth bootstrap failed; falling through to interactive login"
    fi
  fi

  local -a command
  case "$tool" in
    claude)
      if [[ "$claude_token_via_file" -eq 1 ]]; then
        # In-container wrapper: pick the token up from the tmpfs file, delete
        # it, and exec the agent. Works with any image (nothing baked in).
        command=(bash -c "$AIDC_CLAUDE_TOKEN_SNIPPET"'; rm -f "$f" 2>/dev/null || true; exec claude "$@"' \
                 claude-launch "--dangerously-skip-permissions")
      else
        command=("claude" "--dangerously-skip-permissions")
      fi
      ;;
    codex)
      command=("codex" "--dangerously-bypass-approvals-and-sandbox")
      ;;
    opencode)
      command=("opencode")
      ;;
    grok)
      # The container is already the isolation boundary; grok runs unsandboxed
      # like the other agents. Grok Build has operating modes (e.g. plan/auto);
      # append the full-autonomy mode flag here once confirmed against the CLI.
      command=("grok")
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

  # Run the agent in the foreground; once it exits, pull its session transcripts
  # back to the host. Preserve the agent's exit code as our own.
  local rc=0
  aidc::compose_exec "$workspace" "${command[@]}" || rc=$?
  aidc::scrub_profile_env
  aidc::auto_sync_sessions "$workspace" "$tool"
  return "$rc"
}

# Ship the Claude OAuth token into the container over stdin, landing as a
# 0600 tmpfs file. Never on any argv, never in exec env metadata.
aidc::deliver_claude_token() {
  local workspace="$1"
  # xtrace-suppressed: the token value is piped on stdin here.
  aidc::secret_begin
  printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN" | aidc::compose "$workspace" exec -T workspace \
    sh -c 'umask 077 && cat >/dev/shm/aidc-oauth-token'
  local rc=$?
  aidc::secret_end
  return "$rc"
}

# Drop profile-sourced variables (API keys etc.) from aidc's own environment
# once the agent exec has returned — they are only needed for the exec itself.
aidc::scrub_profile_env() {
  local key
  for key in ${AIDC_PROFILE_LOADED_KEYS[@]+"${AIDC_PROFILE_LOADED_KEYS[@]}"}; do
    unset "$key" 2>/dev/null || true
  done
  AIDC_PROFILE_LOADED_KEYS=()
}

aidc::ensure_container_running() {
  local workspace="$1"
  aidc::debug "ensuring workspace ready: $workspace"
  aidc::ensure_workspace_ready "$workspace"

  if [[ "${AIDC_ISOLATE_VM:-0}" == "1" ]]; then
    aidc::vm_ensure "$workspace"
  fi

  if [[ -z "$(aidc::compose_capture "$workspace" ps -q workspace)" ]]; then
    aidc::debug "container not running — starting (first run builds the image; can take minutes)"
    aidc::ensure_base_image "$workspace"
    aidc::ensure_toolchain_volumes "$workspace"
    aidc::compose_up "$workspace"
    # Only on the down→up transition (not every exec), so we recover prior
    # transcripts without adding a sync to each command.
    aidc::auto_sync_sessions "$workspace" all
  fi

  # Every container-entering command passes through here, so this is the single
  # chokepoint that guarantees the aidc-scan shim on PATH (shell, exec, agents,
  # sbom, …), closing the async-bootstrap race and stale-container gaps.
  aidc::ensure_scan_link "$workspace"
}

# Build the -f file chain for docker compose. The base compose.yaml is always
# used; hardening overrides join conditionally:
#   AIDC_ENABLE_EGRESS_FIREWALL=1 -> compose.firewall.yaml (adds NET_ADMIN/NET_RAW,
#     which only the firewall's iptables/ipset init needs)
#   AIDC_NO_NEW_PRIVILEGES=1      -> compose.hardened.yaml (no-new-privileges;
#     breaks setuid, so it is skipped with a warning when the firewall — whose
#     init needs runtime sudo — is also enabled)
# Call AFTER aidc::export_compose_env so project.env settings are in effect.
# Result in AIDC_COMPOSE_FILE_ARGS (always non-empty).
aidc::compose_file_args() {
  local workspace="$1"
  AIDC_COMPOSE_FILE_ARGS=(-f "$workspace/.devcontainer/compose.yaml")
  if [[ "${AIDC_ENABLE_EGRESS_FIREWALL:-0}" == "1" && -f "$workspace/.devcontainer/compose.firewall.yaml" ]]; then
    AIDC_COMPOSE_FILE_ARGS+=(-f "$workspace/.devcontainer/compose.firewall.yaml")
  fi
  if [[ "${AIDC_NO_NEW_PRIVILEGES:-0}" == "1" && -f "$workspace/.devcontainer/compose.hardened.yaml" ]]; then
    if [[ "${AIDC_ENABLE_EGRESS_FIREWALL:-0}" == "1" ]]; then
      aidc::warn "AIDC_NO_NEW_PRIVILEGES=1 skipped: the egress firewall needs runtime sudo (see docs/security.md)"
    else
      AIDC_COMPOSE_FILE_ARGS+=(-f "$workspace/.devcontainer/compose.hardened.yaml")
    fi
  fi
}

aidc::compose() {
  local workspace="$1"
  shift
  aidc::export_compose_env "$workspace"
  aidc::compose_file_args "$workspace"
  docker compose "${AIDC_COMPOSE_FILE_ARGS[@]}" "$@"
}

aidc::compose_capture() {
  local workspace="$1"
  shift
  aidc::export_compose_env "$workspace"
  aidc::compose_file_args "$workspace"
  docker compose "${AIDC_COMPOSE_FILE_ARGS[@]}" "$@"
}

# True when the compose image for this workspace already exists locally.
aidc::image_exists() {
  local workspace="$1"
  local image
  image="$(aidc::compose_capture "$workspace" config --images 2>/dev/null | head -n1)"
  [[ -n "$image" ]] || return 1
  docker image inspect "$image" >/dev/null 2>&1
}

# True when the existing thin image was built on the *current* base tag
# (aidc.base label == $AIDC_BASE_IMAGE). False when it's stale — e.g. the
# AIDC_AGENTS selection or the base template changed and ensure_base_image
# produced a new base — so the fast path rebuilds instead of starting an image
# that lacks the newly-selected agents. Callers set AIDC_BASE_IMAGE first.
aidc::image_base_is_current() {
  local workspace="$1"
  [[ -n "${AIDC_BASE_IMAGE:-}" ]] || return 1
  local image thin_base
  image="$(aidc::compose_capture "$workspace" config --images 2>/dev/null | head -n1)"
  [[ -n "$image" ]] || return 1
  thin_base="$(docker image inspect "$image" --format '{{index .Config.Labels "aidc.base"}}' 2>/dev/null)" || return 1
  [[ -n "$thin_base" && "$thin_base" == "$AIDC_BASE_IMAGE" ]]
}

# Start the container, building only when the image is missing (fast path for
# 'aidc up' and the agent commands — routine restarts skip the multi-minute
# rebuild). 'aidc rebuild'/'aidc rescan' always force a build and bypass this.
# AIDC_NO_BUILD=1 forbids building entirely: fail fast if the image is missing.
aidc::compose_up() {
  local workspace="$1"
  if [[ "${AIDC_NO_BUILD:-0}" == "1" ]]; then
    if ! aidc::image_exists "$workspace"; then
      aidc::die "AIDC_NO_BUILD=1 but no image for $(basename "$workspace"); run 'aidc up' once or 'aidc rebuild'"
    fi
    aidc::compose "$workspace" up -d workspace
  elif aidc::image_exists "$workspace" && aidc::image_base_is_current "$workspace"; then
    aidc::compose "$workspace" up -d workspace
  else
    aidc::compose "$workspace" up -d --build workspace
  fi
}

# ─── shared base image (issue #7) ───
# The project-independent layer (OS/uv/scanners/pmg/agents) is built once from
# Dockerfile.base and reused across projects. The tag is content-hashed on the
# base template plus the AIDC_AGENTS selection, so a template edit or an
# agent-set change transparently produces a fresh base.

aidc::base_image_tag() {
  local workspace="$1"
  local hash cmd input
  if command -v sha256sum >/dev/null 2>&1; then
    cmd="sha256sum"
  else
    cmd="shasum -a 256"
  fi
  input="$(cat "$workspace/.devcontainer/Dockerfile.base" 2>/dev/null)"
  input+="|AIDC_AGENTS=${AIDC_AGENTS:-all}"
  hash="$(printf '%s' "$input" | $cmd | awk '{print $1}' | cut -c1-12)"
  printf 'aidc-base:%s' "${hash:-latest}"
}

# Build the shared base image if it isn't present. An explicit AIDC_BASE_IMAGE
# (environment or project.env) pins a custom base and skips the content hash.
aidc::ensure_base_image() {
  local workspace="$1"
  # Load project.env (custom AIDC_BASE_IMAGE) and compute AIDC_AGENTS before we
  # derive/build the tag.
  aidc::export_compose_env "$workspace"
  local tag
  if [[ -n "${AIDC_BASE_IMAGE:-}" ]]; then
    tag="$AIDC_BASE_IMAGE"
  else
    tag="$(aidc::base_image_tag "$workspace")"
    export AIDC_BASE_IMAGE="$tag"
  fi
  if ! docker image inspect "$tag" >/dev/null 2>&1; then
    aidc::log "building shared base image $tag (one-time; shared across projects)"
    ( cd "$workspace/.devcontainer" \
        && docker build -f "$workspace/.devcontainer/Dockerfile.base" \
             --build-arg AIDC_AGENTS="${AIDC_AGENTS:-all}" \
             -t "$tag" "$workspace/.devcontainer" ) \
      || aidc::die "failed to build base image $tag"
    aidc::log "base image $tag ready"
  fi
}

# ─── shared toolchain volume (issue #9) ───
# Go/Rust/JDK (plus gosec/cargo-audit) live in one read-only named volume shared
# by every project, populated from a per-language store image
# (Dockerfile.toolchain). One copy on disk; revoke by removing the volume and
# repopulating with 'aidc tools install'.

aidc::toolchain_image_tag() {
  local lang="$1"
  local hash cmd
  if command -v sha256sum >/dev/null 2>&1; then
    cmd="sha256sum"
  else
    cmd="shasum -a 256"
  fi
  hash="$($cmd "$AIDC_ROOT/templates/devcontainer/Dockerfile.toolchain.tmpl" 2>/dev/null | awk '{print $1}' | cut -c1-12)"
  printf '%s-%s:%s' "$AIDC_TOOLCHAIN_STORE_IMAGE_PREFIX" "$lang" "${hash:-latest}"
}

aidc::ensure_toolchain_image() {
  local lang="$1"
  local tag
  tag="$(aidc::toolchain_image_tag "$lang")"
  if ! docker image inspect "$tag" >/dev/null 2>&1; then
    aidc::log "building toolchain store image $tag (one-time)"
    ( cd "$AIDC_ROOT" \
        && docker build \
             -f "templates/devcontainer/Dockerfile.toolchain.tmpl" \
             --build-arg AIDC_TOOLCHAIN="$lang" \
             -t "$tag" templates/devcontainer ) \
      || aidc::die "failed to build toolchain store image for $lang"
    aidc::log "toolchain store image $tag ready"
  fi
}

# Populate the shared volume with one toolchain, if not already present. Idempotent.
aidc::ensure_toolchain_volume() {
  local lang="$1"
  local tag
  tag="$(aidc::toolchain_image_tag "$lang")"
  docker volume inspect "$AIDC_TOOLCHAIN_VOLUME" >/dev/null 2>&1 \
    || docker volume create "$AIDC_TOOLCHAIN_VOLUME" >/dev/null
  aidc::ensure_toolchain_image "$lang"
  if ! docker run --rm -v "$AIDC_TOOLCHAIN_VOLUME:/opt/toolchains" \
         --entrypoint test "$tag" -f "/opt/toolchains/$lang/.aidc-ready" >/dev/null 2>&1; then
    aidc::log "populating shared $lang toolchain in $AIDC_TOOLCHAIN_VOLUME (one-time)"
    docker run --rm -v "$AIDC_TOOLCHAIN_VOLUME:/opt/toolchains" "$tag" \
      || aidc::die "failed to populate $lang toolchain volume"
    aidc::log "shared $lang toolchain ready"
  fi
}

# Ensure every volume-backed toolchain the workspace needs (go/rust/java) is
# present before the container starts. Node/Ruby/PHP/shell/Python bake into the
# per-project image instead, so they are skipped here.
aidc::ensure_toolchain_volumes() {
  local workspace="$1"
  aidc::export_compose_env "$workspace"
  # compose mounts the shared volume as `external`, so it must exist before
  # `up` even when no go/rust/java toolchain is used — an empty volume mounts
  # harmlessly (the /opt/toolchains/*/bin dirs are simply absent from PATH).
  docker volume inspect "$AIDC_TOOLCHAIN_VOLUME" >/dev/null 2>&1 \
    || docker volume create "$AIDC_TOOLCHAIN_VOLUME" >/dev/null
  local tc
  IFS=',' read -ra _aidc_tcs <<<"${AIDC_TOOLCHAINS:-}"
  for tc in ${_aidc_tcs[@]+"${_aidc_tcs[@]}"}; do
    case "$tc" in
      go|rust|java) aidc::ensure_toolchain_volume "$tc" ;;
      *) : ;;
    esac
  done
}

# 'aidc tools install [go|rust|java|all]' / 'aidc tools status'.
aidc::cmd_tools() {
  local sub="${1:-status}"
  case "$sub" in
    install|ensure)
      shift || true
      local lang="${1:-all}"
      case "$lang" in
        all) aidc::ensure_toolchain_volume go; aidc::ensure_toolchain_volume rust; aidc::ensure_toolchain_volume java ;;
        go|rust|java) aidc::ensure_toolchain_volume "$lang" ;;
        *) aidc::die "usage: aidc tools install [go|rust|java|all]" ;;
      esac
      ;;
    status)
      aidc::tools_status
      ;;
    *)
      aidc::die "usage: aidc tools <install [go|rust|java|all]|status>"
      ;;
  esac
}

aidc::tools_status() {
  printf 'shared toolchain volume: %s\n' "$AIDC_TOOLCHAIN_VOLUME"
  if ! docker volume inspect "$AIDC_TOOLCHAIN_VOLUME" >/dev/null 2>&1; then
    # shellcheck disable=SC2016  # backticks are literal guidance, not a subshell
    printf '  (not created yet — run `aidc tools install all`)\n'
    return 0
  fi
  local lang tag
  for lang in go rust java; do
    tag="$(aidc::toolchain_image_tag "$lang")"
    if docker image inspect "$tag" >/dev/null 2>&1 \
        && docker run --rm -v "$AIDC_TOOLCHAIN_VOLUME:/opt/toolchains" \
             --entrypoint test "$tag" -f "/opt/toolchains/$lang/.aidc-ready" >/dev/null 2>&1; then
      printf '  %-5s installed\n' "$lang"
    else
      printf '  %-5s not installed\n' "$lang"
    fi
  done
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
  export AIDC_HOST_SEED_GROK
  AIDC_HOST_SEED_GROK="$(aidc::mount_dir_or_empty "$HOME/.grok" "grok")"
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
  # Coding agents baked into the image (AIDC_AGENTS opt-in). Comma-separated
  # (claude,codex,opencode,cursor-agent,grok); 'aidc <tool>' seeds this to just
  # that tool for a first build (see run_tool). Unset/empty here means a plain
  # 'aidc up' bakes in all agents ('all') for back-compat.
  export AIDC_AGENTS
  AIDC_AGENTS="${AIDC_AGENTS:-all}"

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

# True when the workspace contains shell scripts worth linting with shellcheck.
# Fast path is the name-based '*.sh' check; the shebang probe is bounded to
# executable, extensionless files (capped) so big repos stay cheap. Uses only
# POSIX find/head so it works with macOS (BSD) find under bash 3.2.
aidc::has_shell_scripts() {
  local workspace="$1"

  # Fast path: any *.sh file, skipping VCS/vendor dirs.
  if [[ -n "$(find "$workspace" \
        \( -type d \( -name .git -o -name node_modules -o -name vendor \) -prune \) -o \
        \( -type f -name '*.sh' -print \) 2>/dev/null | head -n1)" ]]; then
    return 0
  fi

  # Extensionless executables with a shell shebang (e.g. bin/aidc).
  local f first
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    first="$(head -n1 "$f" 2>/dev/null)"
    [[ "$first" == '#!'*sh* ]] && return 0
  done < <(find "$workspace" \
        \( -type d \( -name .git -o -name node_modules -o -name vendor \) -prune \) -o \
        \( -type f -perm -u+x ! -name '*.*' -print \) 2>/dev/null | head -n 200)

  return 1
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
  # Shell has no manifest file, so detect it from content: any *.sh file or an
  # extensionless executable with a shell shebang (e.g. bin/aidc). The 'shell'
  # toolchain arm installs the shellcheck linter.
  if aidc::has_shell_scripts "$workspace"; then
    detected+=("shell")
  fi
  # Join with commas without touching the global IFS.
  local out="" item
  for item in ${detected[@]+"${detected[@]}"}; do
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
