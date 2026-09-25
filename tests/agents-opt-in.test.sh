#!/usr/bin/env bash
#
# Unit tests for AIDC_AGENTS handling in aidc::run_tool (PR #15 / issue #8,
# reconciled with the shared base image, issue #7; default slimmed to 'claude'
# + binary pre-check added in the remaster).
#
#   - running 'aidc <tool>' does NOT seed AIDC_AGENTS from the tool: with the
#     shared base amortizing the selected agents, the default (claude) is
#     applied later in export_compose_env, not per-tool. So an unset
#     AIDC_AGENTS stays unset here.
#   - an explicit AIDC_AGENTS (project.env / environment) is left untouched.
#   - aidc::agent_installed fails with the fix message when the image lacks
#     the agent binary, and is skipped for non-agent tool names.
#
# The container-facing layer is stubbed (as in token-delivery.test.sh) so the
# test is hermetic. run_tool is invoked in the current shell so AIDC_AGENTS is
# observable.
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

# PROBE_MISSING_AGENTS: when non-empty, the in-image `command -v` probe
# (agent_installed) fails — the image lacks the binary. Other compose calls
# succeed.
PROBE_MISSING_AGENTS=""
aidc::compose() {
  local arg
  if [[ -n "$PROBE_MISSING_AGENTS" ]]; then
    for arg in "$@"; do
      [[ "$arg" == "command -v"* ]] && return 1
    done
  fi
  return 0
}

# ── 1. unset AIDC_AGENTS is NOT seeded from the tool ──
unset AIDC_AGENTS 2>/dev/null || true
aidc::run_tool codex "" </dev/null >/dev/null 2>&1 || true
if [[ -z "${AIDC_AGENTS:-}" ]]; then
  ok "unset AIDC_AGENTS is left unset (default opencode applied at build time)"
else
  fail "run_tool unexpectedly seeded AIDC_AGENTS='${AIDC_AGENTS:-}'"
fi

# ── 2. an explicit AIDC_AGENTS wins and is not overwritten ──
export AIDC_AGENTS="claude,grok"
aidc::run_tool codex "" </dev/null >/dev/null 2>&1 || true
if [[ "$AIDC_AGENTS" == "claude,grok" ]]; then
  ok "explicit AIDC_AGENTS is left untouched"
else
  fail "expected AIDC_AGENTS=claude,grok, got '$AIDC_AGENTS'"
fi

# ── 3. aidc::agents_build_flags maps selections to WITH_* build args ──
flags="$(aidc::agents_build_flags "")"
[[ "$flags" == "--build-arg WITH_OPENCODE=1 " ]] \
  && ok "default (empty) selection maps to opencode only" \
  || fail "default flags wrong: '$flags'"
flags="$(aidc::agents_build_flags all)"
for a in CLAUDE CODEX OPENCODE CURSOR_AGENT GROK OMP; do
  [[ "$flags" == *"--build-arg WITH_$a=1"* ]] || fail "all: missing WITH_$a in '$flags'"
done
ok "'all' maps to all six flags"
flags="$(aidc::agents_build_flags none)"
[[ -z "$flags" ]] \
  && ok "'none' maps to no flags" \
  || fail "none: expected empty, got '$flags'"
flags="$(aidc::agents_build_flags opencode,claude)"
[[ "$flags" == "--build-arg WITH_CLAUDE=1 --build-arg WITH_OPENCODE=1 " ]] \
  && ok "explicit list maps to exactly those agents" \
  || fail "list flags wrong: '$flags'"
flags="$(aidc::agents_build_flags opencode,bogus)"
[[ "$flags" == "--build-arg WITH_OPENCODE=1 " ]] \
  && ok "unknown agent names are ignored by the flag mapping" \
  || fail "unknown-agent flags wrong: '$flags'"

# ── fixture for the auto-extend cases: a real project.env ──
REBUILD_CALLS=""
aidc::ensure_base_image()      { REBUILD_CALLS+=" base"; }
aidc::write_devcontainer_env() { REBUILD_CALLS+=" env"; }
aidc::compose_up()             { REBUILD_CALLS+=" up"; }
aidc::ensure_tool_links()      { REBUILD_CALLS+=" links"; }
make_project_env() { # <contents of AIDC_AGENTS line or empty>
  mkdir -p "$TMP_ROOT/ws/.ai-container"
  { printf '# aidc-managed\nAIDC_VERSION=0.0.0-test\n'
    if [[ -n "${1:-}" ]]; then printf 'AIDC_AGENTS=%s\n' "$1"; fi
  } >"$TMP_ROOT/ws/.ai-container/project.env"
}

# ── 4. auto-extend: missing agent extends the selection and rebuilds ──
PROBE_MISSING_AGENTS=1
unset AIDC_AGENTS 2>/dev/null || true
make_project_env ""
REBUILD_CALLS=""
aidc::run_tool grok "" </dev/null >"$TMP_ROOT/out.log" 2>&1 && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q '^AIDC_AGENTS=opencode,grok$' "$TMP_ROOT/ws/.ai-container/project.env" \
  && [[ "${AIDC_AGENTS:-}" == "opencode,grok" ]] \
  && [[ "$REBUILD_CALLS" == " base env up links" ]]; then
  ok "missing agent extends selection (persisted + exported) and runs the rebuild chain"
else
  fail "auto-extend wrong: rc=$rc env='${AIDC_AGENTS:-}' calls='$REBUILD_CALLS' out:\n$(cat "$TMP_ROOT/out.log")\n$(cat "$TMP_ROOT/ws/.ai-container/project.env")"
fi

# ── 5. auto-extend replaces an existing AIDC_AGENTS line (no dup lines) ──
make_project_env "claude"
PROBE_MISSING_AGENTS=1
AIDC_AGENTS="claude" aidc::run_tool omp "" </dev/null >/dev/null 2>&1 || true
if [[ "$(grep -c '^AIDC_AGENTS=' "$TMP_ROOT/ws/.ai-container/project.env")" -eq 1 ]] \
  && grep -q '^AIDC_AGENTS=claude,omp$' "$TMP_ROOT/ws/.ai-container/project.env"; then
  ok "existing AIDC_AGENTS line is replaced in place"
else
  fail "project.env update wrong:\n$(cat "$TMP_ROOT/ws/.ai-container/project.env")"
fi

# ── 6. auto-extend is idempotent when the agent is already selected ──
make_project_env "opencode,grok"
PROBE_MISSING_AGENTS=1
( AIDC_AGENTS="opencode,grok" aidc::run_tool grok "" </dev/null >/dev/null 2>&1 ) || true
if grep -q '^AIDC_AGENTS=opencode,grok$' "$TMP_ROOT/ws/.ai-container/project.env"; then
  ok "already-selected agent leaves the selection alone (stale image is the real problem)"
else
  fail "selection mutated for an already-selected agent:\n$(cat "$TMP_ROOT/ws/.ai-container/project.env")"
fi

# ── 7. AIDC_AUTO_EXTEND_AGENTS=0 restores the die-with-fix behavior ──
make_project_env ""
PROBE_MISSING_AGENTS=1
unset AIDC_AGENTS 2>/dev/null || true
out="$(AIDC_AUTO_EXTEND_AGENTS=0 aidc::run_tool codex "" </dev/null 2>&1)" && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q "not in this project's image" \
  && printf '%s' "$out" | grep -q 'AIDC_AGENTS=opencode,codex'; then
  ok "knob off: missing agent fails with the AIDC_AGENTS fix message"
else
  fail "expected die with fix message, rc=$rc out:\n$out"
fi

# ── 8. 'all' selected: missing binary is a stale-image problem, not extended ──
make_project_env ""
PROBE_MISSING_AGENTS=1
out="$(AIDC_AGENTS=all aidc::run_tool cursor-agent "" </dev/null 2>&1)" && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'aidc rebuild'; then
  ok "'all' selection: missing agent dies with the rebuild hint (selection unchanged)"
else
  fail "expected rebuild hint under AIDC_AGENTS=all, rc=$rc out:\n$out"
fi

# ── 9. present agent passes the probe and skips the rebuild chain ──
PROBE_MISSING_AGENTS=""
make_project_env ""
REBUILD_CALLS=""
aidc::run_tool codex "" </dev/null >/dev/null 2>&1 || true
[[ -z "$REBUILD_CALLS" ]] \
  && ok "present agent: no rebuild chain invoked" \
  || fail "rebuild chain ran despite a present agent:$REBUILD_CALLS"

# ── 10. non-agent tool names skip the pre-check entirely ──
PROBE_MISSING_AGENTS=1
aidc::agent_installed "$TMP_ROOT/ws" some-custom-tool >/dev/null 2>&1 \
  && ok "non-agent tool name skips the pre-check" \
  || fail "non-agent tool was checked against the binary map"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
