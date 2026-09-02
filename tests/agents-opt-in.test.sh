#!/usr/bin/env bash
#
# Unit tests for AIDC_AGENTS opt-in agent seeding in aidc::run_tool
# (PR #15 / issue #8).
#
#   - running 'aidc <tool>' with AIDC_AGENTS unset seeds AIDC_AGENTS to just
#     that tool, so a first build bakes in only the agent actually used.
#   - an explicit AIDC_AGENTS (project.env / environment) is left untouched.
#
# The container-facing layer is stubbed (as in token-delivery.test.sh) so the
# test is hermetic. run_tool is invoked in the current shell so the exported
# AIDC_AGENTS is observable.
#
# Run with: bash tests/agents-opt-in.test.sh
# shellcheck disable=SC2034,SC1090,SC1091,SC2317
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

. "$REPO_ROOT/lib/aidc.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/ws"

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

# Stub the container-facing layer; the seed runs before any of these.
aidc::default_workspace() { printf '%s\n' "$TMP_ROOT/ws"; }
aidc::ensure_container_running() { :; }
aidc::auto_sync_sessions() { :; }
aidc::resolve_claude_oauth_token() { :; }
aidc::compose() { :; }

# ── 1. unset AIDC_AGENTS is seeded from the tool ──
unset AIDC_AGENTS 2>/dev/null || true
aidc::run_tool codex "" </dev/null >/dev/null 2>&1 || true
if [[ "${AIDC_AGENTS:-}" == "codex" ]]; then
  ok "unset AIDC_AGENTS seeded to the invoked tool (codex)"
else
  fail "expected AIDC_AGENTS=codex, got '${AIDC_AGENTS:-}'"
fi

# ── 2. an explicit AIDC_AGENTS wins and is not overwritten ──
export AIDC_AGENTS="claude,grok"
aidc::run_tool codex "" </dev/null >/dev/null 2>&1 || true
if [[ "$AIDC_AGENTS" == "claude,grok" ]]; then
  ok "explicit AIDC_AGENTS is left untouched"
else
  fail "expected AIDC_AGENTS=claude,grok, got '$AIDC_AGENTS'"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
