#!/usr/bin/env bash
#
# Unit tests for ensure_opencode_permissions in
# templates/devcontainer/scripts/bootstrap-state.sh.tmpl: the seed that stops
# opencode asking (every session — an "always" approval only lasts the current
# session) for the paths aidc workloads legitimately touch outside the
# workspace: /opt/CORE_LOGICS (shared guidance the AGENTS.md tells the agent
# to write), rtk's data dir, and /tmp scratch.
#
#   - seeds the three defaults into an empty/absent config
#   - never clobbers a user-set rule (deny/ask), keeps sibling rules, 0600
#   - knob off (AIDC_OPENCODE_SEED_PERMISSIONS=0) retracts only exact
#     owned allow-defaults
#   - AIDC_OPENCODE_EXTERNAL_ALLOW replaces the list; explicit empty disables
#   - idempotent: no rewrite when nothing changes
#   - invalid JSON recovers with defaults; no python3 -> fail open untouched
#   - sync_opencode wires the seed after the config copy (order matters:
#     the every-start host-seed overwrite of opencode.json drops the block)
#   - the v2 review-gate plugin keeps the event/API surface validated against
#     opencode 2.0.29 (structural smoke: turn-end triggers, per-session
#     serialization, v2 prompt shape, no v1-only call shapes)
#
# Run with: bash tests/opencode-permissions.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BOOTSTRAP="$REPO_ROOT/templates/devcontainer/scripts/bootstrap-state.sh.tmpl"
GATE="$REPO_ROOT/templates/devcontainer/scripts/aidc-review-gate-opencode.ts.tmpl"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 1; }

# Extract just the function under test so the fixture needs no container env.
sed -n '/^ensure_opencode_permissions()/,/^}/p' "$BOOTSTRAP" >"$TMP_ROOT/func.sh"
grep -q '^ensure_opencode_permissions()' "$TMP_ROOT/func.sh" \
  || { echo "could not extract ensure_opencode_permissions from template" >&2; exit 1; }

HOME_FIX="$TMP_ROOT/home"
CFG="$HOME_FIX/.config/opencode/opencode.json"

run_func() { # [ENV=V ...]
  env HOME="$HOME_FIX" "$@" bash -c \
    'source '"$TMP_ROOT"'/func.sh; home_dir='"$HOME_FIX"'; ensure_opencode_permissions'
}
write_cfg() { mkdir -p "$(dirname "$CFG")"; printf '%s' "$1" >"$CFG"; }

# 1. Empty config -> all three defaults seeded.
write_cfg '{}'
run_func AIDC_OPENCODE_SEED_PERMISSIONS=1
python3 - "$CFG" <<'PY' || fail "defaults not seeded"; ok "seeds three defaults into empty config"
import json, sys
e = json.load(open(sys.argv[1]))['permission']['external_directory']
assert e == {'/opt/CORE_LOGICS/**': 'allow', '~/.local/share/rtk/**': 'allow', '/tmp/**': 'allow'}, e
PY

# 2. Absent config -> created with defaults.
rm -f "$CFG"
run_func AIDC_OPENCODE_SEED_PERMISSIONS=1
python3 - "$CFG" <<'PY' || fail "absent config not created"; ok "creates missing config with defaults"
import json, sys, os
e = json.load(open(sys.argv[1]))['permission']['external_directory']
assert '/opt/CORE_LOGICS/**' in e and '~/.local/share/rtk/**' in e and '/tmp/**' in e
assert oct(os.stat(sys.argv[1]).st_mode)[-3:] == '600'
PY

# 3. User rules never clobbered; siblings kept; provider block kept; 0600.
write_cfg '{"provider":{"x":1},"permission":{"external_directory":{"/opt/CORE_LOGICS/**":"deny","~/custom":"ask"},"edit":{"*":"ask"}}}'
run_func AIDC_OPENCODE_SEED_PERMISSIONS=1
python3 - "$CFG" <<'PY' || fail "merge clobbered user rules"; ok "user deny respected, siblings and provider kept, 0600"
import json, sys, os
d = json.load(open(sys.argv[1]))
e = d['permission']['external_directory']
assert e['/opt/CORE_LOGICS/**'] == 'deny' and e['~/custom'] == 'ask', e
assert e['~/.local/share/rtk/**'] == 'allow' and e['/tmp/**'] == 'allow'
assert d['permission']['edit'] == {'*': 'ask'} and d['provider'] == {'x': 1}
assert oct(os.stat(sys.argv[1]).st_mode)[-3:] == '600'
PY

# 4. Knob off retracts only exact owned allow-defaults.
write_cfg '{"permission":{"external_directory":{"/opt/CORE_LOGICS/**":"allow","/opt/CORE_LOGICS/**x":"allow","~/custom":"ask"}}}'
run_func AIDC_OPENCODE_SEED_PERMISSIONS=0
python3 - "$CFG" <<'PY' || fail "knob-off retraction wrong"; ok "knob off retracts only exact owned allow-defaults"
import json, sys
e = json.load(open(sys.argv[1]))['permission']['external_directory']
assert e == {'/opt/CORE_LOGICS/**x': 'allow', '~/custom': 'ask'}, e
PY

# 5. Override list replaces the defaults.
write_cfg '{}'
run_func AIDC_OPENCODE_SEED_PERMISSIONS=1 AIDC_OPENCODE_EXTERNAL_ALLOW='/x/**'
python3 - "$CFG" <<'PY' || fail "override list ignored"; ok "AIDC_OPENCODE_EXTERNAL_ALLOW replaces defaults"
import json, sys
e = json.load(open(sys.argv[1]))['permission']['external_directory']
assert e == {'/x/**': 'allow'}, e
PY

# 6. Explicitly-empty override disables seeding (and removes nothing).
write_cfg '{"permission":{"external_directory":{"/keep":"ask"}}}'
run_func AIDC_OPENCODE_SEED_PERMISSIONS=1 AIDC_OPENCODE_EXTERNAL_ALLOW=''
python3 - "$CFG" <<'PY' || fail "empty override not honored"; ok "explicitly-empty override disables seeding"
import json, sys
e = json.load(open(sys.argv[1]))['permission']['external_directory']
assert e == {'/keep': 'ask'}, e
PY

# 7. Idempotent: nothing changes -> file not rewritten.
write_cfg '{"permission":{"external_directory":{"/opt/CORE_LOGICS/**":"allow","~/.local/share/rtk/**":"allow","/tmp/**":"allow"}}}'
before="$(stat -c '%Y.%N' "$CFG" 2>/dev/null || stat -f '%m' "$CFG")"
sleep 1
run_func AIDC_OPENCODE_SEED_PERMISSIONS=1
after="$(stat -c '%Y.%N' "$CFG" 2>/dev/null || stat -f '%m' "$CFG")"
if [[ "$before" == "$after" ]]; then
  ok "idempotent: no rewrite when nothing changes"
else
  fail "config rewritten on a no-op run"
fi

# 8. Invalid JSON: fail open, file left untouched (never "recovered" by
#    overwriting something its owner may want to fix by hand).
write_cfg 'not-json'
run_func AIDC_OPENCODE_SEED_PERMISSIONS=1
if [[ "$(cat "$CFG")" == 'not-json' ]]; then
  ok "invalid json: fail open, config untouched"
else
  fail "invalid json: config was overwritten"
fi

# 8b. Valid-but-non-object user shapes are left alone: the documented
#     whole-config shorthand and a string external_directory value.
write_cfg '{"permission":"ask"}'
run_func AIDC_OPENCODE_SEED_PERMISSIONS=1
[[ "$(cat "$CFG")" == '{"permission":"ask"}' ]] \
  && ok "permission string shorthand left untouched" \
  || fail "permission shorthand was clobbered"
write_cfg '{"permission":{"external_directory":"ask"}}'
run_func AIDC_OPENCODE_SEED_PERMISSIONS=1
[[ "$(cat "$CFG")" == '{"permission":{"external_directory":"ask"}}' ]] \
  && ok "external_directory string value left untouched" \
  || fail "external_directory string value was clobbered"

# 8c. Knob off never creates a config file.
rm -f "$CFG"
run_func AIDC_OPENCODE_SEED_PERMISSIONS=0
if [[ ! -e "$CFG" ]]; then
  ok "knob off does not create a config file"
else
  fail "knob off created: $(cat "$CFG")"
fi

# 9. No python3 on PATH -> fail open, file untouched.
write_cfg '{"provider":{"x":1}}'
run_func_with_python3_dir() { # <python3-stub-dir> [ENV=V ...]
  local pdir="$1"; shift
  env HOME="$HOME_FIX" PATH="$pdir" "$@" bash -c \
    'source '"$TMP_ROOT"'/func.sh; home_dir='"$HOME_FIX"'; ensure_opencode_permissions'
}
# A PATH that has bash but no python3.
mkdir -p "$TMP_ROOT/nopython"
ln -sf "$(command -v bash)" "$TMP_ROOT/nopython/bash"
run_func_with_python3_dir "$TMP_ROOT/nopython" AIDC_OPENCODE_SEED_PERMISSIONS=1
if [[ "$(cat "$CFG")" == '{"provider":{"x":1}}' ]]; then
  ok "no python3: fail open, config untouched"
else
  fail "no python3: config was modified"
fi

# 10. sync_opencode wires the seed AFTER the config seed copy (the every-start
#     host-seed overwrite would otherwise wipe the permission block on every
#     bootstrap, not just in sync mode).
if awk '/^sync_opencode\(\)/,/^}/' "$BOOTSTRAP" \
   | grep -q 'sync_file_from_seed "/host-seed/opencode/opencode.json"' \
   && awk '/^sync_opencode\(\)/,/^}/' "$BOOTSTRAP" \
   | grep -q 'ensure_opencode_permissions' \
   && [[ "$(awk '/^sync_opencode\(\)/,/^}/' "$BOOTSTRAP" | grep -n 'sync_file_from_seed "/host-seed/opencode/opencode.json"\|ensure_opencode_permissions' | head -1 | cut -d: -f1)" \
        -lt "$(awk '/^sync_opencode\(\)/,/^}/' "$BOOTSTRAP" | grep -n 'ensure_opencode_permissions' | cut -d: -f1)" ]]; then
  ok "sync_opencode seeds permissions after the config copy"
else
  fail "sync_opencode ordering wrong (seed must follow the config copy)"
fi

# ── v2 review-gate plugin: structural smoke against the validated API ────────
# 11. v2 entrypoint shape (plain object with id + setup; no v1 plugin function).
grep -q 'export default {' "$GATE" && grep -q 'id: "aidc-review-gate"' "$GATE" \
  && grep -q 'async setup(' "$GATE" \
  && ! grep -q 'export const .*: Plugin = async' "$GATE" \
  && ok "plugin uses the v2 { id, setup } entrypoint" \
  || fail "plugin entrypoint is not v2-shaped"

# 12. Turn-end triggers: v2 emits session.execution.* in serve/run (verified
#     against 2.0.29); session.idle kept for TUI-lifecycle coverage.
grep -q '"session.execution.succeeded"' "$GATE" \
  && grep -q '"session.execution.failed"' "$GATE" \
  && grep -q '"session.execution.interrupted"' "$GATE" \
  && grep -q '"session.idle"' "$GATE" \
  && ok "plugin triggers on v2 turn-end events" \
  || fail "plugin missing turn-end event triggers"

# 13. v2 prompt call shape (session.prompt({ sessionID, text, delivery }));
#     the v1 client.session.prompt({ path, body: { parts } }) must be gone.
grep -q 'ctx.session.prompt({' "$GATE" \
  && ! grep -q 'client.session.prompt' "$GATE" \
  && ok "plugin uses the v2 session.prompt shape" \
  || fail "plugin prompt call is not v2-shaped"

# 14. Per-session serialization (idle + execution.succeeded fire close
#     together; without chaining both can prompt before either records).
grep -q 'inFlight' "$GATE" \
  && ok "plugin serializes overlapping triggers per session" \
  || fail "plugin lacks per-session serialization"

# 15. Exactly one location instance acts per session (v2 fans events out to
#     every loaded location's plugin instance).
grep -q 'sessionDirectory !== ownDirectory' "$GATE" \
  && ok "plugin gates on session directory matching its location" \
  || fail "plugin lacks the location-match dedup"

# 15b. The check runs against the SCAFFOLD ROOT the script was found under,
#      never the session subdirectory — a subdir-scoped workspace computes a
#      tree hash (and reads a review record) that aidc-review-record, which
#      writes the scaffold root's record, can never satisfy.
grep -q 'findScaffoldRoot' "$GATE" && ! grep -q 'findCheckScript' "$GATE" \
  && grep -q 'runCheck(`${scaffoldRoot}/.devcontainer/scripts/aidc-review-hook.sh`, scaffoldRoot)' "$GATE" \
  && ok "check runs with the scaffold root as the hook workspace" \
  || fail "check workspace is not the scaffold root"

# 16. Loop guards carried over from the v1 design.
grep -q 'AIDC_REVIEW_GATE_MAX_NUDGES' "$GATE" && grep -q 'lastNudged' "$GATE" \
  && ok "loop guards (max nudges + tree-signature dedup) kept" \
  || fail "plugin lost the loop guards"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
