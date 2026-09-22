#!/usr/bin/env bash
#
# Unit tests for the Claude OAuth token delivery paths in aidc::run_tool
# (lib/aidc.sh): file-based delivery (default — token over stdin into a tmpfs
# file, never on argv or in exec env args), the AIDC_TOKEN_DELIVERY=env
# fallback, profile permission enforcement, profile-env scrubbing, and
# merge-template temp-file hygiene.
#
# Run with: bash tests/token-delivery.test.sh
# shellcheck disable=SC2034,SC1090,SC1091,SC2030,SC2031,SC2317
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

FAKE_TOKEN="sk-ant-oat01-TEST-1111111111111111111111111111"

. "$REPO_ROOT/lib/aidc.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

CALL_LOG="$TMP_ROOT/calls.log"
STDIN_LOG="$TMP_ROOT/stdin.log"

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

# ── stubs: replace the container-facing layer, record everything ────────────
aidc::default_workspace() { printf '%s\n' "$TMP_ROOT/ws"; }
aidc::ensure_container_running() { :; }
aidc::auto_sync_sessions() { :; }
aidc::resolve_claude_oauth_token() { :; }  # token preset by each case
aidc::compose() {
  shift # workspace
  printf 'compose %s\n' "$*" >>"$CALL_LOG"
  if [[ -p /dev/stdin ]]; then
    cat >>"$STDIN_LOG"
  fi
  return 0
}

mkdir -p "$TMP_ROOT/ws"

run_case() { # resets logs, runs run_tool claude with current env
  : >"$CALL_LOG"
  : >"$STDIN_LOG"
  aidc::run_tool claude "" -p ok </dev/null >/dev/null 2>&1 || true
}

# 1. Default (file) delivery: no -e for the token, token only on stdin.
export CLAUDE_CODE_OAUTH_TOKEN="$FAKE_TOKEN"
unset AIDC_TOKEN_DELIVERY 2>/dev/null || true
run_case
if grep -q -- '-e CLAUDE_CODE_OAUTH_TOKEN' "$CALL_LOG"; then
  fail "file delivery still passes -e CLAUDE_CODE_OAUTH_TOKEN"
else
  ok "file delivery drops the -e passthrough"
fi
if grep -qF "$FAKE_TOKEN" "$CALL_LOG"; then
  fail "token value leaked into an argv"
else
  ok "token value appears in no argv"
fi
if grep -qF "$FAKE_TOKEN" "$STDIN_LOG"; then
  ok "token travelled via stdin"
else
  fail "token never arrived on stdin"
fi
if grep -q 'umask 077 && cat >/dev/shm/aidc-oauth-token' "$CALL_LOG"; then
  ok "tmpfs delivery exec issued with umask 077"
else
  fail "tmpfs delivery exec missing"
fi
if grep -q 'exec aidc-bootstrap-claude' "$CALL_LOG"; then
  ok "bootstrap wrapped to import the token file"
else
  fail "bootstrap exec missing"
fi
if grep -q 'rm -f "\$f"' "$CALL_LOG"; then
  ok "launch wrapper deletes the token file"
else
  fail "launch wrapper does not delete the token file"
fi

# 2. Legacy env delivery restores -e passthrough, nothing on stdin.
export AIDC_TOKEN_DELIVERY=env
run_case
if grep -q -- '-e CLAUDE_CODE_OAUTH_TOKEN' "$CALL_LOG"; then
  ok "env delivery passes -e CLAUDE_CODE_OAUTH_TOKEN"
else
  fail "env delivery lost the -e passthrough"
fi
if [[ -s "$STDIN_LOG" ]]; then
  fail "env delivery unexpectedly wrote to stdin"
else
  ok "env delivery uses no stdin channel"
fi
unset AIDC_TOKEN_DELIVERY

# 3. No token at all: no delivery exec, no -e, agent still launched.
unset CLAUDE_CODE_OAUTH_TOKEN
run_case
if grep -q 'aidc-oauth-token' "$CALL_LOG"; then
  fail "delivery exec issued without a token"
else
  ok "no token -> no delivery exec"
fi
if grep -q 'exec claude' "$CALL_LOG" || grep -q ' claude --dangerously-skip-permissions' "$CALL_LOG"; then
  ok "agent still launched without a token"
else
  fail "agent launch missing: $(cat "$CALL_LOG")"
fi

# 4. Loose profile permissions are a hard error naming the fix.
profile_root="$TMP_ROOT/profiles"
mkdir -p "$profile_root"
AIDC_CLAUDE_PROFILE_ROOT="$profile_root"
cat >"$profile_root/loose.env" <<'EOF'
AIDC_CLAUDE_DESCRIPTION="test"
ANTHROPIC_AUTH_TOKEN="dummy"
EOF
chmod 644 "$profile_root/loose.env"
out=""
rc=0
out="$( (aidc::load_claude_profile_env loose) 2>&1 )" || rc=$?
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'chmod 600'; then
  ok "loose profile permissions fail hard with a chmod hint"
else
  fail "loose perms case: rc=$rc out=$out"
fi
chmod 600 "$profile_root/loose.env"
if (aidc::load_claude_profile_env loose) >/dev/null 2>&1; then
  ok "0600 profile loads"
else
  fail "0600 profile rejected"
fi

# 5. Profile-env scrubbing after the agent exec.
aidc::load_claude_profile_env loose >/dev/null 2>&1
if [[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
  ok "profile export visible before scrub"
else
  fail "profile export missing before scrub"
fi
aidc::scrub_profile_env
if [[ -z "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
  ok "profile secrets scrubbed after use"
else
  fail "profile secrets survived the scrub"
fi

# 6. merge_template cleans its temp file on failure.
merge_target_dir="$TMP_ROOT/merge"
mkdir -p "$merge_target_dir"
printf 'user content\n' >"$merge_target_dir/CLAUDE.md"
aidc::_strip_block_to() { return 1; }  # force the failure path
rc=0
(aidc::merge_template "templates/CLAUDE.md.tmpl" "$merge_target_dir/CLAUDE.md") >/dev/null 2>&1 || rc=$?
leftovers="$(find "$merge_target_dir" -name '.aidc-merge.*' | wc -l | tr -d ' ')"
if [[ "$rc" -ne 0 && "$leftovers" == "0" ]]; then
  ok "merge failure exits non-zero and leaves no temp file"
else
  fail "merge failure: rc=$rc leftovers=$leftovers"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
