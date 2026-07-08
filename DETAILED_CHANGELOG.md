# Detailed Changelog

The long-form companion to `CHANGELOG.md`. Where `CHANGELOG.md` says *what*
changed in one line, this file records *why* and *how* — enough for a future
reader to audit, reproduce, or roll back any change without re-deriving it.

Add a new entry (newest first) for every meaningful change.

---

## 2026-07-08 — Fix: `aidc-scan` shim missing inside the container

**Summary:** Every container-entering command (`aidc shell`/`exec`/`claude`/
`codex`/`opencode`/`grok`/`cursor-agent`/`sbom`/`scan`/`licenses`) now
re-asserts the in-container `aidc-scan` symlink synchronously, on the host, via
their shared `ensure_container_running` chokepoint — so `aidc-scan` is always on
PATH the first time you enter a container, not only after a full recreate.

**Why:** A user hit `aidc-scan: command not found` inside a freshly started
container. `aidc-scan` is not a binary — it's a symlink
(`~/.local/bin/aidc-scan` → `/workspace/.devcontainer/scripts/aidc-scan.sh`)
created by `bootstrap-state.sh`'s `init` dispatch (`install_aidc_scan_link`).
Two structural gaps:
1. **Race.** The container's compose `command:` is
   `bootstrap-state.sh init && sleep infinity`, run asynchronously. `compose up
   -d` returns as soon as the container *starts*, not when bootstrap *finishes*,
   so `run_tool` can `exec claude` before the link is made — even on a genuine
   first run.
2. **Staleness.** `init` runs only at container (re)creation. A container built
   before the scaffold gained `aidc-scan.sh` never gets the link, and
   `install_aidc_scan_link`'s `[[ -f "$script" ]] || return 0` guard skips it
   silently. Evidence on the dev box: `~/.local/bin/{claude,codex,grok}`
   symlinks dated the container's build day, no `aidc-scan`, while
   `.devcontainer/scripts/aidc-scan.sh` was dated days later.

When the shim is missing the Stop-hook scan guardrail (which calls `aidc-scan`)
silently no-ops (fails open), so this is a security-relevant reliability bug.

**What changed:**
- `lib/aidc/runtime.sh`: new `aidc::ensure_scan_link` runs a single idempotent
  `compose exec … sh -c 'ln -sf …'` that (re)creates
  `$AIDC_CONTAINER_HOME/.local/bin/aidc-scan` → the scaffold's `aidc-scan.sh`
  when that script is present. It is called from `ensure_container_running` — the
  single chokepoint every container-entering command passes through — after the
  `up -d` block, so shell/exec/agents/sbom/… all get the shim. Because it is a
  host-driven `docker exec` (a new process in the already-running container), it
  does not depend on the async bootstrap having reached its link step, closing
  the race deterministically. Non-fatal on failure (bootstrap remains a
  fallback).
- `tests/scan-link.test.sh`: asserts the exec shape (`exec -T … ln -sf` of the
  scaffold path), `AIDC_CONTAINER_HOME` passthrough, non-fatal failure, and that
  `ensure_container_running` wires the call.

**Verification:**
```
bash tests/scan-link.test.sh                # 4 passed
for t in tests/*.test.sh; do bash $t; done  # ALL TESTS PASS
shellcheck -x --severity=warning lib/aidc/runtime.sh tests/scan-link.test.sh  # clean
bash .devcontainer/scripts/aidc-scan.sh     # semgrep/gitleaks/shellcheck clean
```

**Notes:** Placed at `ensure_container_running` rather than only the agent path
so `aidc shell`/`exec` and the rest also guarantee `aidc-scan` on PATH (the
maintainer asked for it everywhere). `bootstrap-state.sh`'s
`install_aidc_scan_link` is left as a belt-and-suspenders fallback (also serves
non-aidc-launched execs). A cheap workaround for an already-running affected
container: `ln -sf /workspace/.devcontainer/scripts/aidc-scan.sh
~/.local/bin/aidc-scan`, or recreate with `aidc down && aidc up`.

## 2026-07-07 — `aidc --debug` tracing (secret-safe)

**Summary:** Added a global `--debug` flag that turns on `set -x` xtrace with a
`file:line` PS4 and a handful of `aidc::debug` breadcrumbs, so a stalled run
shows exactly where it stopped. Crucially, secret values never reach the trace.

**Why:** A user reported `aidc claude` "getting stuck at getting auth from the
macOS Keychain" on a fresh folder. Diagnosis: `aidc::resolve_claude_oauth_token`
runs `security find-generic-password … -w`, and the `-w` read of the secret is
gated by the Keychain item's ACL. When the calling binary (`/usr/bin/security`)
isn't on that item's ACL — the usual case until the user clicks **Always
Allow** once — macOS raises a blocking GUI approval dialog. `2>/dev/null` does
not suppress it (it's a window-server dialog, not stderr), so the CLI hangs.
It reads as "fresh folder" because `aidc claude` on a fresh folder is typically
the first end-to-end run, i.e. the first time the CLI touches that item; once
"Always Allow" adds `security` to the ACL, later runs don't prompt.
(`aidc doctor`'s keychain check uses `security … ` **without** `-w` — metadata
only, no ACL prompt — which is why doctor reports "token present" while the
real path blocks.) There was no way to *see* this happening; hence `--debug`.

**What changed:**
- `lib/aidc.sh` `aidc::main`: parse leading global flags (`--debug` → set
  `AIDC_DEBUG=1`) before the subcommand, so it never collides with a tool's own
  args (`aidc claude -- …`). When on: `export AIDC_DEBUG`, set
  `PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '`, print a one-line notice, `set -x`.
- `lib/aidc/common.sh`: `aidc::debug` (stderr breadcrumb, no-op unless
  `AIDC_DEBUG=1`) and the `aidc::secret_begin`/`aidc::secret_end` pair — the
  latter suppresses xtrace across a secret-handling region and restores the
  prior state (records it in `AIDC_XTRACE_SAVED`; regions must not span an early
  `return` or nest).
- Wrapped every token/secret touchpoint so `set -x` can't echo it:
  `resolve_claude_oauth_token` (the "already set" check, the `-w` read, and the
  export) in `profiles.sh`; the `run_tool` delivery/bootstrap conditionals
  (replaced inline `[[ -n "$TOKEN" ]]` with a once-computed guarded
  `have_oauth`); `deliver_claude_token`'s stdin pipe; `load_claude_profile_env`'s
  `. "$env_file"`; and `doctor_check_keychain`'s token check. Added a keychain
  breadcrumb that names the service/account and tells the user the hang is a
  Keychain prompt (click Always Allow, or Ctrl-C and export the token).
- Help: `aidc [--debug] <command>` usage line + a Notes paragraph.

**Commands / verification:**
```
bash tests/debug-flag.test.sh   # 7 passed (incl. token-not-leaked-under-xtrace)
for t in tests/*.test.sh; do bash $t; done   # ALL TESTS PASS
shellcheck -x --severity=warning lib/aidc*.sh lib/aidc/*.sh tests/debug-flag.test.sh  # clean
# manual: token present + xtrace on -> value appears 0 times in the trace
bash .devcontainer/scripts/aidc-scan.sh   # semgrep/gitleaks/shellcheck clean
```

**Notes:** Blanket `set -x` is a genuine leak risk in this codebase — the token
value is referenced in `[[ -n "$TOKEN" ]]` conditionals and assignments that
xtrace expands verbatim — so the secret-region guard is load-bearing, not
cosmetic. The Keychain **hang itself** is only diagnosed here, not fixed; a
follow-up could wrap the `-w` read in a watchdog/timeout (macOS has no
`timeout(1)`, so it'd need a bash-native killer) and fall back to interactive
login. `--debug` is parsed only as a leading global flag (or `AIDC_DEBUG=1`),
never trailing, so it can't be confused with args passed through to `claude`.

## 2026-07-07 — Namespace scaffolded CI scripts; `aidc init --force`

**Summary:** Two related fixes to `aidc init` ergonomics on a repo that
already has files. (1) The six SBOM/license scripts scaffolded into
`scripts/ci/` are renamed with an `aidc-` prefix so they stop colliding with
a project's own CI helpers. (2) A new `-f/--force` flag lets `aidc init` adopt
a directory that already has files at aidc-managed paths instead of aborting.

**Why:** On a fresh checkout of a repo that ships its own
`scripts/ci/lib-common.sh` (a very common CI-helper name), `aidc claude`
auto-init'd, hit `aidc::check_init_conflicts`, and died with
`refusing to overwrite existing file: …/scripts/ci/lib-common.sh`. The guard
is correct — aidc must never silently clobber a user's file — but the
collision was self-inflicted: aidc claimed generic, un-namespaced paths under
the shared, committed `scripts/ci/` directory. Namespacing removes the
collision at the source; `--force` is the escape hatch for the general case
(any managed path already present).

**What changed:**
- Renamed (via `git mv`, in both `templates/ci/*.sh.tmpl` and the repo's own
  dogfooded `scripts/ci/*.sh`): `lib-common`, `sbom-code`, `sbom-image`,
  `sbom-diff`, `license-check`, `sbom-all` → each `aidc-`-prefixed. The `.sh`
  working copies are byte-identical to their templates (`aidc::copy_template`
  is a plain `cp`), so both were renamed and edited identically.
- Updated every reference in lockstep (deliberately **not** the historical
  `CHANGELOG.md`/`DETAILED_CHANGELOG.md` entries): the scripts' own `source`
  lines and shellcheck directives, `AIDC_MANAGED_PATHS` +
  `AIDC_OVERWRITE_TEMPLATE_MAP` in `lib/aidc/common.sh`, `aidc sbom` /
  `aidc licenses` in `lib/aidc/runtime.sh`, the seeded `aidc-scan.sh` template,
  the reference `.github/workflows/sbom.yml`, `templates/ci/github-sbom.yml.tmpl`,
  `.github/workflows/aidc-e2e.yml`, `docs/security.md`, `lib/aidc.sh` help/notes,
  and the `tests/` that source or name the scripts (including the render loop
  in `tests/validate-scaffold.test.sh`).
- `aidc::cmd_init` now parses `-f/--force` (and an optional `[path]`, either
  order); `--force` skips `check_init_conflicts` and warns; unknown flags die
  with the valid set. Help usage + a Notes paragraph document it.

**Commands:**
```
# renames
for f in lib-common sbom-code sbom-image sbom-diff license-check sbom-all; do
  git mv templates/ci/$f.sh.tmpl templates/ci/aidc-$f.sh.tmpl
  git mv scripts/ci/$f.sh        scripts/ci/aidc-$f.sh
done
# reference rewrite: sed -e 's|<name>.sh|aidc-<name>.sh|g' over the code
# (changelogs excluded); see the file list in this session's log.
```

**Verification:**
- `bash tests/init-force.test.sh` — 7 passed (new).
- Full suite: every `tests/*.test.sh` green (validate-scaffold, license-check,
  license-resolve, sbom-diff, upgrade, aidc-scan, scan-hook, cli-errors, …).
- `grep` confirmed no un-prefixed `scripts/ci/<name>.sh` reference survives
  outside the two changelog files, and no `aidc-aidc-` double prefix.
- `bash .devcontainer/scripts/aidc-scan.sh` — semgrep/gitleaks/shellcheck
  clean; language/dependency scanners skipped (no matching changes).

**Notes:** `.devcontainer/scripts/aidc-scan.sh` is a git-excluded generated
copy (read-only here) — the tracked source is
`templates/devcontainer/scripts/aidc-scan.sh.tmpl`, which was updated.
`scripts/ci/license-matrix.tsv` keeps its name (user-owned policy, not a
script, and not the thing that collided). Existing aidc projects get the
renamed files on their next `aidc upgrade`; the old un-prefixed copies are
left in place for the user to delete (upgrade only writes mapped paths).

## 2026-07-06 — Agent-native guardrails: scan hook, MCP posture, insights

**Summary:** Implemented `plans/roadmap-12-agent-native.md` — the final
roadmap step. The scan guardrail moves from prose to mechanism for Claude
Code; MCP approval posture is pinned; `aidc insights` reports what the
machinery is doing.

**Why:** Prose guardrails degrade — agents rationalize, models weigh
instructions differently, non-Claude agents may ignore CLAUDE.md entirely.
Mechanical enforcement is simultaneously more reliable and less annoying:
the agent spends no tokens remembering to scan.

**How:**
- **Slice 1 — Stop hook** (`aidc-scan-hook.sh`, scaffolded + managed like its
  sibling scripts; the bind-mounted overlay means no image rebuild): reads
  the hook payload, honors `stop_hook_active` (loop guard), sources
  project.env for `AIDC_ENFORCE_SCAN_HOOK` (default 1), exits 0 on clean
  trees, debounces via a tree hash cached after the last clean pass, runs
  `aidc-scan --json`, and on findings exits 2 with the findings on stderr
  (Claude Code feeds that back to the agent). **Every abnormal path fails
  open** — missing scanner, infra error (rc≥2), missing git: allow and log.
  Outcomes append to `.ai-container/scan-hook.log` (bind-mounted → host
  readable). Bootstrap's new `ensure_agent_guardrail_settings` seeds the
  Stop hook into `~/.claude/settings.json` (creating the file if the host
  seeded none), idempotently, preserving rtk/user hooks, and removes exactly
  the aidc hook when the knob is 0.
- **Slice 2 — MCP posture**: the same seeding pins
  `enableAllProjectMcpServers: false` **only when the key is absent** — an
  explicit user choice is never overridden. `docs/security.md` gains the
  MCP-as-supply-chain section.
- **Slice 3 — `aidc insights`** (`lib/aidc/status.sh`): sessions count + top
  projects from `~/.claude/projects` (v1 is Claude-only; other agents'
  formats vary), scan-hook outcome tallies, `--since DATE` (find -newermt
  for files; lexical ISO compare for the log). Deterministic, offline, no
  LLM calls.
- Guardrail templates gain one line telling agents the hook exists and not
  to fight it; repo's own CLAUDE.md/AGENTS.md re-merged. Knob documented in
  the global config seed. insights added to dispatcher/help/README/
  completions/suggestions (the step-10 drift guard would have failed CI
  otherwise — by design).

**Dogfood moment:** the final full-tree `aidc-scan` run *blocked on real
findings* — the lib split had broken shellcheck's ability to follow sourced
globals, surfacing SC2034 in five test files. Exactly the failure mode the
hook exists to catch, found by the tool itself before CI. Fixed with scoped
directives; final scan fully clean (semgrep/gitleaks/shellcheck ok).

**Commands:** `bash tests/scan-hook.test.sh` (14/14 — clean-tree skip,
scan-once + debounce, block with stderr findings + logging, loop guard,
fail-open on infra error and on missing scanner, knob off, settings seeding:
create/idempotent/preserve-user-hooks/remove-on-off/respect-explicit-MCP),
`bash tests/insights.test.sh` (6/6), full suite 17/17 files, repo-wide
shellcheck clean, semgrep 0 findings, gitleaks clean.

**Verification:** hook exercised end-to-end against a fixture git workspace
with a stubbed scanner in all outcome classes; live block requires a Claude
Code session in a rebuilt container (the seeding + hook are unit-proven).

**Notes:** coverage matrix is honest — codex/opencode/grok stay prose-only
until their runtimes grow an equivalent hook point. This completes the
12-step roadmap.

---

## 2026-07-06 — lib/aidc.sh split into modules

**Summary:** Implemented `plans/roadmap-11-lib-split.md` — the ~2,900-line
monolith became a thin dispatcher over eight modules under `lib/aidc/`.
Mechanical move; zero behavior change.

**Why:** One file mixed dispatch, scaffolding, container lifecycle, two VM
backends, profiles, sync, and reporting; tests had to source the world, and
the Apple-`container` runtime plan needs a clean seam around the compose
invocation.

**How:** A one-off Python splitter parsed the monolith into the guard block,
top-level constant chunks (→ `common.sh`, original order preserved), and 131
function blocks with their attached comments, distributed by an exhaustive
name→module map (any unmapped name aborted the split):
`common` (constants + log/paths/perms helpers), `config`, `profiles`,
`scaffold`, `vm` (Lima + Firecracker), `runtime` (compose + lifecycle +
agent exec), `sync`, `status` (status/doctor/version/update). The new
`lib/aidc.sh` keeps the `AIDC_LIB_LOADED` guard, sources the modules from
`$AIDC_LIB_DIR`, and holds only `main`/`suggest_command`/`cmd_help`.
`bin/aidc` and `install.sh` unchanged (lib resolved relative to the checkout
as before). Only post-move touch: two `# shellcheck disable=SC2034`
directives for cross-module globals (comments only).

**Safety harness (all executed):**
- `declare -F` inventory before/after: 131/131 identical.
- Every function body byte-compared against the monolith backup: identical.
- Full test suite (15 files) green unchanged — tests still source
  `lib/aidc.sh` exactly as before.
- Live `aidc version` / `help` / `doctor` behave identically.
- New `.github/scripts/check-module-deps.sh` (in the shellcheck workflow):
  modules never source shell code (runtime sourcing of `.env` *data* files is
  expected and allowed), no duplicate function definitions, the entry point
  loads each module exactly once.
- `bash-compat.yml` and the repo-wide shellcheck job pick the new module
  files up automatically (`*.sh` globs).

**Notes:** `plans/have-a-look-at-lucky-whale.md` (Apple `container` runtime)
updated — its Phase-0 groundwork is delivered; the `aidc::rt_*` dispatch seam
remains its own future change.

---

## 2026-07-06 — CLI polish, docs completeness, Linux clarity

**Summary:** Implemented `plans/roadmap-10-cli-polish.md`.

**Why:** Assorted verified friction: bare `unknown command: X` errors, one
error message for two different project.env failure modes, no completions,
no troubleshooting/uninstall docs, README/docs claiming "macOS-only" while
the e2e suite runs on ubuntu, `sync-sessions` silently syncing only claude.

**How:**
- **Errors** (`lib/aidc.sh`): `aidc::suggest_command` (prefix/substring/
  2-char-prefix matching over the command list) with `aidc help` +
  `aidc doctor` pointers; `load_project_env` distinguishes *not an aidc
  project → run init* from *corrupt project.env → restore from
  .ai-container/backup/ or purge-and-reinit (settings lost)*, pre-validating
  with a `set -u` subshell before sourcing; `up`/`status`/`destroy` flag
  errors name their valid flags.
- **Completions**: `completions/aidc.bash` (commands, per-command flags,
  `--profile` values discovered from `~/.config/aidc/providers/claude/*.env`,
  tool names for `sync-*`); `completions/aidc.zsh` = bashcompinit wrapper.
  `install.sh` links the bash one into
  `~/.local/share/bash-completion/completions/` when that tree exists and
  prints source-lines otherwise (no rc-file edits behind the user's back).
  Drift guard: `tests/cli-errors.test.sh` extracts the dispatcher's command
  list from `aidc::main` and asserts both the completion table and the
  suggestion list cover every command — adding a command without updating
  them fails CI.
- **`sync-sessions` default → `all`** (was `claude`): partial syncs were
  surprising; README already implied parity.
- **Docs**: `docs/troubleshooting.md` (docker, PATH, Keychain, checksum
  mismatch, scaffold staleness/corruption, firewall allowlist + NNP
  conflict, clipboard, sessions — each symptom → cause → fix, with doctor as
  the front door); `docs/uninstall.md` (per-project + full host removal incl.
  aliases, completions, config, Keychain item, leftover docker state);
  platform matrix in `docs/install.md` + README docs index updated
  (troubleshooting/uninstall/releasing added).
- **Tests**: `tests/cli-errors.test.sh` (8 cases: suggestions ×2,
  missing-vs-corrupt ×2, drift guard, completion candidates ×2, dead-link
  check over README + docs/*.md).

**Commands:** suite 15/15 files green; shellcheck clean (SC2207 disabled in
the completion file with justification — compgen word-splitting is the
completion idiom); semgrep 0 findings; gitleaks clean.

**Verification:** typo'd commands produce useful suggestions (exercised in
tests via `bin/aidc statu`); completion candidates asserted for command and
flag positions; the link checker found (and I fixed) its own parsing bug
before finding zero real dead links.

---

## 2026-07-06 — `aidc scan` + right-sized guardrails

**Summary:** Implemented `plans/roadmap-09-guardrails-scan.md`: a single
changed-file-scoped scanner command plus proportionate guardrail text in the
seeded templates.

**Why:** The seeded guardrails mandated five-plus manual scanner invocations
and three documents for *every* change — a one-line fix cost the same
ceremony as a dependency bump. Agents facing that either burn time or start
rationalizing skips. The scanners were right; the packaging was the problem.

**How:**
- `templates/devcontainer/scripts/aidc-scan.sh.tmpl` (scaffolded, managed,
  in the template map → delivered by `aidc upgrade`): scope resolution
  (changed vs HEAD + untracked / `--staged` via the index + `gitleaks
  protect` / `--all` / explicit paths), scanner selection per the matrix in
  CHANGELOG, `--json` output, deliberate `set -u`-only (scanners exit
  non-zero on findings by design), per-scanner summary lines with findings
  printed in full, skips never fatal. **Deviation from the plan:** not baked
  into the image — the script rides the read-only `/workspace/.devcontainer`
  overlay and bootstrap symlinks it to `~/.local/bin/aidc-scan`, so it works
  with every already-built image (no rebuild coupling) and tracks scaffold
  upgrades automatically.
- `lib/aidc.sh`: `aidc scan` subcommand (compose-execs the scaffolded
  script), dispatch + help; bootstrap gains `install_aidc_scan_link`.
- Guardrail rewrite in `templates/CLAUDE.md.tmpl` + `AGENTS.md.tmpl`
  (marker-merged → existing projects get it via `aidc upgrade`): scanning is
  now "run `aidc-scan`, fix everything above LOW"; changelog/session-log
  requirements scale to change size (trivial = typo/comment/formatting with
  no logic, dependency, or security-surface change → exempt); the
  non-negotiables stay (never dismiss findings without user confirmation,
  trufflehog on anything live-looking). This repo's own CLAUDE.md/AGENTS.md
  re-merged from the new templates via `aidc::merge_template` — dogfooding
  the merge path.
- `docs/security.md`: new "`aidc scan`" section at the top; per-scanner
  commands remain documented below it.

**Commands:** `bash tests/aidc-scan.test.sh` (14/14: scoping, per-type
selection, manifest gating, finding propagation, valid `--json`, `--all`,
missing-scanner skip, `--staged` + gitleaks protect, usage errors) with all
scanners stubbed on a restricted PATH; full suite 14/14 files;
`shellcheck` clean (after fixing a comment that parsed as a shellcheck
*directive* — SC1072); semgrep 0 findings; gitleaks clean.

**Verification:** dogfooded — `aidc-scan` run against this session's real
working-tree diff selected semgrep + gitleaks + shellcheck (all clean) and
correctly skipped bandit/gosec/cargo/bundle/npm/vet/license as out of scope.

**Notes:** roadmap step 12 will wire `aidc-scan --json` into a Stop hook so
the guardrail becomes mechanical rather than prose.

---

## 2026-07-06 — `aidc upgrade` + conservative implicit scaffolding

**Summary:** Implemented `plans/roadmap-08-scaffold-upgrade.md`. Two coupled
changes: a new `aidc upgrade` command (diff → confirm → backup → apply), and
the plan's key design decision — implicit commands stop rewriting scaffold
files.

**Why:** Template fixes previously reached existing projects by `up` silently
re-copying every managed file on every run — which also silently clobbered
any local edit to the Dockerfile/compose files (the clobber risk flagged in
the roadmap review). There was no way to see what a newer aidc would change
before it changed it.

**File classes (now encoded once, in `AIDC_OVERWRITE_TEMPLATE_MAP`):**
- *template-tracking* (14 files: Dockerfile, 3 compose files,
  devcontainer.json, 2 bootstrap scripts, cursor rules, 6 scripts/ci
  scripts) — owned by aidc, rewritten only by `upgrade`/`init`;
- *marker-merged* (`CLAUDE.md`, `AGENTS.md`) — only the aidc block is
  replaced, user content preserved (unchanged);
- *seed-once/user-owned* (`project-setup.sh`, `license-matrix.tsv`,
  `CHANGELOG.md`, `DETAILED_CHANGELOG.md`, `logs/`, `github-sbom.yml`,
  `project.env` contents) — never rewritten.

**How (`lib/aidc.sh`):**
- `refresh_scaffold` refactored to iterate the map (single source of truth
  for scaffold + upgrade + staleness check).
- `AIDC_SCAFFOLD_MODE` (`overwrite` default / `create`): `copy_template`
  skips existing targets in create mode; `merge_template` skips files that
  already carry the managed block. `ensure_workspace_ready` (the implicit
  path) runs in create mode and prints
  `scaffold is out of date … run 'aidc upgrade'` when
  `aidc::scaffold_is_stale` (stamp differs OR any mapped file
  missing/differing). `cmd_init` keeps overwrite mode — an explicit init is
  an explicit refresh (e2e's init-idempotency contract unchanged).
- `aidc::cmd_upgrade [--dry-run|--diff] [-y]`: classify each mapped file as
  create/update; `already current` short-circuit requires stamp match AND
  zero drift; unified diffs labeled `current/…` vs `aidc-<ver>/…` (`diff -L`,
  portable to BSD); interactive y/N confirm, `-y` for scripts, hard refusal
  on non-tty stdin without `-y`; backups of every rewritten file under
  `.ai-container/backup/<timestamp>/` (git-excluded via `.ai-container/`);
  apply = overwrite-mode `refresh_scaffold` + in-place stamp update
  (`update_project_env_stamp` rewrites only the `AIDC_VERSION=` line, user
  settings survive).
- **Bug found by the tests:** sourcing `project.env` clobbered the live
  `AIDC_VERSION` with the stamp, so every stamp-vs-current comparison
  compared the stamp to itself. `load_project_env` now restores the live
  version after sourcing. (CHANGELOG → Fixed.)

**Commands:** `bash tests/upgrade.test.sh` (16/16: fresh-scaffold
idempotence, dry-run diff + no-op, apply restore + backup, stale-stamp path +
user project.env settings survive, missing-file create, non-interactive
refusal, user-owned files untouched, CLAUDE.md content survives, implicit
path preserves edits / creates missing / byte-identical merges / notice);
full suite 13/13 files; shellcheck clean; YAML + `bash -n` on workflows;
semgrep 0; gitleaks clean.

**Verification:** e2e gains an upgrade round-trip on the ubuntu leg (edit →
dry-run lists it → `-y` restores + backup exists → second upgrade reports
already current). README documents the new update/upgrade flow.

**Notes:** behavior change recorded under Changed in CHANGELOG: template
fixes now reach existing projects via explicit `aidc upgrade` (surfaced by
the staleness notice and doctor) instead of invisibly on the next `up`.

---

## 2026-07-06 — `aidc doctor` + `aidc update`

**Summary:** Implemented `plans/roadmap-07-doctor-update.md`: one command that
answers "why isn't this working" and one that answers "how do I update".

**Why:** Failures previously surfaced as whatever error the failing layer
emitted (docker down, PATH missing, Keychain empty, stale scaffold), and the
update path was an undocumented `git pull && ./install.sh`.

**How (`lib/aidc.sh`):**
- Composable `aidc::doctor_check_*` functions + `aidc::doctor_report`
  (OK/WARN/FAIL counters) so tests exercise each check in isolation and later
  steps can add posture lines. Checks and their remedies are listed in the
  CHANGELOG entry. Design points: informational states (no Keychain on
  Linux, firewall off) are OK not WARN — matching the no-nagging directive;
  a broken `project.env` gates the deeper project checks (they'd die
  sourcing it); freshness uses `rev-list HEAD..origin/main` against the
  last-fetched state — no network, no hangs, phrased "as of last fetch";
  the Keychain check reuses the `${USER:-$(id -un)}` account fallback and
  never prints token material (asserted in tests).
- `aidc::cmd_update`: refuse non-checkout installs; `git pull --ff-only`
  (never merge a user-modified checkout — divergence gets a manual-resolution
  message and install.sh does NOT run); re-run `install.sh`; report
  `old (sha) -> new (sha)`; hint `aidc upgrade` + `aidc rebuild` when inside
  a project.
- Fixed in passing: `aidc::cmd_version` no longer trips `set -u` when the
  lib is sourced without `AIDC_ROOT` (defensive `${AIDC_ROOT:-}`).

**Commands:** `bash tests/doctor.test.sh` (15/15), `bash tests/update.test.sh`
(6/6), full suite green (12 files), `bash bin/aidc doctor` live in this
container — correctly FAILs on the (absent) docker CLI and flags nothing
else; `shellcheck` clean; `semgrep` 0 findings; `gitleaks` clean.

**Verification:** doctor run against this real environment produced the
expected report (docker FAIL with install hint, keychain informational on
Linux, scaffold stamp OK, firewall off-by-design line). e2e asserts a
well-formed report on both runner OSes (exit ≤ 1, `^host` present).

**Notes:** the `doctor` scaffold-version check references `aidc upgrade`,
which lands in the next roadmap step (same branch) — the hint is accurate by
merge time.

---

## 2026-07-06 — Versioning: `aidc version` + tag-driven release workflow

**Summary:** Implemented `plans/roadmap-06-versioning-releases.md`:
`aidc version` subcommand, `release.yml` workflow (tag → verified GitHub
Release), `docs/releasing.md` procedure.

**Why:** `AIDC_VERSION` was hardcoded `0.1.0`, never surfaced, never compared;
no tags, no releases — users couldn't report what they run, and the upcoming
`doctor`/`update`/`upgrade` commands need a reference point.

**How:**
- `aidc::cmd_version` prints `aidc <version> (<short-sha>)` (sha only when
  running from a git checkout with git present); dispatched as
  `version|--version|-V`; help + README updated.
- `release.yml` on `v*` tag push: (1) parses `AIDC_VERSION` out of
  `lib/aidc.sh` and fails on mismatch with the tag; (2) extracts the
  `## [X.Y.Z]` section from CHANGELOG.md via awk **to a file** (no shell
  interpolation of changelog content into commands — script-injection safe)
  and fails if absent; (3) `gh release create --notes-file`. Zero third-party
  actions beyond the SHA-pinned checkout.
- `docs/releasing.md`: bump → cut changelog section → tag → push; failure
  recovery; 0.x semver policy; the `project.env` stamp is the
  scaffolded-by version (`aidc upgrade`'s comparison point — it is seed-once
  by design, user settings survive refreshes).
- e2e: `aidc version` smoke assertion (exit 0, `^aidc \d+\.\d+\.\d+`).

**Commands:** `bash bin/aidc version` → `aidc 0.1.0 (2d24d38)`; workflow
assertion logic executed locally against the real tree (version parse OK,
tag-match OK, missing-section detection OK); YAML + `bash -n` on the
workflow; `shellcheck` clean; `semgrep` 0 findings.

**Verification:** first real exercise happens on the first tag push
(recommended: `v0.2.0` once this roadmap lands, per docs/releasing.md).

---

## 2026-07-06 — Token handling: tmpfs file delivery, strict profile perms, temp hygiene

**Summary:** Implemented `plans/roadmap-05-token-handling.md`, plus one real
bug found along the way (Linux permission checks never worked — see Fixed in
CHANGELOG).

**Why:** The Claude OAuth token travelled as `docker compose exec -e
CLAUDE_CODE_OAUTH_TOKEN`, making it visible in the exec instance's metadata
and inherited environments; profile env files with API keys only *warned* on
loose permissions and their values lingered in aidc's environment after the
run; `mktemp` temp files in the merge helpers landed in /tmp with no cleanup
on failure.

**How (`lib/aidc.sh`):**
- **File delivery (default).** `aidc::deliver_claude_token` pipes the token
  over the exec's stdin into `/dev/shm/aidc-oauth-token` (`umask 077`).
  Both the one-time-login bootstrap and the agent launch run through an
  inline `bash -c` prelude (`AIDC_CLAUDE_TOKEN_SNIPPET`) that imports the
  token from the file into the process environment; the launch path deletes
  the file before `exec claude`. Deliberately implemented as an inline
  snippet rather than an image-baked wrapper so it works against ANY
  already-built container image — no rebuild required, no version skew
  between lib and image. `-e CLAUDE_CODE_OAUTH_TOKEN` is skipped in the
  passthrough when file delivery is active
  (`AIDC_PASSTHROUGH_SKIP_KEY` consumed by `append_passthrough_env_args`).
  `AIDC_TOKEN_DELIVERY=env` restores the legacy path; a failed file delivery
  falls back to env with a warning. Profile-based runs (API-key `-e`
  forwarding) are unchanged — documented as future work.
- **Strict profile perms.** New `aidc::require_strict_permissions` (die with
  the exact `chmod 600` command) called in `load_claude_profile_env` — the
  moment secrets are exported. Read-only paths (`--list-profiles`, alias
  sync via `claude_profile_metadata`) keep the warning so one bad file can't
  break listing. Generated `*.env.example` files are seeded 0600.
- **Scrubbing.** `load_claude_profile_env` records exported keys in
  `AIDC_PROFILE_LOADED_KEYS`; `aidc::scrub_profile_env` unsets them right
  after the agent exec returns.
- **Temp hygiene.** `merge_template` / `strip_merge_block` now mktemp
  **next to the target** (same-fs atomic `mv`, nothing lingers in /tmp) and
  remove the temp file on every failure path before dying.
- **Bug fix.** `aidc::file_permissions` probed BSD `stat -f` first; on GNU
  stat that means "filesystem status", exits 0, and returns multi-line junk —
  so the `-c` fallback never ran and permission checks were no-ops on Linux
  (visible the moment the new hard check ran in this container). GNU form
  now probed first; output validated as octal on both platforms.

**Commands:** `bash tests/token-delivery.test.sh` (15/15 — file delivery
drops `-e`, token in no argv, token on stdin, umask'd tmpfs write, wrapped
bootstrap, launch-time file deletion, env-mode restore, no-token path, hard
perm error + chmod hint, 0600 loads, scrub before/after, merge-failure temp
cleanup); full suite green; `shellcheck` clean; `semgrep` 0 findings;
`gitleaks` clean.

**Verification:** unit-level with a stubbed compose layer recording argv +
stdin. Live check on a host: `aidc claude -- -p ok` authenticates;
`docker inspect` of the exec shows no token; `/dev/shm/aidc-oauth-token`
absent after launch.

**Notes:** in-container same-user reads of the agent's `/proc/<pid>/environ`
remain possible — inherent to the agent consuming an env var; documented in
`docs/security.md` § How the token reaches the agent.

---

## 2026-07-06 — Egress firewall: IPv6 deny, DNS refresh + pinning (opt-in only)

**Summary:** Implemented `plans/roadmap-04-firewall-hardening.md`. All changes
apply **only** to projects that opt into the firewall — the default container
keeps its open network permanently (maintainer decision, this session).

**Why:** With the firewall "on", three bypasses existed: (1) zero IPv6 rules —
on any v6-capable Docker network an agent could exfiltrate freely over IPv6;
(2) hostnames resolved once at container start — CDN/IP rotation either
stranded legitimate hosts or left stale IPs allowed; (3) port 53 was open to
any destination, allowing DNS to arbitrary resolvers.

**How (template: `templates/devcontainer/scripts/init-firewall.sh.tmpl`,
restructured into sourceable functions with a `main()` guard for testability):**
- `apply_ipv6_rules`: `ip6tables` default-deny INPUT/FORWARD/OUTPUT with
  loopback + established excepted; no v6 allowlist (the allowlist is
  IPv4-only — a follow-up can add `family inet6` resolution if an allowlisted
  endpoint ever goes v6-only). Degrades with a logged note when ip6tables is
  absent or the kernel has no v6 stack.
- `refresh_allow_set`: resolves into a staging ipset and `ipset swap`s it in
  atomically (no empty-allowlist window). `init-firewall.sh refresh` runs one
  cycle; `start_refresh_loop` backgrounds a `sleep`-loop (pidfile-idempotent,
  reparented to the container's init, `AIDC_FIREWALL_REFRESH_SECONDS`
  default 300, 0/non-numeric disables). Refresh diffs log to
  `/var/log/aidc-firewall.log`.
- `dns_rules`: port-53 egress restricted to `/etc/resolv.conf` nameservers
  (Docker's embedded 127.0.0.11 is loopback, already accepted). Falls back to
  open 53 with a logged note if no IPv4 nameserver parses — never break DNS.
- `bootstrap-state.sh.tmpl`: forwards `AIDC_FIREWALL_REFRESH_SECONDS` through
  `sudo -n env …` (sudo resets the environment).
- `lib/aidc.sh`: `aidc status` shows a passive posture line
  (`firewall: off (open network, default)` / `on (default-deny allowlist)`).
  Explicitly NOT a boot-time warning — the open default is the product
  experience, not a degraded mode. Global config seeds the refresh knob.
- `docs/security.md`: rewritten egress-firewall section — enforcement
  semantics (IPv4 allowlist, IPv6 drop, DNS pinning, what DoH can and cannot
  do under the model), allowlist-file format with examples, refresh knob,
  manual refresh command, opt-in-by-design statement.

**Commands:** `bash tests/init-firewall.test.sh` (11/11 — allowlist parsing,
resolution into ipset, rotation pickup via atomic swap, staging cleanup,
IPv4 rule emission, DNS pinning to v4 resolver only, IPv6 default-deny,
refresh-loop disable paths) with stub `iptables`/`ip6tables`/`ipset`/`getent`
binaries recording argv; full test suite green; `shellcheck` clean;
`semgrep` 0 findings; `gitleaks` clean.

**Verification:** unit-level only in this environment (no Docker daemon in
the aidc container). Live end-to-end check on a host, firewall enabled:
`curl https://api.anthropic.com` (allowed), `curl https://example.com`
(blocked), `curl -6` anywhere (blocked), `sudo ipset list aidc-allow` gains
rotated IPs within the refresh interval. The e2e/image CI exercises the
script's syntax + shellcheck via validate-scaffold on every push.

**Notes:** DEFAULT_HOSTS unchanged. Tailscale CGNAT pass-through unchanged
and now documented. Firewall default remains off permanently.

---

## 2026-07-06 — Compose hardening with freedom-preserving defaults

**Summary:** Implemented `plans/roadmap-03-compose-hardening.md`, adjusted to
the maintainer's directive that the default container stay unrestricted:
capabilities become conditional (granted only with the firewall), a pids
fork-bomb guard lands by default (invisible in normal use), memory/CPU are
cappable but unlimited by default, and `no-new-privileges` is opt-in.

**Why:** `compose.yaml` granted `NET_ADMIN`/`NET_RAW` to every container even
though only the (opt-in, off-by-default) egress firewall's iptables/ipset init
needs them — default containers carried raw-network capabilities they never
used. There were no resource limits at all (a fork bomb could starve the
shared Docker VM), and no privilege-escalation guard even as an option.

**Design decisions:**
- `no-new-privileges` is **not** applied by default, deviating from the
  original plan sketch: the devcontainers base image ships passwordless sudo
  as a usability feature (`sudo apt-get install …` inside the container), and
  NNP kills setuid entirely. Freedom-by-default won; the knob exists
  (`AIDC_NO_NEW_PRIVILEGES=1`) with the trade-off documented.
- NNP + firewall is a hard conflict (firewall init runs `sudo -n` at
  container start — verified in `bootstrap-state.sh.tmpl:180-190`), so
  `aidc::compose_file_args` warns and skips the hardened override when both
  are set. Firewall wins because it was requested explicitly per-project.
- No `cap_drop: ALL`: it would break sudo (SETUID/SETGID), ping, and
  bootstrap's chown. Docker's default capability set stays.
- Overrides are separate compose files (`compose.firewall.yaml`,
  `compose.hardened.yaml`) merged via `-f` — compose has no conditional
  syntax, and aidc already owns the invocation. Old scaffolds without the
  override files degrade gracefully to base-only.

**How:**
- `templates/devcontainer/compose.yaml.tmpl`: `cap_add` removed;
  `pids_limit: ${AIDC_PIDS_LIMIT:-4096}`, `mem_limit: ${AIDC_MEM_LIMIT:-0}`,
  `cpus: ${AIDC_CPU_LIMIT:-0}` added (0 = unlimited).
- New `compose.firewall.yaml.tmpl` / `compose.hardened.yaml.tmpl` (managed,
  scaffolded, in `AIDC_MANAGED_PATHS`).
- `lib/aidc.sh`: new `aidc::compose_file_args` builds the `-f` chain from the
  knobs; `aidc::compose` + `aidc::compose_capture` use it; global config seed
  documents the new knobs.
- `.github/scripts/validate-scaffold.sh`: override files required + each must
  merge cleanly onto the base (`docker compose config` per combination).
- `aidc-e2e.yml`: scaffold assertion list extended; new "Compose hardening
  posture" step renders the config default/firewall/hardened and asserts
  NET_ADMIN and no-new-privileges appear exactly when they should.
- `docs/security.md`: new "Container hardening" section.

**Commands:** `bash tests/compose-file-args.test.sh` (6/6 — default chain,
firewall chain, hardened chain, conflict warn+skip, old-scaffold
degradation); full suite re-run (all pass after re-pointing the
validate-scaffold fixtures at `templates/` — the in-container rendered
`.devcontainer` is read-only + stale by design, and templates are the source
of truth); `shellcheck` clean; YAML parses; `semgrep` 0 findings; `gitleaks`
clean.

**Verification:** compose render assertions run in CI on push (no docker in
the aidc container); the unit test proves the file-chain logic including the
conflict and degradation paths.

**Notes:** the repo's own rendered `.devcontainer/` will pick up the new
override files on the next host-side `aidc up`/`rebuild`. VS Code's
`devcontainer.json` flow uses the base file only (documented).

---

## 2026-07-06 — Supply chain: every image installer pinned + checksum-verified

**Summary:** Implemented `plans/roadmap-02-pin-installers.md`. The devcontainer
image build no longer executes anything fetched from a floating branch:
every tool is a version-pinned artifact, and everything that publishes
checksums is verified against a SHA256 recorded in the Dockerfile.

**Why:** aidc's pitch is supply-chain safety, yet the image build piped nine
unpinned installers into a shell — several from `main`/`master`
(`pmg`, `trufflehog`, `rtk`, the syft/grype installer scripts) and all four
agent CLIs unversioned. Rebuilds were non-reproducible and a compromised
installer endpoint would have executed arbitrary code in every build.

**How (all in `templates/devcontainer/Dockerfile.tmpl` — the rendered
`.devcontainer/Dockerfile` is git-excluded, mounted read-only in-container,
and refreshes from the template on the next host-side `aidc up`):**
- New `aidc-fetch-verified <url> <dest> <sha256|SKIP>` helper (COPY heredoc,
  `/bin/sh`): downloads, verifies, deletes the artifact and fails the build on
  mismatch. `SKIP` (used automatically by `<TOOL>_VERSION=latest` ad-hoc
  overrides) prints a loud warning.
- Tier 1 — direct release artifacts + per-arch `ARG *_SHA256_{AMD64,ARM64}`:
  pmg v0.21.3, trufflehog v3.95.8, rtk v0.43.0 (vendor targets:
  x86_64-musl / aarch64-gnu), syft v1.18.1, grype v0.87.0 (both previously
  installed via unpinned installer scripts from `main` that could have ignored
  the version arg), plus checksums added to the already-pinned git-delta
  0.18.2, vet v1.17.3, gitleaks v8.30.1.
- Tier 2 — agents version-pinned through their installers (each verified
  against the vendor's actual contract by reading the installer source):
  claude 2.1.201 (positional arg; installer self-verifies against its
  manifest SHA256), codex 0.142.5 (`--release`), opencode 1.17.13 (`VERSION`
  env), grok 0.2.87 (positional arg). Installers are fetched to a file and
  executed, never piped.
- Tier 3 — documented exceptions in `docs/security.md` § Image supply chain:
  cursor-agent (vendor offers no pin; version logged at build), grok (no
  vendor checksums), rustup (self-verifying official bootstrap), apt/
  NodeSource (GPG chain).
- `scripts/update-pins.sh`: resolves each vendor's latest tag
  (`git ls-remote`-free — release-redirect probe), pulls the checksums file
  (or hashes the artifacts locally for git-delta, which publishes none) and
  prints fresh `ARG` lines; `--write` rewrites them in place. Live-run
  verified: current pins match latest for pmg/trufflehog/gitleaks/rtk/agents;
  newer syft/grype/vet/delta exist but were deliberately NOT bumped here —
  this change is about verification, version bumps ride their own commit.
- CI: `.github/scripts/check-image-pins.sh` (new) asserts every pinned tool
  inside the built image reports its pinned version (runs in the `image-scan`
  job); both `sbom.yml` jobs and the scaffolded `github-sbom.yml.tmpl` now
  install syft/grype from the pinned artifacts (the aidc-repo jobs read the
  pins straight from the Dockerfile template — one source of truth; the
  scaffolded template embeds them since user repos git-exclude
  `.devcontainer/`).

**Commands:** `bash tests/update-pins.test.sh` (23/23),
`bash tests/check-image-pins.test.sh` (5/5), live `scripts/update-pins.sh`
run against real endpoints (all asset patterns resolve),
`shellcheck --severity=warning` on all new scripts (clean), helper extracted
and functionally tested (good sha → pass, bad sha → exit 1 + artifact
removed, SKIP → warning), YAML + `bash -n` validation of changed workflows,
`semgrep` 0 findings, `gitleaks` clean.

**Verification:** the full image build with these pins runs in the `image-scan`
CI job on the next push (no Docker daemon in the aidc container itself);
`check-image-pins.sh` will fail the job if any artifact/installer contract was
misread. Checksum values were fetched from the vendors' published checksums
files and cross-checked against locally-downloaded artifacts for delta.

**Notes:** amd64 + arm64 both covered for every checksum-pinned tool.
`docs/security.md` gains the "Image supply chain" section describing tiers,
exceptions, and the bump procedure.

---

## 2026-07-06 — CI safety net: scaffold validation, lifecycle e2e, image scan, Scorecard

**Summary:** Implemented `plans/roadmap-01-ci-safety-net.md` — the foundation
step of the roadmap. Four additions: (1) a standalone scaffold validator
(`.github/scripts/validate-scaffold.sh`) wired into the e2e workflow, (2) a
destructive-lifecycle e2e step (destroy → assert clean → re-init → assert
identical), (3) an image vulnerability-scan job in `sbom.yml`, (4) an OpenSSF
Scorecard workflow.

**Why:** The `.tmpl` files under `templates/` are scaffolded into every user
project but were never validated in CI — a broken `compose.yaml.tmpl` or a
syntax error in a bootstrap script would ship silently. The destructive
lifecycle (`destroy --purge-*`) had zero coverage. Roadmap steps 2–4 change the
Dockerfile/compose/firewall templates; this step makes those changes
regression-testable before they land.

**How:**
- `validate-scaffold.sh` takes a scaffolded project dir and checks: required
  files present; `bash -n` + `shellcheck --severity=warning` (matches the
  shellcheck workflow) on every scaffolded `*.sh`; `project.env` sources in a
  clean env under `set -u`; `devcontainer.json` parses as JSON (jq, python3
  fallback); `docker compose config -q` renders with every `${AIDC_*}` var
  auto-derived from the compose file and stubbed; `docker build --check`
  BuildKit lint. Docker checks skip with a note when no CLI/daemon (macOS
  runners, local container use). Bash-3.2-safe (no `sort -z`, guarded empty
  arrays) since the macOS e2e leg runs under system bash.
- e2e workflow: "Validate scaffold output" step after init; "Destroy →
  re-init lifecycle" step (ubuntu leg only, guarded by `docker info`)
  snapshots the managed scaffold, destroys with both purge flags, asserts
  managed paths gone / seeded docs survive / CLAUDE.md merge block stripped /
  no `aidc_scaffold-proj*` volumes remain, re-inits and `diff -r`s the
  scaffold against the snapshot. Safe on a never-started container:
  `aidc::auto_sync_sessions` returns early when `compose ps -q` is empty.
- `sbom.yml` `image-scan` job: buildx build of `.devcontainer/` with a local
  layer cache (`actions/cache`, keyed on the Dockerfile hash, swap-not-append
  so it doesn't grow), then grype in report-only mode (`-o table`, artifact
  uploaded). Doubles as a Dockerfile build regression test. Tighten to
  `--fail-on high` after a baseline week.
- `scorecard.yml`: standard OSSF setup, `publish_results: true`, SARIF to the
  Security tab; weekly cron + push to main; all actions pinned by commit SHA
  (resolved via `git ls-remote --tags`): scorecard-action v2.4.3, actions/cache
  v4.3.0, setup-buildx-action v3.9.0, codeql-action v3.36.3.

**Commands:** `bash tests/validate-scaffold.test.sh` (6/6),
all pre-existing test files re-run (pass), `shellcheck --severity=warning` on
both new scripts (clean), YAML parse + `bash -n` of every workflow `run:`
block via a pyyaml one-off, `semgrep scan --config auto .github/ tests/…`
(0 findings), `gitleaks detect` (clean).

**Verification:** validator run against this repo's own rendered scaffold —
all checks pass, docker checks skip (no daemon in the aidc container). Unit
tests prove each failure mode fires: broken shell, broken JSON, missing file,
broken project.env, usage error.

**Notes:** The lifecycle test's re-init comparison is valid because
`project.env` generation is deterministic for a fixed workspace path (slug =
basename + path hash; no timestamps). `bash-compat.yml` parse-checks the new
scripts across bash 3.2/4.2/4.4/5.2 automatically since it globs all `*.sh`.

---

## 2026-07-06 — Usability & security roadmap: 12-step plan series

**Summary:** Added `plans/roadmap-00-overview.md` (master plan) and twelve step
plans `plans/roadmap-01-…` through `plans/roadmap-12-…`. Documentation only —
no code or template changes.

**Why:** A full-project review (three parallel deep-dives: core CLI, container/
template layer, and docs/tests/CI/plans) found the security model sound but
identified concrete gaps: nine unpinned `curl | bash` installers in the
Dockerfile (several fetching install scripts from floating `main`/`master`),
an egress firewall with zero IPv6 rules plus init-time-only DNS resolution and
off-by-default silence, missing compose hardening (`no-new-privileges`,
resource limits, unconditional NET_ADMIN/NET_RAW), no versioning/doctor/update/
upgrade lifecycle, guardrail prose heavy enough to invite agent
rationalization, ~4% unit-test coverage of `lib/aidc.sh`, and no template
validation in CI. Key findings were re-verified directly against the tree
before planning (installer lines in `.devcontainer/Dockerfile:79,105,138–145,
225–230`; no `ip6tables`/`inet6` in `init-firewall.sh`; no `security_opt`/
limits in `compose.yaml`). One subagent finding (a missing `destroy -f` flag)
was disproved during verification and excluded.

**How:** Each step is a PR-sized plan matching the repo's existing plan format
(context → concrete changes with file/function anchors → testing → security
scans → verification → notes). The master plan sequences them in four phases —
A: safety net & hardening (01–05), B: lifecycle (06–08), C: developer
experience (09–10), D: foundation & frontier (11–12) — with explicit
dependencies (versioning before doctor/upgrade; `aidc-scan` before hook
enforcement; lib split last to avoid diff conflicts, doubling as Phase 0 of the
pre-existing Apple-container plan `have-a-look-at-lucky-whale.md`).

**Commands:** review used read-only exploration plus verification greps; files
created with the editor. Scanners run on the changed files (`semgrep`,
`gitleaks`) — see session log.

**Verification:** all 13 plan files present under `plans/`; changelog entries
in both files; session log `logs/2026-07-06-roadmap-plan-series.md`.

**Notes:** Deliberate deferrals recorded inside the plans: strict seccomp and
read-only rootfs are postponed until `aidc upgrade` (step 8) makes rollout to
existing scaffolds cheap and visible. The egress firewall stays **off by
default permanently** (maintainer decision, 2026-07-06): the default container
is intentionally unrestricted; firewall hardening applies to opt-in users only.

---

## 2026-07-01 — SBOM generation, license-conflict checks, and CI-agnostic automation

**Summary:** aidc now generates SBOMs in both CycloneDX and SPDX (at code level
and, when a Docker image is available, at build time), diffs the two to show
what the image build adds over the source, and gates dependency licenses that
conflict with the project's own license — all through a set of CI-agnostic bash
scripts under `scripts/ci/` that any CI (GitHub, Jenkins, GitLab, …) calls the
same way. `syft` and `grype` moved from opt-in to always-on in the image.

**Why:** The container already shipped SCA (`vet`/`pmg`) and SAST/secret
scanners, but had no SBOM, no license-compatibility gate, and no scripted,
provider-neutral way to run supply-chain steps in CI. The request was to make
SBOMs (both formats) and an early license-conflict warning first-class, and to
move build/scan steps into reusable scripts so the CI config is a thin caller.

**Design decisions (confirmed with the requester):**
- **syft + grype always-on** (previously opt-in via `AIDC_SECURITY_TOOLS`) so
  SBOMs "just work" in every project and CI without extra config.
- **License engine = existing `vet` + a syft-derived matrix** — no new binary.
  The syft-SPDX + `license-matrix.tsv` check is the always-on, offline,
  deterministic gate; `vet` license enrichment is opt-in (`AIDC_LICENSE_USE_VET=1`,
  needs network) since its Insights-backed license data requires connectivity.
- **Warn locally / fail in CI** via `AIDC_LICENSE_MODE` (default `warn`).
- **Early hook** = `aidc licenses` + an agent guardrail bullet + a *documented,
  opt-in* pre-commit snippet (git hooks are not auto-installed).

**How it works:** `scripts/ci/` holds standalone bash (`set -euo pipefail`,
bash-3.2-safe, shellcheck-clean) that sources only its own `lib-common.sh`,
never `lib/aidc.sh`, so it runs on a bare CI runner. Config is via env vars
(`AIDC_SBOM_DIR`, `AIDC_SBOM_SRC`, `AIDC_IMAGE_REF`, `AIDC_LICENSE_MODE`,
`AIDC_LICENSE_MATRIX`, …); exit codes are `0` ok / `1` policy violation in fail
mode / `2` tool-missing. `syft` generates both formats from a single catalog in
one invocation so the CycloneDX and SPDX outputs stay consistent. `sbom-diff.sh`
keys CycloneDX components by `group/name` (version-independent) so a version
bump reads as a change, not add+remove. `license-check.sh` resolves the
project's own license (`AIDC_PROJECT_LICENSE` override → manifest `license`
field → `LICENSE` text heuristics), extracts the dependency license inventory
from the SPDX SBOM, splits dual-license expressions into atoms, and flags any
that match a matrix row for the project license (or a `*` wildcard row).

**What changed:**
- `scripts/ci/`: `lib-common.sh`, `sbom-code.sh`, `sbom-image.sh`,
  `sbom-diff.sh`, `license-check.sh`, `sbom-all.sh`, `license-matrix.tsv`.
- `.devcontainer/Dockerfile` + `templates/devcontainer/Dockerfile.tmpl`: `syft`
  + `grype` promoted to a pinned always-on layer (`SYFT_VERSION`/`GRYPE_VERSION`);
  the opt-in `AIDC_SECURITY_TOOLS` arms for both became no-ops (back-compat).
  NOTE: `.devcontainer/` is bind-mounted read-only inside the aidc container, so
  the Dockerfile edit could not be written from within this session — the
  identical change is provided as `sbom-dockerfile.patch` at the repo root to
  `git apply` on the host (then delete the patch). The template carries the
  change directly.
- `lib/aidc.sh`: `sbom` / `licenses` dispatch + `aidc::cmd_sbom` /
  `aidc::cmd_licenses` (with `aidc::append_sbom_env_args` forwarding the SBOM env
  knobs into the container exec); help text; `AIDC_MANAGED_PATHS` gains the six
  `scripts/ci/` scripts; `aidc::refresh_scaffold` copies `templates/ci/` into
  `<project>/scripts/ci/` (scripts managed/refreshed, `license-matrix.tsv` and
  the reference workflow copied once / user-owned).
- `templates/ci/`: `.tmpl` mirrors of the scripts + matrix + `github-sbom.yml.tmpl`.
- `.github/workflows/sbom.yml`: reference CI caller on aidc's own tree.
- `.github/workflows/shellcheck.yml`: runs the three new unit tests (the `*.sh`
  glob already lints `scripts/ci/`).
- `tests/`: `license-resolve.test.sh`, `license-check.test.sh`,
  `sbom-diff.test.sh` (offline; SPDX/CycloneDX fixtures under
  `tests/fixtures/`, no syft/network needed).
- Docs/guardrails: new "SBOM & license compliance" section in `docs/security.md`
  (+ always-on/opt-in updates); an "SBOM & licenses" bullet in the security
  guardrails of `CLAUDE.md`/`AGENTS.md` and their templates.

**Commands / verification:**
```bash
shellcheck --severity=warning scripts/ci/*.sh lib/aidc.sh tests/*.test.sh
bash tests/license-resolve.test.sh   # 6 passed
bash tests/license-check.test.sh     # 5 passed
bash tests/sbom-diff.test.sh         # 3 passed
# In a built container: aidc sbom / aidc licenses --fail
```

**Notes / trade-offs:** The license check is intentionally conservative — a dual
`(MIT OR GPL-2.0-only)` dependency is flagged even though a consumer could pick
MIT, because the goal is to *surface* concerns early; review those by hand. The
matrix is user-owned and ships a conservative default (permissive projects vs.
strong copyleft; AGPL flagged everywhere) and is explicitly not legal advice.
`vet` license enrichment is opt-in because it needs network for Insights data.

---

## 2026-06-26 — Resolve Claude OAuth token from the macOS Keychain on demand

**Summary:** `aidc claude` now fetches `CLAUDE_CODE_OAUTH_TOKEN` from the macOS
Keychain at exec time when it isn't already exported, removing the need for the
`~/.zshrc` line that broadcast the token to every shell process.

**Why:** The documented setup put

```bash
export CLAUDE_CODE_OAUTH_TOKEN="$(security find-generic-password -a "$USER" -s claude-code-oauth-token -w 2>/dev/null)"
```

in `~/.zshrc`. That works, but it exports the plaintext token into the
environment of *every* process the shell spawns, for the whole session — far
wider exposure than needed. The token only has to exist for the brief
`docker compose exec` that launches Claude inside the container. Moving the
Keychain read into `aidc` shrinks the token's lifetime to that single call and
keeps it out of unrelated processes' environments.

**How it works:** `aidc::run_tool` calls a new `aidc::resolve_claude_oauth_token`
on the `claude` path, before the existing env passthrough
(`aidc::append_passthrough_env_args`) and the `aidc-bootstrap-claude` one-time
login step — both of which already read `CLAUDE_CODE_OAUTH_TOKEN` from `aidc`'s
own process env, so populating it there is all that's needed. Resolution order:

1. `CLAUDE_CODE_OAUTH_TOKEN` already set → used as-is (back-compat with the old
   `~/.zshrc` export and with CI secrets).
2. Else `security find-generic-password -a "$USER" -s "$service" -w` →
   exported into `aidc`'s env only.
3. Else unchanged (interactive login / profile auth).

It is a deliberate no-op when: the var is already set; `CLAUDE_CODE_OAUTH_TOKEN`
has been removed from `AIDC_PASSTHROUGH_ENV_KEYS` (per-project opt-out); the
service name `AIDC_CLAUDE_OAUTH_KEYCHAIN_SERVICE` is empty; or `security` is not
on `PATH` (non-macOS hosts). The token value is never logged.

**What changed:**
- `lib/aidc.sh`:
  - New `AIDC_CLAUDE_OAUTH_KEYCHAIN_SERVICE` default (`claude-code-oauth-token`),
    overridable/disable-able via `~/.config/aidc/config.env`.
  - New `aidc::resolve_claude_oauth_token` (account falls back to `id -un` when
    `$USER` is unset, so it is safe under `set -u`).
  - Wired into `aidc::run_tool` ahead of the passthrough/bootstrap, gated to the
    `claude` tool so codex/opencode/grok containers don't receive an unused
    credential.
  - Seeded a commented `AIDC_CLAUDE_OAUTH_KEYCHAIN_SERVICE` entry in the
    generated global config (`aidc::ensure_global_config`).
- `tests/resolve-oauth-token.test.sh`: new self-contained test that stubs
  `security` on `PATH` and covers all seven branches (preset wins; resolve +
  no-leak; empty result; failed lookup; disabled service; passthrough opt-out;
  missing `security`).
- Docs: a new **Claude authentication** section in `README.md` documents the
  recommended flow (`claude setup-token` → store under the `claude-code-oauth-token`
  Keychain item → aidc reads it at runtime), with an explicit warning against
  using the short-lived `accessToken` from Claude Code's own
  `Claude Code-credentials` Keychain item. `docs/claude-profiles.md` Option A
  rewritten (the `~/.zshrc` export is now optional); `docs/security.md` documents
  the on-demand lookup and the per-container passthrough override.

**Commands / verification:**
```bash
bash tests/resolve-oauth-token.test.sh   # 7 passed, 0 failed
shellcheck lib/aidc.sh tests/resolve-oauth-token.test.sh
semgrep scan --config auto lib/aidc.sh tests/
gitleaks detect --no-banner
```

End-to-end on a Mac (token in Keychain, `CLAUDE_CODE_OAUTH_TOKEN` unset):
`aidc claude` authenticates with no interactive login, `aidc exec -- printenv
CLAUDE_CODE_OAUTH_TOKEN` shows the token reached the container, and `printenv
CLAUDE_CODE_OAUTH_TOKEN` in the parent shell stays empty.

**Notes:** macOS-only by design (matches the project's documented "host-side bits
assume Mac" stance); other hosts fall through to the existing env/profile/login
paths unchanged. A future resolver hook could generalise this to 1Password /
`pass` / Vault, but that was intentionally out of scope here.

Decision — raw setup-token, not the subscription `accessToken`. Claude Code on
macOS keeps its own Keychain item (`Claude Code-credentials`) holding a JSON blob
with `claudeAiOauth.accessToken` + `refreshToken`. That `accessToken` is
short-lived (hours) and only refreshed when Claude Code runs on the host, so it
goes stale for container-only use. Rather than parse/extract it (and depend on
host refresh), aidc reads the long-lived token from `claude setup-token`, stored
as a raw value under `claude-code-oauth-token`. The resolver therefore stays a
plain raw-string read — no JSON parsing, no `refreshToken` persisted into a
volume.

---

## 2026-06-25 — rtk-only VM hooks; drop gryph/cot from the container

**Summary:** The container's Claude Code `settings.json` now carries only the
rtk token-saving hook. The host-seed hooks for host-only tooling (`gryph`,
`cot`) are stripped at sync time, `gryph` is no longer installed in the image or
hooked at bootstrap, and rtk is wired non-interactively by the bootstrap itself.

**Why:** The host's `~/.claude/settings.json` is the seed for the container's
`settings.json` (copied by `sync_claude`), so it dragged in two classes of hooks
that don't belong in the VM:

- `gryph _hook claude-code <Event>` — the agent audit layer. Redundant in the VM
  now that in-container session transcripts auto-sync to the host on container
  start and exit, so observability already happens on the host.
- `/Users/ion1/.cot/bin/cot hook claude` — a hard-coded macOS binary path that can
  never resolve inside the container, so it errored on every `UserPromptSubmit` /
  `Stop` / `SubagentStop` / `PreCompact` fire.

`gryph install` in `install_agent_hooks` re-added the gryph hooks even if the
copy were cleaned, so both the seed-copy path and the install path had to change.

**What changed:**
- `templates/devcontainer/scripts/bootstrap-state.sh.tmpl` (source of truth; the
  generated `.devcontainer/scripts/bootstrap-state.sh` is byte-identical and is
  regenerated from this on `aidc rebuild`):
  - New `strip_host_hooks()` — surgical, idempotent Python that removes only hook
    commands matching `\bgryph\b|\bcot\b` from a Claude Code `settings.json`,
    preserves rtk and any user hooks, prunes emptied hook arrays and emptied
    event keys, and is a no-op (no rewrite) when nothing matches.
  - `sync_claude()` calls `strip_host_hooks` after seeding `settings.json`, so it
    runs on every init (self-heals volumes seeded by an older bootstrap, not just
    fresh copies).
  - `install_agent_hooks()` no longer runs `gryph install`; it wires only
    `rtk init --global --auto-patch --hook-only` (non-interactive; adds just the
    `PreToolUse`/`Bash` hook, no `RTK.md`/`CLAUDE.md` rewrite since both are
    already seeded from the host).
  - Added an exec-guard (`[[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]`, nounset-safe)
    around the bottom init/sync dispatch so the helper functions are importable by
    unit tests without triggering side effects.
- `templates/devcontainer/Dockerfile.tmpl`: removed the `gryph` install `RUN`
  (curl | sh) and its comment. The new image no longer ships the gryph binary.
- `.github/scripts/test-bootstrap-state.sh` (new): 9 unit tests for
  `strip_host_hooks` — mixed PreToolUse keeps rtk/drops gryph, cot/gryph-only
  events pruned, user hooks preserved, idempotent, no-op when clean, malformed
  JSON and missing file don't crash.
- `.github/workflows/shellcheck.yml`: runs the unit tests in CI (ubuntu-latest
  ships `python3` + `jq`).
- Docs: `docs/security.md` "Agent guardrails" rewritten rtk-only with the
  host-side-observability rationale; `README.md`, `docs/install.md`, `SECURITY.md`
  de-listed `gryph`.

**Commands:**
- `bash .github/scripts/test-bootstrap-state.sh` → `passed=9 failed=0`.
- `shellcheck --severity=warning .github/scripts/test-bootstrap-state.sh` and
  `shellcheck -x templates/devcontainer/scripts/bootstrap-state.sh.tmpl` → clean.
- `rtk init --global --auto-patch --hook-only` (verified on a throwaway HOME)
  produces exactly `{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"rtk hook claude"}]}]}}` and no `RTK.md`.

**Verification:**
- Stripped the live container's `~/.claude/settings.json` in place (backup at
  `settings.json.bak-pre-rtk-only-20260625T212157Z`): result is rtk-only, valid
  JSON, 0 `gryph`/`cot` matches.
- Created `~/.claude/.aidc-agent-hooks-installed` so this running container's
  stale (read-only) bootstrap won't re-run `gryph install` on restart; confirmed
  `rtk --version` and `rtk gain` still work (165 cmds, ~65% saved).
- Scanners: shellcheck clean, `semgrep --config auto --error` exit 0,
  `gitleaks detect` no leaks, `trufflehog filesystem` 0 secrets. No dependency
  added (gryph removed), so `vet` SCA scan is N/A.

**Notes:**
- `.devcontainer/` is read-only inside the container and git-ignored on the host
  (`.git/info/exclude`); only the template is edited here. `aidc rebuild`
  regenerates `.devcontainer/*` from the template and rebuilds the image without
  gryph. A fresh `claude_home` volume (after `aidc destroy`) gets the clean
  rtk-only state from the new bootstrap.
- For the currently-running container, the in-place strip + marker makes it
  stable until the next rebuild; no restart re-adds gryph.



**Summary:** Added automatic session-sync, a new `aidc rescan` command, shell-script
detection that installs `shellcheck`, and per-project documentation scaffolding
(`CHANGELOG.md` / `DETAILED_CHANGELOG.md` / `logs/`), driven by six points of
real-world usage feedback.

**Why:** Daily use surfaced friction: session-sync was easy to forget; shell scripts
had no in-container linter; projects that start empty never picked up language
security tools because detection only ran at first build; and scaffolded projects
lacked enforced test-coverage and documentation discipline.

**What changed:**
- `lib/aidc.sh`:
  - `aidc::auto_sync_sessions` helper (gated on `AIDC_AUTO_SYNC_SESSIONS`, default on),
    wired into `run_tool` (exit code preserved), `cmd_down`, `cmd_destroy`
    (before `down -v`), and the container-start transition (`cmd_up`, `cmd_rebuild`,
    and the lazy-start branch of `ensure_container_running`) as the recovery path for
    ungraceful exits the on-exit hooks can't cover.
  - `aidc::has_shell_scripts` + a `shell` entry in `detect_toolchains`.
  - `aidc::cmd_rescan` + `rescan` dispatch case + help text.
  - `AIDC_AUTO_SYNC_SESSIONS` documented in `write_project_env`; three
    `copy_template_once` seed calls in `refresh_scaffold`.
  - Host-wide config: `AIDC_GLOBAL_CONFIG` (`~/.config/aidc/config.env`),
    `aidc::load_global_config` sourced first in `load_project_env` (so per-folder
    `project.env` overrides it), and `aidc::ensure_global_config` seeds a commented
    template via `ensure_host_config_dirs`. Verified precedence:
    project.env > config.env > built-in default.
- `templates/devcontainer/Dockerfile.tmpl`: `shell)` arm installs `shellcheck`.
- `templates/CLAUDE.md.tmpl` + `templates/AGENTS.md.tmpl`: shellcheck guardrail line;
  Testing & coverage, Documentation & changelog, Documentation requirements, and
  Session log convention sections (inside the aidc-managed markers).
- New seed templates: `templates/CHANGELOG.md.tmpl`,
  `templates/DETAILED_CHANGELOG.md.tmpl`, `templates/logs/README.md.tmpl`.
- `README.md` and `CHANGELOG.md` updated; this repo dogfoods the new doc files.
- `.github/workflows/aidc-e2e.yml`: assert the new seed files appear after `aidc init`.

**How / commands run:** see `logs/2026-06-25-aidc-usability-hardening.md`.

**Verification:** `shellcheck bin/aidc lib/aidc.sh`; bash-compat check; `aidc init`
scaffold assertions; `semgrep` / `gitleaks` / `trufflehog` on changed files.

**Notes / follow-ups:** `.devcontainer/`, `CLAUDE.md`, and `AGENTS.md` are generated
artifacts in this repo (listed in `.git/info/exclude`), so only the templates were
edited — the generated copies refresh from them on the next `aidc up`.
