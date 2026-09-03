#!/usr/bin/env bash
# aidc module: Shared constants + small helpers (logging, paths, permissions).
# Sourced by lib/aidc.sh — never directly. Functions moved verbatim from
# the former monolith; behavior changes ride their own commits.
#
# SC2034: the globals below are consumed by the sibling modules; shellcheck
# lints each module file in isolation and cannot see those uses.
# shellcheck disable=SC2034

AIDC_VERSION="${AIDC_VERSION:-0.2.0}"

AIDC_CONTAINER_USER="${AIDC_CONTAINER_USER:-vscode}"

AIDC_CONTAINER_HOME="${AIDC_CONTAINER_HOME:-/home/vscode}"

AIDC_HOST_CONFIG_ROOT="${AIDC_HOST_CONFIG_ROOT:-$HOME/.config/aidc}"

AIDC_GLOBAL_CONFIG="${AIDC_GLOBAL_CONFIG:-$AIDC_HOST_CONFIG_ROOT/config.env}"

AIDC_EMPTY_ROOT="${AIDC_EMPTY_ROOT:-$AIDC_HOST_CONFIG_ROOT/empty}"

AIDC_PROVIDER_ROOT="${AIDC_PROVIDER_ROOT:-$AIDC_HOST_CONFIG_ROOT/providers/claude}"

AIDC_CLAUDE_PROFILE_ROOT="${AIDC_CLAUDE_PROFILE_ROOT:-$AIDC_PROVIDER_ROOT}"

AIDC_BIN_DIR="${AIDC_BIN_DIR:-${AIDC_INSTALL_DIR:-$HOME/.local/bin}}"

# macOS Keychain service that holds the Claude OAuth token. When set (the
# default), aidc reads the token from the Keychain on demand instead of
# requiring it to be exported into every shell. Set empty to disable.
AIDC_CLAUDE_OAUTH_KEYCHAIN_SERVICE="${AIDC_CLAUDE_OAUTH_KEYCHAIN_SERVICE:-claude-code-oauth-token}"

AIDC_CORE_ROOT_DEFAULT="${AIDC_CORE_ROOT_DEFAULT:-$HOME/CORE_LOGICS}"

AIDC_CORE_WORKTREE_ROOT="${AIDC_CORE_WORKTREE_ROOT:-$HOME/.local/share/aidc/core-worktrees}"

AIDC_MANAGED_CLAUDE_ALIAS_MARKER="# aidc-managed claude-alias"

# Shared toolchain store (issue #9): one read-only named volume holds Go/Rust/
# JDK for every project, populated from per-language store images tagged
# "<prefix>-<lang>:<hash>".
AIDC_TOOLCHAIN_VOLUME="${AIDC_TOOLCHAIN_VOLUME:-aidc_toolchains}"
AIDC_TOOLCHAIN_STORE_IMAGE_PREFIX="aidc-toolchain-store"

AIDC_MANAGED_PATHS=(
  ".devcontainer/Dockerfile"
  ".devcontainer/Dockerfile.base"
  ".devcontainer/compose.yaml"
  ".devcontainer/compose.firewall.yaml"
  ".devcontainer/compose.hardened.yaml"
  ".devcontainer/compose.opencode-web.yaml"
  ".devcontainer/devcontainer.json"
  ".devcontainer/scripts/bootstrap-state.sh"
  ".devcontainer/scripts/init-firewall.sh"
  ".devcontainer/scripts/aidc-scan.sh"
  ".devcontainer/scripts/aidc-scan-hook.sh"
  ".ai-container/project.env"
  ".cursor/rules/00-core-logics.mdc"
  "scripts/ci/aidc-lib-common.sh"
  "scripts/ci/aidc-sbom-code.sh"
  "scripts/ci/aidc-sbom-image.sh"
  "scripts/ci/aidc-sbom-diff.sh"
  "scripts/ci/aidc-license-check.sh"
  "scripts/ci/aidc-sbom-all.sh"
)

AIDC_MERGE_PATHS=(
  "CLAUDE.md"
  "AGENTS.md"
)

# aidc-owned files that track the current templates ("template:target:mode").
# Consumed by refresh_scaffold, upgrade, and the staleness check — keep the
# three in agreement by keeping the list here, in one place. Files NOT in
# this map are either marker-merged (AIDC_MERGE_PATHS) or user-owned
# seed-once files that are never rewritten.
AIDC_OVERWRITE_TEMPLATE_MAP=(
  "templates/devcontainer/Dockerfile.tmpl:.devcontainer/Dockerfile:0755"
  "templates/devcontainer/Dockerfile.base.tmpl:.devcontainer/Dockerfile.base:0644"
  "templates/devcontainer/compose.yaml.tmpl:.devcontainer/compose.yaml:0644"
  "templates/devcontainer/compose.firewall.yaml.tmpl:.devcontainer/compose.firewall.yaml:0644"
  "templates/devcontainer/compose.hardened.yaml.tmpl:.devcontainer/compose.hardened.yaml:0644"
  "templates/devcontainer/compose.opencode-web.yaml.tmpl:.devcontainer/compose.opencode-web.yaml:0644"
  "templates/devcontainer/devcontainer.json.tmpl:.devcontainer/devcontainer.json:0644"
  "templates/devcontainer/scripts/bootstrap-state.sh.tmpl:.devcontainer/scripts/bootstrap-state.sh:0755"
  "templates/devcontainer/scripts/init-firewall.sh.tmpl:.devcontainer/scripts/init-firewall.sh:0755"
  "templates/devcontainer/scripts/aidc-scan.sh.tmpl:.devcontainer/scripts/aidc-scan.sh:0755"
  "templates/devcontainer/scripts/aidc-scan-hook.sh.tmpl:.devcontainer/scripts/aidc-scan-hook.sh:0755"
  "templates/cursor-rules/00-core-logics.mdc.tmpl:.cursor/rules/00-core-logics.mdc:0644"
  "templates/ci/aidc-lib-common.sh.tmpl:scripts/ci/aidc-lib-common.sh:0755"
  "templates/ci/aidc-sbom-code.sh.tmpl:scripts/ci/aidc-sbom-code.sh:0755"
  "templates/ci/aidc-sbom-image.sh.tmpl:scripts/ci/aidc-sbom-image.sh:0755"
  "templates/ci/aidc-sbom-diff.sh.tmpl:scripts/ci/aidc-sbom-diff.sh:0755"
  "templates/ci/aidc-license-check.sh.tmpl:scripts/ci/aidc-license-check.sh:0755"
  "templates/ci/aidc-sbom-all.sh.tmpl:scripts/ci/aidc-sbom-all.sh:0755"
)

# "create" = only materialize missing files (implicit paths: up/agent
# commands); "overwrite" = track templates (explicit: init, upgrade).
AIDC_SCAFFOLD_MODE="overwrite"

AIDC_MERGE_MARKER_START="<!-- aidc:core-logics:start -->"

AIDC_MERGE_MARKER_END="<!-- aidc:core-logics:end -->"

AIDC_EXEC_ENV_ARGS=()

AIDC_PROFILE_LOADED_KEYS=()

# In-container prelude for file-based token delivery: import the token from
# the tmpfs file when the environment doesn't already carry it. Shared by the
# bootstrap and launch execs in aidc::run_tool.
AIDC_CLAUDE_TOKEN_SNIPPET='f=/dev/shm/aidc-oauth-token; if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" && -f "$f" ]]; then CLAUDE_CODE_OAUTH_TOKEN="$(cat "$f")"; export CLAUDE_CODE_OAUTH_TOKEN; fi'

# Host env vars forwarded into the agent process when present (only if set, so a
# long list is safe — unset keys are skipped by append_passthrough_env_args).
# These let API-key auth "just work" without an interactive login: Anthropic +
# Claude OAuth, OpenAI (codex), xAI (grok), Cursor, and the common multi-provider
# keys opencode/omp accept. Narrow or extend it per host/project via
# AIDC_PASSTHROUGH_ENV_KEYS in config.env / project.env (see docs/security.md).
AIDC_PASSTHROUGH_ENV_KEYS=(
  "ANTHROPIC_API_KEY"
  "CLAUDE_CODE_OAUTH_TOKEN"
  "OPENAI_API_KEY"
  "OPENAI_BASE_URL"
  "CURSOR_API_KEY"
  "XAI_API_KEY"
  "OPENROUTER_API_KEY"
  "GEMINI_API_KEY"
  "GOOGLE_GENERATIVE_AI_API_KEY"
  "GROQ_API_KEY"
  "MISTRAL_API_KEY"
  "DEEPSEEK_API_KEY"
  "PERPLEXITY_API_KEY"
)

# Host-set knobs forwarded into the container for `aidc sbom` / `aidc licenses`
# so overrides like AIDC_IMAGE_REF or AIDC_LICENSE_MODE reach scripts/ci/.
AIDC_SBOM_ENV_KEYS=(
  "AIDC_SBOM_DIR"
  "AIDC_SBOM_SRC"
  "AIDC_IMAGE_REF"
  "AIDC_LICENSE_MODE"
  "AIDC_LICENSE_MATRIX"
  "AIDC_LICENSE_SBOM"
  "AIDC_PROJECT_LICENSE"
  "AIDC_LICENSE_USE_VET"
)

aidc::need_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || aidc::die "required command not found: $cmd"
  done
}

# ─── Lima backend (macOS) ──────────────────────────────────────────

AIDC_LIMA_CONFIG_DIR="${AIDC_HOST_CONFIG_ROOT}/lima-configs"

# Resource defaults for the Lima VM.  Override via AIDC_LIMA_CPUS /
# AIDC_LIMA_MEMORY / AIDC_LIMA_DISK in .ai-container/project.env.
AIDC_LIMA_CPUS="${AIDC_LIMA_CPUS:-2}"

AIDC_LIMA_MEMORY="${AIDC_LIMA_MEMORY:-2GiB}"

AIDC_LIMA_DISK="${AIDC_LIMA_DISK:-10GiB}"

# ─── Firecracker backend (Linux) ──────────────────────────────────
#
# Firecracker runs a lightweight microVM per project.  This backend is
# included for future Linux support — the scaffold is here but requires
# kernel/rootfs images and is not yet enabled by default.

AIDC_FIRECRACKER_KERNEL="${AIDC_FIRECRACKER_KERNEL:-/var/lib/aidc/vmlinux}"

AIDC_FIRECRACKER_ROOTFS="${AIDC_FIRECRACKER_ROOTFS:-/var/lib/aidc/rootfs.ext4}"

AIDC_FIRECRACKER_SOCKET_DIR="${AIDC_HOST_CONFIG_ROOT}/firecracker-sockets"

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

aidc::shell_escape() {
  printf '%q' "$1"
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
  # GNU stat first (-c). The BSD form must NOT be probed first: GNU stat
  # treats -f as "filesystem status" and exits 0 with multi-line junk, which
  # used to poison this result on Linux. Validate the output is octal either
  # way and return empty when neither form yields a mode.
  local path="$1"
  local perms=""
  perms="$(stat -c "%a" "$path" 2>/dev/null || true)"
  if ! [[ "$perms" =~ ^[0-7]+$ ]]; then
    perms="$(stat -f "%OLp" "$path" 2>/dev/null || true)"
  fi
  [[ "$perms" =~ ^[0-7]+$ ]] || perms=""
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

# Same check, but fatal — used where the file's secrets are about to be
# exported into the environment and forwarded to a container.
aidc::require_strict_permissions() {
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
      aidc::die "profile file has loose permissions ($perms) and may contain API keys: $path
fix with: chmod 600 $path"
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

# Debug breadcrumb — printed to stderr only when `aidc --debug` (or AIDC_DEBUG=1)
# is active. Cheap no-op otherwise, so it is safe to sprinkle at decision points.
# Never pass secret values here.
aidc::debug() {
  [[ "${AIDC_DEBUG:-0}" == "1" ]] || return 0
  printf '[aidc] debug: %s\n' "$*" >&2
}

# Secret-region guard. `--debug` turns on shell xtrace, which would otherwise
# echo the OAuth token / profile API keys the moment they appear in an
# expansion. Wrap any code that touches a secret value in:
#     aidc::secret_begin;  <secret-handling lines>;  aidc::secret_end
# secret_begin suppresses xtrace and records whether it was on; secret_end
# restores it. Regions must not span an early `return` and must not nest.
aidc::secret_begin() {
  AIDC_XTRACE_SAVED=0
  case "$-" in
    *x*) AIDC_XTRACE_SAVED=1; set +x ;;
  esac
}

aidc::secret_end() {
  [[ "${AIDC_XTRACE_SAVED:-0}" -eq 1 ]] && set -x
  AIDC_XTRACE_SAVED=0
  return 0
}
