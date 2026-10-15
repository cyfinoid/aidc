#!/usr/bin/env bash
#
# Unit tests for the opencode host→container auth seeding (the sanctioned
# direction of the credential contract):
#
#   Host side (aidc::opencode_auth_snapshot, lib/aidc/runtime.sh):
#   - writes .aidc-auth-seed.json (0600) with the auth tables' rows
#   - knob AIDC_OPENCODE_SYNC_AUTH=0 → no-op; missing host db → no-op
#   - cmp-quiet: unchanged content rewrites nothing (no log line)
#   - a table missing from the host schema is simply absent from the snapshot
#
#   Container side (seed_opencode_auth, bootstrap-state.sh.tmpl):
#   - inserts host rows into the volume db; session tables untouched
#   - PK conflict: fresher host time_updated wins, fresher container row kept
#   - account_state (no timestamps) is INSERT OR IGNORE — never duplicated
#   - schema-tolerant: snapshot columns the dst lacks are dropped; dst tables
#     the snapshot lacks are skipped; a pre-v2 dst (no auth tables) is a no-op
#   - knob off → no-op; missing container db → skip with the init hint
#
# Run with: bash tests/opencode-auth-seed.test.sh
# shellcheck disable=SC2034,SC1090,SC1091
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

command -v sqlite3 >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 \
  || { echo "sqlite3 + python3 required" >&2; exit 1; }

# ── host side ────────────────────────────────────────────────────────────────
. "$REPO_ROOT/lib/aidc.sh"

export HOME="$TMP_ROOT/host"
mkdir -p "$HOME/.local/share/opencode"
HDB="$HOME/.local/share/opencode/opencode.db"
SNAP="$HOME/.local/share/opencode/.aidc-auth-seed.json"

mk_host_db() {
  sqlite3 "$HDB" \
    "CREATE TABLE session (id TEXT PRIMARY KEY, data TEXT);
     CREATE TABLE credential (id TEXT PRIMARY KEY, label TEXT, value TEXT, time_updated INTEGER);
     CREATE TABLE account (id TEXT PRIMARY KEY, email TEXT, access_token TEXT, refresh_token TEXT, token_expiry INTEGER, time_updated INTEGER);
     CREATE TABLE account_state (id TEXT PRIMARY KEY, active_account_id TEXT);
     CREATE TABLE control_account (email TEXT NOT NULL, url TEXT NOT NULL, access_token TEXT, time_updated INTEGER, PRIMARY KEY(email, url));
     INSERT INTO session VALUES ('s1', '{}');
     INSERT INTO credential VALUES ('c1', 'OpenAI', 'HOST-SECRET', 200);
     INSERT INTO account VALUES ('acct1', 'me@example.com', 'TOKEN', 'REFRESH', 999, 200);
     INSERT INTO account_state VALUES ('st1', 'acct1');
     INSERT INTO control_account VALUES ('me@example.com', 'https://x', 'CTOKEN', 200);"
}

# 1. snapshot written, 0600, valid JSON, carries rows, skips nothing present.
mk_host_db
aidc::opencode_auth_snapshot
if [[ -f "$SNAP" ]] \
   && [[ "$(stat -c '%a' "$SNAP" 2>/dev/null || stat -f '%Lp' "$SNAP")" == "600" ]] \
   && python3 -c "
import json, sys
d = json.load(open('$SNAP'))
t = d['tables']
assert t['credential'][0]['value'] == 'HOST-SECRET', t
assert t['account'][0]['email'] == 'me@example.com', t
assert t['account_state'][0]['id'] == 'st1', t
assert t['control_account'][0]['url'] == 'https://x', t
assert 'session' not in t, t
" 2>&1; then
  ok "snapshot: 0600 JSON with all four auth tables' rows (no session table)"
else
  fail "snapshot missing/wrong: $(head -c 200 "$SNAP" 2>/dev/null)"
fi

# 2. cmp-quiet: unchanged second run leaves the file untouched (mtime + no log).
mtime1="$(stat -c '%Y' "$SNAP" 2>/dev/null || stat -f '%m' "$SNAP")"
sleep 1
aidc::opencode_auth_snapshot
mtime2="$(stat -c '%Y' "$SNAP" 2>/dev/null || stat -f '%m' "$SNAP")"
if [[ "$mtime1" == "$mtime2" ]]; then
  ok "snapshot: unchanged content is cmp-quiet (no rewrite)"
else
  fail "snapshot rewritten despite identical content"
fi

# 3. knob off → no-op: the snapshot is NOT regenerated (deleting it first
#    makes the assertion discriminating — identical-content regeneration
#    would otherwise still leave a file on disk).
rm -f "$SNAP"
AIDC_OPENCODE_SYNC_AUTH=0 aidc::opencode_auth_snapshot
if [[ ! -e "$SNAP" ]]; then
  ok "AIDC_OPENCODE_SYNC_AUTH=0 disables the host-side snapshot"
else
  fail "knob-off still generated the snapshot"
fi
unset AIDC_OPENCODE_SYNC_AUTH

# 4. no host db → silent no-op (fresh hosts have nothing to seed).
rm -f "$HDB" "$SNAP"
aidc::opencode_auth_snapshot
if [[ ! -e "$SNAP" ]]; then
  ok "snapshot: missing host db is a no-op"
else
  fail "snapshot created without a host db"
fi

# 5. partial schema: a host db with only credential → snapshot carries just it.
sqlite3 "$HDB" "CREATE TABLE credential (id TEXT PRIMARY KEY, label TEXT, value TEXT, time_updated INTEGER);
     INSERT INTO credential VALUES ('c9', 'Grok', 'G-SECRET', 5);"
aidc::opencode_auth_snapshot
if python3 -c "
import json
t = json.load(open('$SNAP'))['tables']
assert set(t) == {'credential'}, set(t)
assert t['credential'][0]['id'] == 'c9'
"; then
  ok "snapshot: tables missing from the host schema are absent, not errors"
else
  fail "snapshot mishandled a partial host schema"
fi
rm -f "$HDB" "$SNAP"

# ── container side ───────────────────────────────────────────────────────────
# Extract seed_opencode_auth from the template and repoint its seed-mount path
# at a fixture directory (the real path lives behind a read-only bind mount).
SEED_DIR="$TMP_ROOT/host-seed"
mkdir -p "$SEED_DIR"
sed -n '/^seed_opencode_auth()/,/^}/p' "$TMPL" \
  | sed "s|/host-seed/opencode-data|$SEED_DIR|g" >"$TMP_ROOT/func.sh"
grep -q '^seed_opencode_auth()' "$TMP_ROOT/func.sh" \
  || { echo "could not extract seed_opencode_auth from template" >&2; exit 1; }

home_dir="$TMP_ROOT/container"
mkdir -p "$home_dir/.local/share/opencode"
bootstrap_warn() { printf '[bootstrap] warn: %s\n' "$*" >&2; }
# shellcheck disable=SC1090
. "$TMP_ROOT/func.sh"

CDB="$home_dir/.local/share/opencode/opencode.db"
mk_container_db() {  # v2-shaped volume db, empty auth tables (fresh file)
  rm -f "$CDB"
  sqlite3 "$CDB" \
    "CREATE TABLE session (id TEXT PRIMARY KEY, data TEXT);
     CREATE TABLE credential (id TEXT PRIMARY KEY, label TEXT, value TEXT, time_updated INTEGER);
     CREATE TABLE account (id TEXT PRIMARY KEY, email TEXT, access_token TEXT, refresh_token TEXT, token_expiry INTEGER, time_updated INTEGER);
     CREATE TABLE account_state (id TEXT PRIMARY KEY, active_account_id TEXT);
     INSERT INTO session VALUES ('sess1', 'KEEP');
     INSERT INTO credential VALUES ('c1', 'OpenAI', 'STALE', 100);"
}
write_snap() { printf '%s' "$1" >"$SEED_DIR/.aidc-auth-seed.json"; }

# 6. fresh insert + PK-conflict upsert (host newer wins) + session untouched.
mk_container_db
write_snap '{"generated": 1, "tables": {
  "credential": [{"id":"c1","label":"OpenAI","value":"FRESH","time_updated":300},
                 {"id":"c2","label":"xAI","value":"NEW","time_updated":300}],
  "account": [{"id":"a1","email":"me@x","access_token":"T","refresh_token":"R","token_expiry":1,"time_updated":300}]
}}'
seed_opencode_auth
if [[ "$(sqlite3 "$CDB" "SELECT value FROM credential WHERE id='c1';")" == "FRESH" ]] \
   && [[ "$(sqlite3 "$CDB" "SELECT count(*) FROM credential;")" == "2" ]] \
   && [[ "$(sqlite3 "$CDB" "SELECT count(*) FROM account;")" == "1" ]] \
   && [[ "$(sqlite3 "$CDB" "SELECT data FROM session WHERE id='sess1';")" == "KEEP" ]]; then
  ok "seed: host rows inserted/upserted by recency; session table untouched"
else
  fail "seed wrong: credential=$(sqlite3 "$CDB" "SELECT count(*) FROM credential;") account=$(sqlite3 "$CDB" "SELECT count(*) FROM account;")"
fi

# 7. PK conflict, container fresher → container row kept (no downgrade).
write_snap '{"generated": 2, "tables": {"credential": [
  {"id":"c1","label":"OpenAI","value":"OLD-HOST","time_updated":50}]}}'
seed_opencode_auth
if [[ "$(sqlite3 "$CDB" "SELECT value FROM credential WHERE id='c1';")" == "FRESH" ]]; then
  ok "seed: a fresher container-side row is not downgraded by a stale host row"
else
  fail "seed clobbered a fresher container row"
fi

# 8. account_state: INSERT OR IGNORE — re-running never duplicates.
write_snap '{"generated": 3, "tables": {"account_state": [
  {"id":"st1","active_account_id":"a1"},
  {"id":"st2","active_account_id":"a1"}]}}'
seed_opencode_auth
seed_opencode_auth
if [[ "$(sqlite3 "$CDB" "SELECT count(*) FROM account_state;")" == "2" ]]; then
  ok "seed: account_state is INSERT OR IGNORE (idempotent re-runs)"
else
  fail "account_state duplicated on re-run: $(sqlite3 "$CDB" "SELECT count(*) FROM account_state;")"
fi

# 9. schema tolerance: snapshot columns the dst lacks are dropped; dst tables
#    the snapshot lacks are skipped. Pre-v2 dst (no auth tables) is a no-op.
write_snap '{"generated": 4, "tables": {"credential": [
  {"id":"c9","label":"Future","value":"V","time_updated":9,"future_column":"x"}]}}'
sqlite3 "$CDB" "DROP TABLE account;"
seed_opencode_auth
if [[ "$(sqlite3 "$CDB" "SELECT count(*) FROM credential WHERE id='c9';")" == "1" ]]; then
  ok "seed: snapshot columns missing from the dst schema are dropped"
else
  fail "seed failed on schema-column intersection"
fi
rm -f "$CDB"
sqlite3 "$CDB" "CREATE TABLE session (id TEXT PRIMARY KEY, data TEXT);
     INSERT INTO session VALUES ('sess1', 'KEEP');"
write_snap '{"generated": 5, "tables": {"credential": [
  {"id":"c1","label":"OpenAI","value":"V","time_updated":1}]}}'
seed_opencode_auth
if [[ "$(sqlite3 "$CDB" "SELECT count(*) FROM session;")" == "1" ]]; then
  ok "seed: pre-v2 container db (no auth tables) is a safe no-op"
else
  fail "seed disturbed a pre-v2 container db"
fi

# 10. knob off → no-op (discriminating: the snapshot row is FRESHER than the
#     container's, so knob-on would update it — knob-off must leave it).
mk_container_db
write_snap '{"generated": 6, "tables": {"credential": [
  {"id":"c1","label":"OpenAI","value":"KNOB-TEST","time_updated":300}]}}'
AIDC_OPENCODE_SYNC_AUTH=0 seed_opencode_auth
if [[ "$(sqlite3 "$CDB" "SELECT count(*) FROM credential;")" == "1" ]] \
   && [[ "$(sqlite3 "$CDB" "SELECT value FROM credential WHERE id='c1';")" == "STALE" ]]; then
  ok "AIDC_OPENCODE_SYNC_AUTH=0 disables the container-side seed"
else
  fail "knob-off seed still applied rows"
fi
# Contrast run: knob ON with the same fixture must apply (proves the knob, not
# the recency guard, was what blocked it above).
seed_opencode_auth
if [[ "$(sqlite3 "$CDB" "SELECT value FROM credential WHERE id='c1';")" == "KNOB-TEST" ]]; then
  ok "knob-on contrast: the same snapshot applies when enabled"
else
  fail "knob-on contrast did not apply: $(sqlite3 "$CDB" "SELECT value FROM credential WHERE id='c1';")"
fi
unset AIDC_OPENCODE_SYNC_AUTH
rm -f "$CDB"
if out="$(seed_opencode_auth 2>&1)"; then
  if printf '%s' "$out" | grep -q 'not initialized yet'; then
    ok "seed: missing container db skips with the init hint (no error)"
  else
    fail "missing-db path lost its hint: $out"
  fi
else
  fail "seed errored on a missing container db: $out"
fi

# 11. a corrupt snapshot fails CLOSED: warn path fires, the volume db is
#     untouched (the python transaction rolls back — no partial seed).
mk_container_db
printf '{"tables": {"credential": [ TRUNCATED' >"$SEED_DIR/.aidc-auth-seed.json"
if seed_opencode_auth 2>&1 | grep -q 'could not apply the host auth snapshot'; then
  if [[ "$(sqlite3 "$CDB" "SELECT count(*) FROM credential;")" == "1" ]] \
     && [[ "$(sqlite3 "$CDB" "SELECT value FROM credential WHERE id='c1';")" == "STALE" ]]; then
    ok "corrupt snapshot: warn + rollback, volume db untouched"
  else
    fail "corrupt snapshot partially applied"
  fi
else
  fail "corrupt snapshot did not take the warn path"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
