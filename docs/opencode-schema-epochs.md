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
| **v1.17.10 – v1.18.30** | **38**     | **frozen — byte-identical `migration.gen.ts` and `schema.gen.ts`** |

Migrations added on the way to the frozen set:

- **→ v1.17.5** (reaching 35): `20260611035744_credential`,
  `20260611192811_lush_chimera`, `20260612174303_project_dir_strategy`
  (one of which lands at v1.17.4 → 33).
- **→ v1.17.10** (reaching 38): `20260622142730_simplify_session_context_epoch`,
  `20260622170816_reset_v2_session_state`, `20260622202450_simplify_session_input`.
  Note these are *reshaping/destructive* (a v2-session-state reset and two
  "simplify" rewrites), i.e. genuine breaking boundaries — crossing them is the
  case where a blind row-merge would be unsafe.

**Key result:** the schema has not changed for the entire current 1.17.10 → 1.18.x
line — 40+ consecutive releases. In particular the last 20 versions
(v1.18.11 … v1.18.30) contain **zero** schema changes.

## Support policy

> **We support merging between any two opencode builds that carry the same set of
> migration ids in their `migration` table.** In practice that is the single
> frozen epoch **v1.17.10 → current (v1.18.30)** — which covers every realistic
> container-pin vs host-version combination today.

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
  the extra host columns are additive and the insert is name-qualified).
- `aidc::opencode_db_merge` — `INSERT OR IGNORE INTO t (c1,c2,…) SELECT
  c1,c2,… FROM src.t` with the **source's** column list (the gate guarantees
  every source column exists in the destination, so it *is* the shared
  intersection). Never a positional `SELECT *`.
