#!/usr/bin/env bash
#
# Unit tests for aidc::cmd_opencode_web (lib/aidc/runtime.sh): the opencode
# "desktop feeling" launcher (issue #5).
#
#   - default builds `opencode web --port 4096 --hostname 0.0.0.0`
#   - --port flows through to both the exec and AIDC_OPENCODE_WEB_PORT
#   - auth on by default: generates + env-references OPENCODE_SERVER_PASSWORD
#   - --no-auth ships no password and warns
#   - --username adds OPENCODE_SERVER_USERNAME
#   - a bad --port dies before any exec
#
# docker/compose and the container-bring-up are stubbed so the test is hermetic.
#
# Run with: bash tests/opencode-web.test.sh
# shellcheck disable=SC2034,SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

. "$REPO_ROOT/lib/aidc.sh"

WS="$(mktemp -d)"
trap 'rm -rf "$WS"' EXIT

# ── Stubs: neutralize everything that would touch docker or the host. ──
aidc::default_workspace()        { printf '%s' "$WS"; }
aidc::ensure_workspace_ready()   { :; }
aidc::vm_ensure()                { :; }
aidc::ensure_base_image()        { :; }
aidc::ensure_toolchain_volumes() { :; }
aidc::compose_up()               { :; }
aidc::auto_sync_sessions()       { :; }
aidc::ensure_scan_link()         { :; }
aidc::append_passthrough_env_args() { :; }
aidc::gen_web_password()         { printf 'testpass123'; }

# Capture the foreground exec (command + the -e env-key args) instead of running it.
EXEC_CMD=""
EXEC_ENV=""
aidc::compose_exec() {
  shift  # drop the workspace arg
  EXEC_CMD="$*"
  EXEC_ENV="${AIDC_EXEC_ENV_ARGS[*]:-}"
  return 0
}

reset_state() {
  EXEC_CMD=""; EXEC_ENV=""
  unset OPENCODE_SERVER_PASSWORD OPENCODE_SERVER_USERNAME \
        AIDC_OPENCODE_WEB AIDC_OPENCODE_WEB_PORT 2>/dev/null || true
}

# 1. Default: web on port 4096, bound 0.0.0.0 inside the container.
reset_state
aidc::cmd_opencode_web >/dev/null
if [[ "$EXEC_CMD" == "opencode web --port 4096 --hostname 0.0.0.0" ]]; then
  ok "default runs 'opencode web --port 4096 --hostname 0.0.0.0'"
else
  fail "default exec: got '$EXEC_CMD'"
fi
if [[ "${AIDC_OPENCODE_WEB:-}" == "1" && "${AIDC_OPENCODE_WEB_PORT:-}" == "4096" ]]; then
  ok "default exports AIDC_OPENCODE_WEB=1 and port 4096"
else
  fail "default env: AIDC_OPENCODE_WEB='${AIDC_OPENCODE_WEB:-}' port='${AIDC_OPENCODE_WEB_PORT:-}'"
fi

# 2. Auth on by default: password generated + delivered by env-key reference.
if [[ "${OPENCODE_SERVER_PASSWORD:-}" == "testpass123" ]]; then
  ok "auth default generates OPENCODE_SERVER_PASSWORD"
else
  fail "auth password: got '${OPENCODE_SERVER_PASSWORD:-}'"
fi
case " $EXEC_ENV " in
  *" -e OPENCODE_SERVER_PASSWORD "*) ok "auth adds '-e OPENCODE_SERVER_PASSWORD'" ;;
  *) fail "auth env args: got '$EXEC_ENV'" ;;
esac

# 3. --port flows to the exec and the publish env var.
reset_state
aidc::cmd_opencode_web --port 5000 >/dev/null
if [[ "$EXEC_CMD" == "opencode web --port 5000 --hostname 0.0.0.0" \
      && "${AIDC_OPENCODE_WEB_PORT:-}" == "5000" ]]; then
  ok "--port 5000 flows to exec + AIDC_OPENCODE_WEB_PORT"
else
  fail "--port 5000: exec='$EXEC_CMD' port='${AIDC_OPENCODE_WEB_PORT:-}'"
fi

# 4. --username adds OPENCODE_SERVER_USERNAME alongside the password.
reset_state
aidc::cmd_opencode_web --username alice >/dev/null
if [[ "${OPENCODE_SERVER_USERNAME:-}" == "alice" ]]; then ok "--username exports OPENCODE_SERVER_USERNAME"; else fail "username: '${OPENCODE_SERVER_USERNAME:-}'"; fi
case " $EXEC_ENV " in
  *" -e OPENCODE_SERVER_USERNAME "*) ok "--username adds '-e OPENCODE_SERVER_USERNAME'" ;;
  *) fail "username env args: '$EXEC_ENV'" ;;
esac

# 5. --no-auth: no password, no password env arg, and a warning.
reset_state
warn_out="$(aidc::cmd_opencode_web --no-auth 2>&1 >/dev/null)"
if [[ -z "${OPENCODE_SERVER_PASSWORD:-}" ]]; then ok "--no-auth generates no password"; else fail "--no-auth leaked password '${OPENCODE_SERVER_PASSWORD:-}'"; fi
case " $EXEC_ENV " in
  *" -e OPENCODE_SERVER_PASSWORD "*) fail "--no-auth still passed the password env" ;;
  *) ok "--no-auth omits the password env" ;;
esac
if printf '%s' "$warn_out" | grep -qi 'without auth'; then ok "--no-auth warns"; else fail "--no-auth warning missing: '$warn_out'"; fi

# 6. --port passthrough after '--' is not consumed as extra web args by mistake.
reset_state
aidc::cmd_opencode_web --port 4200 -- --cors https://example.com >/dev/null
if [[ "$EXEC_CMD" == "opencode web --port 4200 --hostname 0.0.0.0 --cors https://example.com" ]]; then
  ok "extra args after -- pass through to opencode web"
else
  fail "passthrough: got '$EXEC_CMD'"
fi

# 7. Bad --port dies before any exec.
reset_state
out="$( (aidc::cmd_opencode_web --port 99) 2>&1 )" && rc=0 || rc=$?
if [[ "$rc" -ne 0 && -z "$EXEC_CMD" ]] && printf '%s' "$out" | grep -qi 'invalid --port'; then
  ok "out-of-range --port dies before exec"
else
  fail "bad port (99): rc=$rc exec='$EXEC_CMD' out='$out'"
fi
reset_state
out="$( (aidc::cmd_opencode_web --port abc) 2>&1 )" && rc=0 || rc=$?
if [[ "$rc" -ne 0 && -z "$EXEC_CMD" ]] && printf '%s' "$out" | grep -qi 'invalid --port'; then
  ok "non-numeric --port dies before exec"
else
  fail "bad port (abc): rc=$rc exec='$EXEC_CMD' out='$out'"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
