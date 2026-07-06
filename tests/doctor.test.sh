#!/usr/bin/env bash
#
# Unit tests for aidc doctor (lib/aidc.sh): individual check functions with
# stubbed docker/security binaries, output format, and aggregate exit code.
#
# Run with: bash tests/doctor.test.sh
# shellcheck disable=SC2034,SC1091,SC2030,SC2031,SC2317
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

. "$REPO_ROOT/lib/aidc.sh"
AIDC_ROOT="$REPO_ROOT"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
STUB_DIR="$TMP_ROOT/bin"
mkdir -p "$STUB_DIR"

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

reset_counts() { AIDC_DOCTOR_FAILS=0; AIDC_DOCTOR_WARNS=0; }

# 1. Report lines carry the status prefix and bump the right counter.
reset_counts
out="$(aidc::doctor_report ok t "fine"; aidc::doctor_report warn t "meh"; aidc::doctor_report fail t "broken")"
# counters were bumped in a subshell above — redo in-shell:
reset_counts
aidc::doctor_report warn t "meh" >/dev/null
aidc::doctor_report fail t "broken" >/dev/null
if printf '%s' "$out" | grep -q '^  OK ' && printf '%s' "$out" | grep -q '^  WARN ' \
   && printf '%s' "$out" | grep -q '^  FAIL ' \
   && [[ "$AIDC_DOCTOR_WARNS" -eq 1 && "$AIDC_DOCTOR_FAILS" -eq 1 ]]; then
  ok "doctor_report format + counters"
else
  fail "doctor_report: out='$out' warns=$AIDC_DOCTOR_WARNS fails=$AIDC_DOCTOR_FAILS"
fi

# 2. docker check: missing CLI -> FAIL; responding daemon -> OK; dead daemon -> FAIL.
reset_counts
out="$(PATH="$STUB_DIR" aidc::doctor_check_docker)"
if printf '%s' "$out" | grep -q 'FAIL.*docker.*CLI not found'; then
  ok "docker missing CLI -> FAIL"
else
  fail "docker missing CLI: $out"
fi
printf '#!/usr/bin/env bash\nexit 0\n' >"$STUB_DIR/docker"; chmod +x "$STUB_DIR/docker"
out="$(PATH="$STUB_DIR:$PATH" aidc::doctor_check_docker)"
if printf '%s' "$out" | grep -q 'OK.*docker'; then
  ok "docker responding -> OK"
else
  fail "docker responding: $out"
fi
printf '#!/usr/bin/env bash\nexit 1\n' >"$STUB_DIR/docker"
out="$(PATH="$STUB_DIR:$PATH" aidc::doctor_check_docker)"
if printf '%s' "$out" | grep -q 'FAIL.*daemon not responding'; then
  ok "docker dead daemon -> FAIL"
else
  fail "docker dead daemon: $out"
fi
rm -f "$STUB_DIR/docker"

# 3. PATH check.
out="$(AIDC_BIN_DIR="$TMP_ROOT/somebin" PATH="/usr/bin" aidc::doctor_check_path)"
if printf '%s' "$out" | grep -q 'WARN.*not on PATH'; then
  ok "bin dir off PATH -> WARN"
else
  fail "path warn case: $out"
fi
out="$(AIDC_BIN_DIR="$TMP_ROOT/somebin" PATH="$TMP_ROOT/somebin:/usr/bin" aidc::doctor_check_path)"
if printf '%s' "$out" | grep -q 'OK.*on PATH'; then
  ok "bin dir on PATH -> OK"
else
  fail "path ok case: $out"
fi

# 4. Keychain check with stubbed `security`.
cat >"$STUB_DIR/security" <<'STUB'
#!/usr/bin/env bash
[[ "${STUB_KEYCHAIN_HAS:-0}" == "1" ]] && exit 0
exit 44
STUB
chmod +x "$STUB_DIR/security"
out="$(PATH="$STUB_DIR:$PATH" STUB_KEYCHAIN_HAS=1 CLAUDE_CODE_OAUTH_TOKEN="" aidc::doctor_check_keychain)"
if printf '%s' "$out" | grep -q 'OK.*token present'; then
  ok "keychain token present -> OK"
else
  fail "keychain present case: $out"
fi
out="$(PATH="$STUB_DIR:$PATH" STUB_KEYCHAIN_HAS=0 CLAUDE_CODE_OAUTH_TOKEN="" aidc::doctor_check_keychain)"
if printf '%s' "$out" | grep -q 'WARN.*no token in Keychain'; then
  ok "keychain token absent -> WARN"
else
  fail "keychain absent case: $out"
fi
if printf '%s' "$out" | grep -qi 'sk-ant'; then
  fail "keychain output leaked token material"
else
  ok "keychain output never contains token material"
fi
rm -f "$STUB_DIR/security"

# 5. Scaffold-version stamp comparison.
ws="$TMP_ROOT/ws"
mkdir -p "$ws/.ai-container"
printf 'AIDC_VERSION=%s\n' "$AIDC_VERSION" >"$ws/.ai-container/project.env"
out="$(aidc::doctor_check_scaffold_version "$ws")"
if printf '%s' "$out" | grep -q 'OK.*current aidc'; then
  ok "matching stamp -> OK"
else
  fail "matching stamp: $out"
fi
printf 'AIDC_VERSION=0.0.1\n' >"$ws/.ai-container/project.env"
out="$(aidc::doctor_check_scaffold_version "$ws")"
if printf '%s' "$out" | grep -q "WARN.*aidc upgrade"; then
  ok "stale stamp -> WARN + upgrade hint"
else
  fail "stale stamp: $out"
fi

# 6. project.env parse check.
printf 'AIDC_VERSION=0.0.1\n' >"$ws/.ai-container/project.env"
if aidc::doctor_check_project_env "$ws" >/dev/null; then
  ok "clean project.env passes"
else
  fail "clean project.env rejected"
fi
printf 'AIDC_BROKEN="$UNDEFINED_VARIABLE_XYZ"\n' >>"$ws/.ai-container/project.env"
reset_counts
if aidc::doctor_check_project_env "$ws" >/dev/null; then
  fail "broken project.env accepted"
else
  ok "broken project.env fails (and gates deeper checks)"
fi

# 7. Aggregate: any FAIL -> cmd_doctor exits 1; none -> exits 0.
aidc::default_workspace() { printf '%s\n' "$TMP_ROOT/empty-ws"; }
mkdir -p "$TMP_ROOT/empty-ws"
aidc::doctor_check_git()      { aidc::doctor_report ok git "stub"; }
aidc::doctor_check_docker()   { aidc::doctor_report ok docker "stub"; }
aidc::doctor_check_path()     { aidc::doctor_report ok path "stub"; }
aidc::doctor_check_install()  { aidc::doctor_report ok install "stub"; }
aidc::doctor_check_keychain() { aidc::doctor_report ok keychain "stub"; }
if aidc::cmd_doctor >/dev/null; then
  ok "all-OK doctor exits 0"
else
  fail "all-OK doctor exited non-zero"
fi
aidc::doctor_check_docker() { aidc::doctor_report fail docker "stub broken"; }
if aidc::cmd_doctor >/dev/null; then
  fail "failing doctor exited 0"
else
  ok "failing doctor exits non-zero"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
