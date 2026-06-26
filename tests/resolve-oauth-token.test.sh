#!/usr/bin/env bash
#
# Unit tests for aidc::resolve_claude_oauth_token (lib/aidc.sh).
#
# Stubs the macOS `security` binary on PATH so the resolver can be exercised on
# any host. Run with: bash tests/resolve-oauth-token.test.sh
#
# Each test case runs in its own ( ... ) subshell on purpose, so per-case PATH /
# STUB_* exports stay isolated. shellcheck's subshell-modification warnings are
# false positives for that pattern; SC1091 is the un-followable lib source.
# shellcheck disable=SC1091,SC2030,SC2031
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Obviously-fake token — never a real credential (keeps gitleaks/semgrep clean).
FAKE_TOKEN="sk-ant-oat01-TEST-0000000000000000000000000000"

# shellcheck source=../lib/aidc.sh
. "$REPO_ROOT/lib/aidc.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

STUB_DIR="$TMP_ROOT/bin"
mkdir -p "$STUB_DIR"

# Cross-subshell tallies (subshell-local variables would not propagate).
PASSED_FILE="$TMP_ROOT/passed"
FAILED_FILE="$TMP_ROOT/failed"
: >"$PASSED_FILE"
: >"$FAILED_FILE"

# `security` stub. Behaviour driven by env vars so each case configures it:
#   STUB_TOKEN  — value to print for `find-generic-password ... -w`
#   STUB_FAIL=1 — exit non-zero with no output (item-not-found)
#   STUB_MARKER — file the stub touches on every invocation (call detection)
cat >"$STUB_DIR/security" <<'STUB'
#!/usr/bin/env bash
[[ -n "${STUB_MARKER:-}" ]] && : >"$STUB_MARKER"
if [[ "${STUB_FAIL:-0}" == "1" ]]; then
  exit 44
fi
printf '%s' "${STUB_TOKEN:-}"
STUB
chmod +x "$STUB_DIR/security"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf '%s\n' "$1" >>"$FAILED_FILE"
}
ok() {
  printf 'ok: %s\n' "$1"
  printf '%s\n' "$1" >>"$PASSED_FILE"
}

# Run the resolver in the current shell. Captures stdout+stderr to a file (a
# redirect, not a subshell) so any export survives for inspection. Sets
# RESULT_TOKEN, RESULT_OUTPUT, RESULT_CALLED.
run_resolver() {
  local out_file="$TMP_ROOT/out"
  local marker="$TMP_ROOT/called"
  rm -f "$marker"
  unset CLAUDE_CODE_OAUTH_TOKEN
  if [[ -n "${PRESET:-}" ]]; then
    export CLAUDE_CODE_OAUTH_TOKEN="$PRESET"
  fi

  STUB_MARKER="$marker" aidc::resolve_claude_oauth_token >"$out_file" 2>&1

  RESULT_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}"
  RESULT_OUTPUT="$(cat "$out_file")"
  RESULT_CALLED=0
  if [[ -f "$marker" ]]; then
    RESULT_CALLED=1
  fi
  return 0
}

# 1. Token already in the environment: left untouched, Keychain never read.
(
  export PATH="$STUB_DIR:$PATH"
  export STUB_TOKEN="$FAKE_TOKEN"
  PRESET="preset-value"
  run_resolver
  if [[ "$RESULT_TOKEN" == "preset-value" && "$RESULT_CALLED" -eq 0 ]]; then
    ok "preset env token is preserved"
  else
    fail "preset case: token='$RESULT_TOKEN' called=$RESULT_CALLED"
  fi
)

# 2. Unset + stub returns a token: exported with that exact value, no leak.
(
  export PATH="$STUB_DIR:$PATH"
  export STUB_TOKEN="$FAKE_TOKEN"
  run_resolver
  if [[ "$RESULT_TOKEN" == "$FAKE_TOKEN" && "$RESULT_CALLED" -eq 1 && "$RESULT_OUTPUT" != *"$FAKE_TOKEN"* ]]; then
    ok "token resolved from Keychain without leaking to output"
  else
    fail "resolve case: token='$RESULT_TOKEN' called=$RESULT_CALLED output='$RESULT_OUTPUT'"
  fi
)

# 3. Unset + stub returns empty: variable stays unset, no crash.
(
  export PATH="$STUB_DIR:$PATH"
  export STUB_TOKEN=""
  run_resolver
  if [[ -z "$RESULT_TOKEN" ]]; then
    ok "empty Keychain result leaves token unset"
  else
    fail "empty case: unexpected token '$RESULT_TOKEN'"
  fi
)

# 4. Unset + stub exits non-zero: variable stays unset, no crash under set -e.
(
  export PATH="$STUB_DIR:$PATH"
  export STUB_TOKEN="$FAKE_TOKEN"
  export STUB_FAIL=1
  run_resolver
  if [[ -z "$RESULT_TOKEN" ]]; then
    ok "failed Keychain lookup is handled gracefully"
  else
    fail "failed-lookup case: unexpected token '$RESULT_TOKEN'"
  fi
)

# 5. Lookup disabled via empty service name: skipped, stub never called.
(
  export PATH="$STUB_DIR:$PATH"
  export STUB_TOKEN="$FAKE_TOKEN"
  export AIDC_CLAUDE_OAUTH_KEYCHAIN_SERVICE=""
  run_resolver
  if [[ -z "$RESULT_TOKEN" && "$RESULT_CALLED" -eq 0 ]]; then
    ok "empty service name disables the lookup"
  else
    fail "disabled case: token='$RESULT_TOKEN' called=$RESULT_CALLED"
  fi
)

# 6. Key removed from passthrough list (per-project opt-out): skipped.
(
  export PATH="$STUB_DIR:$PATH"
  export STUB_TOKEN="$FAKE_TOKEN"
  # Read indirectly by the sourced resolver, so shellcheck can't see the use.
  # shellcheck disable=SC2034
  AIDC_PASSTHROUGH_ENV_KEYS=("OPENAI_API_KEY")
  run_resolver
  if [[ -z "$RESULT_TOKEN" && "$RESULT_CALLED" -eq 0 ]]; then
    ok "dropping key from passthrough disables resolution"
  else
    fail "opt-out case: token='$RESULT_TOKEN' called=$RESULT_CALLED"
  fi
)

# 7. `security` not on PATH (e.g. non-macOS host): no-op, no error.
(
  empty_path="$TMP_ROOT/empty-path"
  mkdir -p "$empty_path"
  export PATH="$empty_path"
  unset CLAUDE_CODE_OAUTH_TOKEN
  aidc::resolve_claude_oauth_token >/dev/null 2>&1
  if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
    ok "missing security tool is a clean no-op"
  else
    fail "missing-tool case: unexpected token '${CLAUDE_CODE_OAUTH_TOKEN:-}'"
  fi
)

PASS_COUNT="$(wc -l <"$PASSED_FILE" | tr -d ' ')"
FAIL_COUNT="$(wc -l <"$FAILED_FILE" | tr -d ' ')"
printf '\n%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
