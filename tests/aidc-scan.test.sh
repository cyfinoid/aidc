#!/usr/bin/env bash
#
# Unit tests for the scaffolded aidc-scan script
# (templates/devcontainer/scripts/aidc-scan.sh.tmpl).
#
# Every scanner is stubbed on a restricted PATH (stubs + /usr/bin:/bin only,
# so the container's real scanners can't leak in); a throwaway git repo
# provides the change scope. Run with: bash tests/aidc-scan.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCAN="$REPO_ROOT/templates/devcontainer/scripts/aidc-scan.sh.tmpl"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

STUB_DIR="$TMP_ROOT/bin"
CALL_LOG="$TMP_ROOT/calls.log"
mkdir -p "$STUB_DIR"

for tool in semgrep gitleaks shellcheck bandit gosec cargo-audit cargo bundle-audit npm vet; do
  cat >"$STUB_DIR/$tool" <<STUB
#!/usr/bin/env bash
echo "$tool \$*" >>"\$CALL_LOG"
var="STUB_EXIT_$(echo "$tool" | tr 'a-z-' 'A-Z_')"
exit "\${!var:-0}"
STUB
  chmod +x "$STUB_DIR/$tool"
done

RESTRICTED_PATH="$STUB_DIR:/usr/bin:/bin"

# Throwaway repo with a committed baseline.
WS="$TMP_ROOT/repo"
mkdir -p "$WS"
git -C "$WS" init -q
git -C "$WS" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'print("hi")\n' >"$WS/app.py"
printf '#!/usr/bin/env bash\necho hi\n' >"$WS/run.sh"
printf '{"name":"x","version":"0.0.0"}\n' >"$WS/package.json"
git -C "$WS" add -A
git -C "$WS" -c user.email=t@t -c user.name=t commit -q -m baseline

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

run_scan() { # args…
  : >"$CALL_LOG"
  (cd "$WS" && PATH="$RESTRICTED_PATH" CALL_LOG="$CALL_LOG" bash "$SCAN" "$@")
}

# 1. Code-only change: semgrep gets both files, shellcheck the .sh, bandit
#    the .py; gosec/vet/license stay out of scope. Exit 0.
printf 'print("more")\n' >>"$WS/app.py"
printf 'echo more\n' >>"$WS/run.sh"
out="$(run_scan)" || fail "clean scoped scan exited non-zero"
grep -q 'semgrep .*app.py' "$CALL_LOG" && grep -q 'semgrep .*run.sh' "$CALL_LOG" \
  && ok "semgrep scoped to changed files" || fail "semgrep scope: $(grep semgrep "$CALL_LOG")"
grep -q '^shellcheck --severity=warning run.sh' "$CALL_LOG" \
  && ok "shellcheck gets the changed shell file" || fail "shellcheck: $(grep shellcheck "$CALL_LOG" || true)"
grep -q '^bandit -q -ll app.py' "$CALL_LOG" \
  && ok "bandit gets the changed python file" || fail "bandit: $(grep bandit "$CALL_LOG" || true)"
if grep -q '^gosec' "$CALL_LOG" || grep -q '^vet' "$CALL_LOG"; then
  fail "out-of-scope scanner ran: $(grep -E '^(gosec|vet)' "$CALL_LOG")"
else
  ok "out-of-scope scanners (gosec/vet) not run"
fi
printf '%s' "$out" | grep -q 'vet:.*skipped' \
  && ok "skips are reported in the summary" || fail "summary: $out"

# 2. Manifest change brings in npm-audit + vet.
git -C "$WS" -c user.email=t@t -c user.name=t commit -qam wip
printf '{"name":"x","version":"0.0.1"}\n' >"$WS/package.json"
run_scan >/dev/null || fail "manifest-change scan exited non-zero"
grep -q '^npm audit --omit=dev' "$CALL_LOG" \
  && ok "npm audit on package.json change" || fail "npm audit missing"
grep -q '^vet scan -D .' "$CALL_LOG" \
  && ok "vet on manifest change" || fail "vet missing"

# 3. Findings propagate: scanner exit 1 -> aidc-scan exit 1.
rc=0
out="$(STUB_EXIT_SEMGREP=1 run_scan 2>&1)" || rc=$?
if [[ "$rc" -eq 1 ]] && printf '%s' "$out" | grep -q 'semgrep:.*findings'; then
  ok "findings propagate to exit 1 with a named scanner"
else
  fail "propagation: rc=$rc out=$out"
fi

# 4. --json is valid JSON with the failure count.
out="$(STUB_EXIT_SEMGREP=1 run_scan --json 2>/dev/null)" || true
if printf '%s' "$out" | jq -e '.failures == 1 and (.scanners | length) > 3' >/dev/null 2>&1; then
  ok "--json emits valid JSON with failure count"
else
  fail "--json output: $out"
fi

# 5. --all scans the repo, not a file list.
run_scan --all >/dev/null || fail "--all scan exited non-zero"
grep -qE '^semgrep .* \.$' "$CALL_LOG" \
  && ok "--all points semgrep at the repo root" || fail "--all semgrep: $(grep semgrep "$CALL_LOG")"

# 6. Missing scanner is a skip, not a failure.
rm "$STUB_DIR/bandit"
printf 'print("again")\n' >>"$WS/app.py"
out="$(run_scan)" || fail "scan with missing scanner exited non-zero"
printf '%s' "$out" | grep -q 'bandit:.*skipped.*not installed' \
  && ok "missing scanner reported as skipped" || fail "missing scanner: $out"
cp "$STUB_DIR/semgrep" "$STUB_DIR/bandit"   # restore (same stub shape)
sed_i_tmp="$(mktemp)"; sed 's/semgrep/bandit/g' "$STUB_DIR/bandit" >"$sed_i_tmp" && mv "$sed_i_tmp" "$STUB_DIR/bandit"; chmod +x "$STUB_DIR/bandit"

# 7. --staged scopes to the index and uses gitleaks protect.
git -C "$WS" -c user.email=t@t -c user.name=t commit -qam wip2
printf 'echo staged\n' >>"$WS/run.sh"
printf 'print("unstaged")\n' >>"$WS/app.py"
git -C "$WS" add run.sh
run_scan --staged >/dev/null || fail "--staged scan exited non-zero"
if grep -q '^semgrep .*run.sh' "$CALL_LOG" && ! grep -q '^semgrep .*app.py' "$CALL_LOG"; then
  ok "--staged scopes to the index only"
else
  fail "--staged scope: $(grep semgrep "$CALL_LOG")"
fi
grep -q '^gitleaks protect --staged' "$CALL_LOG" \
  && ok "--staged uses gitleaks protect" || fail "gitleaks staged: $(grep gitleaks "$CALL_LOG")"

# 8. Unknown flag exits 2.
rc=0
run_scan --bogus >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] && ok "unknown flag exits 2" || fail "unknown flag: rc=$rc"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
