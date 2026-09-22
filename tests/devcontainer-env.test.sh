#!/usr/bin/env bash
#
# Unit tests for aidc::write_devcontainer_env (lib/aidc/runtime.sh): the
# .devcontainer/.env generator that lets VS Code / Cursor "Reopen in Container"
# run `docker compose up` with the same AIDC_* bind sources + COMPOSE_PROJECT_NAME
# the aidc CLI uses.
#
# Run with: bash tests/devcontainer-env.test.sh
# shellcheck disable=SC2034,SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

. "$REPO_ROOT/lib/aidc.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
WS="$TMP_ROOT/ws"
mkdir -p "$WS/.devcontainer"

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

ENV_FILE="$WS/.devcontainer/.env"
has() { grep -qFx "$1" "$ENV_FILE"; }

# Resolved values, as export_compose_env would have set them. Deliberately leave
# the limit vars UNSET to prove the writer tolerates unset vars under `set -u`.
COMPOSE_PROJECT_NAME="aidc_myrepo"
AIDC_BASE_IMAGE="aidc-base:abc123def456"
AIDC_TOOLCHAINS="go,node"
AIDC_SECURITY_TOOLS=""
AIDC_AGENTS="all"
AIDC_WORKSPACE="$WS"
AIDC_DEVCONTAINER_DIR="$WS/.devcontainer"
AIDC_CORE_LOGICS_WORKTREE="$TMP_ROOT/core"
AIDC_HOST_SEED_CLAUDE="$TMP_ROOT/seed/claude"
AIDC_HOST_SEED_CODEX="$TMP_ROOT/seed/codex"
AIDC_HOST_SEED_OPENCODE="$TMP_ROOT/seed/opencode"
AIDC_HOST_SEED_OPENCODE_DATA="$TMP_ROOT/seed/opencode-data"
AIDC_HOST_SEED_GROK="$TMP_ROOT/seed/grok"
AIDC_HOST_SEED_OMP="$TMP_ROOT/seed/omp"
AIDC_HOST_SEED_CURSOR="$TMP_ROOT/seed/cursor"
AIDC_GITCONFIG_SOURCE="$TMP_ROOT/seed/gitconfig"
AIDC_CLIPBOARD_DIR_SOURCE="$TMP_ROOT/seed/clipboard"
unset AIDC_PIDS_LIMIT AIDC_MEM_LIMIT AIDC_CPU_LIMIT 2>/dev/null || true

aidc::write_devcontainer_env "$WS"

# 1. The file is created.
if [[ -f "$ENV_FILE" ]]; then ok ".env is written"; else fail ".env not created"; fi

# 2. COMPOSE_PROJECT_NAME so the extension joins the same compose project.
if has "COMPOSE_PROJECT_NAME=aidc_myrepo"; then ok "COMPOSE_PROJECT_NAME written"; else fail "COMPOSE_PROJECT_NAME missing"; fi

# 3. Every no-default compose var is present with its resolved value.
nd_ok=1
for line in \
  "AIDC_WORKSPACE=$WS" \
  "AIDC_DEVCONTAINER_DIR=$WS/.devcontainer" \
  "AIDC_CORE_LOGICS_WORKTREE=$TMP_ROOT/core" \
  "AIDC_HOST_SEED_CLAUDE=$TMP_ROOT/seed/claude" \
  "AIDC_HOST_SEED_CODEX=$TMP_ROOT/seed/codex" \
  "AIDC_HOST_SEED_OPENCODE=$TMP_ROOT/seed/opencode" \
  "AIDC_HOST_SEED_OPENCODE_DATA=$TMP_ROOT/seed/opencode-data" \
  "AIDC_HOST_SEED_GROK=$TMP_ROOT/seed/grok" \
  "AIDC_HOST_SEED_OMP=$TMP_ROOT/seed/omp" \
  "AIDC_HOST_SEED_CURSOR=$TMP_ROOT/seed/cursor" \
  "AIDC_GITCONFIG_SOURCE=$TMP_ROOT/seed/gitconfig" \
  "AIDC_CLIPBOARD_DIR_SOURCE=$TMP_ROOT/seed/clipboard"; do
  has "$line" || { fail "missing no-default var line: $line"; nd_ok=0; }
done
[[ "$nd_ok" -eq 1 ]] && ok "all no-default vars present with resolved values"

# 4. The real base image hash (not the compose 'aidc-base:latest' fallback).
if has "AIDC_BASE_IMAGE=aidc-base:abc123def456"; then ok "AIDC_BASE_IMAGE pinned to the resolved hash"; else fail "AIDC_BASE_IMAGE not the resolved hash"; fi

# 5. Unset limit vars are emitted empty (proves no `set -u` crash / no leak).
if has "AIDC_PIDS_LIMIT="; then ok "unset limit var emitted empty (set -u safe)"; else fail "AIDC_PIDS_LIMIT line missing"; fi

# 6. Perms are 0600.
mode="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE" 2>/dev/null)"
if [[ "$mode" == "600" ]]; then ok ".env is mode 0600"; else fail ".env mode is $mode (want 600)"; fi

# 7. Atomic write leaves no temp file behind.
if ! ls "$WS/.devcontainer"/.env.aidc-tmp.* >/dev/null 2>&1; then ok "no temp file left behind"; else fail "temp file remained"; fi

# 8. No .devcontainer dir → no-op, no crash.
if aidc::write_devcontainer_env "$TMP_ROOT/nonexistent-ws"; then ok "missing .devcontainer is a no-op"; else fail "no-op path returned non-zero"; fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
