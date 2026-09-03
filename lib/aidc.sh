#!/usr/bin/env bash

if [[ -n "${AIDC_LIB_LOADED:-}" ]]; then
  return 0
fi
export AIDC_LIB_LOADED=1

# aidc entry point: loads the modules and dispatches commands.
# Layering: common first (constants + helpers used everywhere), then the
# feature modules. Modules never source each other — only this file
# composes them (enforced by .github/scripts/check-module-deps.sh).
AIDC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=aidc/common.sh
. "$AIDC_LIB_DIR/aidc/common.sh"
# shellcheck source=aidc/config.sh
. "$AIDC_LIB_DIR/aidc/config.sh"
# shellcheck source=aidc/profiles.sh
. "$AIDC_LIB_DIR/aidc/profiles.sh"
# shellcheck source=aidc/scaffold.sh
. "$AIDC_LIB_DIR/aidc/scaffold.sh"
# shellcheck source=aidc/vm.sh
. "$AIDC_LIB_DIR/aidc/vm.sh"
# shellcheck source=aidc/runtime.sh
. "$AIDC_LIB_DIR/aidc/runtime.sh"
# shellcheck source=aidc/sync.sh
. "$AIDC_LIB_DIR/aidc/sync.sh"
# shellcheck source=aidc/status.sh
. "$AIDC_LIB_DIR/aidc/status.sh"

aidc::main() {
  # Global flags that precede the subcommand. Kept minimal and parsed here so
  # they never collide with a tool's own args (e.g. `aidc claude -- ...`).
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --debug) AIDC_DEBUG=1; shift ;;
      *) break ;;
    esac
  done
  if [[ "${AIDC_DEBUG:-0}" == "1" ]]; then
    export AIDC_DEBUG=1
    # file:line prefix so the trace pinpoints where a run stalls; secrets are
    # suppressed at their source via aidc::secret_begin/secret_end.
    export PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
    printf '[aidc] debug: tracing enabled (file:line prefixed; secret values suppressed)\n' >&2
    set -x
  fi

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
    rescan)
      aidc::cmd_rescan "$@"
      ;;
    tools)
      aidc::cmd_tools "$@"
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
    opencode-web)
      aidc::cmd_opencode_web "$@"
      ;;
    grok)
      aidc::cmd_grok "$@"
      ;;
    omp)
      aidc::cmd_omp "$@"
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
    sbom)
      aidc::cmd_sbom "$@"
      ;;
    scan)
      aidc::cmd_scan "$@"
      ;;
    licenses)
      aidc::cmd_licenses "$@"
      ;;
    version|--version|-V)
      aidc::cmd_version
      ;;
    doctor)
      aidc::cmd_doctor
      ;;
    insights)
      aidc::cmd_insights "$@"
      ;;
    update)
      aidc::cmd_update
      ;;
    upgrade)
      aidc::cmd_upgrade "$@"
      ;;
    help|-h|--help)
      aidc::cmd_help
      ;;
    *)
      aidc::suggest_command "$cmd"
      ;;
  esac
}

# Unknown-command handler: suggest close matches (prefix / substring / same
# first letter) before pointing at help and doctor.
aidc::suggest_command() {
  local cmd="$1"
  local known="init up down rebuild rescan tools status destroy shell exec claude codex opencode opencode-web grok omp cursor-agent cursor sync-claude-aliases sync-config sync-sessions sbom licenses scan doctor insights update upgrade version help"
  local suggestions="" k
  for k in $known; do
    case "$k" in
      "$cmd"*|*"$cmd"*) suggestions="$suggestions $k"; continue ;;
    esac
    if [[ "${k:0:2}" == "${cmd:0:2}" ]]; then
      suggestions="$suggestions $k"
    fi
  done
  if [[ -n "$suggestions" ]]; then
    aidc::die "unknown command: $cmd — did you mean:$suggestions ? ('aidc help' lists everything; 'aidc doctor' checks your setup)"
  fi
  aidc::die "unknown command: $cmd ('aidc help' lists everything; 'aidc doctor' checks your setup)"
}

aidc::cmd_help() {
  cat <<'EOF'
aidc - AI devcontainer bootstrapper

Usage:
  aidc [--debug] <command> [args...]
  aidc init [-f|--force] [path]
  aidc up [--clipboard] [--isolate-vm]
  aidc down
  aidc rebuild [--clipboard] [--isolate-vm]
  aidc rescan
  aidc tools <install [go|rust|java|all]|status>
  aidc status [--global]
  aidc destroy [-f] [--purge-worktree] [--purge-scaffold]
  aidc shell
  aidc exec -- <command>...
  aidc claude [--profile NAME] [--provider NAME] [--list-profiles] [-- ...]
  aidc codex [-- ...]
  aidc opencode [-- ...]
  aidc opencode-web [--port N] [--no-auth] [--username NAME] [-- ...]
  aidc grok [-- ...]
  aidc omp [-- ...]
  aidc cursor-agent [-- ...]
  aidc cursor
  aidc sync-claude-aliases
  aidc sync-config <claude|codex|opencode|grok|omp|cursor|all>
  aidc sync-sessions [claude|codex|opencode|grok|omp|all]
  aidc sbom [-- ...]
  aidc licenses [--fail] [-- ...]
  aidc scan [--all|--staged|paths...] [--json]
  aidc doctor
  aidc insights [--since DATE]
  aidc update
  aidc upgrade [--dry-run|--diff] [-y]
  aidc version

Notes:
  - aidc sbom generates code-level + build-time SBOMs (CycloneDX + SPDX), diffs
    them, and runs the license check. It calls scripts/ci/aidc-sbom-all.sh in the
    container; any CI can call the same scripts directly. Set AIDC_IMAGE_REF to
    scan a built image for the build-time SBOM.
  - aidc licenses runs the license-conflict check (scripts/ci/aidc-license-check.sh).
    Defaults to warn; pass --fail to exit non-zero on a conflict (CI gate).
  - aidc --debug <command> (or AIDC_DEBUG=1) prints a file:line-prefixed
    execution trace to stderr to diagnose where a run stalls (e.g. the macOS
    Keychain token read, or the first container build). Secret values (OAuth
    token, profile API keys) are suppressed from the trace.
  - Run commands from the repo root you want to isolate.
  - Tool commands auto-bootstrap the repo and container if needed.
  - aidc init refuses to run if the repo already has a file at an aidc-managed
    path (e.g. its own scripts/ci/*.sh). Pass -f/--force to adopt the directory
    anyway, overwriting those managed files with the current templates.
  - aidc opencode-web runs opencode's browser UI inside the container and
    publishes it on the host loopback (http://127.0.0.1:4096, --port to change),
    so a host browser gets the "desktop feeling" while the LAN never sees it.
    Auth is on by default (a random OPENCODE_SERVER_PASSWORD is generated and
    printed); --no-auth disables it. Opting in (re)creates the container to add
    the port; a later plain 'aidc <tool>' recreates it back without the port.
  - Plain 'aidc claude' keeps the default Anthropic path.
  - aidc cursor opens the host Cursor app; reopen the repo in the devcontainer.
  - aidc destroy removes the container, named volumes, and image by default.
    Worktree and scaffold removal are opt-in via the listed flags.
  - aidc rescan re-detects project languages (handy once a repo that started
    empty gains code) and rebuilds so the matching toolchains/scanners install.
  - aidc tools install [go|rust|java|all] populates the shared, read-only
    toolchain volume (one copy of Go/Rust/JDK for all projects); 'aidc tools
    status' shows what's installed. Detected go/rust/java toolchains are
    populated automatically on 'aidc up'.
  - aidc sync-sessions pulls in-container session logs back to host
    ~/.claude/projects so '/insights' on the host can see them. Sessions also
    auto-sync on container start, agent exit, 'down', and 'destroy' unless
    AIDC_AUTO_SYNC_SESSIONS=0.
  - The host-clipboard bridge is off by default. Enable it at (re)create time
    with 'aidc up --clipboard' or 'aidc rebuild --clipboard'.
  - Per-project VM isolation is off by default due to resource cost. Enable it
    with 'aidc up --isolate-vm' or persist AIDC_ISOLATE_VM=1 in
    .ai-container/project.env. See README "Isolation modes".
EOF
}
