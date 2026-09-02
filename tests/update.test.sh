#!/usr/bin/env bash
#
# Unit tests for aidc update (lib/aidc.sh) with a stubbed `git` and a fixture
# AIDC_ROOT. No network, no real pulls.
#
# Run with: bash tests/update.test.sh
# shellcheck disable=SC2034,SC1091,SC2030,SC2031
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

. "$REPO_ROOT/lib/aidc.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
STUB_DIR="$TMP_ROOT/bin"
mkdir -p "$STUB_DIR"

# git stub, behavior via env:
#   STUB_GIT_IS_REPO=0  -> rev-parse --git-dir fails
#   STUB_GIT_FF_FAILS=1 -> pull --ff-only fails
cat >"$STUB_DIR/git" <<'STUB'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"rev-parse --git-dir"*)   [[ "${STUB_GIT_IS_REPO:-1}" == "1" ]] && { echo .git; exit 0; } || exit 128 ;;
  *"rev-parse --short HEAD"*) echo abc1234; exit 0 ;;
  *"pull --ff-only"*)         [[ "${STUB_GIT_FF_FAILS:-0}" == "1" ]] && exit 1 || { echo "Already up to date."; exit 0; } ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$STUB_DIR/git"
export PATH="$STUB_DIR:$PATH"

# Fixture aidc root with a version line and a marker-dropping install.sh. The
# canonical AIDC_VERSION lives in lib/aidc/common.sh (that's what aidc update
# re-reads for the post-pull version).
FIXTURE_ROOT="$TMP_ROOT/aidc-root"
mkdir -p "$FIXTURE_ROOT/lib/aidc"
printf 'AIDC_VERSION="${AIDC_VERSION:-9.9.9}"\n' >"$FIXTURE_ROOT/lib/aidc/common.sh"
cat >"$FIXTURE_ROOT/install.sh" <<'EOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/.install-ran"
EOF
chmod +x "$FIXTURE_ROOT/install.sh"

AIDC_ROOT="$FIXTURE_ROOT"
aidc::default_workspace() { printf '%s\n' "$TMP_ROOT/no-project"; }
mkdir -p "$TMP_ROOT/no-project"

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

# 1. Not a git checkout: refuse with guidance.
out=""
rc=0
out="$( (STUB_GIT_IS_REPO=0 aidc::cmd_update) 2>&1 )" || rc=$?
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'not a git checkout'; then
  ok "non-checkout install refused"
else
  fail "non-checkout: rc=$rc out=$out"
fi

# 2. Non-fast-forward pull: die with manual-resolution hint, install.sh NOT run.
rm -f "$FIXTURE_ROOT/.install-ran"
rc=0
out="$( (STUB_GIT_FF_FAILS=1 aidc::cmd_update) 2>&1 )" || rc=$?
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'fast-forward pull failed'; then
  ok "diverged checkout refused"
else
  fail "ff-fail: rc=$rc out=$out"
fi
if [[ ! -f "$FIXTURE_ROOT/.install-ran" ]]; then
  ok "install.sh not run after failed pull"
else
  fail "install.sh ran despite failed pull"
fi

# 3. Happy path: pull, install.sh runs, old -> new version reported.
rc=0
out="$( (aidc::cmd_update) 2>&1 )" || rc=$?
if [[ "$rc" -eq 0 && -f "$FIXTURE_ROOT/.install-ran" ]]; then
  ok "happy path pulls and reruns install.sh"
else
  fail "happy path: rc=$rc install-ran=$([[ -f "$FIXTURE_ROOT/.install-ran" ]] && echo y || echo n)"
fi
if printf '%s' "$out" | grep -q 'updated: .* -> 9.9.9'; then
  ok "old -> new version reported"
else
  fail "version report missing: $out"
fi

# 4. Inside an aidc project: the follow-up hint appears.
mkdir -p "$TMP_ROOT/with-project/.ai-container"
touch "$TMP_ROOT/with-project/.ai-container/project.env"
aidc::default_workspace() { printf '%s\n' "$TMP_ROOT/with-project"; }
out="$( (aidc::cmd_update) 2>&1 )" || true
if printf '%s' "$out" | grep -q "aidc upgrade"; then
  ok "post-update upgrade hint shown inside a project"
else
  fail "upgrade hint missing: $out"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
