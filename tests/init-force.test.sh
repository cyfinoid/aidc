#!/usr/bin/env bash
#
# Unit tests for `aidc init` conflict handling and the -f/--force escape hatch,
# plus the namespacing invariants that keep aidc's scaffolded scripts/ci/*.sh
# from colliding with a project's own CI scripts.
#
#   - check_init_conflicts fires (and names the file) on a pre-existing
#     aidc-managed path, and passes when only a legacy unprefixed file exists.
#   - `aidc init` without --force stops on a conflict; with --force it adopts
#     the directory and refreshes the scaffold anyway.
#   - unknown init flags are rejected.
#   - every scripts/ci entry is aidc-namespaced and every template in the
#     overwrite map exists on disk (map/file drift guard).
#
# The docker/git/core-repo machinery cmd_init drives is stubbed so the test is
# hermetic and needs neither Docker nor network.
#
# Run with: bash tests/init-force.test.sh
# shellcheck disable=SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

. "$REPO_ROOT/lib/aidc.sh"

# ── 1. check_init_conflicts fires on a pre-existing managed path ──
ws="$TMP_ROOT/conflict"
mkdir -p "$ws/scripts/ci"
: >"$ws/scripts/ci/aidc-lib-common.sh"
out="$( (aidc::check_init_conflicts "$ws") 2>&1 )" && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]] \
   && printf '%s' "$out" | grep -q 'refusing to overwrite' \
   && printf '%s' "$out" | grep -q 'scripts/ci/aidc-lib-common.sh'; then
  ok "conflict on a managed path stops init and names the file"
else
  fail "expected a named conflict, got rc=$rc: $out"
fi

# ── 2. a project's own legacy-named scripts/ci file no longer collides ──
ws="$TMP_ROOT/legacy"
mkdir -p "$ws/scripts/ci"
: >"$ws/scripts/ci/lib-common.sh"   # the exact path that used to break init
if (aidc::check_init_conflicts "$ws") >/dev/null 2>&1; then
  ok "a project's own unprefixed scripts/ci/lib-common.sh is not a conflict"
else
  fail "namespacing regression: unprefixed lib-common.sh still trips the guard"
fi

# Stub the docker/git/core-repo machinery so cmd_init is hermetic. Function
# names resolve at call time, so redefining after sourcing is enough.
REFRESH_CALLED=0
aidc::need_cmd() { :; }
aidc::ensure_host_config_dirs() { :; }
aidc::ensure_claude_profile_examples() { :; }
aidc::sync_claude_aliases() { :; }
aidc::repo_slug() { printf 'fixture-00000000\n'; }
aidc::ensure_core_repo() { :; }
aidc::core_root() { printf '%s\n' "$TMP_ROOT/core"; }
aidc::ensure_core_worktree() { printf '%s\n' "$TMP_ROOT/wt"; }
aidc::refresh_scaffold() { REFRESH_CALLED=1; }
aidc::ensure_local_git_excludes() { :; }
aidc::log() { :; }

# ── 3. cmd_init without --force stops on a conflict ──
ws="$TMP_ROOT/init-noforce"
mkdir -p "$ws/scripts/ci"
: >"$ws/scripts/ci/aidc-sbom-all.sh"
REFRESH_CALLED=0
out="$( (aidc::cmd_init "$ws") 2>&1 )" && rc=0 || rc=$?
if [[ "$rc" -ne 0 && "$REFRESH_CALLED" -eq 0 ]] \
   && printf '%s' "$out" | grep -q 'refusing to overwrite'; then
  ok "init without --force refuses a dir with a pre-existing managed file"
else
  fail "expected refusal, got rc=$rc refresh=$REFRESH_CALLED: $out"
fi

# ── 4. cmd_init --force adopts the dir and refreshes the scaffold ──
for flagpos in "before" "after"; do
  ws="$TMP_ROOT/init-force-$flagpos"
  mkdir -p "$ws/scripts/ci"
  : >"$ws/scripts/ci/aidc-sbom-all.sh"
  REFRESH_CALLED=0
  if [[ "$flagpos" == "before" ]]; then
    (aidc::cmd_init --force "$ws") >/dev/null 2>&1 && rc=0 || rc=$?
  else
    (aidc::cmd_init "$ws" -f) >/dev/null 2>&1 && rc=0 || rc=$?
  fi
  # cmd_init runs in a subshell, so read REFRESH_CALLED via a re-run that
  # echoes it (the subshell above can't mutate our REFRESH_CALLED).
  probe="$( if [[ "$flagpos" == "before" ]]; then
              aidc::cmd_init --force "$ws" >/dev/null 2>&1
            else
              aidc::cmd_init "$ws" -f >/dev/null 2>&1
            fi; printf '%s' "$REFRESH_CALLED" )"
  if [[ "$rc" -eq 0 && "$probe" -eq 1 ]]; then
    ok "init --force ($flagpos path) adopts the dir and refreshes"
  else
    fail "force ($flagpos): rc=$rc refresh=$probe"
  fi
done

# ── 5. unknown init flag is rejected ──
out="$( (aidc::cmd_init --bogus) 2>&1 )" && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'unknown init flag'; then
  ok "unknown init flag is rejected"
else
  fail "expected unknown-flag error, got rc=$rc: $out"
fi

# ── 6. namespacing + map/file drift guard ──
drift=0
for p in "${AIDC_MANAGED_PATHS[@]}"; do
  case "$p" in
    scripts/ci/*)
      case "$p" in
        scripts/ci/aidc-*) ;;
        *) fail "managed scripts/ci path is not aidc-namespaced: $p"; drift=1 ;;
      esac
      ;;
  esac
done
for entry in "${AIDC_OVERWRITE_TEMPLATE_MAP[@]}"; do
  tmpl="${entry%%:*}"
  if [[ ! -f "$REPO_ROOT/$tmpl" ]]; then
    fail "overwrite map references a missing template: $tmpl"; drift=1
  fi
done
[[ "$drift" -eq 0 ]] && ok "all scripts/ci paths namespaced and every mapped template exists"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
