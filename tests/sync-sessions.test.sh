#!/usr/bin/env bash
#
# Unit tests for `aidc sync-sessions` — transcript path rewriting and the
# opencode data-dir mapping.
#
#   - aidc::sync_session_tool rewrites the in-container mount root (/workspace)
#     to the real host workspace path in synced *.json / *.jsonl transcripts,
#     so logs copied to the host reference paths that exist on this machine.
#   - only JSON/JSONL files are rewritten; other files are left byte-for-byte.
#   - the rewrite is a no-op when the workspace already is /workspace.
#   - workspace paths containing sed-significant characters (&, |, \) survive.
#   - opencode sessions sync FROM the XDG data dir (~/.local/share/opencode —
#     never ~/.config/opencode, which opencode only uses for config), gated on
#     actual session artifacts (storage/ or opencode.db), excluding auth.json
#     (credentials never leave the container) and cache dirs, and land in an
#     aidc-owned host subtree (~/.local/share/aidc/sessions/opencode/<slug>/)
#     so the host's own opencode database is never clobbered. The binary
#     opencode.db is not sed-rewritten (only *.json/*.jsonl are).
#
# The container plumbing (compose exec + the tar stream) is stubbed so the test
# is hermetic and needs neither Docker nor a running container: the stubbed
# aidc::compose runs the same `tar`/`test` argv the container would see, but
# against a local fixture tree standing in for the container filesystem.
#
# Run with: bash tests/sync-sessions.test.sh
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

# Container plumbing stubs. Function names resolve at call time, so redefining
# after sourcing is enough. Both stubs receive the sync path's argv as
# `<ws> exec -T workspace <cmd...>`; they drop the compose prefix, rewrite any
# /home/aidc-prefixed path in <cmd> to point into the fixture tree (which
# mirrors the container's /home/aidc layout), and run the command locally —
# so the gate probe (`test ...`) and the tar stream behave as if in-container.
CONTAINER_ROOT=""
STUB_ARGV=()
stub_translate_argv() {
  STUB_ARGV=()
  local a
  for a in "$@"; do
    case "$a" in
      /home/aidc|/home/aidc/*) a="$CONTAINER_ROOT${a#/home/aidc}" ;;
    esac
    STUB_ARGV+=("$a")
  done
}
aidc::compose_capture() {
  shift 4  # <ws> exec -T workspace
  stub_translate_argv "$@"
  "${STUB_ARGV[@]}"
}
aidc::compose() {
  shift 4  # <ws> exec -T workspace
  stub_translate_argv "$@"
  "${STUB_ARGV[@]}"
}
# aidc::log output is part of the contract this suite asserts (the
# schema-skip line must name its cause), so capture every message; cases that
# care truncate LOGS before their sync call and grep it after.
LOGS="$TMP_ROOT/messages.log"
: >"$LOGS"
aidc::log() { printf '%s\n' "$*" >>"$LOGS"; }

# Build a fresh container-side fixture (standing in for the container's
# /home/aidc) and point HOME at a clean host tree. Sets CONTAINER_ROOT, HOME
# and host_dst (claude transcripts) in the caller's shell — must NOT run in a
# subshell or the exports are lost.
setup_case() {
  local case="$1"
  CONTAINER_ROOT="$TMP_ROOT/$case/container-home"
  export HOME="$TMP_ROOT/$case/home"
  mkdir -p "$CONTAINER_ROOT" "$HOME"
  host_dst="$HOME/.claude/projects"
}

# ── 1. /workspace paths are rewritten to the host workspace in .jsonl/.json ──
setup_case rewrite
mkdir -p "$CONTAINER_ROOT/.claude/projects"
printf '{"cwd":"/workspace/app","file":"/workspace/app/main.go"}\n' >"$CONTAINER_ROOT/.claude/projects/a.jsonl"
printf '{"root":"/workspace"}\n' >"$CONTAINER_ROOT/.claude/projects/b.json"
ws="/home/alice/projects/app"
aidc::sync_session_tool "$ws" claude
if grep -q '"cwd":"/home/alice/projects/app/app"' "$host_dst/a.jsonl" \
   && grep -q '"file":"/home/alice/projects/app/app/main.go"' "$host_dst/a.jsonl" \
   && grep -q '"root":"/home/alice/projects/app"' "$host_dst/b.json"; then
  ok "/workspace rewritten to host path in .jsonl and .json"
else
  fail "rewrite did not produce host paths: $(cat "$host_dst"/*.json*)"
fi

# ── 2. non-JSON files are left untouched ──
setup_case skip-other
mkdir -p "$CONTAINER_ROOT/.claude/projects"
printf 'see /workspace/app\n' >"$CONTAINER_ROOT/.claude/projects/notes.txt"
aidc::sync_session_tool "/home/alice/app" claude
if grep -q 'see /workspace/app' "$host_dst/notes.txt"; then
  ok "non-JSON files are not rewritten"
else
  fail "notes.txt was modified: $(cat "$host_dst/notes.txt")"
fi

# ── 3. no-op when the workspace already is /workspace ──
setup_case noop
mkdir -p "$CONTAINER_ROOT/.claude/projects"
printf '{"file":"/workspace/x"}\n' >"$CONTAINER_ROOT/.claude/projects/c.jsonl"
aidc::sync_session_tool "/workspace" claude
if grep -q '{"file":"/workspace/x"}' "$host_dst/c.jsonl"; then
  ok "no rewrite when workspace is /workspace"
else
  fail "unexpected rewrite for /workspace workspace: $(cat "$host_dst/c.jsonl")"
fi

# ── 4. sed-significant characters in the host path survive ──
setup_case special
mkdir -p "$CONTAINER_ROOT/.claude/projects"
printf '{"file":"/workspace/x"}\n' >"$CONTAINER_ROOT/.claude/projects/d.jsonl"
ws='/home/a&b/c|d/e\f'
aidc::sync_session_tool "$ws" claude
if grep -Fq '{"file":"/home/a&b/c|d/e\f/x"}' "$host_dst/d.jsonl"; then
  ok "workspace path with & | \\ is inserted literally"
else
  fail "special-char host path mangled: $(cat "$host_dst/d.jsonl")"
fi

# ── 5. opencode syncs from the XDG data dir, excluded files stay behind ──
# Mirror the container layout: ~/.local/share/opencode/{opencode.db,auth.json,log/…}.
setup_case opencode-data-dir
oc_data="$CONTAINER_ROOT/.local/share/opencode"
mkdir -p "$oc_data/log" "$oc_data/storage/session"
printf 'binary-db-bytes' >"$oc_data/opencode.db"
printf 'SECRET' >"$oc_data/auth.json"
printf 'logline\n' >"$oc_data/log/debug.log"
printf '{"cwd":"/workspace/app"}\n' >"$oc_data/storage/session/s1.json"
ws="/home/alice/projects/app"
# Opt out of the host-db merge here so this case exercises ONLY the quarantine
# step (and proves AIDC_OPENCODE_MERGE_TO_BASE=0 leaves the host's own data dir
# untouched). The merge itself is covered by the sqlite cases below.
AIDC_OPENCODE_MERGE_TO_BASE=0 aidc::sync_session_tool "$ws" opencode
# Expected host dst: ~/.local/share/aidc/sessions/opencode/<repo-slug>/ —
# resolve the slug dir via glob (one repo synced into this HOME).
oc_dst="$(echo "$HOME"/.local/share/aidc/sessions/opencode/*/)"
[[ -d "$oc_dst" ]] || oc_dst="$HOME/.local/share/aidc/sessions/opencode"
if [[ -f "$oc_dst/opencode.db" && -f "$oc_dst/storage/session/s1.json" ]] \
   && ! [[ -e "$oc_dst/auth.json" || -e "$oc_dst/log" ]] \
   && ! grep -rq 'SECRET' "$oc_dst"; then
  ok "opencode: db + storage synced from data dir, auth.json/log excluded"
else
  fail "opencode sync layout wrong: $(find "$HOME/.local/share/aidc" -mindepth 1 2>/dev/null | head -20)"
fi
# ...and with the merge opted out the host's own data dir is never a target:
if [[ ! -e "$HOME/.local/share/opencode" ]]; then
  ok "opencode: AIDC_OPENCODE_MERGE_TO_BASE=0 leaves host data dir untouched"
else
  fail "opencode sync wrote into the host's own data dir despite opt-out"
fi
# JSON transcripts still get the /workspace rewrite…
if grep -q '"cwd":"/home/alice/projects/app/app"' "$oc_dst/storage/session/s1.json"; then
  ok "opencode: /workspace rewritten in synced storage JSON"
else
  fail "storage JSON not rewritten: $(cat "$oc_dst/storage/session/s1.json")"
fi
# …but the binary db must NOT be sed-rewritten (it would be corrupted):
if cmp -s <(printf 'binary-db-bytes') "$oc_dst/opencode.db"; then
  ok "opencode: binary opencode.db left byte-for-byte"
else
  fail "opencode.db was modified by the rewrite pass"
fi

# ── 6. opencode gate: data dir without session artifacts syncs nothing ──
setup_case opencode-empty
oc_data="$CONTAINER_ROOT/.local/share/opencode"
mkdir -p "$oc_data/log"
printf 'SECRET' >"$oc_data/auth.json"
aidc::sync_session_tool "/home/alice/app" opencode
if [[ ! -e "$HOME/.local/share/aidc" ]]; then
  ok "opencode: no session artifacts → nothing synced, no host dir created"
else
  fail "opencode synced (or created host dirs) despite having no sessions"
fi

# ── 7. opencode legacy layout: storage/ without opencode.db still syncs ──
setup_case opencode-legacy
oc_data="$CONTAINER_ROOT/.local/share/opencode"
mkdir -p "$oc_data/storage/session"
printf '{"info":"/workspace/x"}\n' >"$oc_data/storage/session/old.json"
aidc::sync_session_tool "/home/alice/app" opencode
oc_dst="$(echo "$HOME"/.local/share/aidc/sessions/opencode/*/)"
if [[ -f "$oc_dst/storage/session/old.json" ]] \
   && grep -Fq '"info":"/home/alice/app/x"' "$oc_dst/storage/session/old.json"; then
  ok "opencode: legacy storage/ layout synced + rewritten"
else
  fail "legacy storage/ sync failed: $(find "$HOME/.local/share/aidc" -type f 2>/dev/null)"
fi
# legacy storage/ is additively folder-merged into the host's own data dir too
# (the merge model that mirrors claude's simple folder sync).
base_old="$HOME/.local/share/opencode/storage/session/old.json"
if [[ -f "$base_old" ]] && grep -Fq '"info":"/home/alice/app/x"' "$base_old"; then
  ok "opencode: legacy storage/ merged into host ~/.local/share/opencode"
else
  fail "legacy storage/ not merged into host base: $(find "$HOME/.local/share/opencode" -type f 2>/dev/null)"
fi

# ── opencode.db SQLite merge cases (require sqlite3) ──────────────────────────
# These exercise aidc::opencode_merge_to_base's row-merge into the host's own
# opencode.db: additive, host-rows-win, schema-gated, never overwriting.
if command -v sqlite3 >/dev/null 2>&1; then

  # Minimal opencode-like schema: id PK + JSON `data` column (where opencode
  # keeps absolute paths). mk_db <file> <sql...> builds a db from statements.
  mk_session_db() {
    local db="$1"; shift
    sqlite3 "$db" "CREATE TABLE session (id TEXT PRIMARY KEY, data TEXT);"
    local stmt
    for stmt in "$@"; do sqlite3 "$db" "$stmt"; done
  }

  # ── 8. additive merge: container rows added, host rows untouched, paths fixed
  setup_case oc-merge-additive
  oc_data="$CONTAINER_ROOT/.local/share/opencode"
  mkdir -p "$oc_data"
  mk_session_db "$oc_data/opencode.db" \
    "INSERT INTO session VALUES ('contB', '{\"cwd\":\"/workspace/proj\"}');"
  mkdir -p "$HOME/.local/share/opencode"
  mk_session_db "$HOME/.local/share/opencode/opencode.db" \
    "INSERT INTO session VALUES ('hostA', '{\"cwd\":\"/home/alice/app/host\"}');"
  aidc::sync_session_tool "/home/alice/app" opencode
  bdb="$HOME/.local/share/opencode/opencode.db"
  got_b="$(sqlite3 "$bdb" "SELECT data FROM session WHERE id='contB';")"
  got_a="$(sqlite3 "$bdb" "SELECT data FROM session WHERE id='hostA';")"
  if [[ "$got_a" == '{"cwd":"/home/alice/app/host"}' \
     && "$got_b" == '{"cwd":"/home/alice/app/proj"}' ]]; then
    ok "opencode.db: container row merged in (path rewritten), host row intact"
  else
    fail "opencode.db additive merge wrong: hostA=$got_a contB=$got_b"
  fi
  if [[ ! -e "$bdb.aidc-bak" && ! -e "$(echo "$HOME"/.local/share/aidc/sessions/opencode/*/).opencode.merge.db" ]]; then
    ok "opencode.db: merge backup + temp copy cleaned up on success"
  else
    fail "opencode.db merge left scratch files behind"
  fi

  # ── 9. primary-key collision keeps the HOST row (INSERT OR IGNORE) ──────────
  setup_case oc-merge-collision
  oc_data="$CONTAINER_ROOT/.local/share/opencode"
  mkdir -p "$oc_data"
  mk_session_db "$oc_data/opencode.db" \
    "INSERT INTO session VALUES ('dup', 'CONTAINERVERSION');"
  mkdir -p "$HOME/.local/share/opencode"
  mk_session_db "$HOME/.local/share/opencode/opencode.db" \
    "INSERT INTO session VALUES ('dup', 'HOSTVERSION');"
  aidc::sync_session_tool "/home/alice/app" opencode
  got="$(sqlite3 "$HOME/.local/share/opencode/opencode.db" "SELECT data FROM session WHERE id='dup';")"
  if [[ "$got" == "HOSTVERSION" ]]; then
    ok "opencode.db: id collision keeps the host row"
  else
    fail "opencode.db collision clobbered host row: $got"
  fi

  # ── 10. schema drift → merge skipped, host db untouched ─────────────────────
  setup_case oc-merge-schema-drift
  oc_data="$CONTAINER_ROOT/.local/share/opencode"
  mkdir -p "$oc_data"
  sqlite3 "$oc_data/opencode.db" "CREATE TABLE session (id TEXT PRIMARY KEY, data TEXT, extra TEXT);"
  sqlite3 "$oc_data/opencode.db" "INSERT INTO session VALUES ('contB', '{}', 'x');"
  mkdir -p "$HOME/.local/share/opencode"
  mk_session_db "$HOME/.local/share/opencode/opencode.db" \
    "INSERT INTO session VALUES ('hostA', '{}');"
  : >"$LOGS"
  aidc::sync_session_tool "/home/alice/app" opencode
  n="$(sqlite3 "$HOME/.local/share/opencode/opencode.db" "SELECT count(*) FROM session;")"
  if [[ "$n" == "1" ]] && [[ -f "$(echo "$HOME"/.local/share/aidc/sessions/opencode/*/)opencode.db" ]]; then
    ok "opencode.db: schema drift skips merge, host db untouched, quarantine kept"
  else
    fail "opencode.db schema-drift not skipped safely: host session count=$n"
  fi
  if grep -Fq "column/type drift between container and host (first on table 'session')" "$LOGS" \
     && ! grep -Fq "newer schema epoch" "$LOGS"; then
    ok "opencode.db: drift skip names column drift (with table), not a schema epoch"
  else
    fail "opencode.db drift skip message wrong: $(cat "$LOGS")"
  fi

  # ── 11. no sqlite3 on host → merge skipped, host db untouched ───────────────
  setup_case oc-merge-no-sqlite
  oc_data="$CONTAINER_ROOT/.local/share/opencode"
  mkdir -p "$oc_data"
  mk_session_db "$oc_data/opencode.db" \
    "INSERT INTO session VALUES ('contB', '{}');"
  mkdir -p "$HOME/.local/share/opencode"
  mk_session_db "$HOME/.local/share/opencode/opencode.db" \
    "INSERT INTO session VALUES ('hostA', '{}');"
  AIDC_SQLITE3="/nonexistent/sqlite3-xyz" aidc::sync_session_tool "/home/alice/app" opencode
  n="$(sqlite3 "$HOME/.local/share/opencode/opencode.db" "SELECT count(*) FROM session;")"
  if [[ "$n" == "1" ]] && [[ -f "$(echo "$HOME"/.local/share/aidc/sessions/opencode/*/)opencode.db" ]]; then
    ok "opencode.db: absent sqlite3 skips merge, host db untouched, quarantine kept"
  else
    fail "opencode.db no-sqlite3 not skipped safely: host session count=$n"
  fi

  # ── 12. same schema, different column ORDER → merges, values land right ────
  # The real-world false positive this fix exists for: a long-lived host db
  # grown via ALTER TABLE ADD COLUMN appends columns at the end, a fresh
  # container db lays them out in definition order. A positional SELECT *
  # would swap values between columns; the name-qualified insert must not.
  setup_case oc-merge-reordered
  oc_data="$CONTAINER_ROOT/.local/share/opencode"
  mkdir -p "$oc_data"
  sqlite3 "$oc_data/opencode.db" \
    "CREATE TABLE session (id TEXT PRIMARY KEY, extra_col TEXT, data TEXT);
     INSERT INTO session VALUES ('contB', 'e', '{\"cwd\":\"/workspace/proj\"}');"
  mkdir -p "$HOME/.local/share/opencode"
  sqlite3 "$HOME/.local/share/opencode/opencode.db" \
    "CREATE TABLE session (id TEXT PRIMARY KEY, data TEXT);
     INSERT INTO session VALUES ('hostA', 'HOSTROW');
     ALTER TABLE session ADD COLUMN extra_col TEXT;"
  aidc::sync_session_tool "/home/alice/app" opencode
  bdb="$HOME/.local/share/opencode/opencode.db"
  got_b="$(sqlite3 "$bdb" "SELECT data FROM session WHERE id='contB';")"
  got_bx="$(sqlite3 "$bdb" "SELECT extra_col FROM session WHERE id='contB';")"
  got_a="$(sqlite3 "$bdb" "SELECT data FROM session WHERE id='hostA';")"
  if [[ "$got_b" == '{"cwd":"/home/alice/app/proj"}' && "$got_bx" == "e" && "$got_a" == "HOSTROW" ]]; then
    ok "opencode.db: reordered-but-equal schema merges, values in the right columns"
  else
    fail "opencode.db reordered merge wrong: hostA=$got_a contB=$got_b extra=$got_bx"
  fi

  # ── 13. host db has MORE columns (newer build) → still merges by name ──────
  setup_case oc-merge-host-newer
  oc_data="$CONTAINER_ROOT/.local/share/opencode"
  mkdir -p "$oc_data"
  sqlite3 "$oc_data/opencode.db" \
    "CREATE TABLE session (id TEXT PRIMARY KEY, data TEXT);
     INSERT INTO session VALUES ('contB', '{\"cwd\":\"/workspace/proj\"}');"
  mkdir -p "$HOME/.local/share/opencode"
  sqlite3 "$HOME/.local/share/opencode/opencode.db" \
    "CREATE TABLE session (id TEXT PRIMARY KEY, data TEXT);
     INSERT INTO session VALUES ('hostA', '{}');
     ALTER TABLE session ADD COLUMN newer_col TEXT;"
  aidc::sync_session_tool "/home/alice/app" opencode
  bdb="$HOME/.local/share/opencode/opencode.db"
  got_b="$(sqlite3 "$bdb" "SELECT data FROM session WHERE id='contB';")"
  got_bnew="$(sqlite3 "$bdb" "SELECT newer_col FROM session WHERE id='contB';")"
  if [[ "$got_b" == '{"cwd":"/home/alice/app/proj"}' && -z "$got_bnew" ]] \
     && [[ "$(sqlite3 "$bdb" "SELECT count(*) FROM session;")" == "2" ]]; then
    ok "opencode.db: host-extra column tolerated, container row merged (new col NULL)"
  else
    fail "opencode.db host-newer merge wrong: contB=$got_b newer_col=$got_bnew"
  fi

  # ── 14. migration journal: container AHEAD of host → skip (epoch drift) ────
  setup_case oc-merge-journal-ahead
  oc_data="$CONTAINER_ROOT/.local/share/opencode"
  mkdir -p "$oc_data"
  sqlite3 "$oc_data/opencode.db" \
    "CREATE TABLE session (id TEXT PRIMARY KEY, data TEXT);
     CREATE TABLE migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
     INSERT INTO session VALUES ('contB', '{}');
     INSERT INTO migration VALUES ('m1', 1), ('m2_new', 2);"
  mkdir -p "$HOME/.local/share/opencode"
  sqlite3 "$HOME/.local/share/opencode/opencode.db" \
    "CREATE TABLE session (id TEXT PRIMARY KEY, data TEXT);
     CREATE TABLE migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
     INSERT INTO session VALUES ('hostA', '{}');
     INSERT INTO migration VALUES ('m1', 1);"
  : >"$LOGS"
  aidc::sync_session_tool "/home/alice/app" opencode
  n="$(sqlite3 "$HOME/.local/share/opencode/opencode.db" "SELECT count(*) FROM session;")"
  if [[ "$n" == "1" ]] && [[ -f "$(echo "$HOME"/.local/share/aidc/sessions/opencode/*/)opencode.db" ]]; then
    ok "opencode.db: container migration-journal ahead of host → skipped, quarantine kept"
  else
    fail "opencode.db journal-ahead not skipped safely: host session count=$n"
  fi
  # The skip must say WHICH mismatch and carry the remedy (upgrade the host),
  # not the old conflated "newer than host, or column/type drift" guess.
  if grep -Fq "newer schema epoch than the host's (migration journal 1 id(s) ahead" "$LOGS" \
     && grep -Fq "upgrade the host's opencode" "$LOGS" \
     && ! grep -Fq "column/type drift" "$LOGS"; then
    ok "opencode.db: epoch-ahead skip names the cause, gap size, and upgrade remedy"
  else
    fail "opencode.db epoch-ahead skip message wrong: $(cat "$LOGS")"
  fi

  # ── 14b. journal ahead AND a drifted shared table → epoch-ahead wins ────────
  # A newer opencode build typically ALTERs shared tables too (that is how the
  # schema grows), so the pair is both journal-ahead and column-drifted. The
  # journal gap is the root cause with the upgrade remedy; reporting drift
  # here would bury the remedy — the exact conflation this split fixes.
  setup_case oc-merge-journal-ahead-plus-drift
  oc_data="$CONTAINER_ROOT/.local/share/opencode"
  mkdir -p "$oc_data"
  sqlite3 "$oc_data/opencode.db" \
    "CREATE TABLE session (id TEXT PRIMARY KEY, data TEXT, extra TEXT);
     CREATE TABLE migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
     INSERT INTO session VALUES ('contB', '{}', 'x');
     INSERT INTO migration VALUES ('m1', 1), ('m2_new', 2);"
  mkdir -p "$HOME/.local/share/opencode"
  sqlite3 "$HOME/.local/share/opencode/opencode.db" \
    "CREATE TABLE session (id TEXT PRIMARY KEY, data TEXT);
     CREATE TABLE migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
     INSERT INTO session VALUES ('hostA', '{}');
     INSERT INTO migration VALUES ('m1', 1);"
  : >"$LOGS"
  aidc::sync_session_tool "/home/alice/app" opencode
  n="$(sqlite3 "$HOME/.local/share/opencode/opencode.db" "SELECT count(*) FROM session;")"
  if [[ "$n" == "1" ]] && [[ -f "$(echo "$HOME"/.local/share/aidc/sessions/opencode/*/)opencode.db" ]]; then
    ok "opencode.db: journal-ahead+drift still skips safely, quarantine kept"
  else
    fail "opencode.db journal-ahead+drift not skipped safely: host session count=$n"
  fi
  if grep -Fq "newer schema epoch" "$LOGS" && ! grep -Fq "column/type drift" "$LOGS"; then
    ok "opencode.db: epoch-ahead takes precedence over column drift (root cause + remedy)"
  else
    fail "opencode.db precedence wrong (drift should lose to epoch-ahead): $(cat "$LOGS")"
  fi

  # ── 14c. verified-additive journal gap → degraded merge (host cols) ────────
  # The live 2.0.25-host vs 2.0.29-container shape: gap = one allowlisted
  # additive migration; container's `project` has the added column; payload
  # tables identical. Must MERGE (not skip) using the host's column list.
  ADD_ID="20261010180456_project_time_archived"   # on the verified allowlist
  setup_case oc-merge-additive-gap
  oc_data="$CONTAINER_ROOT/.local/share/opencode"
  mkdir -p "$oc_data"
  sqlite3 "$oc_data/opencode.db" \
    "CREATE TABLE session_v2 (id TEXT PRIMARY KEY, data TEXT);
     CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT, time_archived INTEGER);
     CREATE TABLE migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
     INSERT INTO session_v2 VALUES ('contB', '{\"cwd\":\"/workspace/proj\"}');
     INSERT INTO project VALUES ('projNew', 'from-container', 1759971600);
     INSERT INTO project VALUES ('dup', 'CONTAINERVERSION', 1);
     INSERT INTO migration VALUES ('m1', 1), ('$ADD_ID', 2);"
  mkdir -p "$HOME/.local/share/opencode"
  sqlite3 "$HOME/.local/share/opencode/opencode.db" \
    "CREATE TABLE session_v2 (id TEXT PRIMARY KEY, data TEXT);
     CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
     CREATE TABLE migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
     INSERT INTO session_v2 VALUES ('hostA', '{}');
     INSERT INTO project VALUES ('dup', 'HOSTVERSION');
     INSERT INTO migration VALUES ('m1', 1);"
  : >"$LOGS"
  aidc::sync_session_tool "/home/alice/app" opencode
  bdb="$HOME/.local/share/opencode/opencode.db"
  got_b="$(sqlite3 "$bdb" "SELECT data FROM session_v2 WHERE id='contB';")"
  got_new="$(sqlite3 "$bdb" "SELECT name FROM project WHERE id='projNew';")"
  got_dup="$(sqlite3 "$bdb" "SELECT name FROM project WHERE id='dup';")"
  if [[ "$got_b" == '{"cwd":"/home/alice/app/proj"}' \
     && "$got_new" == "from-container" \
     && "$got_dup" == "HOSTVERSION" ]] \
     && [[ "$(sqlite3 "$bdb" "SELECT count(*) FROM session_v2;")" == "2" ]] \
     && [[ "$(sqlite3 "$bdb" "SELECT count(*) FROM migration;")" == "1" ]]; then
    ok "opencode.db: additive gap merges (sessions + new project row land, host row wins, journal untouched)"
  else
    fail "opencode.db additive-gap merge wrong: contB=$got_b projNew=$got_new dup=$got_dup"
  fi
  if grep -Fq "gap verified additive-only" "$LOGS" \
     && grep -Fq "merged opencode sessions into" "$LOGS" \
     && ! grep -Fq "skipping merge" "$LOGS"; then
    ok "opencode.db: additive-gap merge logs the degraded mode, no skip"
  else
    fail "opencode.db additive-gap messages wrong: $(cat "$LOGS")"
  fi

  # ── 14d. NON-allowlisted gap id (a real reshaping migration) → skip ────────
  # Fail-safe: only source-verified ids merge; everything else keeps the
  # conservative epoch-ahead skip.
  setup_case oc-merge-additive-unlisted
  oc_data="$CONTAINER_ROOT/.local/share/opencode"
  mkdir -p "$oc_data"
  sqlite3 "$oc_data/opencode.db" \
    "CREATE TABLE session_v2 (id TEXT PRIMARY KEY, data TEXT);
     CREATE TABLE migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
     INSERT INTO session_v2 VALUES ('contB', '{}');
     INSERT INTO migration VALUES ('m1', 1), ('20260622170816_reset_v2_session_state', 2);"
  mkdir -p "$HOME/.local/share/opencode"
  sqlite3 "$HOME/.local/share/opencode/opencode.db" \
    "CREATE TABLE session_v2 (id TEXT PRIMARY KEY, data TEXT);
     CREATE TABLE migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
     INSERT INTO session_v2 VALUES ('hostA', '{}');
     INSERT INTO migration VALUES ('m1', 1);"
  : >"$LOGS"
  aidc::sync_session_tool "/home/alice/app" opencode
  n="$(sqlite3 "$HOME/.local/share/opencode/opencode.db" "SELECT count(*) FROM session_v2;")"
  if [[ "$n" == "1" ]] && grep -Fq "newer schema epoch" "$LOGS" \
     && ! grep -Fq "additive-only" "$LOGS"; then
    ok "opencode.db: unlisted gap id still refuses (epoch-ahead), no degraded merge"
  else
    fail "opencode.db unlisted-gap case wrong: count=$n logs=$(cat "$LOGS")"
  fi

  # ── 14e. allowlisted gap but NOT purely additive (host-only column) → skip ─
  # The runtime shape check must catch an allowlist that lied or drifted data.
  setup_case oc-merge-additive-shape
  oc_data="$CONTAINER_ROOT/.local/share/opencode"
  mkdir -p "$oc_data"
  sqlite3 "$oc_data/opencode.db" \
    "CREATE TABLE session_v2 (id TEXT PRIMARY KEY, data TEXT);
     CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
     CREATE TABLE migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
     INSERT INTO session_v2 VALUES ('contB', '{}');
     INSERT INTO migration VALUES ('m1', 1), ('$ADD_ID', 2);"
  mkdir -p "$HOME/.local/share/opencode"
  sqlite3 "$HOME/.local/share/opencode/opencode.db" \
    "CREATE TABLE session_v2 (id TEXT PRIMARY KEY, data TEXT);
     CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT, host_only TEXT);
     CREATE TABLE migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
     INSERT INTO session_v2 VALUES ('hostA', '{}');
     INSERT INTO migration VALUES ('m1', 1);"
  : >"$LOGS"
  aidc::sync_session_tool "/home/alice/app" opencode
  n="$(sqlite3 "$HOME/.local/share/opencode/opencode.db" "SELECT count(*) FROM session_v2;")"
  if [[ "$n" == "1" ]] && grep -Fq "column/type drift between container and host (first on table 'project')" "$LOGS"; then
    ok "opencode.db: allowlisted gap with non-additive shape refuses (drift named)"
  else
    fail "opencode.db additive-shape case wrong: count=$n logs=$(cat "$LOGS")"
  fi

  # ── 14f. AIDC_OPENCODE_ADDITIVE_MIGRATIONS='' disables degraded merging ────
  setup_case oc-merge-additive-off
  oc_data="$CONTAINER_ROOT/.local/share/opencode"
  mkdir -p "$oc_data"
  sqlite3 "$oc_data/opencode.db" \
    "CREATE TABLE session_v2 (id TEXT PRIMARY KEY, data TEXT);
     CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT, time_archived INTEGER);
     CREATE TABLE migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
     INSERT INTO session_v2 VALUES ('contB', '{}');
     INSERT INTO migration VALUES ('m1', 1), ('$ADD_ID', 2);"
  mkdir -p "$HOME/.local/share/opencode"
  sqlite3 "$HOME/.local/share/opencode/opencode.db" \
    "CREATE TABLE session_v2 (id TEXT PRIMARY KEY, data TEXT);
     CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
     CREATE TABLE migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
     INSERT INTO session_v2 VALUES ('hostA', '{}');
     INSERT INTO migration VALUES ('m1', 1);"
  : >"$LOGS"
  AIDC_OPENCODE_ADDITIVE_MIGRATIONS="" aidc::sync_session_tool "/home/alice/app" opencode
  n="$(sqlite3 "$HOME/.local/share/opencode/opencode.db" "SELECT count(*) FROM session_v2;")"
  if [[ "$n" == "1" ]] && grep -Fq "newer schema epoch" "$LOGS"; then
    ok "opencode.db: explicitly-empty allowlist knob restores the conservative skip"
  else
    fail "opencode.db knob-off case wrong: count=$n logs=$(cat "$LOGS")"
  fi

  # ── 14g. case-variant journal table name → still never merged ─────────────
  # SQL addresses tables case-insensitively (`SELECT id FROM migration` reads
  # a `Migration`-cased table fine), so the merge's journal exclusion must not
  # be an exact bash match such a db could slip past — that would insert the
  # gap id into the host journal (the falsification the exclusion exists for).
  setup_case oc-merge-additive-journal-case
  oc_data="$CONTAINER_ROOT/.local/share/opencode"
  mkdir -p "$oc_data"
  sqlite3 "$oc_data/opencode.db" \
    "CREATE TABLE session_v2 (id TEXT PRIMARY KEY, data TEXT);
     CREATE TABLE Migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
     INSERT INTO session_v2 VALUES ('contB', '{}');
     INSERT INTO Migration VALUES ('m1', 1), ('$ADD_ID', 2);"
  mkdir -p "$HOME/.local/share/opencode"
  sqlite3 "$HOME/.local/share/opencode/opencode.db" \
    "CREATE TABLE session_v2 (id TEXT PRIMARY KEY, data TEXT);
     CREATE TABLE Migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
     INSERT INTO session_v2 VALUES ('hostA', '{}');
     INSERT INTO Migration VALUES ('m1', 1);"
  aidc::sync_session_tool "/home/alice/app" opencode
  bdb="$HOME/.local/share/opencode/opencode.db"
  ns="$(sqlite3 "$bdb" "SELECT count(*) FROM session_v2;")"
  nj="$(sqlite3 "$bdb" "SELECT count(*) FROM Migration;")"
  if [[ "$ns" == "2" && "$nj" == "1" ]]; then
    ok "opencode.db: case-variant journal table excluded from merge (gap id never lands)"
  else
    fail "opencode.db case-variant journal merged: session_v2=$ns journal=$nj"
  fi

  # ── 15. migration journal: host ahead (container a subset) → merge proceeds ─
  setup_case oc-merge-journal-behind
  oc_data="$CONTAINER_ROOT/.local/share/opencode"
  mkdir -p "$oc_data"
  sqlite3 "$oc_data/opencode.db" \
    "CREATE TABLE session (id TEXT PRIMARY KEY, data TEXT);
     CREATE TABLE migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
     INSERT INTO session VALUES ('contB', '{\"cwd\":\"/workspace/proj\"}');
     INSERT INTO migration VALUES ('m1', 1);"
  mkdir -p "$HOME/.local/share/opencode"
  sqlite3 "$HOME/.local/share/opencode/opencode.db" \
    "CREATE TABLE session (id TEXT PRIMARY KEY, data TEXT);
     CREATE TABLE migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
     INSERT INTO session VALUES ('hostA', '{}');
     INSERT INTO migration VALUES ('m1', 1), ('m2_new', 2);"
  : >"$LOGS"
  aidc::sync_session_tool "/home/alice/app" opencode
  bdb="$HOME/.local/share/opencode/opencode.db"
  got="$(sqlite3 "$bdb" "SELECT data FROM session WHERE id='contB';")"
  nj="$(sqlite3 "$bdb" "SELECT count(*) FROM migration;")"
  if [[ "$got" == '{"cwd":"/home/alice/app/proj"}' && "$nj" == "2" ]]; then
    ok "opencode.db: host journal ahead → merged, journal stays host-complete"
  else
    fail "opencode.db journal-behind merge wrong: contB=$got migration_rows=$nj"
  fi
  if ! grep -Fq "skipping merge" "$LOGS"; then
    ok "opencode.db: host-ahead merge logs no schema skip"
  else
    fail "opencode.db host-ahead merge logged a skip: $(cat "$LOGS")"
  fi

  # ── 16. journal on one side only → skip (can't reason about the epoch) ─────
  setup_case oc-merge-journal-one-sided
  oc_data="$CONTAINER_ROOT/.local/share/opencode"
  mkdir -p "$oc_data"
  sqlite3 "$oc_data/opencode.db" \
    "CREATE TABLE session (id TEXT PRIMARY KEY, data TEXT);
     CREATE TABLE migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
     INSERT INTO session VALUES ('contB', '{}');
     INSERT INTO migration VALUES ('m1', 1);"
  mkdir -p "$HOME/.local/share/opencode"
  mk_session_db "$HOME/.local/share/opencode/opencode.db" \
    "INSERT INTO session VALUES ('hostA', '{}');"
  : >"$LOGS"
  aidc::sync_session_tool "/home/alice/app" opencode
  n="$(sqlite3 "$HOME/.local/share/opencode/opencode.db" "SELECT count(*) FROM session;")"
  if [[ "$n" == "1" ]] && [[ -f "$(echo "$HOME"/.local/share/aidc/sessions/opencode/*/)opencode.db" ]]; then
    ok "opencode.db: journal present on one side only → skipped, quarantine kept"
  else
    fail "opencode.db one-sided journal not skipped safely: host session count=$n"
  fi
  if grep -Fq "migration journal present on only one side" "$LOGS"; then
    ok "opencode.db: one-sided-journal skip names its cause"
  else
    fail "opencode.db one-sided skip message wrong: $(cat "$LOGS")"
  fi

  # ── 17. auto_sync_sessions_fresh: the post-exit sync runs ON-DISK code ────
  # The 2026-10-14 scenario in miniature: a wrapper that sourced its sync
  # functions before an edit must still sync with the code now on disk.
  setup_case oc-fresh-reload
  oc_data="$CONTAINER_ROOT/.local/share/opencode"
  mkdir -p "$oc_data"
  mk_session_db "$oc_data/opencode.db" \
    "INSERT INTO session VALUES ('contB', '{\"cwd\":\"/workspace/proj\"}');"
  mkdir -p "$HOME/.local/share/opencode"
  mk_session_db "$HOME/.local/share/opencode/opencode.db" \
    "INSERT INTO session VALUES ('hostA', '{}');"
  # auto_sync_sessions probes for a running container first — satisfy it.
  aidc::compose_capture() {
    if [[ "$2" == "ps" ]]; then printf 'fake-container\n'; return 0; fi
    shift 4  # <ws> exec -T workspace
    stub_translate_argv "$@"
    "${STUB_ARGV[@]}"
  }
  # Shadow the sync implementation the way a stale in-memory copy differs
  # from disk: if the parent's definition runs, only a marker is written.
  shadow_ran="$TMP_ROOT/shadow-ran"
  aidc::sync_session_tool() { printf 'stale\n' >>"$shadow_ran"; }
  # AIDC_ROOT set (as bin/aidc exports): the fresh path re-sources the
  # on-disk module in a subshell — the REAL sync must run, not the shadow.
  AIDC_ROOT="$REPO_ROOT"
  # shellcheck disable=SC2218  # defined via the sourced lib, not lexically
  aidc::auto_sync_sessions_fresh "/home/alice/app" opencode
  got="$(sqlite3 "$HOME/.local/share/opencode/opencode.db" "SELECT data FROM session WHERE id='contB';" 2>/dev/null || true)"
  if [[ "$got" == '{"cwd":"/home/alice/app/proj"}' && ! -e "$shadow_ran" ]]; then
    ok "auto_sync_sessions_fresh re-sources the on-disk module (stale shadow ignored)"
  else
    fail "fresh sync did not run on-disk code: contB=$got shadow=$([[ -e "$shadow_ran" ]] && echo yes || echo no)"
  fi
  # Without AIDC_ROOT (tests source the lib without bin/aidc): the parent's
  # definitions — here the shadow — are the intended ones.
  AIDC_ROOT=""
  # shellcheck disable=SC2218  # defined via the sourced lib, not lexically
  aidc::auto_sync_sessions_fresh "/home/alice/app" opencode
  if [[ -e "$shadow_ran" ]]; then
    ok "auto_sync_sessions_fresh falls back to in-process sync without AIDC_ROOT"
  else
    fail "fallback path did not use the parent's definitions"
  fi
  # The opt-out knob gates the fresh path itself (AIDC_ROOT re-set — the
  # previous sub-case left it empty, which would only exercise the fallback).
  rm -f "$shadow_ran"
  AIDC_ROOT="$REPO_ROOT"
  AIDC_AUTO_SYNC_SESSIONS=0
  # shellcheck disable=SC2218  # defined via the sourced lib, not lexically
  aidc::auto_sync_sessions_fresh "/home/alice/app" opencode
  if [[ ! -e "$shadow_ran" ]] \
     && [[ "$(sqlite3 "$HOME/.local/share/opencode/opencode.db" "SELECT count(*) FROM session;")" == "2" ]]; then
    ok "AIDC_AUTO_SYNC_SESSIONS=0 gates the fresh post-exit sync"
  else
    fail "knob-off not honored on the fresh path"
  fi
  unset AIDC_AUTO_SYNC_SESSIONS
  # A broken tree must SKIP, never fall through to the parent's (stale)
  # definitions: an unparseable module (bash -n gate) and a missing module
  # both leave the shadow unrun and the host db untouched.
  broken_root="$TMP_ROOT/broken-aidc-root"
  mkdir -p "$broken_root/lib/aidc"
  printf 'if [[ -n "broken"; then\n' >"$broken_root/lib/aidc/sync.sh"
  AIDC_ROOT="$broken_root"
  # shellcheck disable=SC2218  # defined via the sourced lib, not lexically
  aidc::auto_sync_sessions_fresh "/home/alice/app" opencode
  rm -f "$broken_root/lib/aidc/sync.sh"
  # shellcheck disable=SC2218  # defined via the sourced lib, not lexically
  aidc::auto_sync_sessions_fresh "/home/alice/app" opencode
  if [[ ! -e "$shadow_ran" ]] \
     && [[ "$(sqlite3 "$HOME/.local/share/opencode/opencode.db" "SELECT count(*) FROM session;")" == "2" ]]; then
    ok "auto_sync_sessions_fresh skips on unparseable/missing module (no stale fallback)"
  else
    fail "broken-module case ran stale code: shadow=$([[ -e "$shadow_ran" ]] && echo yes || echo no)"
  fi
  unset AIDC_ROOT
  # Restore the real definitions shadowed above (the same mechanism the
  # fresh helper uses) and the original compose_capture stub, so nothing
  # leaks past this section.
  # shellcheck disable=SC1090,SC1091
  . "$REPO_ROOT/lib/aidc/sync.sh"
  aidc::compose_capture() {
    shift 4  # <ws> exec -T workspace
    stub_translate_argv "$@"
    "${STUB_ARGV[@]}"
  }

else
  printf 'skip: opencode.db SQLite merge cases (sqlite3 not installed)\n'
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
