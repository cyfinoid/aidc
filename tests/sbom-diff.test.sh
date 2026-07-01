#!/usr/bin/env bash
#
# Unit tests for scripts/ci/sbom-diff.sh.
#
# Offline: uses pre-baked CycloneDX fixtures. Run with:
#   bash tests/sbom-diff.test.sh
#
# Each case runs in its own ( ... ) subshell so per-case dirs stay isolated.
# shellcheck disable=SC1091,SC2030,SC2031
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIFF="$REPO_ROOT/scripts/ci/sbom-diff.sh"
FIX="$SCRIPT_DIR/fixtures/sbom-diff"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASSED_FILE="$TMP_ROOT/passed"; : >"$PASSED_FILE"
FAILED_FILE="$TMP_ROOT/failed"; : >"$FAILED_FILE"
fail() { printf 'FAIL: %s\n' "$1" >&2; printf '%s\n' "$1" >>"$FAILED_FILE"; }
ok()   { printf 'ok: %s\n' "$1"; printf '%s\n' "$1" >>"$PASSED_FILE"; }

# 1. Full diff: 1 added, 1 removed, 1 changed.
(
  outdir="$(mktemp -d)"
  cp "$FIX/code.cdx.json" "$outdir/code.cdx.json"
  cp "$FIX/image.cdx.json" "$outdir/image.cdx.json"
  rc=0
  AIDC_SBOM_DIR="$outdir" bash "$DIFF" >/dev/null 2>&1 || rc=$?
  s="$(jq -c '.summary' "$outdir/diff.json" 2>/dev/null || echo '{}')"
  if [[ "$rc" -eq 0 && "$s" == '{"added":1,"removed":1,"changed":1}' ]]; then
    ok "diff classifies added/removed/changed"
  else
    fail "full-diff case: rc=$rc summary=$s"
  fi
)

# 2. No build-time SBOM: clean no-op, no diff.json, exit 0.
(
  outdir="$(mktemp -d)"
  cp "$FIX/code.cdx.json" "$outdir/code.cdx.json"
  rc=0
  AIDC_SBOM_DIR="$outdir" bash "$DIFF" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 0 && ! -f "$outdir/diff.json" ]]; then
    ok "missing image SBOM is a clean skip"
  else
    fail "no-image case: rc=$rc diff-exists=$([[ -f "$outdir/diff.json" ]] && echo yes || echo no)"
  fi
)

# 3. Missing code SBOM: error, exit 2.
(
  outdir="$(mktemp -d)"
  cp "$FIX/image.cdx.json" "$outdir/image.cdx.json"
  rc=0
  AIDC_SBOM_DIR="$outdir" bash "$DIFF" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    ok "missing code SBOM exits 2"
  else
    fail "missing-code case: rc=$rc"
  fi
)

PASS_COUNT="$(wc -l <"$PASSED_FILE" | tr -d ' ')"
FAIL_COUNT="$(wc -l <"$FAILED_FILE" | tr -d ' ')"
printf '\n%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
