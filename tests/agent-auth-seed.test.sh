#!/usr/bin/env bash
#
# Unit tests for the agent credential-seed wiring in
# templates/devcontainer/scripts/bootstrap-state.sh.tmpl. The script is
# source-safe (its init/sync dispatch is guarded by a BASH_SOURCE check), so we
# source it, stub the copy primitives to record (source -> target) pairs, and
# assert each sync_<agent> seeds its real credential store — in particular that
# opencode's auth lands in the XDG *data* dir, and that cursor seeds settings
# only (its token is Keychain-bound, not seedable).
#
# Run with: bash tests/agent-auth-seed.test.sh
# shellcheck disable=SC2034,SC1090,SC1091,SC2317
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMPL="$REPO_ROOT/templates/devcontainer/scripts/bootstrap-state.sh.tmpl"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

# Source the bootstrap script with a controlled HOME; the guarded dispatch does
# not run on source.
export AIDC_CONTAINER_HOME="$TMP_ROOT/home"
mkdir -p "$AIDC_CONTAINER_HOME"
. "$TMPL"

# Behavioral checks for the real sync_file_from_seed, run BEFORE the copy
# primitives below are replaced with recorders. The function is defined by
# the sourced template above — the later in-file definition is the recorder
# stub, so SC2218 (definition later in file) is expected and suppressed at
# each call site.
SEED="$TMP_ROOT/seed"
VOL="$TMP_ROOT/vol"
mkdir -p "$SEED" "$VOL"
printf '%s' '{"apiKey":"rotated"}' >"$SEED/cred.json"
printf '%s' '{"apiKey":"stale"}'   >"$VOL/cred.json"

# 0a. A host seed overwrites an existing (stale) volume copy — the every-start
#     re-seed contract; also confirms the exact 0600 mode (bits-set is not
#     enough: find -perm 0600 also matches 0644/0666).
# shellcheck disable=SC2218
sync_file_from_seed "$SEED/cred.json" "$VOL/cred.json" "0600"
cred_mode="$(stat -c '%a' "$VOL/cred.json" 2>/dev/null || stat -f '%Lp' "$VOL/cred.json")"
if [[ "$(cat "$VOL/cred.json")" == '{"apiKey":"rotated"}' ]] \
   && [[ "$cred_mode" == "600" ]]; then
  ok "sync_file_from_seed: host seed overwrites a stale volume copy (exactly 0600)"
else
  fail "sync_file_from_seed: volume copy not refreshed from host seed (mode=$cred_mode)"
fi

# 0b. A missing host seed is a no-op — in-container-only state (a login made
#     inside the container with no host counterpart) survives.
rm "$SEED/cred.json"
# shellcheck disable=SC2218
sync_file_from_seed "$SEED/cred.json" "$VOL/cred.json" "0600"
if [[ "$(cat "$VOL/cred.json")" == '{"apiKey":"rotated"}' ]]; then
  ok "sync_file_from_seed: missing host seed is a no-op (volume copy kept)"
else
  fail "sync_file_from_seed: missing host seed clobbered the volume copy"
fi

# 0c. An unwritable target degrades to warn-and-continue — bootstrap-state.sh
#     is the container start command, so a failed cp must keep the stale copy
#     and report, never kill the session under `set -e`. cp is shadowed with a
#     failing function (call-time resolution beats the binary), restored after.
printf '%s' '{"apiKey":"rotated-v2"}' >"$SEED/cred.json"
cp() { return 1; }
# shellcheck disable=SC2218
seed_fail_out="$(sync_file_from_seed "$SEED/cred.json" "$VOL/cred.json" "0600" 2>&1)"
unset -f cp
if [[ "$(cat "$VOL/cred.json")" == '{"apiKey":"rotated"}' ]] \
   && printf '%s' "$seed_fail_out" | grep -q 'could not re-seed'; then
  ok "sync_file_from_seed: unwritable target warns and keeps the volume copy"
else
  fail "sync_file_from_seed: failed cp did not degrade safely (out: $seed_fail_out)"
fi

# 0d. Mode independence is structural: no reference to $mode anywhere in the
#     helper (copy_file_from_seed's init-once skip is exactly what must NOT
#     reappear here). mode_ref holds the literal '$mode' — single-quoted on
#     purpose, we are grepping for the dollar sign, not expanding (SC2016).
mode_ref='$mode'
if awk '/^sync_file_from_seed\(\)/,/^}/' "$TMPL" | grep -qF -- "$mode_ref"; then
  fail "sync_file_from_seed must be mode-independent (found \$mode)"
else
  ok "sync_file_from_seed is mode-independent"
fi

# Replace the copy primitives with recorders (call-time resolved, so this wins).
CALLS=""
ensure_dir() { :; }
copy_file_from_seed() { CALLS+="FILE|$1|$2"$'\n'; }
sync_file_from_seed() { CALLS+="SYNC|$1|$2"$'\n'; }
copy_dir_from_seed()  { CALLS+="DIR|$1|$2"$'\n'; }
# sync_claude also runs these real file/python helpers — neutralize them so the
# seed wiring is all we exercise. Any helper sync_claude gains must be added
# here: with copy_file_from_seed and ensure_dir stubbed out, settings.json and
# its parent directory never exist, so a real helper that writes to that path
# dies on FileNotFoundError and takes the suite down with it under `set -e`.
strip_host_hooks() { :; }
ensure_agent_guardrail_settings() { :; }
ensure_rtk_session_end_settings() { :; }
ensure_opencode_permissions() { :; }
# wire_aidc_review_cursor writes ~/.cursor/hooks.json through python with a
# mkdir done by ensure_dir — stubbed here — so the real helper would die on a
# missing parent directory. The review-gate wiring has its own coverage in
# tests/review-hook.test.sh.
wire_aidc_review_cursor() { :; }

seeds() { printf '%s' "$CALLS" | grep -Fq "$1"; }
run()   { CALLS=""; "$1"; }

H="$AIDC_CONTAINER_HOME"

# 1. opencode seeds auth.json in the XDG DATA dir (the fix), plus its config.
#    Both go through sync_file_from_seed (SYNC records): credentials re-seed
#    from the host on every bootstrap, not just the first.
run sync_opencode
if seeds "SYNC|/host-seed/opencode-data/auth.json|$H/.local/share/opencode/auth.json"; then
  ok "sync_opencode re-seeds auth.json into ~/.local/share/opencode (data dir, every start)"
else
  fail "opencode auth re-seed missing:\n$CALLS"
fi
seeds "SYNC|/host-seed/opencode/opencode.json|$H/.config/opencode/opencode.json" \
  && ok "sync_opencode re-seeds opencode.json (config, every start)" || fail "opencode config re-seed missing"

# 2. codex/grok/omp seed their real credential files (regression guard).
run sync_codex
seeds "FILE|/host-seed/codex/auth.json|$H/.codex/auth.json" && ok "sync_codex seeds auth.json" || fail "codex auth: $CALLS"
run sync_grok
seeds "FILE|/host-seed/grok/auth.json|$H/.grok/auth.json" && ok "sync_grok seeds auth.json" || fail "grok auth: $CALLS"
run sync_omp
seeds "FILE|/host-seed/omp/agent/agent.db|$H/.omp/agent/agent.db" && ok "sync_omp seeds agent.db (auth store)" || fail "omp auth: $CALLS"

# 3. cursor seeds settings ONLY — never a token file (Keychain-bound).
run sync_cursor
if seeds "FILE|/host-seed/cursor/cli-config.json|$H/.cursor/cli-config.json" \
   && ! printf '%s' "$CALLS" | grep -Eiq "auth|token|credential"; then
  ok "sync_cursor seeds cli-config.json only (no token file)"
else
  fail "cursor seed unexpected:\n$CALLS"
fi

# 4. 'all' wires every agent, including the opencode data-dir auth.
CALLS=""; sync_tool all
seeds "SYNC|/host-seed/opencode-data/auth.json|$H/.local/share/opencode/auth.json" \
  && ok "sync_tool all includes opencode data-dir auth" || fail "all missing opencode-data auth"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
