#!/usr/bin/env bash
#
# Unit tests for aidc::ensure_scan_link — the host-side, synchronous
# re-assertion of the in-container `aidc-scan` PATH shim that closes the
# first-run race and stale-container gaps in bootstrap-state.sh init.
#
#   - it execs an idempotent `ln -sf` of the scaffold's aidc-scan.sh into the
#     container's ~/.local/bin, honoring AIDC_CONTAINER_HOME;
#   - a failing exec is non-fatal (returns 0);
#   - ensure_container_running calls it, so every container-entering command
#     (shell, exec, agents, sbom, …) gets the shim.
#
# Run with: bash tests/scan-link.test.sh
# shellcheck disable=SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
CAP="$TMP_ROOT/compose-args"

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

. "$REPO_ROOT/lib/aidc.sh"

# Capture what aidc::compose is asked to run (newline-joined args), and let the
# test dictate its exit status via COMPOSE_RC.
COMPOSE_RC=0
aidc::compose() { printf '%s\n' "$@" >"$CAP"; return "$COMPOSE_RC"; }

# ── 1. default home: idempotent ln -sf of the scaffold script ──
COMPOSE_RC=0
aidc::ensure_scan_link "/some/ws"
args="$(cat "$CAP")"
if printf '%s' "$args" | grep -qx 'exec' \
   && printf '%s' "$args" | grep -qx -- '-T' \
   && printf '%s' "$args" | grep -q '/workspace/.devcontainer/scripts/aidc-scan.sh' \
   && printf '%s' "$args" | grep -q 'ln -sf' \
   && printf '%s' "$args" | grep -qx '/home/vscode'; then
  ok "execs an idempotent ln -sf of aidc-scan.sh into the default container home"
else
  fail "unexpected compose args: $args"
fi

# ── 2. honors AIDC_CONTAINER_HOME ──
COMPOSE_RC=0
( AIDC_CONTAINER_HOME="/home/dev" aidc::ensure_scan_link "/some/ws" )
if grep -qx '/home/dev' "$CAP"; then
  ok "passes AIDC_CONTAINER_HOME through as the link's home dir"
else
  fail "AIDC_CONTAINER_HOME not honored: $(cat "$CAP")"
fi

# ── 3. a failing exec is non-fatal ──
COMPOSE_RC=7
rc=0
aidc::ensure_scan_link "/some/ws" || rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "a failing container exec is swallowed (non-fatal)"
else
  fail "expected rc=0 on exec failure, got $rc"
fi

# ── 4. the chokepoint wires it: every container-entering command gets the shim ──
if awk '/^aidc::ensure_container_running\(\)/,/^\}/' "$REPO_ROOT/lib/aidc/runtime.sh" \
     | grep -q 'aidc::ensure_scan_link'; then
  ok "ensure_container_running calls ensure_scan_link"
else
  fail "ensure_container_running does not call ensure_scan_link"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
