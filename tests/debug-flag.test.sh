#!/usr/bin/env bash
#
# Unit tests for the global --debug flag (lib/aidc.sh) and the secret-region
# guard that keeps xtrace from leaking the OAuth token / profile API keys:
#
#   - aidc::debug is silent by default, prints to stderr under AIDC_DEBUG=1.
#   - aidc::secret_begin/secret_end toggle xtrace and restore prior state.
#   - resolve_claude_oauth_token under `set -x` never echoes the token value.
#   - `aidc --debug help` enables tracing, is consumed (not treated as a
#     command), and emits a file:line-prefixed trace.
#
# Run with: bash tests/debug-flag.test.sh
# shellcheck disable=SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

. "$REPO_ROOT/lib/aidc.sh"

# ── 1. aidc::debug gating ──
out="$( (unset AIDC_DEBUG; aidc::debug "hello") 2>&1 )"
if [[ -z "$out" ]]; then
  ok "aidc::debug is silent when AIDC_DEBUG unset"
else
  fail "expected no output, got: $out"
fi
out="$( (AIDC_DEBUG=1 aidc::debug "hello") 2>&1 )"
if printf '%s' "$out" | grep -q 'debug: hello'; then
  ok "aidc::debug prints under AIDC_DEBUG=1"
else
  fail "expected debug line, got: $out"
fi

# ── 2. secret_begin/secret_end toggle + restore xtrace ──
state="$( {
  set -x
  aidc::secret_begin
  case "$-" in *x*) printf 'INSIDE:on ' ;; *) printf 'INSIDE:off ' ;; esac
  aidc::secret_end
  case "$-" in *x*) printf 'AFTER:on' ;; *) printf 'AFTER:off' ;; esac
  set +x
} 2>/dev/null )"
if [[ "$state" == "INSIDE:off AFTER:on" ]]; then
  ok "secret region suppresses xtrace inside and restores it after"
else
  fail "xtrace toggle wrong: '$state'"
fi
# And a no-op when xtrace was never on: secret_end must not turn it ON.
state="$( aidc::secret_begin
  aidc::secret_end
  case "$-" in *x*) printf 'on' ;; *) printf 'off' ;; esac
)"
if [[ "$state" == "off" ]]; then
  ok "secret region leaves xtrace off when it started off"
else
  fail "secret region wrongly enabled xtrace: '$state'"
fi

# ── 3. token value never leaks into an xtrace ──
secret="SECRET-TOKEN-VALUE-do-not-leak-9f3a"
trace="$( export CLAUDE_CODE_OAUTH_TOKEN="$secret"
  { set -x; aidc::resolve_claude_oauth_token; set +x; } 2>&1 )"
if printf '%s' "$trace" | grep -q "$secret"; then
  fail "token value leaked into xtrace output"
else
  ok "resolve_claude_oauth_token does not leak the token under xtrace"
fi

# ── 4. `aidc --debug help` enables tracing and consumes the flag ──
# This test sourced lib/aidc.sh (which exports AIDC_LIB_LOADED); clear it so the
# child bin/aidc actually re-loads the library and defines aidc::main.
out="$( env -u AIDC_LIB_LOADED "$REPO_ROOT/bin/aidc" --debug help 2>/tmp/aidc-debug-err.$$ )" || true
err="$(cat /tmp/aidc-debug-err.$$; rm -f /tmp/aidc-debug-err.$$)"
if printf '%s' "$out" | grep -q 'AI devcontainer bootstrapper'; then
  ok "--debug is consumed; the command still runs (help shown)"
else
  fail "help not shown with --debug: $out"
fi
if printf '%s' "$err" | grep -q 'debug: tracing enabled' \
   && printf '%s' "$err" | grep -qE '^\+ [a-z0-9_.-]+\.sh:[0-9]+: '; then
  ok "--debug emits the notice and a file:line-prefixed trace"
else
  fail "no debug trace on stderr: $err"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
