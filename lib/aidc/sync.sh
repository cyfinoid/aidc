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
      container_src="/home/aidc/.claude/projects"
      host_dst="$HOME/.claude/projects"
      ;;
    codex)
      container_src="/home/aidc/.codex/sessions"
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
      container_src="/home/aidc/.local/share/opencode"
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
      container_src="/home/aidc/.grok/sessions"
      host_dst="$HOME/.grok/sessions"
      ;;
    omp)
      # omp (oh-my-pi) stores conversations as JSONL under
      # ~/.omp/agent/sessions/<encoded-cwd>/<ts>_<id>.jsonl.
      container_src="/home/aidc/.omp/agent/sessions"
      host_dst="$HOME/.omp/agent/sessions"
      ;;
    rtk)
      # rtk's savings history: one SQLite db in the XDG data dir, shared by
      # every rtk-wired agent (claude hook, opencode plugin, cursor hooks.json,
      # omp extension). Copied to an aidc-owned quarantine first and merged
      # into the host's OWN rtk db afterwards (aidc::rtk_merge_to_base below) —
      # never extracted over the host's data dir, whose db sits at the same
      # path. tee/ holds raw command-output logs: bulky, not savings data.
      container_src="/home/aidc/.local/share/rtk"
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
    # v2 opencode keeps provider credentials in the db itself — scrub them
    # from the at-rest quarantine copy BEFORE anything reads it: container
    # auth state never travels host-ward, and the host is the source of
    # truth for credentials (the merge re-guards this independently).
    aidc::opencode_scrub_auth "$host_dst/opencode.db"
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
#     rather than risk a partial/failed insert; the gate reports WHICH
#     (epoch-ahead vs column drift) so the skip log names cause + remedy.
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
  # The gate names the cause so the log carries the matching remedy: an
  # epoch-ahead skip is the expected transient while the container's opencode
  # build runs ahead of the host's (v2 container vs v1 host, or a newer v2
  # minor — e.g. 2.0.29 container vs 2.0.25 host) and self-heals once the
  # host's opencode catches up; column/type drift is a genuine mismatch.
  # One exception: a gap made only of source-verified ADDITIVE migrations
  # (docs/opencode-schema-epochs.md) merges now, in restricted-columns mode.
  local mismatch="" restrict=""
  if ! mismatch="$(aidc::opencode_db_schema_match "$mdb" "$bdb")"; then
    case "$mismatch" in
      epoch-ahead*)
        aidc::log "container opencode.db is from a newer schema epoch than the host's (migration journal ${mismatch#epoch-ahead } id(s) ahead — the container runs a newer opencode build); skipping merge (sessions kept at $quarantine; upgrade the host's opencode to at least the container's version and launch it once: the host db migrates in place and the next sync merges)"
        ;;
      journal-one-sided*)
        aidc::log "opencode migration journal present on only one side of the merge; cannot compare schema epochs; skipping merge (sessions kept at $quarantine)"
        ;;
      column-drift*)
        aidc::log "opencode.db column/type drift between container and host (first on table '${mismatch#column-drift }'); skipping merge (sessions kept at $quarantine)"
        ;;
      # Unreachable with the current gate (every refusal prints a known
      # token) — kept as a fail-safe so a future token can never silence
      # the skip line entirely.
      *)
        aidc::log "opencode.db schema not merge-compatible (${mismatch:-unknown cause}); skipping merge (sessions kept at $quarantine)"
        ;;
    esac
    rm -f "$mdb"
    return 0
  fi
  if [[ "$mismatch" == additive-ahead* ]]; then
    restrict="restrict"
    aidc::log "host opencode.db is ${mismatch#additive-ahead } migration(s) behind the container (gap verified additive-only); merging shared columns (gap columns land empty until the host's opencode catches up)"
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

  if aidc::opencode_db_merge "$mdb" "$bdb" ${restrict:+"$restrict"}; then
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

# Is this opencode.db table auth/credential state? Since opencode v2, provider
# logins (`opencode auth login`) no longer update the legacy auth.json — they
# land in the db: `credential` rows (one per provider; `value` is the secret),
# plus `account`/`account_state`/`control_account` for ChatGPT/Codex-style
# OAuth accounts. aidc's contract is one-directional by design: the HOST is
# the source of truth for credentials, and container auth state never travels
# host-ward (the documented "credentials never leave the container"
# guarantee). Anything this returns true for is excluded from the container →
# host db merge and scrubbed from the at-rest quarantine copy.
aidc::opencode_table_is_auth() {
  local db="$1"
  local t="$2"
  local sqlite="${AIDC_SQLITE3:-sqlite3}"
  # Known auth tables by name. Case-folded: SQL resolves table names
  # case-insensitively, so a `Credential`-cased db must not slip past a bash
  # exact match (same reasoning as the migration-journal exclusion).
  case "$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')" in
    credential|account|account_state|control_account) return 0 ;;
  esac
  # Schema-driven guard for auth tables upstream may add under any name: a
  # table carrying OAuth token columns is auth state, whatever it is called.
  # (Deliberately specific — `value`, `key` or `secret` alone would false-
  # positive ordinary session tables and silently drop session data.)
  [[ -n "$("$sqlite" "$db" \
    "SELECT 1 FROM pragma_table_info('${t//\'/\'\'}') \
       WHERE lower(name) IN ('access_token','refresh_token') LIMIT 1;" 2>/dev/null)" ]]
}

# Drop auth/credential rows from a quarantined opencode.db copy — the at-rest
# container-data-dir staging on host disk that the merge later reads. With v2
# keeping provider credentials IN the db (see aidc::opencode_table_is_auth),
# the raw extract would otherwise park container auth state on the host, the
# exact inverse of the documented "credentials never leave the container"
# guarantee. DELETE with secure_delete so freed page content is zeroed (the
# WAL is checkpointed too), leaving no recoverable secret in the at-rest
# copy. Best-effort, and only the presence of host sqlite3 makes the later
# merge possible anyway; a failure warns so the directory can be removed by
# hand. The sqlite3-absent path warns too: without it the raw copy keeps
# credential rows, and silence here would strand them unflagged.
aidc::opencode_scrub_auth() {
  local db="$1"
  local sqlite="${AIDC_SQLITE3:-sqlite3}"
  [[ -f "$db" ]] || return 0
  if ! command -v "$sqlite" >/dev/null 2>&1; then
    aidc::warn "sqlite3 not on host — cannot scrub credential tables from $db (opencode v2 keeps auth in the db; remove the directory if you do not want container auth state on host disk)"
    return 0
  fi
  local t sql="" scrubbed=""
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    if aidc::opencode_table_is_auth "$db" "$t"; then
      sql+="DELETE FROM \"${t//\"/\"\"}\";"$'\n'
      scrubbed+="${scrubbed:+, }$t"
    fi
  done < <(aidc::opencode_db_tables "$db")
  [[ -n "$sql" ]] || return 0
  # wal_checkpoint cannot run inside a transaction — it goes after COMMIT,
  # best-effort (a failed checkpoint only means the WAL keeps old page
  # images; the rows are already gone). secure_delete is a connection pragma:
  # set it before BEGIN so the DELETEs zero freed content.
  if "$sqlite" "$db" "PRAGMA busy_timeout=3000; PRAGMA secure_delete=ON; BEGIN;
${sql}
COMMIT;" >/dev/null 2>&1; then
    "$sqlite" "$db" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true
    aidc::log "scrubbed credential tables from the synced opencode.db copy ($scrubbed)"
  else
    aidc::warn "could not scrub credential tables from $db — remove the directory if you do not want container auth state on host disk"
  fi
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

# Migration ids verified ADDITIVE from upstream source (receipts in
# docs/opencode-schema-epochs.md): a container-journal-ahead gap made up ONLY
# of these ids may merge in restricted-columns mode (host column list) as
# long as the runtime column check confirms a purely-additive shape. Override
# or extend with AIDC_OPENCODE_ADDITIVE_MIGRATIONS (whitespace-separated;
# explicitly empty disables additive-gap merging).
AIDC_OPENCODE_ADDITIVE_MIGRATIONS_DEFAULT="20261010180456_project_time_archived"

# True when every id in $1 (one per line) is on the verified-additive
# allowlist. No output — pure boolean, callable inside the gate.
aidc::opencode_gap_all_additive() {
  local ids="$1"
  # `${var-default}` (not `:-`): an explicitly-empty override disables
  # additive-gap merging; unset falls back to the verified default list.
  local allow="${AIDC_OPENCODE_ADDITIVE_MIGRATIONS-$AIDC_OPENCODE_ADDITIVE_MIGRATIONS_DEFAULT}"
  local id a found
  local -a allow_arr=()
  # read -a word-splits without pathname expansion (a bare `for x in $allow`
  # would glob-expand an override containing *?[ and silently mis-match).
  read -r -a allow_arr <<<"$allow"
  while IFS= read -r id; do
    # A blank journal id is degenerate, not additive — refuse the gap.
    [[ -n "$id" ]] || return 1
    found=0
    for a in ${allow_arr[@]+"${allow_arr[@]}"}; do
      [[ -z "$a" ]] && continue
      if [[ "$a" == "$id" ]]; then found=1; break; fi
    done
    if [[ "$found" -ne 1 ]]; then return 1; fi
  done < <(printf '%s\n' "$ids")
  return 0
}

# True when merging src into dst is schema-safe:
#   - when either db carries a `migration` journal, both must, and the
#     container's applied ids must be a subset of the host's — a container
#     running ahead straddles data migrations whose row shapes SQL cannot
#     reconcile (epoch boundaries: docs/opencode-schema-epochs.md).
#     EXCEPTION (verified-additive gap): when every gap id is on the
#     source-verified additive allowlist AND, on every shared table, the
#     host's columns are a subset of the container's (purely-additive
#     shape), the merge is allowed in restricted-columns mode — the caller
#     is told via the `additive-ahead <n>` success token.
#   - for every table the dbs share, src's columns (name:type, order
#     independent) must be a subset of dst's. Equal is the normal same-epoch
#     case; dst holding extra columns (host build newer, additive growth) is
#     fine because the merge inserts by column name. src holding anything dst
#     lacks means the container db is from a newer schema epoch → refuse.
# Tables present in only one db are ignored — the merge simply skips those.
#
# On refusal, prints a reason token (stdout) so callers can log the actual
# cause with its remedy instead of one conflated message:
#   "epoch-ahead <n>"       container journal holds n ids the host lacks and
#                           the gap is not verified-additive — expected
#                           transient while the container's opencode build
#                           runs ahead (v2 vs v1, or a newer minor); self-
#                           heals once the host's opencode catches up
#   "journal-one-sided"     only one db carries a migration journal
#   "column-drift <table>"  a shared table where src has a column dst lacks
#                           (aligned journals: a genuine mismatch), or the
#                           host holds a column the container lacks while the
#                           gap looked additive (not a purely-additive shape)
# On success, prints nothing (full merge) or:
#   "additive-ahead <n>"    verified-additive gap of n ids — merge allowed in
#                           restricted-columns mode (host column list; the
#                           gap columns' values are dropped for this merge)
# Epoch reasons are checked BEFORE per-table drift, and the first match wins:
# a newer opencode build typically ALTERs shared tables too (that is how the
# schema grows — docs/opencode-schema-epochs.md), so such a pair is both
# journal-ahead and column-drifted under the aligned-journals rule; the
# journal gap is the root cause (with its upgrade remedy) and the column
# difference only a symptom, so that case must report epoch-ahead unless the
# gap is verified additive. Drift with aligned journals really is an anomaly.
aidc::opencode_db_schema_match() {
  local src="$1"
  local dst="$2"
  local t sa sb extra dextra n src_ids dst_ids
  src_ids="$(aidc::opencode_db_migration_ids "$src")"
  dst_ids="$(aidc::opencode_db_migration_ids "$dst")"
  if [[ -n "$src_ids" || -n "$dst_ids" ]]; then
    if [[ -z "$src_ids" || -z "$dst_ids" ]]; then
      printf 'journal-one-sided\n'
      return 1
    fi
    # LC_ALL=C: comm requires sorted input, and the ids come out of SQLite's
    # BINARY collation — a UTF-8 locale could order them differently and
    # misreport the gap.
    extra="$(LC_ALL=C comm -23 <(printf '%s\n' "$src_ids") <(printf '%s\n' "$dst_ids"))"
    if [[ -n "$extra" ]]; then
      n="$(printf '%s\n' "$extra" | wc -l | tr -d ' ')"
      if aidc::opencode_gap_all_additive "$extra"; then
        # Purely-additive shape must hold at runtime too: on every shared
        # table the host's columns must be a subset of the container's.
        # Anything else (host-only column, type change) is real drift.
        while IFS= read -r t; do
          [[ -n "$t" ]] || continue
          sa="$(aidc::opencode_db_columns "$src" "$t")"
          sb="$(aidc::opencode_db_columns "$dst" "$t")"
          [[ -n "$sa" && -n "$sb" ]] || continue  # not a shared table
          dextra="$(LC_ALL=C comm -23 <(printf '%s\n' "$sb") <(printf '%s\n' "$sa"))"
          if [[ -n "$dextra" ]]; then
            printf 'column-drift %s\n' "$t"
            return 1
          fi
        done < <(aidc::opencode_db_tables "$dst")
        printf 'additive-ahead %s\n' "$n"
        return 0
      fi
      printf 'epoch-ahead %s\n' "$n"
      return 1
    fi
  fi
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    sa="$(aidc::opencode_db_columns "$src" "$t")"
    [[ -n "$sa" ]] || continue  # table absent in src → nothing to merge for it
    sb="$(aidc::opencode_db_columns "$dst" "$t")"
    # Subset test: nothing in src's column set may be missing from dst's.
    # LC_ALL=C — see the journal-gap comm above.
    extra="$(LC_ALL=C comm -23 <(printf '%s\n' "$sa") <(printf '%s\n' "$sb"))"
    if [[ -n "$extra" ]]; then
      printf 'column-drift %s\n' "$t"
      return 1
    fi
  done < <(aidc::opencode_db_tables "$dst")
  return 0
}

# Additively merge every shared table from src into dst with INSERT OR IGNORE
# (host rows win on primary-key collision). One transaction, foreign keys off:
# additive inserts can't orphan rows (a conflicting parent is already present),
# so table order is irrelevant. Rows are inserted by column NAME, never a
# positional SELECT * — the two dbs may lay the same columns out in a different
# physical order, and a positional insert would silently shift values between
# columns. Returns non-zero on any SQLite error.
#
# Optional third arg (any non-empty value) = restricted-columns mode, used
# after an `additive-ahead` gate pass: the column list comes from the DST
# (host) db instead of the source — the gate's additive check guarantees the
# host's columns are a subset of the source's, so dst's list is the shared
# intersection and the gap columns' values are dropped for this merge (they
# are NULL/default in the host until its opencode upgrades past the gap).
aidc::opencode_db_merge() {
  local src="$1"
  local dst="$2"
  local restrict="${3:-}"
  local sqlite="${AIDC_SQLITE3:-sqlite3}"
  local src_sql="${src//\'/\'\'}"
  local sql t collist collist_db auth_excluded=""
  # busy_timeout as SQL (not the .timeout dot-command, which is silently
  # ignored — and aborts the rest — when passed as a command-line argument).
  sql="PRAGMA busy_timeout=5000;
PRAGMA foreign_keys=OFF;
ATTACH DATABASE '$src_sql' AS aidc_src;
BEGIN IMMEDIATE;
"
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    # The migration journal is schema bookkeeping, never data to sync —
    # merging container journal rows into the host's would falsify its
    # epoch fingerprint (in restricted mode it would insert gap ids the
    # host has NOT run; the host's own upgrade would then skip replaying
    # them). Full mode was only ever safe here by the gate's invariant.
    # Lowercased compare: SQL addresses tables case-insensitively, so a
    # `Migration`-cased journal must not slip past a bash exact match.
    [[ "$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')" == "migration" ]] && continue
    # Auth/credential tables NEVER flow container → host: the host is the
    # source of truth for credentials (aidc seeds auth into the container,
    # never the reverse). Without this, every session sync would merge the
    # container db's credential/account rows into the host's own db — the
    # exact inverse of "credentials never leave the container".
    if aidc::opencode_table_is_auth "$src" "$t"; then
      auth_excluded+="${auth_excluded:+, }$t"
      continue
    fi
    # Only merge tables the source db also has.
    [[ -n "$("$sqlite" "$src" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='${t//\'/\'\'}' LIMIT 1;" 2>/dev/null)" ]] || continue
    # Full merge: the gate guarantees every source column exists in the
    # destination, so the source's column list is exactly the shared
    # intersection. Restricted mode: the destination's list is (see above).
    collist_db="$src"
    [[ -n "$restrict" ]] && collist_db="$dst"
    collist="$("$sqlite" "$collist_db" "SELECT group_concat('\"' || name || '\"', ',') FROM (SELECT name FROM pragma_table_info('${t//\'/\'\'}') ORDER BY cid);" 2>/dev/null)"
    [[ -n "$collist" ]] || continue
    sql+="INSERT OR IGNORE INTO \"$t\" ($collist) SELECT $collist FROM aidc_src.\"$t\";
"
  done < <(aidc::opencode_db_tables "$dst")
  sql+="COMMIT;
DETACH DATABASE aidc_src;
"
  # One line per sync, names only — enough to audit that auth state stayed put.
  [[ -n "$auth_excluded" ]] \
    && aidc::log "excluded auth tables from the host merge (host owns credentials): $auth_excluded"
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
  # the opencode epoch clauses inside it are inert here — for rtk only the
  # column-drift arm can fire, and the skip message names the table.
  local mismatch=""
  if ! mismatch="$(aidc::opencode_db_schema_match "$mdb" "$bdb")"; then
    case "$mismatch" in
      column-drift*)
        aidc::log "rtk history.db schema not merge-compatible (container rtk newer than host — column/type drift on table '${mismatch#column-drift }'); skipping merge (savings kept at $quarantine)"
        ;;
      # Fail-safe only (unreachable for real rtk dbs: no migration journal →
      # only the drift arm can fire; epoch tokens render as this generic line).
      *)
        aidc::log "rtk history.db schema not merge-compatible (container rtk newer than host, or column/type drift); skipping merge (savings kept at $quarantine)"
        ;;
    esac
    rm -f "$mdb"
    return 0
  elif [[ "$mismatch" == additive-ahead* ]]; then
    # Real rtk dbs carry no opencode-style migration journal, so this needs a
    # mispointed AIDC_RTK_DB — but if it ever happens, say so instead of
    # silently running a full-mode merge whose source collists would error
    # on the gap columns (fail-closed rollback with a cryptic message).
    aidc::log "rtk history.db carries an opencode-style migration journal with an additive gap; skipping merge (savings kept at $quarantine)"
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
    # Journal/bookkeeping tables are never merged (see opencode_db_merge;
    # lowercased for the same case-insensitivity reason).
    [[ "$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')" == "migration" ]] && continue
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

# Post-exit session sync that re-reads the sync module from disk. Agent
# wrappers (`aidc claude`, `aidc opencode`/`opencode-web`, …) are long-lived:
# bin/aidc sources lib/aidc/*.sh once at startup and the wrapper then blocks
# on the agent for the session's lifetime, so an in-process post-exit sync
# executes function definitions captured before any mid-session edit or
# update to the aidc checkout landed (observed 2026-10-14: a session started
# before a merge-gate fix exited logging the removed conflation message).
# This helper re-sources lib/aidc/sync.sh inside a subshell and runs the
# same single common method (`auto_sync_sessions` → `sync_session_tool` →
# the per-tool merges) with current code. Freshness is module-scoped: all
# session-sync and merge logic lives in sync.sh, but helpers it calls from
# other modules (aidc::compose*, aidc::log, …) remain the wrapper's
# in-memory versions. Short-lived triggers (up/rebuild/down/destroy/
# exec-start) are fresh processes already and keep calling
# `aidc::auto_sync_sessions` directly. Without AIDC_ROOT (tests source the
# lib without bin/aidc) the in-process sync runs, so test stubs stay
# authoritative. A broken tree — module missing, or unparseable (checked
# with `bash -n`, which parses without executing) — SKIPS the sync: never
# fall through to the parent's stale definitions (a subshell that is the
# left operand of `||` has set -e suppressed inside, so a failed `.` does
# not abort it by itself — the failure is caught explicitly instead).
aidc::auto_sync_sessions_fresh() {
  local workspace="$1"
  local tool="${2:-all}"
  [[ "${AIDC_AUTO_SYNC_SESSIONS:-1}" == "0" ]] && return 0
  if [[ -n "${AIDC_ROOT:-}" ]]; then
    local module="$AIDC_ROOT/lib/aidc/sync.sh"
    if [[ ! -f "$module" ]] || ! bash -n "$module" 2>/dev/null; then
      aidc::log "aidc sync module missing or unparseable; skipping exit sync (sessions stay in the container volume)"
      return 0
    fi
    # shellcheck disable=SC1090,SC1091
    (
      set -uo pipefail
      # Explicit failure catch: set -e is inert inside a `||`-guarded
      # subshell (see above), so the source's status is handled by hand
      # and a failed reload must exit without calling anything stale.
      if ! . "$module"; then exit 0; fi
      aidc::auto_sync_sessions "$workspace" "$tool"
    ) || true
    return 0
  fi
  aidc::auto_sync_sessions "$workspace" "$tool" || true
}
