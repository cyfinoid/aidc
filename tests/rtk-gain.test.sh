#!/usr/bin/env bash
#
# Unit tests for rtk savings tracking:
#   - the Claude Code SessionEnd reporter
#     (templates/devcontainer/scripts/rtk-session-end.sh.tmpl)
#   - the settings.json seeding + per-agent rtk wiring in
#     bootstrap-state.sh.tmpl (ensure_rtk_session_end_settings,
#     wire_rtk_opencode/cursor/omp)
#   - the host-side quarantine sync + additive merge into the host's own rtk
#     db (lib/aidc/sync.sh: sync_session_tool rtk, aidc::rtk_merge_to_base)
#
# rtk is stubbed on PATH (emulating the pinned 0.48.0 install layout, incl.
# the cursor mkdir bug); sqlite3 fixtures stand in for the dbs. The container
# plumbing (compose exec + tar) is stubbed like sync-sessions.test.sh, so the
# test needs neither Docker nor a running container. Run with:
#   bash tests/rtk-gain.test.sh
# shellcheck disable=SC1090,SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/templates/devcontainer/scripts/rtk-session-end.sh.tmpl"
BOOTSTRAP="$REPO_ROOT/templates/devcontainer/scripts/bootstrap-state.sh.tmpl"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

require() { command -v "$1" >/dev/null 2>&1 || { printf 'skip: %s not on PATH\n' "$1"; exit 0; }; }
require sqlite3
require jq

# ── stub rtk: install modes create the files the real 0.48.0 build creates ──
STUB_BIN="$TMP_ROOT/bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/rtk" <<'STUB'
#!/usr/bin/env bash
# Emulates `rtk init` (file layout incl. the cursor tmp-write mkdir bug and
# the CLAUDE_CONFIG_DIR leak) and `rtk gain -f json` (fixed shape of the
# pinned build). GAIN_JSON overrides the gain payload.
set -u
if [[ "${1:-}" == "gain" ]]; then
  printf '%s\n' "${GAIN_JSON:-{\"summary\":{\"total_commands\":9,\"total_input\":1116,\"total_output\":451,\"total_saved\":665,\"avg_savings_pct\":59.587813620071685,\"total_time_ms\":10,\"avg_time_ms\":1}}}"
  exit 0
fi
[[ "${1:-}" == "init" ]] || exit 0
agent=claude opencode=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --opencode) opencode=1 ;;
    --agent) agent="$2"; shift ;;
  esac
  shift
done
home="${HOME:?}"
# Real rtk honors CLAUDE_CONFIG_DIR over HOME and patches its claude
# integration on every init (verified live) — mirror that so the omp wiring's
# `env -u` guard is actually tested.
if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
  mkdir -p "$CLAUDE_CONFIG_DIR"
  printf 'stub\n' >"$CLAUDE_CONFIG_DIR/RTK.md"
fi
write() { # <path> <content>
  local d
  d="$(dirname "$1")"
  if [[ "$1" == "$home/.cursor/"* ]]; then
    # Real rtk 0.48.0 writes ~/.cursor/hooks.json tmp+rename style WITHOUT
    # creating the directory first (verified live): mirror that, so the
    # bootstrap's pre-create workaround is actually tested.
    [[ -d "$d" ]] || exit 1
  else
    mkdir -p "$d"
  fi
  printf '%s\n' "$2" >"$1"
}
if [[ "$opencode" == "1" ]]; then
  write "$home/.config/opencode/plugins/rtk.ts" "// rtk opencode plugin (stub)"
  exit 0
fi
case "$agent" in
  cursor) write "$home/.cursor/hooks.json" '{"version":1,"hooks":{"preToolUse":[{"command":"rtk hook cursor","matcher":"Shell"}]}}' ;;
  pi)     write "$home/.pi/agent/extensions/rtk.ts" "// rtk pi extension (stub)" ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/rtk"

# ── fixture workspace + homes ────────────────────────────────────────────────
WS="$TMP_ROOT/ws"
mkdir -p "$WS/.ai-container" "$TMP_ROOT/home"
run_hook() { # [payload]
  local payload="${1:-{\}}"
  PATH="$STUB_BIN:$PATH" HOME="$TMP_ROOT/home" AIDC_RTK_HOOK_WORKSPACE="$WS" \
    bash "$HOOK" <<<"$payload"
}

# ── 1-4: SessionEnd reporter ─────────────────────────────────────────────────
# 1. Gain available -> one-liner on stderr, exit 2 (the documented SessionEnd
#    display channel; the hook cannot block the exit).
rc=0
err="$(run_hook '{"session_id":"s1","reason":"exit"}' 2>&1 >/dev/null)" || rc=$?
if [[ "$rc" -eq 2 ]] && [[ "$err" == *"rtk: 665 tokens saved (59%) over 9 commands"* ]]; then
  ok "prints the savings summary on stderr and exits 2"
else
  fail "happy path: rc=$rc err=$err"
fi

# 2. Knob off -> silent exit 0.
printf 'AIDC_RTK_SESSION_END_HOOK=0\n' >"$WS/.ai-container/project.env"
if run_hook >/dev/null 2>&1; then
  ok "AIDC_RTK_SESSION_END_HOOK=0 silences the reporter"
else
  fail "knob-off case"
fi

# 3. rtk missing (real rtk lives in /usr/local/bin; CI has none) -> fail open.
rm -f "$WS/.ai-container/project.env"
if PATH="/usr/bin:/bin" HOME="$TMP_ROOT/home" AIDC_RTK_HOOK_WORKSPACE="$WS" \
     bash "$HOOK" <<< '{}' >/dev/null 2>&1; then
  ok "missing rtk fails open"
else
  fail "missing-rtk case"
fi

# 4. Unparseable gain -> fail open.
if GAIN_JSON='not json at all' run_hook >/dev/null 2>&1; then
  ok "garbage rtk gain fails open"
else
  fail "garbage-gain case"
fi

# ── 5-8: settings.json seeding (bootstrap patcher) ───────────────────────────
# home_dir is captured when the template is sourced, so the fixture container
# home must be exported BEFORE — and the stub rtk writes under $HOME, so the
# wiring cases below need HOME pointed at the same fixture (as in production,
# where AIDC_CONTAINER_HOME is the container $HOME).
export AIDC_CONTAINER_HOME="$TMP_ROOT/agent-home"
export HOME="$AIDC_CONTAINER_HOME"
mkdir -p "$AIDC_CONTAINER_HOME"
. "$BOOTSTRAP" 2>/dev/null || true   # guarded dispatch: safe to source
SETTINGS="$TMP_ROOT/settings.json"
HOOK_CMD="$TMP_ROOT/scripts/rtk-session-end.sh"
mkdir -p "$(dirname "$HOOK_CMD")"; printf '#!stub\n' >"$HOOK_CMD"

# 5. Seeding into a missing file creates the SessionEnd entry.
rm -f "$SETTINGS"
AIDC_RTK_SESSION_END_HOOK=1 ensure_rtk_session_end_settings "$SETTINGS" "$HOOK_CMD"
if jq -e --arg c "$HOOK_CMD" \
     '.hooks.SessionEnd[]?.hooks[]? | select(.command == $c)' "$SETTINGS" >/dev/null; then
  ok "seeding creates the SessionEnd hook"
else
  fail "seeded settings: $(cat "$SETTINGS")"
fi

# 6. Idempotent, and sibling hooks (rtk PreToolUse, aidc Stop) survive.
jq '.hooks.PreToolUse = [{"matcher":"Bash","hooks":[{"type":"command","command":"rtk hook claude"}]}]
    | .hooks.Stop = [{"hooks":[{"type":"command","command":"aidc-scan-hook.sh"}]}]' \
  "$SETTINGS" >"$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
AIDC_RTK_SESSION_END_HOOK=1 ensure_rtk_session_end_settings "$SETTINGS" "$HOOK_CMD"
AIDC_RTK_SESSION_END_HOOK=1 ensure_rtk_session_end_settings "$SETTINGS" "$HOOK_CMD"
count="$(jq --arg c "$HOOK_CMD" \
  '[.hooks.SessionEnd[]?.hooks[]? | select(.command == $c)] | length' "$SETTINGS")"
if [[ "$count" == "1" ]] \
   && jq -e '.hooks.PreToolUse[0].hooks[0].command == "rtk hook claude"' "$SETTINGS" >/dev/null \
   && jq -e '.hooks.Stop[0].hooks[0].command == "aidc-scan-hook.sh"' "$SETTINGS" >/dev/null; then
  ok "seeding is idempotent and preserves sibling hooks"
else
  fail "idempotence: count=$count settings=$(cat "$SETTINGS")"
fi

# 7. Knob off removes only ours.
AIDC_RTK_SESSION_END_HOOK=0 ensure_rtk_session_end_settings "$SETTINGS" "$HOOK_CMD"
count="$(jq --arg c "$HOOK_CMD" \
  '[.hooks.SessionEnd[]?.hooks[]? | select(.command == $c)] | length' "$SETTINGS")"
if [[ "$count" == "0" ]] \
   && jq -e '.hooks.PreToolUse[0].hooks[0].command == "rtk hook claude"' "$SETTINGS" >/dev/null; then
  ok "knob off removes the reporter, keeps sibling hooks"
else
  fail "removal: count=$count settings=$(cat "$SETTINGS")"
fi

# 8. Missing script + knob on -> entry is not added (fail closed on absence,
#    so a stale settings.json never points at a nonexistent script).
rm -f "$SETTINGS"
AIDC_RTK_SESSION_END_HOOK=1 ensure_rtk_session_end_settings "$SETTINGS" "$TMP_ROOT/scripts/does-not-exist.sh"
if [[ ! -e "$SETTINGS" ]] || ! jq -e '.hooks.SessionEnd' "$SETTINGS" >/dev/null 2>&1; then
  ok "missing reporter script: no hook entry added"
else
  fail "missing-script case: $(cat "$SETTINGS")"
fi

# ── 9-12: per-agent rtk wiring (bootstrap) ───────────────────────────────────
# 9. opencode: plugin installed (and re-installed after a wipe — copy_dir_
#     from_seed rsync --deletes it in sync mode, so wire must repair).
PATH="$STUB_BIN:$PATH" sync_opencode
if [[ -f "$HOME/.config/opencode/plugins/rtk.ts" ]]; then
  ok "opencode plugin installed"
else
  fail "opencode wiring"
fi
rm -rf "$HOME/.config/opencode/plugins"
PATH="$STUB_BIN:$PATH" sync_opencode
if [[ -f "$HOME/.config/opencode/plugins/rtk.ts" ]]; then
  ok "opencode plugin repaired after sync-mode wipe"
else
  fail "opencode repair"
fi

# 10. cursor: hooks.json created (the stub fails like real rtk when ~/.cursor
#     is missing, so this proves the pre-create workaround).
PATH="$STUB_BIN:$PATH" sync_cursor
if jq -e '.hooks.preToolUse[0].command == "rtk hook cursor"' \
     "$HOME/.cursor/hooks.json" >/dev/null; then
  ok "cursor hooks.json created despite rtk's missing-mkdir bug"
else
  fail "cursor wiring: $(cat "$HOME/.cursor/hooks.json" 2>/dev/null)"
fi

# 11. omp: pi extension lands under ~/.omp/agent/extensions/, and the pi
#     installer's throwaway HOME never leaked into CLAUDE_CONFIG_DIR.
export CLAUDE_CONFIG_DIR="$TMP_ROOT/claude-canary"
PATH="$STUB_BIN:$PATH" sync_omp
if [[ -f "$HOME/.omp/agent/extensions/rtk.ts" ]] \
   && [[ ! -e "$CLAUDE_CONFIG_DIR" ]]; then
  ok "omp extension placed; CLAUDE_CONFIG_DIR not leaked into pi install"
else
  fail "omp wiring (ext=$([[ -f $HOME/.omp/agent/extensions/rtk.ts ]] && echo yes || echo no) canary=$([[ -e $CLAUDE_CONFIG_DIR ]] && echo yes || echo no))"
fi
unset CLAUDE_CONFIG_DIR

# 12. Without rtk on PATH the wiring no-ops (slim builds).
rm -rf "$HOME/.config/opencode/plugins" "$HOME/.cursor/hooks.json"
PATH="/usr/bin:/bin" sync_opencode
PATH="/usr/bin:/bin" sync_cursor
if [[ ! -e "$HOME/.config/opencode/plugins/rtk.ts" ]] \
   && [[ ! -e "$HOME/.cursor/hooks.json" ]]; then
  ok "missing rtk: wiring no-ops"
else
  fail "no-rtk case"
fi

# ── 13-19: host-side sync + merge (lib/aidc/sync.sh) ─────────────────────────
. "$REPO_ROOT/lib/aidc.sh"
aidc::log() { :; }
aidc::warn() { :; }

# The sync paths resolve host destinations under $HOME (and the host-db
# resolver under XDG_DATA_HOME) — point both at fixture trees.
HOST_HOME="$TMP_ROOT/host-home"
export HOME="$HOST_HOME"
unset XDG_DATA_HOME
mkdir -p "$HOST_HOME"

# Container-side fixture tree; compose stubs run the probes/tar locally
# (same approach as sync-sessions.test.sh).
CONTAINER_ROOT="$TMP_ROOT/container"
mkdir -p "$CONTAINER_ROOT/.local/share/rtk/tee"
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

RTK_SCHEMA_CMDS="CREATE TABLE commands (id INTEGER PRIMARY KEY, timestamp TEXT NOT NULL, original_cmd TEXT NOT NULL, rtk_cmd TEXT NOT NULL, input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL, saved_tokens INTEGER NOT NULL, savings_pct REAL NOT NULL, exec_time_ms INTEGER DEFAULT 0, project_path TEXT DEFAULT '')"
RTK_SCHEMA_HOOKS="CREATE TABLE hook_decisions (id INTEGER PRIMARY KEY, timestamp TEXT NOT NULL, session_id TEXT NOT NULL, tool_use_id TEXT NOT NULL, project_path TEXT DEFAULT '', raw_cmd TEXT NOT NULL, decision TEXT NOT NULL, rewritten_cmd TEXT, rtk_version TEXT NOT NULL)"
RTK_SCHEMA_FAILS="CREATE TABLE parse_failures (id INTEGER PRIMARY KEY, timestamp TEXT NOT NULL, raw_command TEXT NOT NULL, error_message TEXT NOT NULL, fallback_succeeded INTEGER NOT NULL DEFAULT 0)"

# 13. Sync pulls history.db into the per-project quarantine and leaves tee/
#     out (merge opted out here so this exercises ONLY the quarantine step —
#     the merge itself is tested below against a controlled host db).
sqlite3 "$CONTAINER_ROOT/.local/share/rtk/history.db" \
  "$RTK_SCHEMA_CMDS; $RTK_SCHEMA_HOOKS; $RTK_SCHEMA_FAILS;
   INSERT INTO commands (timestamp, original_cmd, rtk_cmd, input_tokens, output_tokens, saved_tokens, savings_pct, exec_time_ms, project_path) VALUES
     ('2026-09-10T10:11:33.022205306+00:00','ls /workspace','rtk ls /workspace',217,55,162,74.6,0,'/workspace');"
printf 'bulky output log\n' >"$CONTAINER_ROOT/.local/share/rtk/tee/1234_ls.log"
AIDC_RTK_MERGE_TO_BASE=0 aidc::sync_session_tool "$WS" rtk
Q="$HOST_HOME/.local/share/aidc/rtk/$(aidc::repo_slug "$WS")"
if [[ -f "$Q/history.db" ]] && [[ ! -e "$Q/tee" ]] \
   && [[ "$(sqlite3 "$Q/history.db" 'SELECT COUNT(*) FROM commands')" == "1" ]]; then
  ok "sync quarantines history.db, excludes tee/"
else
  fail "sync: Q=$Q ($(find "$Q" -mindepth 1 -maxdepth 1 2>/dev/null | tr '\n' ' '))"
fi

# 14. Merge into an existing host db: overlapping integer ids must not drop or
#     duplicate rows (3 host + 1 container -> 4), /workspace is rewritten, and
#     no scratch files (snapshot, staged copy) survive a successful merge.
HOST_DB="$HOST_HOME/.local/share/rtk/history.db"
mkdir -p "$(dirname "$HOST_DB")"
sqlite3 "$HOST_DB" \
  "$RTK_SCHEMA_CMDS; $RTK_SCHEMA_HOOKS; $RTK_SCHEMA_FAILS;
   INSERT INTO commands (timestamp, original_cmd, rtk_cmd, input_tokens, output_tokens, saved_tokens, savings_pct, exec_time_ms, project_path) VALUES
     ('2026-01-01T10:00:00.000000001+00:00','git status','rtk git status',100,40,60,60.0,1,'$WS'),
     ('2026-01-01T10:00:01.000000002+00:00','ls -la','rtk ls -la',50,10,40,80.0,1,'$WS'),
     ('2026-01-01T10:00:02.000000003+00:00','npm test','rtk test',200,90,110,55.0,2,'$WS');"
aidc::rtk_merge_to_base "$WS" "$Q"
n="$(sqlite3 "$HOST_DB" 'SELECT COUNT(*) FROM commands')"
pp="$(sqlite3 "$HOST_DB" "SELECT project_path FROM commands WHERE original_cmd = 'ls /workspace'")"
if [[ "$n" == "4" && "$pp" == "$WS" ]] \
   && [[ ! -e "$HOST_DB.aidc-bak" && ! -e "$Q/.rtk.merge.db" ]]; then
  ok "merge survives overlapping integer ids, rewrites project_path, cleans up"
else
  fail "merge: n=$n pp=$pp bak=$([[ -e $HOST_DB.aidc-bak ]] && echo yes || echo no) mdb=$([[ -e $Q/.rtk.merge.db ]] && echo yes || echo no)"
fi

# 15. Re-merge is a no-op (natural-key dedupe).
aidc::rtk_merge_to_base "$WS" "$Q"
if [[ "$(sqlite3 "$HOST_DB" 'SELECT COUNT(*) FROM commands')" == "4" ]]; then
  ok "re-merge is a no-op"
else
  fail "re-merge duplicated rows"
fi

# 16. Schema drift (container rtk newer): merge refused, quarantine kept, no
#     snapshot (the gate runs before any host-db write).
sqlite3 "$Q/history.db" "ALTER TABLE commands ADD COLUMN extra_col TEXT;"
before="$(sqlite3 "$HOST_DB" 'SELECT COUNT(*) FROM commands')"
aidc::rtk_merge_to_base "$WS" "$Q"
if [[ "$(sqlite3 "$HOST_DB" 'SELECT COUNT(*) FROM commands')" == "$before" ]] \
   && [[ -f "$Q/history.db" ]] && [[ ! -e "$HOST_DB.aidc-bak" ]]; then
  ok "schema drift refuses the merge, quarantine kept, no leftover snapshot"
else
  fail "schema-drift case"
fi

# 17. No host db at the override: wholesale create (paths already rewritten).
HOST_DB2="$TMP_ROOT/host2/rtk/history.db"
rm -rf "$TMP_ROOT/host2"
AIDC_RTK_DB="$HOST_DB2" aidc::rtk_merge_to_base "$WS" "$Q"
if [[ "$(sqlite3 "$HOST_DB2" 'SELECT COUNT(*) FROM commands')" == "1" ]] \
   && [[ "$(sqlite3 "$HOST_DB2" "SELECT project_path FROM commands")" == "$WS" ]]; then
  ok "missing host db is created wholesale (path-rewritten)"
else
  fail "wholesale-create case"
fi

# 18. Opt-out keeps the host db untouched.
before="$(sqlite3 "$HOST_DB" 'SELECT COUNT(*) FROM commands')"
AIDC_RTK_MERGE_TO_BASE=0 aidc::rtk_merge_to_base "$WS" "$Q"
if [[ "$(sqlite3 "$HOST_DB" 'SELECT COUNT(*) FROM commands')" == "$before" ]]; then
  ok "AIDC_RTK_MERGE_TO_BASE=0 skips the merge"
else
  fail "opt-out case"
fi

# 19. hook_decisions + parse_failures merge by their natural keys (quarantine
#     rebuilt fresh — case 16 drifted its schema on purpose).
rm -f "$Q/history.db"
sqlite3 "$Q/history.db" \
  "$RTK_SCHEMA_CMDS; $RTK_SCHEMA_HOOKS; $RTK_SCHEMA_FAILS;
   INSERT INTO commands (timestamp, original_cmd, rtk_cmd, input_tokens, output_tokens, saved_tokens, savings_pct, exec_time_ms, project_path) VALUES
     ('2026-09-10T10:11:33.022205306+00:00','ls /workspace','rtk ls /workspace',217,55,162,74.6,0,'/workspace');
   INSERT INTO hook_decisions (timestamp, session_id, tool_use_id, project_path, raw_cmd, decision, rewritten_cmd, rtk_version) VALUES
     ('2026-09-10T10:11:33.022205306+00:00','ctr-sess','tu_ctr_1','/workspace','ls /workspace','rewrite','rtk ls /workspace','0.48.0');
   INSERT INTO parse_failures (timestamp, raw_command, error_message) VALUES
     ('2026-09-10T10:13:00.555555555+00:00','odd cmd','parse fail');"
aidc::rtk_merge_to_base "$WS" "$Q"
if [[ "$(sqlite3 "$HOST_DB" 'SELECT COUNT(*) FROM hook_decisions')" == "1" ]] \
   && [[ "$(sqlite3 "$HOST_DB" 'SELECT COUNT(*) FROM parse_failures')" == "1" ]] \
   && [[ "$(sqlite3 "$HOST_DB" "SELECT project_path FROM hook_decisions")" == "$WS" ]] \
   && [[ "$(sqlite3 "$HOST_DB" 'SELECT COUNT(*) FROM commands')" == "4" ]]; then
  ok "hook_decisions/parse_failures merge; commands still deduped"
else
  fail "aux-tables case: hd=$(sqlite3 "$HOST_DB" 'SELECT COUNT(*) FROM hook_decisions') pf=$(sqlite3 "$HOST_DB" 'SELECT COUNT(*) FROM parse_failures') c=$(sqlite3 "$HOST_DB" 'SELECT COUNT(*) FROM commands')"
fi

# ── 20-23: static wiring assertions ──────────────────────────────────────────
# 20. omp launch guard present in run_tool.
if grep -q 'AIDC_RTK_OMP_EXTENSION' "$REPO_ROOT/lib/aidc/runtime.sh" \
   && grep -q -- '--extension' "$REPO_ROOT/lib/aidc/runtime.sh"; then
  ok "omp launch guard wired in run_tool"
else
  fail "omp guard missing"
fi

# 21. rtk_data volume declared and mounted.
if grep -q 'source: rtk_data' "$REPO_ROOT/templates/devcontainer/compose.yaml.tmpl" \
   && grep -qE '^  rtk_data:' "$REPO_ROOT/templates/devcontainer/compose.yaml.tmpl"; then
  ok "rtk_data volume declared + mounted"
else
  fail "compose volume"
fi

# 22. Template registered in both maps; sync_claude seeds RTK.md; sqlite3 in image.
if grep -q 'rtk-session-end.sh.tmpl:.devcontainer/scripts/rtk-session-end.sh:0755' "$REPO_ROOT/lib/aidc/common.sh" \
   && grep -q '".devcontainer/scripts/rtk-session-end.sh"' "$REPO_ROOT/lib/aidc/common.sh"; then
  ok "template registered in overwrite map + managed paths"
else
  fail "template map registration"
fi
if grep -q '/host-seed/claude/RTK.md' "$REPO_ROOT/templates/devcontainer/scripts/bootstrap-state.sh.tmpl"; then
  ok "sync_claude seeds RTK.md"
else
  fail "RTK.md seed"
fi
if grep -q 'sqlite3' "$REPO_ROOT/templates/devcontainer/Dockerfile.base.tmpl"; then
  ok "sqlite3 installed in the base image"
else
  fail "sqlite3 in image"
fi

# 23. rtk rides along with the wired agents' auto-sync.
if grep -A3 'rides along' "$REPO_ROOT/lib/aidc/sync.sh" | grep -q 'claude|opencode|cursor-agent'; then
  ok "auto-sync pulls rtk history for wired agents"
else
  fail "auto-sync piggyback"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
