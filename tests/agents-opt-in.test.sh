#!/usr/bin/env bash
#
# Unit tests for agent-availability handling in aidc::run_tool (issue #8 /
# slim-by-default remaster; install prompt + first-build bake added later):
#
#   - running 'aidc <tool>' does NOT seed AIDC_AGENTS from the tool: with the
#     shared base amortizing the selected agents, the default (opencode) is
#     applied later in export_compose_env, not per-tool. So an unset
#     AIDC_AGENTS stays unset here.
#   - an explicit AIDC_AGENTS (project.env / environment) is left untouched.
#   - FIRST BUILD (workspace not yet materialized): invoking an agent bakes it
#     into the initial selection — persisted BEFORE the container starts, no
#     prompt, no probe-then-rebuild dance.
#   - EXISTING workspace, interactive: a missing agent prompts y/n. y extends
#     the selection (or rebuilds a stale image unchanged) with
#     --force-recreate and re-probes; n dies with the fix, selection intact.
#   - EXISTING workspace, non-interactive: the historical silent auto-extend;
#     an already-selected-but-missing agent (stale image) dies with the
#     rebuild hint.
#   - AIDC_AUTO_EXTEND_AGENTS=0: hard error before any build.
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

# Hermeticity: the suite tests these knobs, so the host must not supply them
# (an ambient AIDC_AUTO_EXTEND_AGENTS=0 or AIDC_NO_BUILD=1 would flip whole
# cases; AIDC_ISOLATE_VM=1 would route run_tool into the unstubbed vm_ensure).
unset AIDC_AUTO_EXTEND_AGENTS AIDC_NO_BUILD AIDC_ISOLATE_VM 2>/dev/null || true

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

# ── harness knobs ────────────────────────────────────────────────────────────
# MATERIALIZED=1 (default): the workspace already has an image/container —
#   run_tool takes the probe path. MATERIALIZED=0: first-ever run.
# INTERACTIVE=1: aidc::is_interactive reports a TTY (the prompt path).
# PROBE_MISSING_AGENTS=1: the in-image `command -v` probe fails — the image
#   lacks the binary. Flips to 0 once a --force-recreate rebuild ran, so the
#   post-rebuild verification passes (as it would against a real rebuild).
MATERIALIZED="${MATERIALIZED:-1}"
INTERACTIVE=""
PROBE_MISSING_AGENTS=""

aidc::default_workspace() { printf '%s\n' "$TMP_ROOT/ws"; }
aidc::resolve_claude_oauth_token() { :; }
aidc::auto_sync_sessions() { :; }

# ensure_workspace_ready: the real one scaffolds heavy host state; what
# run_tool needs from it is the loaded project.env (the AIDC_AGENTS source).
aidc::ensure_workspace_ready() { aidc::load_project_env "$1"; }

CALLS=""
aidc::ensure_container_running() { CALLS+=" start[${AIDC_AGENTS:-unset}]"; }
aidc::ensure_base_image()        { CALLS+=" base"; }
aidc::write_devcontainer_env()   { CALLS+=" env"; }
aidc::ensure_tool_links()        { CALLS+=" links"; }

COMPOSE_CALLS=""
aidc::workspace_materialized() { [[ "$MATERIALIZED" == "1" ]]; }
aidc::is_interactive() { [[ "$INTERACTIVE" == "1" ]]; }

aidc::compose() {
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "--force-recreate" ]]; then
      COMPOSE_CALLS+=" force-recreate"
      PROBE_MISSING_AGENTS=""
    fi
  done
  COMPOSE_CALLS+=" compose"
  if [[ -n "$PROBE_MISSING_AGENTS" ]]; then
    for arg in "$@"; do
      [[ "$arg" == "command -v"* ]] && return 1
    done
  fi
  return 0
}

make_project_env() { # <contents of AIDC_AGENTS line or empty>
  mkdir -p "$TMP_ROOT/ws/.ai-container"
  { printf '# aidc-managed\nAIDC_VERSION=0.0.0-test\n'
    if [[ -n "${1:-}" ]]; then printf 'AIDC_AGENTS=%s\n' "$1"; fi
  } >"$TMP_ROOT/ws/.ai-container/project.env"
}

# ── 1. unset AIDC_AGENTS is NOT seeded from the tool ──
unset AIDC_AGENTS 2>/dev/null || true
make_project_env ""
PROBE_MISSING_AGENTS=""
aidc::run_tool codex "" </dev/null >/dev/null 2>&1 || true
if [[ -z "${AIDC_AGENTS:-}" ]]; then
  ok "unset AIDC_AGENTS is left unset (default opencode applied at build time)"
else
  fail "run_tool unexpectedly seeded AIDC_AGENTS='${AIDC_AGENTS:-}'"
fi

# ── 2. an explicit AIDC_AGENTS wins and is not overwritten ──
export AIDC_AGENTS="claude,grok"
make_project_env "claude,grok"
PROBE_MISSING_AGENTS=""
aidc::run_tool codex "" </dev/null >/dev/null 2>&1 || true
if [[ "$AIDC_AGENTS" == "claude,grok" ]] && grep -q '^AIDC_AGENTS=claude,grok$' "$TMP_ROOT/ws/.ai-container/project.env"; then
  ok "explicit AIDC_AGENTS is left untouched"
else
  fail "expected AIDC_AGENTS=claude,grok untouched, got '${AIDC_AGENTS:-}'"
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

# ── 4. aidc::selection_includes mirrors the selection semantics ──
AIDC_AGENTS="opencode,grok"
aidc::selection_includes grok && ok "selection_includes: listed agent found" \
  || fail "selection_includes missed a listed agent"
AIDC_AGENTS="all"
aidc::selection_includes omp && ok "selection_includes: 'all' covers every agent" \
  || fail "selection_includes missed 'all'"
AIDC_AGENTS="opencode"
aidc::selection_includes grok && fail "selection_includes false-positive" \
  || ok "selection_includes: unlisted agent rejected"
AIDC_AGENTS=""
aidc::selection_includes opencode && ok "selection_includes: empty selection resolves to the opencode default" \
  || fail "selection_includes missed the empty-selection default"
unset AIDC_AGENTS 2>/dev/null || true

# ── 5. aidc::workspace_materialized: container, image, or neither ──
aidc::compose_capture() { printf 'abc123\n'; }
aidc::workspace_materialized "$TMP_ROOT/ws" \
  && ok "materialized: an existing container counts" \
  || fail "materialized: existing container not detected"
aidc::compose_capture() { printf '\n'; }
aidc::image_exists() { return 0; }
aidc::workspace_materialized "$TMP_ROOT/ws" \
  && ok "materialized: a built image counts" \
  || fail "materialized: built image not detected"
aidc::image_exists() { return 1; }
aidc::workspace_materialized "$TMP_ROOT/ws" \
  || ok "materialized: no container + no image = first-ever run" \
  || fail "materialized: first-ever run not detected"

# ── 6. first-ever run: the invoked agent is baked into the initial build ──
MATERIALIZED=0
INTERACTIVE=""
PROBE_MISSING_AGENTS=""
unset AIDC_AGENTS 2>/dev/null || true
make_project_env ""
CALLS=""
# Direct call (not in $()): run_tool must run in THIS shell so CALLS is
# observable; output goes to a file for the message assertions.
aidc::run_tool claude "" </dev/null >"$TMP_ROOT/out.log" 2>&1 && rc=0 || rc=$?
out="$(cat "$TMP_ROOT/out.log")"
if [[ "$rc" -eq 0 ]] \
  && grep -q '^AIDC_AGENTS=opencode,claude$' "$TMP_ROOT/ws/.ai-container/project.env" \
  && [[ "$CALLS" == " start[opencode,claude]"* ]] \
  && printf '%s' "$out" | grep -q "baking agent 'claude' into the first build"; then
  ok "first build: agent baked into the selection before the container starts (no prompt, no rebuild)"
else
  fail "first build wrong: rc=$rc calls='$CALLS' env='${AIDC_AGENTS:-}' out:\n$out"
fi

# ── 7. first build with an already-selected agent changes nothing ──
MATERIALIZED=0
make_project_env "opencode,grok"
AIDC_AGENTS="opencode,grok"
CALLS=""
aidc::run_tool grok "" </dev/null >/dev/null 2>&1 || true
if [[ "$CALLS" == " start[opencode,grok]"* ]] && [[ "$(grep -c '^AIDC_AGENTS=' "$TMP_ROOT/ws/.ai-container/project.env")" -eq 1 ]]; then
  ok "first build: already-selected agent leaves the selection alone"
else
  fail "first build (selected) wrong: calls='$CALLS' env:\n$(cat "$TMP_ROOT/ws/.ai-container/project.env")"
fi

# ── 8. AIDC_AUTO_EXTEND_AGENTS=0 dies BEFORE any build on a first run ──
MATERIALIZED=0
unset AIDC_AGENTS 2>/dev/null || true
make_project_env ""
CALLS=""
out="$(AIDC_AUTO_EXTEND_AGENTS=0 aidc::run_tool codex "" </dev/null 2>&1)" && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]] && [[ -z "$CALLS" ]] \
  && printf '%s' "$out" | grep -q "not in this project's image" \
  && printf '%s' "$out" | grep -q 'AIDC_AGENTS=opencode,codex'; then
  ok "knob off: missing agent dies before the container build (no wasted first build)"
else
  fail "knob-off first build wrong: rc=$rc calls='$CALLS' out:\n$out"
fi

# ── 9. existing workspace, interactive y: prompt, extend, force-recreate ──
MATERIALIZED=1
INTERACTIVE=1
PROBE_MISSING_AGENTS=1
unset AIDC_AGENTS 2>/dev/null || true
make_project_env ""
CALLS=""
COMPOSE_CALLS=""
aidc::run_tool grok "" </dev/null <<<"y" >"$TMP_ROOT/out.log" 2>&1 && rc=0 || rc=$?
out="$(cat "$TMP_ROOT/out.log")"
if [[ "$rc" -eq 0 ]] \
  && grep -q '^AIDC_AGENTS=opencode,grok$' "$TMP_ROOT/ws/.ai-container/project.env" \
  && printf '%s' "$out" | grep -q "install it now?" \
  && [[ "$CALLS" == " start[unset] base env links" ]] \
  && [[ "$COMPOSE_CALLS" == *"force-recreate"* ]] \
  && ! printf '%s' "$out" | grep -q "still missing"; then
  ok "interactive y: prompt shown, selection extended, rebuilt with --force-recreate, verified"
else
  fail "interactive y wrong: rc=$rc calls='$CALLS' compose='$COMPOSE_CALLS' out:\n$out"
fi

# ── 10. existing workspace, interactive n: hard error, selection untouched ──
INTERACTIVE=1
PROBE_MISSING_AGENTS=1
unset AIDC_AGENTS 2>/dev/null || true
make_project_env ""
CALLS=""
out="$(aidc::run_tool grok "" </dev/null <<<"n" 2>&1)" && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]] \
  && printf '%s' "$out" | grep -q "not in this project's image" \
  && ! grep -q '^AIDC_AGENTS=' "$TMP_ROOT/ws/.ai-container/project.env" \
  && [[ "$CALLS" != *" base"* ]]; then
  ok "interactive n: dies with the fix, no rebuild, project.env untouched"
else
  fail "interactive n wrong: rc=$rc calls='$CALLS' out:\n$out"
fi

# ── 11. existing workspace, interactive y on a STALE image (already selected) ──
INTERACTIVE=1
PROBE_MISSING_AGENTS=1
make_project_env "opencode,grok"
CALLS=""
COMPOSE_CALLS=""
AIDC_AGENTS="opencode,grok" aidc::run_tool grok "" </dev/null <<<"y" >"$TMP_ROOT/out.log" 2>&1 && rc=0 || rc=$?
out="$(cat "$TMP_ROOT/out.log")"
if [[ "$rc" -eq 0 ]] \
  && printf '%s' "$out" | grep -q "stale build) — rebuild now?" \
  && [[ "$COMPOSE_CALLS" == *"force-recreate"* ]] \
  && grep -q '^AIDC_AGENTS=opencode,grok$' "$TMP_ROOT/ws/.ai-container/project.env" \
  && [[ "$(grep -c '^AIDC_AGENTS=' "$TMP_ROOT/ws/.ai-container/project.env")" -eq 1 ]]; then
  ok "interactive stale image: rebuild offered, selection unchanged, force-recreate ran"
else
  fail "interactive stale wrong: rc=$rc calls='$CALLS' compose='$COMPOSE_CALLS' out:\n$out"
fi

# ── 12. existing workspace, non-interactive: silent auto-extend (legacy) ──
INTERACTIVE=""
PROBE_MISSING_AGENTS=1
unset AIDC_AGENTS 2>/dev/null || true
make_project_env ""
CALLS=""
aidc::run_tool grok "" </dev/null >/dev/null 2>&1 || true
if grep -q '^AIDC_AGENTS=opencode,grok$' "$TMP_ROOT/ws/.ai-container/project.env" \
  && [[ "${AIDC_AGENTS:-}" == "opencode,grok" ]] \
  && [[ "$CALLS" == *" base"* && "$CALLS" == *" env"* && "$CALLS" == *" links"* ]]; then
  ok "non-interactive: missing agent extends the selection (persisted + exported) and rebuilds"
else
  fail "non-interactive extend wrong: env='${AIDC_AGENTS:-}' calls='$CALLS'"
fi

# ── 13. non-interactive + already selected (stale image): rebuild hint ──
PROBE_MISSING_AGENTS=1
make_project_env "opencode,grok"
out="$(AIDC_AGENTS="opencode,grok" aidc::run_tool grok "" </dev/null 2>&1)" && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'aidc rebuild'; then
  ok "non-interactive stale image: dies with the rebuild hint (selection unchanged)"
else
  fail "non-interactive stale wrong: rc=$rc out:\n$out"
fi

# ── 13b. the knob beats the prompt: selected + stale + interactive → hard error ──
INTERACTIVE=1
PROBE_MISSING_AGENTS=1
make_project_env "opencode,grok"
out="$(AIDC_AUTO_EXTEND_AGENTS=0 AIDC_AGENTS="opencode,grok" aidc::run_tool grok "" </dev/null <<<"y" 2>&1)" && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]] \
  && printf '%s' "$out" | grep -q 'stale build' \
  && printf '%s' "$out" | grep -q "run 'aidc rebuild'" \
  && ! printf '%s' "$out" | grep -q 'rebuild now?'; then
  ok "knob off + stale image: hard error even on a TTY, no prompt offered"
else
  fail "knob-off stale interactive wrong: rc=$rc out:\n$out"
fi

# ── 13c. AIDC_NO_BUILD=1 refuses the install instead of building implicitly ──
INTERACTIVE=""
PROBE_MISSING_AGENTS=1
unset AIDC_AGENTS 2>/dev/null || true
make_project_env ""
CALLS=""
COMPOSE_CALLS=""
out="$(AIDC_NO_BUILD=1 aidc::run_tool codex "" </dev/null 2>&1)" && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]] \
  && printf '%s' "$out" | grep -q "AIDC_NO_BUILD=1 but agent 'codex' is missing" \
  && printf '%s' "$out" | grep -q "aidc rebuild" \
  && [[ "$COMPOSE_CALLS" != *"force-recreate"* ]]; then
  ok "AIDC_NO_BUILD=1: missing agent dies with the rebuild fix, never builds implicitly"
else
  fail "no-build knob wrong: rc=$rc compose='$COMPOSE_CALLS' out:\n$out"
fi

# ── 14. auto-extend replaces an existing AIDC_AGENTS line (no dup lines) ──
# Explicit non-interactive reset: this block runs run_tool directly in the
# current shell (not a subshell), where aidc::die's `exit 1` would kill the
# whole suite — and INTERACTIVE=1 leaks in from the prompt cases above.
INTERACTIVE=""
make_project_env "claude"
PROBE_MISSING_AGENTS=1
( AIDC_AGENTS="claude" aidc::run_tool omp "" </dev/null >/dev/null 2>&1 ) || true
if [[ "$(grep -c '^AIDC_AGENTS=' "$TMP_ROOT/ws/.ai-container/project.env")" -eq 1 ]] \
  && grep -q '^AIDC_AGENTS=claude,omp$' "$TMP_ROOT/ws/.ai-container/project.env"; then
  ok "existing AIDC_AGENTS line is replaced in place"
else
  fail "project.env update wrong:\n$(cat "$TMP_ROOT/ws/.ai-container/project.env")"
fi

# ── 15. probe pass: no prompt, no install chain ──
INTERACTIVE=""
PROBE_MISSING_AGENTS=""
make_project_env ""
CALLS=""
aidc::run_tool codex "" </dev/null >"$TMP_ROOT/out.log" 2>&1 && rc=0 || rc=$?
out="$(cat "$TMP_ROOT/out.log")"
if [[ "$rc" -eq 0 ]] && [[ "$CALLS" == " start["* && "$CALLS" != *" base"* ]] \
  && ! printf '%s' "$out" | grep -q "install it now"; then
  ok "present agent: no prompt, no rebuild chain invoked"
else
  fail "probe pass wrong: rc=$rc calls='$CALLS' out:\n$out"
fi

# ── 16. non-agent tool names skip the pre-check entirely ──
PROBE_MISSING_AGENTS=1
aidc::agent_installed "$TMP_ROOT/ws" some-custom-tool >/dev/null 2>&1 \
  && ok "non-agent tool name skips the pre-check" \
  || fail "non-agent tool was checked against the binary map"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
