#!/usr/bin/env bash
#
# Unit tests for aidc::cmd_opencode_web (lib/aidc/runtime.sh): the opencode
# "desktop feeling" launcher (issue #5), on the opencode v2 CLI surface.
#
#   - default builds `opencode serve --port 4096 --hostname 0.0.0.0`
#     (v2 renamed v1's `opencode web` subcommand to `serve`)
#   - --port flows through to both the exec and AIDC_OPENCODE_WEB_PORT
#   - auth: v2 always enforces a server password; the default path generates
#     + env-references OPENCODE_PASSWORD
#   - a pre-set v1 OPENCODE_SERVER_PASSWORD is reused as OPENCODE_PASSWORD
#   - --no-auth ships no password (v2 mints + prints its own) and warns
#   - --username is accepted for compatibility and warned about, never sent
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
aidc::ensure_tool_links()        { :; }
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
  unset OPENCODE_PASSWORD OPENCODE_SERVER_PASSWORD OPENCODE_SERVER_USERNAME \
        AIDC_OPENCODE_WEB AIDC_OPENCODE_WEB_PORT 2>/dev/null || true
}

# 1. Default: serve on port 4096, bound 0.0.0.0 inside the container.
reset_state
aidc::cmd_opencode_web >/dev/null
if [[ "$EXEC_CMD" == "opencode serve --port 4096 --hostname 0.0.0.0" ]]; then
  ok "default runs 'opencode serve --port 4096 --hostname 0.0.0.0'"
else
  fail "default exec: got '$EXEC_CMD'"
fi
if [[ "${AIDC_OPENCODE_WEB:-}" == "1" && "${AIDC_OPENCODE_WEB_PORT:-}" == "4096" ]]; then
  ok "default exports AIDC_OPENCODE_WEB=1 and port 4096"
else
  fail "default env: AIDC_OPENCODE_WEB='${AIDC_OPENCODE_WEB:-}' port='${AIDC_OPENCODE_WEB_PORT:-}'"
fi

# 2. Auth default: password generated + delivered by env-key reference.
if [[ "${OPENCODE_PASSWORD:-}" == "testpass123" ]]; then
  ok "auth default generates OPENCODE_PASSWORD"
else
  fail "auth password: got '${OPENCODE_PASSWORD:-}'"
fi
case " $EXEC_ENV " in
  *" -e OPENCODE_PASSWORD "*) ok "auth adds '-e OPENCODE_PASSWORD'" ;;
  *) fail "auth env args: got '$EXEC_ENV'" ;;
esac

# 3. --port flows to the exec and the publish env var.
reset_state
aidc::cmd_opencode_web --port 5000 >/dev/null
if [[ "$EXEC_CMD" == "opencode serve --port 5000 --hostname 0.0.0.0" \
      && "${AIDC_OPENCODE_WEB_PORT:-}" == "5000" ]]; then
  ok "--port 5000 flows to exec + AIDC_OPENCODE_WEB_PORT"
else
  fail "--port 5000: exec='$EXEC_CMD' port='${AIDC_OPENCODE_WEB_PORT:-}'"
fi

# 4. A pre-set v1 OPENCODE_SERVER_PASSWORD is reused, not clobbered.
reset_state
export OPENCODE_SERVER_PASSWORD=legacy-pw
aidc::cmd_opencode_web >/dev/null 2>"$WS/ocweb-compat.err"
if [[ "${OPENCODE_PASSWORD:-}" == "legacy-pw" ]]; then
  ok "v1 OPENCODE_SERVER_PASSWORD reused as OPENCODE_PASSWORD"
else
  fail "v1 password compat: OPENCODE_PASSWORD='${OPENCODE_PASSWORD:-}'"
fi
case " $EXEC_ENV " in
  *" -e OPENCODE_PASSWORD "*) ok "compat path still env-references OPENCODE_PASSWORD" ;;
  *) fail "compat env args: '$EXEC_ENV'" ;;
esac
if grep -qi 'OPENCODE_SERVER_PASSWORD' "$WS/ocweb-compat.err"; then
  ok "compat path logs the v1-name note"
else
  fail "compat note missing: '$(cat "$WS/ocweb-compat.err")'"
fi

# 5. --username: warned and ignored; no username env ever sent.
reset_state
aidc::cmd_opencode_web --username alice >/dev/null 2>"$WS/ocweb-user.err"
case " $EXEC_ENV " in
  *" -e OPENCODE_SERVER_USERNAME "*|*" -e OPENCODE_USERNAME "*) fail "--username leaked a username env: '$EXEC_ENV'" ;;
  *) ok "--username sends no username env" ;;
esac
if grep -qi 'ignored' "$WS/ocweb-user.err"; then ok "--username warns it is ignored"; else fail "--username warning missing: '$(cat "$WS/ocweb-user.err")'"; fi
if [[ "${OPENCODE_PASSWORD:-}" == "testpass123" ]]; then ok "auth still on with --username"; else fail "--username dropped auth: '${OPENCODE_PASSWORD:-}'"; fi

# 6. --no-auth: no password shipped (v2 mints + prints its own) and a warning.
reset_state
warn_out="$(aidc::cmd_opencode_web --no-auth 2>&1 >/dev/null)"
if [[ -z "${OPENCODE_PASSWORD:-}" ]]; then ok "--no-auth generates no password"; else fail "--no-auth leaked password '${OPENCODE_PASSWORD:-}'"; fi
case " $EXEC_ENV " in
  *" -e OPENCODE_PASSWORD "*) fail "--no-auth still passed the password env" ;;
  *) ok "--no-auth omits the password env" ;;
esac
if printf '%s' "$warn_out" | grep -qi 'password'; then ok "--no-auth warns about v2 password behavior"; else fail "--no-auth warning missing: '$warn_out'"; fi

# 7. --port passthrough after '--' is not consumed as extra serve args by mistake.
reset_state
aidc::cmd_opencode_web --port 4200 -- --cors https://example.com >/dev/null
if [[ "$EXEC_CMD" == "opencode serve --port 4200 --hostname 0.0.0.0 --cors https://example.com" ]]; then
  ok "extra args after -- pass through to opencode serve"
else
  fail "passthrough: got '$EXEC_CMD'"
fi

# 8. Bad --port dies before any exec.
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
