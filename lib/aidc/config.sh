#!/usr/bin/env bash
# aidc module: Global + per-project configuration loading and seeding.
# Sourced by lib/aidc.sh — never directly. Functions moved verbatim from
# the former monolith; behavior changes ride their own commits.

# Source host-wide aidc defaults (~/.config/aidc/config.env) if present. These
# are universal settings shared by every project on this host. A project's
# .ai-container/project.env is sourced afterwards and overrides them, so a
# per-folder setting always wins over the global default.
aidc::load_global_config() {
  [[ -f "$AIDC_GLOBAL_CONFIG" ]] || return 0
  # shellcheck disable=SC1090
  . "$AIDC_GLOBAL_CONFIG"
}

aidc::load_project_env() {
  local workspace="$1"
  local env_file="$workspace/.ai-container/project.env"
  # Two distinct failure modes with distinct remedies: never initialized
  # (run init) vs present-but-broken (restore/repair — re-initializing loses
  # per-project settings).
  [[ -f "$env_file" ]] \
    || aidc::die "not an aidc project: $workspace has no .ai-container/project.env — run 'aidc init' first"
  # shellcheck disable=SC1090
  if ! (set -u; . "$env_file") >/dev/null 2>&1; then
    aidc::die "corrupt project env: $env_file does not parse — restore it (backups may exist under .ai-container/backup/), or 'aidc destroy -f --purge-scaffold' and re-init (per-project settings will be lost)"
  fi
  # Global defaults first; per-folder project.env overrides them.
  aidc::load_global_config
  # project.env carries AIDC_VERSION as the scaffolded-by *stamp*; sourcing it
  # must not clobber the running aidc's version (stamp-vs-current comparisons
  # in upgrade/doctor/staleness would otherwise compare the stamp to itself).
  local current_version="$AIDC_VERSION"
  # shellcheck disable=SC1090
  . "$env_file"
  AIDC_VERSION="$current_version"
}

aidc::ensure_host_config_dirs() {
  mkdir -p "$AIDC_HOST_CONFIG_ROOT" "$AIDC_EMPTY_ROOT" "$AIDC_CLAUDE_PROFILE_ROOT"
  mkdir -p "$AIDC_EMPTY_ROOT/claude" "$AIDC_EMPTY_ROOT/codex" "$AIDC_EMPTY_ROOT/opencode" "$AIDC_EMPTY_ROOT/grok" "$AIDC_EMPTY_ROOT/omp" "$AIDC_EMPTY_ROOT/cursor" "$AIDC_EMPTY_ROOT/clipboard"
  touch "$AIDC_EMPTY_ROOT/gitconfig"
  aidc::ensure_global_config
}

# Seed the host-wide config file once, fully commented so sourcing it is a no-op
# until the user edits it. Lists the settings that make sense as global defaults.
aidc::ensure_global_config() {
  [[ -f "$AIDC_GLOBAL_CONFIG" ]] && return 0
  mkdir -p "$(dirname "$AIDC_GLOBAL_CONFIG")"
  cat >"$AIDC_GLOBAL_CONFIG" <<'EOF'
# aidc global config — universal defaults for every project on this host.
# A project's .ai-container/project.env is sourced AFTER this file and overrides
# anything set here, so per-folder settings win. Uncomment a line to change a
# host-wide default.

# Auto-pull in-container agent transcripts to the host on container start, agent
# exit, 'down', and 'destroy'. Set to 0 to disable everywhere by default.
# AIDC_AUTO_SYNC_SESSIONS=1

# macOS Keychain service holding the Claude OAuth token. aidc reads it on demand
# for 'aidc claude' (no need to export CLAUDE_CODE_OAUTH_TOKEN in your shell).
# Store the token once with:
#   security add-generic-password -U -a "$USER" -s claude-code-oauth-token -w 'sk-ant-oat01-...'
# Override the service name below, or set it empty to disable the lookup.
# AIDC_CLAUDE_OAUTH_KEYCHAIN_SERVICE=claude-code-oauth-token

# Container resource limits. The pids cap is a fork-bomb guard (invisible in
# normal use); memory/CPU are unlimited by default (0 = no limit; use Docker
# units, e.g. AIDC_MEM_LIMIT=8g, AIDC_CPU_LIMIT=4).
# AIDC_PIDS_LIMIT=4096
# AIDC_MEM_LIMIT=0
# AIDC_CPU_LIMIT=0

# Block privilege escalation inside the container (no-new-privileges).
# Off by default because it also disables interactive sudo (no more
# 'sudo apt-get install' in the container) and conflicts with the egress
# firewall's runtime sudo. See docs/security.md.
# AIDC_NO_NEW_PRIVILEGES=0

# Egress-firewall allowlist re-resolution interval in seconds (only relevant
# when AIDC_ENABLE_EGRESS_FIREWALL=1). 0 disables the refresh loop.
# AIDC_FIREWALL_REFRESH_SECONDS=300

# Claude Code Stop hook that blocks "done" while aidc-scan reports findings
# above LOW in the changed files. Mechanical version of the CLAUDE.md
# guardrail; fails open on scanner errors. Set 0 to disable.
# AIDC_ENFORCE_SCAN_HOOK=1

# Container engine ("Docker provider"). Default 'docker' uses your ambient Docker
# (Docker Desktop / OrbStack / Colima). Set 'apple' to route aidc through Apple's
# native `container` runtime via a socktainer Docker-API socket — macOS 26 +
# Apple Silicon, EXPERIMENTAL/unverified (see docs/apple-container.md). An
# explicit DOCKER_HOST in your environment always wins.
# AIDC_DOCKER_PROVIDER=docker
# AIDC_APPLE_CONTAINER_SOCKET=$HOME/.socktainer/container.sock
EOF
}

# Route aidc's docker/compose/build/volume calls at the selected engine. aidc
# always shells out to `docker`/`docker compose` with the inherited environment,
# so setting DOCKER_HOST here transparently redirects every call — no per-call
# change needed. Default 'docker' is a no-op (ambient Docker context). 'apple'
# points DOCKER_HOST at the socktainer socket bridging Apple's `container`
# runtime to the Docker API. An explicit DOCKER_HOST always wins. Idempotent.
aidc::apply_docker_provider() {
  local provider="${AIDC_DOCKER_PROVIDER:-docker}"
  case "$provider" in
    docker)
      : # ambient Docker; nothing to do
      ;;
    apple)
      local socket="${AIDC_APPLE_CONTAINER_SOCKET:-$HOME/.socktainer/container.sock}"
      if [[ -z "${DOCKER_HOST:-}" ]]; then
        export DOCKER_HOST="unix://$socket"
      fi
      ;;
    *)
      aidc::warn "unknown AIDC_DOCKER_PROVIDER='$provider' (valid: docker, apple); using ambient Docker"
      ;;
  esac
}

# True when the Docker engine is reachable at the current/DOCKER_HOST endpoint.
# `docker info` is the authoritative "daemon responding" check (the CLI alone is
# not enough — socktainer/OrbStack/etc. all present as `docker`).
aidc::docker_is_usable() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

# True on an interactive terminal (stdin+stdout are TTYs). Factored out so the
# provider prompt is skippable in tests and never fires in CI/piped runs.
aidc::is_interactive() {
  [[ -t 0 && -t 1 ]]
}

# Print the space-separated set of *alternative* container engines available on
# this host, most-preferred first. This is the provider registry: each engine
# aidc can drive via a Docker-API endpoint gets one arm here. All alternatives
# still require the `docker` CLI + compose plugin (aidc is a docker-compose tool);
# they differ only in the engine/socket behind it. Add a provider by adding an
# availability probe below and a matching arm in aidc::apply_docker_provider.
aidc::detect_alt_providers() {
  local out=""
  command -v docker >/dev/null 2>&1 || { printf ''; return 0; }
  # apple: Apple's `container` runtime via socktainer's Docker-API socket.
  local apple_sock="${AIDC_APPLE_CONTAINER_SOCKET:-$HOME/.socktainer/container.sock}"
  if command -v container >/dev/null 2>&1 && [[ -S "$apple_sock" ]]; then
    out+="${out:+ }apple"
  fi
  # (extend here: e.g. `podman` when a docker-compatible podman.sock is present.)
  printf '%s' "$out"
}

# Remember an auto-selected provider in the host-wide config so the prompt is a
# one-time event. Replaces an existing active line, else appends. Atomic;
# never fatal (a failed write just means we'll ask again next time).
aidc::persist_docker_provider() {
  local name="$1"
  local cfg="$AIDC_GLOBAL_CONFIG"
  mkdir -p "$(dirname "$cfg")" 2>/dev/null || true
  [[ -f "$cfg" ]] || : >"$cfg" 2>/dev/null || return 0
  local tmp="$cfg.aidc-tmp.$$"
  if grep -Eq '^[[:space:]]*AIDC_DOCKER_PROVIDER=' "$cfg" 2>/dev/null; then
    sed "s|^[[:space:]]*AIDC_DOCKER_PROVIDER=.*|AIDC_DOCKER_PROVIDER=$name|" "$cfg" >"$tmp" 2>/dev/null \
      && mv -f "$tmp" "$cfg" 2>/dev/null || { rm -f "$tmp" 2>/dev/null || true; return 0; }
  else
    { cat "$cfg"; printf 'AIDC_DOCKER_PROVIDER=%s\n' "$name"; } >"$tmp" 2>/dev/null \
      && mv -f "$tmp" "$cfg" 2>/dev/null || { rm -f "$tmp" 2>/dev/null || true; return 0; }
  fi
}

# Resolve which container engine aidc uses, once per invocation. Called from the
# compose gateway (export_compose_env), so it runs only for container-touching
# commands and (via the AIDC_PROVIDER_RESOLVED guard) prompts at most once.
#
# Precedence: an explicit AIDC_DOCKER_PROVIDER is honored verbatim (no probe, no
# prompt). Otherwise the default is Docker; only when Docker's engine is NOT
# reachable do we look for alternatives and — interactively — offer to switch.
aidc::ensure_docker_provider() {
  if [[ -n "${AIDC_PROVIDER_RESOLVED:-}" ]]; then
    aidc::apply_docker_provider
    return 0
  fi
  export AIDC_PROVIDER_RESOLVED=1

  # Explicit choice wins outright.
  if [[ -n "${AIDC_DOCKER_PROVIDER:-}" ]]; then
    aidc::apply_docker_provider
    return 0
  fi

  # Default path: Docker works → use it (no DOCKER_HOST change).
  if aidc::docker_is_usable; then
    return 0
  fi

  # Docker unreachable — is anything else available to offer?
  local alts
  alts="$(aidc::detect_alt_providers)"
  if [[ -z "$alts" ]]; then
    return 0  # let the normal flow fail with the (provider-aware) docker error
  fi

  if ! aidc::is_interactive; then
    aidc::warn "Docker engine unavailable; detected provider(s): $alts — set AIDC_DOCKER_PROVIDER=<name> to use one (see docs/apple-container.md)"
    return 0
  fi

  local choice reply
  for choice in $alts; do
    printf '[aidc] Docker is not available, but %s is. Use %s for this and future runs? [y/N] ' "$choice" "$choice" >&2
    read -r reply || reply=""
    case "$reply" in
      y|Y|yes|YES)
        export AIDC_DOCKER_PROVIDER="$choice"
        aidc::apply_docker_provider
        aidc::persist_docker_provider "$choice"
        aidc::log "using '$choice' (saved AIDC_DOCKER_PROVIDER to $AIDC_GLOBAL_CONFIG; edit/remove it there to change)"
        return 0
        ;;
      *) : ;;  # decline this one, offer the next
    esac
  done
  aidc::warn "continuing with Docker (no alternative accepted); 'aidc doctor' has details"
  return 0
}
