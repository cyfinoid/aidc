#!/usr/bin/env bash
# aidc module: Session-transcript and agent-config sync between container and host.
# Sourced by lib/aidc.sh — never directly. Functions moved verbatim from
# the former monolith; behavior changes ride their own commits.

aidc::cmd_sync_config() {
  local workspace
  workspace="$(aidc::default_workspace)"
  local tool="${1:-}"
  [[ -n "$tool" ]] || aidc::die "usage: aidc sync-config <claude|codex|opencode|grok|omp|cursor|all>"
  aidc::ensure_container_running "$workspace"
  aidc::compose "$workspace" exec workspace /workspace/.devcontainer/scripts/bootstrap-state.sh sync "$tool"
  aidc::log "synced $tool config into the container volume"
}

aidc::cmd_sync_sessions() {
  local workspace
  workspace="$(aidc::default_workspace)"
  # Default to all agents — partial syncs surprised people (transcripts from
  # codex/opencode/grok silently missing on the host).
  local tool="${1:-all}"
  aidc::ensure_container_running "$workspace"

  case "$tool" in
    claude|codex|opencode|grok|omp|rtk|all) ;;
    *) aidc::die "usage: aidc sync-sessions [claude|codex|opencode|grok|omp|rtk|all]" ;;
  esac

  if [[ "$tool" == "all" ]]; then
    aidc::sync_session_tool "$workspace" claude
    aidc::sync_session_tool "$workspace" codex
    aidc::sync_session_tool "$workspace" opencode
    aidc::sync_session_tool "$workspace" grok
    aidc::sync_session_tool "$workspace" omp
    aidc::sync_session_tool "$workspace" rtk
  else
    aidc::sync_session_tool "$workspace" "$tool"
  fi
}

aidc::sync_session_tool() {
  local workspace="$1"
  local tool="$2"
  local container_src host_dst
  # Per-tool tar excludes (currently only opencode needs any): flags applied
  # to the *creation* side inside the container, so the GNU-tar exclude
  # semantics (dir pattern prunes its contents too) are what matters.
  local -a src_excludes=()
  # Existence probe run inside the container before anything is copied, plus
  # the human-readable reason used in the "nothing to sync" message.
  local -a gate=()
  local gate_desc

  case "$tool" in
    claude)
      container_src="/home/vscode/.claude/projects"
      host_dst="$HOME/.claude/projects"
      ;;
    codex)
      container_src="/home/vscode/.codex/sessions"
      host_dst="$HOME/.codex/sessions"
      ;;
    opencode)
      # opencode keeps sessions in the XDG *data* dir — never under
      # ~/.config/opencode (that is config only). Older builds wrote JSON
      # transcripts to storage/; current builds keep everything in a SQLite
      # opencode.db (+ -wal/-shm sidecars). The host's own opencode uses the
      # same data-dir path, so the container copy first lands in an aidc-owned
      # quarantine subtree — a raw tar extract over ~/.local/share/opencode
      # would clobber the host's own database (data loss, not a merge). The
      # merge INTO the host's default data dir happens afterwards, additively
      # and safety-gated, in aidc::opencode_merge_to_base (see the hook at the
      # end of this function).
      container_src="/home/vscode/.local/share/opencode"
      host_dst="$HOME/.local/share/aidc/sessions/opencode/$(aidc::repo_slug "${workspace:-/workspace}")"
      # Session artifacts only: credentials never leave the container, and
      # log/repos/snapshot/tool-output/bin are caches, not sessions.
      src_excludes=(
        --exclude=./auth.json
        --exclude=./log
        --exclude=./repos
        --exclude=./snapshot
        --exclude=./tool-output
        --exclude=./bin
      )
      # The data dir itself always exists (named volume mounts there), so
      # probe for actual session artifacts in either on-disk format.
      gate=(test -d "$container_src/storage" -o -f "$container_src/opencode.db")
      gate_desc="no session artifacts in $container_src"
      ;;
    grok)
      container_src="/home/vscode/.grok/sessions"
      host_dst="$HOME/.grok/sessions"
      ;;
    omp)
      # omp (oh-my-pi) stores conversations as JSONL under
      # ~/.omp/agent/sessions/<encoded-cwd>/<ts>_<id>.jsonl.
      container_src="/home/vscode/.omp/agent/sessions"
      host_dst="$HOME/.omp/agent/sessions"
      ;;
    rtk)
      # rtk's savings history: one SQLite db in the XDG data dir, shared by
      # every rtk-wired agent (claude hook, opencode plugin, cursor hooks.json,
      # omp extension). Copied to an aidc-owned quarantine first and merged
      # into the host's OWN rtk db afterwards (aidc::rtk_merge_to_base below) —
      # never extracted over the host's data dir, whose db sits at the same
      # path. tee/ holds raw command-output logs: bulky, not savings data.
      container_src="/home/vscode/.local/share/rtk"
      host_dst="$HOME/.local/share/aidc/rtk/$(aidc::repo_slug "${workspace:-/workspace}")"
      src_excludes=(--exclude=./tee)
      gate=(test -f "$container_src/history.db")
      gate_desc="no rtk history.db in $container_src"
      ;;
    *)
      aidc::die "unknown session tool: $tool"
      ;;
  esac

  if [[ ${#gate[@]} -gt 0 ]]; then
    if ! aidc::compose_capture "$workspace" exec -T workspace "${gate[@]}" >/dev/null 2>&1; then
      aidc::log "no $tool sessions to sync ($gate_desc)"
      return
    fi
  elif ! aidc::compose_capture "$workspace" exec -T workspace test -d "$container_src" >/dev/null 2>&1; then
    aidc::log "no $tool sessions to sync ($container_src missing)"
    return
  fi

  mkdir -p "$host_dst"
  # ${arr[@]+...} guard: empty-array expansion under `set -u` (bash 3.2) errors.
  aidc::compose "$workspace" exec -T workspace \
    tar -C "$container_src" -cf - ${src_excludes[@]+"${src_excludes[@]}"} . \
    | tar -C "$host_dst" --no-same-owner --no-same-permissions -xf -

  # Agent transcripts record absolute paths from inside the container, where the
  # repo is bind-mounted at /workspace (see compose.yaml.tmpl). Copied verbatim,
  # those `/workspace/...` paths do not exist on the host. Rewrite the in-container
  # mount root to the real host workspace path so synced logs/transcripts point at
  # paths that actually exist on this machine.
  if [[ -n "$workspace" && "$workspace" != "/workspace" ]]; then
    local esc_ws f
    esc_ws="$(printf '%s' "$workspace" | sed 's/[&|\\]/\\&/g')"
    while IFS= read -r f; do
      { sed "s|/workspace|${esc_ws}|g" "$f" >"$f.aidc-tmp" && mv "$f.aidc-tmp" "$f"; } \
        || rm -f "$f.aidc-tmp"
    done < <(find "$host_dst" -type f \( -name '*.jsonl' -o -name '*.json' \) 2>/dev/null)
  fi

  aidc::log "synced $tool sessions to $host_dst"

  # opencode's quarantined copy is additionally merged into the host's OWN
  # opencode data dir (the default ~/.local/share/opencode path) so session
  # viewers reading that default location see container sessions too. The
  # merge is additive and never overwrites host data — see the function.
  if [[ "$tool" == "opencode" ]]; then
    aidc::opencode_merge_to_base "$workspace" "$host_dst"
  fi

  # rtk's quarantined history is likewise merged into the host's OWN rtk db so
  # a plain host `rtk gain` reflects container savings — additive, never
  # overwriting host data (see the function).
  if [[ "$tool" == "rtk" ]]; then
    aidc::rtk_merge_to_base "$workspace" "$host_dst"
  fi
}

# Promote the quarantined opencode sessions (in $quarantine) into the host's
# own opencode data dir so tools reading the default ~/.local/share/opencode
# path see them — WITHOUT ever overwriting or corrupting the host's data.
#
# Two layouts, two strategies:
#   - legacy storage/ JSON: per-session files → a plain additive file copy
#     merges cleanly (the same model that makes claude's folder sync trivial).
#   - current opencode.db (SQLite): a single binary file can't be folder-merged,
#     so rows are merged with INSERT OR IGNORE (existing host rows always win).
#
# Every SQLite step is gated so the host db is only touched when it is provably
# safe; on any doubt we bail and leave the quarantine copy as the record:
#   - sqlite3 must be present on the host;
#   - the host db is snapshotted first (rollback + a liveness/lock probe);
#   - schemas must be merge-compatible: per shared table, the container's
#     columns (name:type, compared order-independently) must be a subset of the
#     host's, and when either db carries opencode's `migration` journal both
#     must and the container's applied ids must not run ahead of the host's
#     (epoch policy: docs/opencode-schema-epochs.md). Anything else → skip
#     rather than risk a partial/failed insert.
# The actual insert runs in one transaction with a busy_timeout, so against the
# host-native filesystem it is atomic even if the host's opencode is running.
#
# Opt out entirely (keep only the aidc quarantine) with
# AIDC_OPENCODE_MERGE_TO_BASE=0. Override the sqlite3 binary with AIDC_SQLITE3.
aidc::opencode_merge_to_base() {
  local workspace="$1"
  local quarantine="$2"
  [[ "${AIDC_OPENCODE_MERGE_TO_BASE:-1}" == "0" ]] && return 0

  local base="$HOME/.local/share/opencode"

  # 1. Legacy storage/ JSON layout — additive per-file copy (paths in the
  #    quarantine copy were already /workspace-rewritten by the caller).
  if [[ -d "$quarantine/storage" ]]; then
    mkdir -p "$base/storage"
    if cp -R "$quarantine/storage/." "$base/storage/" 2>/dev/null; then
      aidc::log "merged opencode JSON sessions into $base/storage"
    else
      aidc::warn "could not copy opencode JSON sessions into $base/storage (kept at $quarantine)"
    fi
  fi

  # 2. SQLite opencode.db.
  local qdb="$quarantine/opencode.db"
  [[ -f "$qdb" ]] || return 0

  local sqlite="${AIDC_SQLITE3:-sqlite3}"
  if ! command -v "$sqlite" >/dev/null 2>&1; then
    aidc::log "sqlite3 not on host; opencode.db sessions kept at $quarantine (install sqlite3 to merge into $base)"
    return 0
  fi

  # Work on a private copy so the host db only ever receives path-corrected
  # rows, and a failed merge never disturbs the quarantine copy people inspect.
  local mdb="$quarantine/.opencode.merge.db"
  rm -f "$mdb"
  if ! cp "$qdb" "$mdb" 2>/dev/null; then
    aidc::warn "could not stage opencode.db for merge (kept at $quarantine)"
    return 0
  fi
  if [[ -n "$workspace" && "$workspace" != "/workspace" ]]; then
    aidc::opencode_db_rewrite_paths "$mdb" "$workspace"
  fi

  mkdir -p "$base"
  local bdb="$base/opencode.db"

  # Host has no db yet → nothing to merge into; install our copy wholesale.
  if [[ ! -f "$bdb" ]]; then
    if cp "$mdb" "$bdb" 2>/dev/null; then
      aidc::log "created $bdb from container opencode sessions"
    else
      aidc::warn "could not create $bdb (sessions kept at $quarantine)"
    fi
    rm -f "$mdb"
    return 0
  fi

  # A container db from a newer schema epoch (or outright column/type drift)
  # makes a row merge unsafe — skip rather than risk a partial/failed insert.
  if ! aidc::opencode_db_schema_match "$mdb" "$bdb"; then
    aidc::log "opencode.db schema not merge-compatible (container db newer than host, or column/type drift); skipping merge (sessions kept at $quarantine)"
    rm -f "$mdb"
    return 0
  fi

  # Snapshot the host db first (VACUUM INTO = a consistent copy + an implicit
  # lock/readability probe). Restored verbatim if the merge somehow fails.
  local bak="$bdb.aidc-bak"
  rm -f "$bak"
  local bak_sql="${bak//\'/\'\'}"
  if ! "$sqlite" "$bdb" "PRAGMA busy_timeout=3000; VACUUM INTO '$bak_sql';" >/dev/null 2>&1; then
    aidc::log "host opencode.db busy or unreadable; skipping merge (sessions kept at $quarantine)"
    rm -f "$mdb" "$bak"
    return 0
  fi

  if aidc::opencode_db_merge "$mdb" "$bdb"; then
    aidc::log "merged opencode sessions into $bdb"
    rm -f "$bak"
  else
    mv -f "$bak" "$bdb" 2>/dev/null || true
    aidc::warn "opencode.db merge failed and was rolled back; sessions kept at $quarantine"
  fi
  rm -f "$mdb"
}

# List the mergeable user tables of a SQLite db: everything except sqlite's own
# bookkeeping (sqlite_*) and Drizzle's migration tables (__*).
aidc::opencode_db_tables() {
  local db="$1"
  local sqlite="${AIDC_SQLITE3:-sqlite3}"
  "$sqlite" "$db" \
    "SELECT name FROM sqlite_master WHERE type='table' \
       AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' \
       AND name NOT LIKE '\\_\\_%' ESCAPE '\\';" 2>/dev/null
}

# Rewrite the in-container mount root (/workspace) to the host workspace inside
# a db copy. opencode stores absolute paths in each row's JSON `data` column;
# rewriting the string there mirrors the *.json/*.jsonl sed the caller runs.
aidc::opencode_db_rewrite_paths() {
  local db="$1"
  local ws="$2"
  local sqlite="${AIDC_SQLITE3:-sqlite3}"
  local ws_sql="${ws//\'/\'\'}"
  local t
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    [[ -n "$("$sqlite" "$db" "SELECT 1 FROM pragma_table_info('${t//\'/\'\'}') WHERE name='data' LIMIT 1;" 2>/dev/null)" ]] || continue
    "$sqlite" "$db" \
      "UPDATE \"$t\" SET data=replace(data,'/workspace','$ws_sql') WHERE data LIKE '%/workspace%';" \
      >/dev/null 2>&1 || true
  done < <(aidc::opencode_db_tables "$db")
}

# Column fingerprint of one table: name:type per line, sorted by name. Physical
# order (cid) is deliberately excluded — a long-lived host db grown through
# ALTER TABLE … ADD COLUMN appends columns at the end, while a fresh db built
# from opencode's schema snapshot lays them out in definition order: same
# logical schema, different physical layout (docs/opencode-schema-epochs.md).
aidc::opencode_db_columns() {
  local db="$1"
  local t="$2"
  local sqlite="${AIDC_SQLITE3:-sqlite3}"
  "$sqlite" "$db" "SELECT name||':'||type FROM pragma_table_info('${t//\'/\'\'}') ORDER BY name;" 2>/dev/null
}

# Applied-migration ids from opencode's `migration` journal, one per line.
# Empty when the table is absent (pre-journal opencode build, test fixture) or
# holds no rows.
aidc::opencode_db_migration_ids() {
  local db="$1"
  local sqlite="${AIDC_SQLITE3:-sqlite3}"
  "$sqlite" "$db" "SELECT id FROM migration ORDER BY id;" 2>/dev/null
}

# True when merging src into dst is schema-safe:
#   - for every table the dbs share, src's columns (name:type, order
#     independent) must be a subset of dst's. Equal is the normal same-epoch
#     case; dst holding extra columns (host build newer, additive growth) is
#     fine because the merge inserts by column name. src holding anything dst
#     lacks means the container db is from a newer schema epoch → refuse.
#   - when either db carries a `migration` journal, both must, and the
#     container's applied ids must be a subset of the host's — a container
#     running ahead straddles data migrations whose row shapes SQL cannot
#     reconcile (epoch boundaries: docs/opencode-schema-epochs.md).
# Tables present in only one db are ignored — the merge simply skips those.
aidc::opencode_db_schema_match() {
  local src="$1"
  local dst="$2"
  local t sa sb src_ids dst_ids
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    sa="$(aidc::opencode_db_columns "$src" "$t")"
    [[ -n "$sa" ]] || continue  # table absent in src → nothing to merge for it
    sb="$(aidc::opencode_db_columns "$dst" "$t")"
    # Subset test: nothing in src's column set may be missing from dst's.
    [[ -z "$(comm -23 <(printf '%s\n' "$sa") <(printf '%s\n' "$sb"))" ]] || return 1
  done < <(aidc::opencode_db_tables "$dst")
  src_ids="$(aidc::opencode_db_migration_ids "$src")"
  dst_ids="$(aidc::opencode_db_migration_ids "$dst")"
  if [[ -n "$src_ids" || -n "$dst_ids" ]]; then
    [[ -n "$src_ids" && -n "$dst_ids" ]] || return 1
    [[ -z "$(comm -23 <(printf '%s\n' "$src_ids") <(printf '%s\n' "$dst_ids"))" ]] || return 1
  fi
  return 0
}

# Additively merge every shared table from src into dst with INSERT OR IGNORE
# (host rows win on primary-key collision). One transaction, foreign keys off:
# additive inserts can't orphan rows (a conflicting parent is already present),
# so table order is irrelevant. Rows are inserted by column NAME, never a
# positional SELECT * — the two dbs may lay the same columns out in a different
# physical order, and a positional insert would silently shift values between
# columns. Returns non-zero on any SQLite error.
aidc::opencode_db_merge() {
  local src="$1"
  local dst="$2"
  local sqlite="${AIDC_SQLITE3:-sqlite3}"
  local src_sql="${src//\'/\'\'}"
  local sql t collist
  # busy_timeout as SQL (not the .timeout dot-command, which is silently
  # ignored — and aborts the rest — when passed as a command-line argument).
  sql="PRAGMA busy_timeout=5000;
PRAGMA foreign_keys=OFF;
ATTACH DATABASE '$src_sql' AS aidc_src;
BEGIN IMMEDIATE;
"
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    # Only merge tables the source db also has.
    [[ -n "$("$sqlite" "$src" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='${t//\'/\'\'}' LIMIT 1;" 2>/dev/null)" ]] || continue
    # The schema gate guarantees every source column exists in the destination,
    # so the source's column list is exactly the shared intersection.
    collist="$("$sqlite" "$src" "SELECT group_concat('\"' || name || '\"', ',') FROM (SELECT name FROM pragma_table_info('${t//\'/\'\'}') ORDER BY cid);" 2>/dev/null)"
    [[ -n "$collist" ]] || continue
    sql+="INSERT OR IGNORE INTO \"$t\" ($collist) SELECT $collist FROM aidc_src.\"$t\";
"
  done < <(aidc::opencode_db_tables "$dst")
  sql+="COMMIT;
DETACH DATABASE aidc_src;
"
  "$sqlite" "$dst" "$sql" >/dev/null 2>&1
}

# ── rtk savings merge ──
#
# Merge the quarantined container copy of rtk's history.db (in $quarantine)
# into the host's OWN rtk db, so a plain host `rtk gain` reflects what rtk
# saved inside aidc containers. Same safety posture as the opencode merge,
# with one structural difference: rtk's tables use `id INTEGER PRIMARY KEY`
# (rowid) on every table, so — unlike opencode's UUID-keyed rows — ids can
# NEVER be carried over (the host already owns ids 1..N; INSERT OR IGNORE by
# pk would silently drop every container row). Instead rows are inserted
# WITHOUT the id (the host assigns fresh rowids) and re-merges are made
# idempotent by natural keys, which rtk's nanosecond-precision timestamps
# make tight:
#   commands      → (timestamp, original_cmd)
#   parse_failures→ (timestamp, raw_command)
#   hook_decisions→ (session_id, tool_use_id)
# Identical rows can at worst collapse indistinguishable duplicates — an
# undercount of zero information. Everything else mirrors opencode: work on a
# private copy, path-rewrite /workspace to the host workspace (stable dedupe
# + host `rtk gain -p <workspace>` works), schema-subset gate, VACUUM INTO
# snapshot for rollback, one transaction with busy_timeout. Degrades to
# quarantine-only on any doubt. Opt out with AIDC_RTK_MERGE_TO_BASE=0;
# override the host db with AIDC_RTK_DB; override sqlite3 with AIDC_SQLITE3.

# Resolve the host's own rtk history.db: explicit override, else the first
# existing candidate across the layouts rtk uses (XDG data dir on Linux,
# Application Support on macOS), else the XDG path — used to create the db
# wholesale when the host runs no rtk of its own yet.
aidc::rtk_resolve_host_db() {
  if [[ -n "${AIDC_RTK_DB:-}" ]]; then
    printf '%s\n' "$AIDC_RTK_DB"
    return 0
  fi
  local d
  for d in "${XDG_DATA_HOME:-$HOME/.local/share}/rtk" "$HOME/Library/Application Support/rtk"; do
    if [[ -f "$d/history.db" ]]; then
      printf '%s\n' "$d/history.db"
      return 0
    fi
  done
  printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/rtk/history.db"
}

aidc::rtk_merge_to_base() {
  local workspace="$1"
  local quarantine="$2"
  [[ "${AIDC_RTK_MERGE_TO_BASE:-1}" == "0" ]] && return 0

  local qdb="$quarantine/history.db"
  [[ -f "$qdb" ]] || return 0

  local bdb
  bdb="$(aidc::rtk_resolve_host_db)"

  local sqlite="${AIDC_SQLITE3:-sqlite3}"
  if ! command -v "$sqlite" >/dev/null 2>&1; then
    aidc::log "sqlite3 not on host; rtk savings kept at $quarantine (install sqlite3 to merge into $bdb)"
    return 0
  fi

  # Work on a private copy so the host db only ever receives path-corrected
  # rows, and a failed merge never disturbs the quarantine copy people inspect.
  local mdb="$quarantine/.rtk.merge.db"
  rm -f "$mdb"
  if ! cp "$qdb" "$mdb" 2>/dev/null; then
    aidc::warn "could not stage rtk history.db for merge (kept at $quarantine)"
    return 0
  fi
  if [[ -n "$workspace" && "$workspace" != "/workspace" ]]; then
    aidc::rtk_db_rewrite_paths "$mdb" "$workspace"
  fi

  mkdir -p "$(dirname "$bdb")"

  # Host has no rtk data yet → nothing to merge into; install our copy
  # wholesale (a future host rtk install picks the db up at the same path).
  if [[ ! -f "$bdb" ]]; then
    if cp "$mdb" "$bdb" 2>/dev/null; then
      aidc::log "created $bdb from container rtk savings"
    else
      aidc::warn "could not create $bdb (rtk savings kept at $quarantine)"
    fi
    rm -f "$mdb"
    return 0
  fi

  # A container db from an rtk build with extra per-table columns makes a row
  # merge unsafe — skip rather than risk a partial insert. The schema check is
  # generic SQLite (name:type subsets); rtk carries no migration journal, so
  # the opencode epoch clause inside it is inert here.
  if ! aidc::opencode_db_schema_match "$mdb" "$bdb"; then
    aidc::log "rtk history.db schema not merge-compatible (container rtk newer than host, or column/type drift); skipping merge (savings kept at $quarantine)"
    rm -f "$mdb"
    return 0
  fi

  # Snapshot the host db first (VACUUM INTO = consistent copy + implicit
  # lock/readability probe). Restored verbatim if the merge somehow fails.
  local bak="$bdb.aidc-bak"
  rm -f "$bak"
  local bak_sql="${bak//\'/\'\'}"
  if ! "$sqlite" "$bdb" "PRAGMA busy_timeout=3000; VACUUM INTO '$bak_sql';" >/dev/null 2>&1; then
    aidc::log "host rtk history.db busy or unreadable; skipping merge (savings kept at $quarantine)"
    rm -f "$mdb" "$bak"
    return 0
  fi

  if aidc::rtk_db_merge "$mdb" "$bdb"; then
    aidc::log "merged rtk savings into $bdb"
    rm -f "$bak"
  else
    mv -f "$bak" "$bdb" 2>/dev/null || true
    aidc::warn "rtk history.db merge failed and was rolled back; savings kept at $quarantine"
  fi
  rm -f "$mdb"
}

# Rewrite the in-container mount root (/workspace) to the host workspace inside
# a db copy. rtk records the cwd in commands.project_path and
# hook_decisions.project_path; rewriting mirrors the *.json/*.jsonl sed the
# sync runs for transcripts.
aidc::rtk_db_rewrite_paths() {
  local db="$1"
  local ws="$2"
  local sqlite="${AIDC_SQLITE3:-sqlite3}"
  local ws_sql="${ws//\'/\'\'}"
  "$sqlite" "$db" \
    "UPDATE commands SET project_path=replace(project_path,'/workspace','$ws_sql') WHERE project_path LIKE '%/workspace%';
UPDATE hook_decisions SET project_path=replace(project_path,'/workspace','$ws_sql') WHERE project_path LIKE '%/workspace%';" \
    >/dev/null 2>&1 || true
}

# Natural dedupe key of one rtk table, as a WHERE clause comparing host alias
# h against source alias s. Unknown/future tables return empty → skipped.
aidc::rtk_db_natural_key() {
  case "$1" in
    commands) printf 'h.timestamp=s.timestamp AND h.original_cmd=s.original_cmd' ;;
    parse_failures) printf 'h.timestamp=s.timestamp AND h.raw_command=s.raw_command' ;;
    hook_decisions) printf 'h.session_id=s.session_id AND h.tool_use_id=s.tool_use_id' ;;
  esac
}

# Additively merge every shared table from src into dst. Rows are inserted by
# column NAME minus id (host assigns fresh rowids — see the block comment
# above for why ids must not travel), skipping rows whose natural key already
# exists in the host. One transaction, busy_timeout as SQL. Returns non-zero
# on any SQLite error.
aidc::rtk_db_merge() {
  local src="$1"
  local dst="$2"
  local sqlite="${AIDC_SQLITE3:-sqlite3}"
  local src_sql="${src//\'/\'\'}"
  local sql t collist natkey
  sql="PRAGMA busy_timeout=5000;
ATTACH DATABASE '$src_sql' AS aidc_src;
BEGIN IMMEDIATE;
"
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    # Only merge tables the source db also has, with a known natural key.
    [[ -n "$(aidc::rtk_db_natural_key "$t")" ]] || continue
    [[ -n "$("$sqlite" "$src" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='${t//\'/\'\'}' LIMIT 1;" 2>/dev/null)" ]] || continue
    # The schema gate guarantees every source column exists in the destination,
    # so the source's column list (minus id) is the shared intersection.
    collist="$("$sqlite" "$src" "SELECT group_concat('\"' || name || '\"', ',') FROM (SELECT name FROM pragma_table_info('${t//\'/\'\'}') WHERE name != 'id' ORDER BY cid);" 2>/dev/null)"
    [[ -n "$collist" ]] || continue
    natkey="$(aidc::rtk_db_natural_key "$t")"
    sql+="INSERT INTO \"$t\" ($collist) SELECT $collist FROM aidc_src.\"$t\" AS s WHERE NOT EXISTS (SELECT 1 FROM main.\"$t\" AS h WHERE $natkey);
"
  done < <(aidc::opencode_db_tables "$dst")
  sql+="COMMIT;
DETACH DATABASE aidc_src;
"
  "$sqlite" "$dst" "$sql" >/dev/null 2>&1
}

# Best-effort session sync wired into the agent/lifecycle paths so transcripts
# land on the host without a manual 'aidc sync-sessions'. Opt out by setting
# AIDC_AUTO_SYNC_SESSIONS=0 in .ai-container/project.env. 'tool' is a single
# tool name or 'all'; tools without a session mapping (e.g. cursor-agent) are
# skipped. Never aborts the caller — sync failures are logged, not fatal.
aidc::auto_sync_sessions() {
  local workspace="$1"
  local tool="$2"
  [[ "${AIDC_AUTO_SYNC_SESSIONS:-1}" == "0" ]] && return 0

  # No container, nothing to pull (e.g. auto-sync after a failed start).
  [[ -n "$(aidc::compose_capture "$workspace" ps -q workspace 2>/dev/null)" ]] || return 0

  if [[ "$tool" == "all" ]]; then
    local t
    for t in claude codex opencode grok omp rtk; do
      aidc::sync_session_tool "$workspace" "$t" || true
    done
    return 0
  fi

  case "$tool" in
    claude|codex|opencode|grok|omp)
      aidc::sync_session_tool "$workspace" "$tool" || true
      ;;
    *)
      # cursor-agent and unknowns have no session volume to sync.
      ;;
  esac

  # rtk's savings history is one shared db per container, so it rides along
  # with the syncs of the agents rtk is wired into (claude/opencode/cursor).
  case "$tool" in
    claude|opencode|cursor-agent)
      aidc::sync_session_tool "$workspace" rtk || true
      ;;
  esac
}
