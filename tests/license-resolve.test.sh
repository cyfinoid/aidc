#!/usr/bin/env bash
#
# Unit tests for sbom::resolve_project_license (scripts/ci/lib-common.sh).
#
# Pure/offline: no syft, no network. Run with:
#   bash tests/license-resolve.test.sh
#
# Each case runs in its own ( ... ) subshell so per-case env stays isolated.
# shellcheck disable=SC1091,SC2030,SC2031
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../scripts/ci/lib-common.sh
. "$REPO_ROOT/scripts/ci/lib-common.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASSED_FILE="$TMP_ROOT/passed"; : >"$PASSED_FILE"
FAILED_FILE="$TMP_ROOT/failed"; : >"$FAILED_FILE"
fail() { printf 'FAIL: %s\n' "$1" >&2; printf '%s\n' "$1" >>"$FAILED_FILE"; }
ok()   { printf 'ok: %s\n' "$1"; printf '%s\n' "$1" >>"$PASSED_FILE"; }

# 1. AIDC_PROJECT_LICENSE override always wins.
(
  d="$TMP_ROOT/override"; mkdir -p "$d"
  printf 'GNU GENERAL PUBLIC LICENSE\nVersion 3\n' >"$d/LICENSE"
  export AIDC_PROJECT_LICENSE="Apache-2.0"
  got="$(sbom::resolve_project_license "$d")"
  [[ "$got" == "Apache-2.0" ]] && ok "env override wins" || fail "override: got '$got'"
)

# 2. package.json license field is read.
(
  d="$TMP_ROOT/manifest"; mkdir -p "$d"
  printf '{"name":"x","license":"MIT"}\n' >"$d/package.json"
  got="$(sbom::resolve_project_license "$d")"
  [[ "$got" == "MIT" ]] && ok "package.json license resolved" || fail "manifest: got '$got'"
)

# 3. MIT LICENSE text heuristic (no manifest).
(
  d="$TMP_ROOT/mit"; mkdir -p "$d"
  printf 'MIT License\n\nPermission is hereby granted, free of charge, to any person\n' >"$d/LICENSE"
  got="$(sbom::resolve_project_license "$d")"
  [[ "$got" == "MIT" ]] && ok "MIT text heuristic" || fail "mit-text: got '$got'"
)

# 4. GPL-3.0 LICENSE text heuristic.
(
  d="$TMP_ROOT/gpl"; mkdir -p "$d"
  printf '                    GNU GENERAL PUBLIC LICENSE\n                       Version 3, 29 June 2007\n' >"$d/LICENSE"
  got="$(sbom::resolve_project_license "$d")"
  [[ "$got" == "GPL-3.0-only" ]] && ok "GPL-3.0 text heuristic" || fail "gpl-text: got '$got'"
)

# 5. Apache-2.0 LICENSE text heuristic.
(
  d="$TMP_ROOT/apache"; mkdir -p "$d"
  printf '                                 Apache License\n                           Version 2.0, January 2004\n' >"$d/LICENSE"
  got="$(sbom::resolve_project_license "$d")"
  [[ "$got" == "Apache-2.0" ]] && ok "Apache-2.0 text heuristic" || fail "apache-text: got '$got'"
)

# 6. Nothing to resolve: empty output, no crash under set -e.
(
  d="$TMP_ROOT/empty"; mkdir -p "$d"
  got="$(sbom::resolve_project_license "$d")"
  [[ -z "$got" ]] && ok "no license resolves to empty" || fail "empty: got '$got'"
)

PASS_COUNT="$(wc -l <"$PASSED_FILE" | tr -d ' ')"
FAIL_COUNT="$(wc -l <"$FAILED_FILE" | tr -d ' ')"
printf '\n%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
