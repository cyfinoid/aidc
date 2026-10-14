# opencode.db schema epochs & merge-support policy

Context for `aidc::opencode_merge_to_base` in `lib/aidc/sync.sh`. When aidc syncs
opencode sessions from a container back to the host, it can additively merge the
container's `opencode.db` rows into the host's native `opencode.db` so the host's
opencode session viewer sees them. That row-merge is only safe when the two
builds agree on the DB schema — this document records which versions actually
change that schema, so we can define the supported range precisely instead of
rejecting on any physical difference.

## How opencode versions the local DB

- Storage is SQLite (`~/.local/share/opencode/opencode.db`), managed by Drizzle
  via `packages/core/src/database/` in `sst/opencode`.
- The registered migration list is `database/migration.gen.ts`; each entry is a
  timestamped migration under `database/migration/`. A fresh DB is built from the
  compacted snapshot `database/schema.gen.ts` and then stamped with **every**
  migration id; an existing DB replays only the pending ones.
- Applied migrations are recorded in a plain **`migration`** table
  (`id TEXT PRIMARY KEY, time_completed INTEGER`). That table is *not* one of the
  Drizzle bookkeeping tables (`__*`) aidc skips, so it is present in every DB and
  its id-set is the authoritative schema fingerprint.

## Schema-change history (verified against release tags)

Migration count is the number of entries in `migration.gen.ts` at each tag.
Verified via `raw.githubusercontent.com/sst/opencode/<tag>/…/migration.gen.ts`.

| opencode version        | migrations | schema |
|-------------------------|:----------:|--------|
| v1.16.0                 | 30         | older epochs |
| v1.17.0 – v1.17.3       | 32         | |
| v1.17.4                 | 33         | |
| v1.17.5 – v1.17.9       | 35         | |
| **v1.17.10 – v1.18.x**  | **38**     | **frozen — byte-identical `migration.gen.ts` and `schema.gen.ts`** |
| **v2 line (2.0.x)**     | **50+**    | **new epoch: v2 extends the same journal and migrates v1 dbs in place** |

Migrations added on the way to the frozen set:

- **→ v1.17.5** (reaching 35): `20260611035744_credential`,
  `20260611192811_lush_chimera`, `20260612174303_project_dir_strategy`
  (one of which lands at v1.17.4 → 33).
- **→ v1.17.10** (reaching 38): `20260622142730_simplify_session_context_epoch`,
  `20260622170816_reset_v2_session_state`, `20260622202450_simplify_session_input`.
  Note these are *reshaping/destructive* (a v2-session-state reset and two
  "simplify" rewrites), i.e. genuine breaking boundaries — crossing them is the
  case where a blind row-merge would be unsafe.

**Key result:** the schema did not change for the entire 1.17.10 → 1.18.x
line — 40+ consecutive releases. In particular the last 20 versions
(v1.18.11 … v1.18.30) contain **zero** schema changes.

### The v2 epoch (verified empirically against 2.0.29, 2026-10-14)

aidc moved its container pin to the v2 line; these facts were established by
running the actual binaries, not from docs:

- **Same storage location and journal mechanics.** v2 keeps
  `~/.local/share/opencode/opencode.db` and the same Drizzle `migration`
  journal table; a *fresh* v2 db (2.0.29) carries 50 migration ids.
- **v2 migrates a v1 db in place.** Opening a copy of a real v1 db (38 ids)
  with v2 replays the 12 additional migrations onto it: the journal grows to
  50, the v1 tables (`session`, `message`, `part`, `todo`, …) survive, and new
  v2 tables (`session_v2`, `session_inbox`, `session_pending`,
  `instruction_*`, `kv`, `worktree`, …) appear alongside.
- **v2 writes new sessions to `session_v2`**, not `session`. The old `session`
  rows from v1 remain readable in the same db.
- **v2 minors keep appending migrations, so the epoch gate bites across v2
  minors too.** The last journal ids are dated well into the v2 line
  (…20260923013825, 20261007190000, 20261010180456 on 2.0.29), so an older
  v2 host holds a strictly smaller id-set. Observed live (2026-10-14):
  syncing the 2.0.29 container into a host running opencode 2.0.25 refused
  the full merge (container journal verified at 50 ids, fresh 2.0.25 db
  verified at 49; host version user-reported). The gap is exactly one
  migration — `20261010180456_project_time_archived` — which upstream source
  shows is a single `ALTER TABLE project ADD time_archived integer`, i.e.
  purely additive, verified by a bidirectional schema diff of both dbs (the
  only delta on any shared table). Such verified-additive gaps now merge in
  restricted-columns mode (below) instead of skipping.
- **Consequences for the merge, all handled by the existing gates:** a v2
  container db synced into a v1 host db is refused by the epoch gate (journal
  ahead with reshaping migrations in the gap → skip to quarantine — the
  correct outcome until the host's own opencode upgrades); a v2 container
  into a v2 host merges over the shared tables (`session`, `session_v2`,
  `message`, …) exactly as before; a v2 container into a *migrated* host db
  (v1 grown to v2 in place) also merges — the host simply holds the superset
  schema — and a v2 container a few *additive* migrations ahead of the host
  merges in restricted-columns mode (next section).

## Support policy

> **We support merging between any two opencode builds that carry the same set of
> migration ids in their `migration` table.** In practice that is the frozen v1
> epoch **v1.17.10 → v1.18.x** (container and host both on v1) plus the **v2
> epoch** (both on v2, or a host db that v2 migrated forward in place) — which
> covers every realistic container-pin vs host-version combination today. The
> v1-container → v2-host direction also merges (host journal is a superset);
> only v2-container → v1-host skips, by design — plus verified-additive gaps
> (next section), which merge in restricted-columns mode.

### Additive-gap merges (verified allowlist)

A container journal that runs ahead of the host's normally refuses the merge,
because a journal id can be a *data-reshaping* migration
(`20260622170816_reset_v2_session_state` reshapes rows without leaving a
schema fingerprint pragma dumps can see). But a gap made up **only of
migrations verified additive from upstream source** is safe to merge in a
restricted-columns mode: the merge inserts each shared table using the
*host's* column list (the gate first confirms at runtime that the host's
columns are a subset of the container's on every shared table — the
purely-additive shape), so gap columns simply don't travel this round.

- **Allowlist** (default `AIDC_OPENCODE_ADDITIVE_MIGRATIONS_DEFAULT` in
  `lib/aidc/sync.sh`; override/extend via `AIDC_OPENCODE_ADDITIVE_MIGRATIONS`,
  explicitly empty to disable and restore the conservative skip):
  - `20261010180456_project_time_archived` — receipt (upstream
    `packages/core/src/database/migration/20261010180456_project_time_archived.ts`
    at tag v2.0.29): a single
    `ALTER TABLE \`project\` ADD \`time_archived\` integer;`. Cross-checked
    against a fresh 2.0.25 db vs the 2.0.29 container db: the only schema
    delta on any shared table is `project.time_archived`.
- **Fidelity note:** rows that land during a restricted merge carry NULL for
  the gap columns, and `INSERT OR IGNORE` means a later (full) re-merge will
  not backfill them — the host's row already won the collision. Container
  rows for projects/sessions are the payload; treat gap-column values on
  pre-upgrade-merged rows as best-effort metadata.
- **Maintenance rule:** whenever the container pin bump widens a journal gap,
  each new gap id must be verified additive from upstream source (fetch the
  migration file — never judge by the id's name) before joining the
  allowlist. Unlisted ids keep the conservative epoch-ahead skip, so an
  unverified gap can never corrupt anything — it just quarantines.
- **Journal integrity:** the `migration` table itself is never merged (in
  either mode — the exclusion compares case-insensitively, because SQL
  addresses tables case-insensitively while bash does not) — inserting
  container journal rows into the host's would falsify the host's epoch
  fingerprint and make its own upgrade skip replaying migrations it has
  not run.

Consequences for the merge code:

1. **Gate on the `migration` id-set, not physical column layout.** If the two
   DBs' `migration` id-sets are equal, they are the same schema epoch and the
   merge is safe. (If the container's set is a strict subset of the host's — host
   is newer — the extra host columns are additive and still safe via a
   column-name-qualified insert; a container carrying migrations the host lacks,
   or a set that straddles one of the breaking boundaries above, is *not*
   supported → skip to quarantine.)

2. **Do not compare column *position* (`cid`).** A long-lived host DB created by
   an older opencode and incrementally `ALTER TABLE … ADD COLUMN`-migrated lays
   its columns out in a different physical order than a freshly-created container
   DB built from `schema.gen.ts` — **same columns and types, different order**.
   The original `cid:name:type` comparison flags that cosmetic difference as
   drift and skips a merge that is in fact 100% safe. Compare the order-independent
   set of `name:type` instead, and insert with explicit shared column names
   (`INSERT OR IGNORE INTO t (c1,c2) SELECT c1,c2 FROM src.t`).

This is why `aidc opencode` logged *"opencode.db schema differs between
container and host; skipping merge"* even between a 1.17.13 container and a
1.18.20 host whose schemas are provably identical: the guard was comparing
physical column order, not the logical schema.

**Confirmed from data (2026-09-09):** `pragma_table_info` dumps of the actual
container (quarantine) and host dbs showed the identical 29-column `session`
table in both — with 11 columns at different `cid` positions (`workspace_id` at
cid 2 vs 18, `metadata` at 14 vs 28, …), and the host's `CREATE TABLE` text
showing the trailing `time_archived integer, workspace_id text, path text, …`
run of appended columns that is the fingerprint of `ALTER TABLE … ADD COLUMN`
growth. Same for `project` (`icon_url_override` cid 5 vs 11); `message`, `part`,
`todo`, `account`, `migration` were byte-identical. The version numbers were
never the cause; the *age* of the host db was.

## Implementation notes (current code)

`lib/aidc/sync.sh` implements the policy above:

- `aidc::opencode_db_schema_match` — per shared table, the container's columns
  (`name:type`, sorted; physical order ignored) must be a **subset** of the
  host's; and when either db carries a `migration` journal, both must and the
  container's applied ids must be a subset of the host's (a container db from a
  newer epoch is refused; a host db that has migrated *ahead* is fine, because
  the extra host columns are additive and the insert is name-qualified). On
  refusal the gate prints a reason token — `epoch-ahead <n>`,
  `journal-one-sided`, or `column-drift <table>` — and the callers log a
  cause-specific line: the epoch-ahead skip (the expected transient while the
  container's opencode build runs ahead of the host's, v2-vs-v1 or a newer v2
  minor) says so and carries the upgrade remedy; column drift names the table.
  Epoch reasons are checked *first* (first match wins): a newer build that
  also `ALTER`s shared tables — the normal way the schema grows — is both
  journal-ahead and column-drifted, and the journal gap is the root cause
  with the remedy, so that pair must report `epoch-ahead`, not drift.
  Exception: a journal gap made only of allowlisted, source-verified additive
  migrations (`aidc::opencode_gap_all_additive` +
  `AIDC_OPENCODE_ADDITIVE_MIGRATIONS_DEFAULT`) *and* a runtime-confirmed
  purely-additive shape (host columns ⊆ container columns on every shared
  table) prints the success token `additive-ahead <n>` and returns 0 — the
  merge then runs in restricted-columns mode.
- `aidc::opencode_db_merge` — `INSERT OR IGNORE INTO t (c1,c2,…) SELECT
  c1,c2,… FROM src.t` with the **source's** column list (the gate guarantees
  every source column exists in the destination, so it *is* the shared
  intersection). Never a positional `SELECT *`. In restricted-columns mode
  (after an `additive-ahead` pass) the column list comes from the
  **destination** instead. The `migration` journal table is excluded from
  both modes (schema bookkeeping, never data — see the allowlist section).
