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
# /home/vscode-prefixed path in <cmd> to point into the fixture tree (which
# mirrors the container's /home/vscode layout), and run the command locally —
# so the gate probe (`test ...`) and the tar stream behave as if in-container.
CONTAINER_ROOT=""
STUB_ARGV=()
stub_translate_argv() {
  STUB_ARGV=()
  local a
  for a in "$@"; do
    case "$a" in
      /home/vscode|/home/vscode/*) a="$CONTAINER_ROOT${a#/home/vscode}" ;;
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
aidc::log() { :; }

# Build a fresh container-side fixture (standing in for the container's
# /home/vscode) and point HOME at a clean host tree. Sets CONTAINER_ROOT, HOME
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
  aidc::sync_session_tool "/home/alice/app" opencode
  n="$(sqlite3 "$HOME/.local/share/opencode/opencode.db" "SELECT count(*) FROM session;")"
  if [[ "$n" == "1" ]] && [[ -f "$(echo "$HOME"/.local/share/aidc/sessions/opencode/*/)opencode.db" ]]; then
    ok "opencode.db: schema drift skips merge, host db untouched, quarantine kept"
  else
    fail "opencode.db schema-drift not skipped safely: host session count=$n"
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

else
  printf 'skip: opencode.db SQLite merge cases (sqlite3 not installed)\n'
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
