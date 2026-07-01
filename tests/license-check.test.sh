#!/usr/bin/env bash
#
# Unit tests for scripts/ci/license-check.sh.
#
# Offline: feeds pre-baked SPDX SBOM fixtures via AIDC_LICENSE_SBOM so no syft
# or network is needed. Run with: bash tests/license-check.test.sh
#
# Each case runs in its own ( ... ) subshell so per-case env/dirs stay isolated.
# shellcheck disable=SC1091,SC2030,SC2031
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK="$REPO_ROOT/scripts/ci/license-check.sh"
FIX="$SCRIPT_DIR/fixtures"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASSED_FILE="$TMP_ROOT/passed"; : >"$PASSED_FILE"
FAILED_FILE="$TMP_ROOT/failed"; : >"$FAILED_FILE"
fail() { printf 'FAIL: %s\n' "$1" >&2; printf '%s\n' "$1" >>"$FAILED_FILE"; }
ok()   { printf 'ok: %s\n' "$1"; printf '%s\n' "$1" >>"$PASSED_FILE"; }

# Run license-check.sh with a fresh output dir; sets RC and REPORT.
# Args: <spdx-fixture> <project-license> <mode> [extra env assignments...]
run_check() {
  local spdx="$1" plicense="$2" mode="$3"; shift 3
  local outdir; outdir="$(mktemp -d)"
  RC=0
  env AIDC_SBOM_DIR="$outdir" \
      AIDC_LICENSE_SBOM="$spdx" \
      AIDC_PROJECT_LICENSE="$plicense" \
      AIDC_LICENSE_MODE="$mode" \
      "$@" \
      bash "$CHECK" >"$TMP_ROOT/out" 2>&1 || RC=$?
  REPORT="$outdir/license-report.json"
}

# 1. MIT project + GPL deps, warn mode: reports 2 conflicts but exits 0.
(
  run_check "$FIX/sample-project/code.spdx.json" "MIT" "warn"
  count="$(jq '.conflict_count' "$REPORT" 2>/dev/null || echo -1)"
  if [[ "$RC" -eq 0 && "$count" -eq 2 ]]; then
    ok "warn: 2 conflicts detected, exit 0"
  else
    fail "warn case: rc=$RC count=$count"
  fi
)

# 2. Same inputs, fail mode: exits 1.
(
  run_check "$FIX/sample-project/code.spdx.json" "MIT" "fail"
  count="$(jq '.conflict_count' "$REPORT" 2>/dev/null || echo -1)"
  if [[ "$RC" -eq 1 && "$count" -eq 2 ]]; then
    ok "fail: conflicts gate the build (exit 1)"
  else
    fail "fail case: rc=$RC count=$count"
  fi
)

# 3. Clean project (MIT + permissive deps): no conflicts even in fail mode.
(
  run_check "$FIX/clean-project/code.spdx.json" "MIT" "fail"
  count="$(jq '.conflict_count' "$REPORT" 2>/dev/null || echo -1)"
  if [[ "$RC" -eq 0 && "$count" -eq 0 ]]; then
    ok "clean project passes in fail mode"
  else
    fail "clean case: rc=$RC count=$count"
  fi
)

# 4. Wildcard rule: AGPL dep flagged regardless of project license.
(
  spdx="$TMP_ROOT/agpl.spdx.json"
  cat >"$spdx" <<'JSON'
{"packages":[
  {"name":"root","versionInfo":"1.0.0","licenseDeclared":"GPL-3.0-only"},
  {"name":"libnet","versionInfo":"9.9.9","licenseConcluded":"AGPL-3.0-only"}
]}
JSON
  run_check "$spdx" "GPL-3.0-only" "warn"
  lic="$(jq -r '.conflicts[0].license // ""' "$REPORT" 2>/dev/null || echo "")"
  if [[ "$lic" == "AGPL-3.0-only" ]]; then
    ok "wildcard '*' rule flags AGPL in any project"
  else
    fail "wildcard case: rc=$RC first-license='$lic'"
  fi
)

# 5. Invalid mode: usage error, exit 2.
(
  run_check "$FIX/clean-project/code.spdx.json" "MIT" "bogus"
  if [[ "$RC" -eq 2 ]]; then
    ok "invalid mode exits 2"
  else
    fail "invalid-mode case: rc=$RC"
  fi
)

PASS_COUNT="$(wc -l <"$PASSED_FILE" | tr -d ' ')"
FAIL_COUNT="$(wc -l <"$FAILED_FILE" | tr -d ' ')"
printf '\n%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
