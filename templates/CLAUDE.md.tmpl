<!-- aidc:core-logics:start -->
# Claude Project Guidance (aidc)

Before doing anything else, read `/opt/CORE_LOGICS/patternlist.md`.

Treat `/opt/CORE_LOGICS` as the shared reusable-guidance workspace for this repo's project branch. If you discover something that should be reusable outside this repo, add it there instead of leaving it only in local project notes.

Keep repo changes inside `/workspace` unless the task explicitly concerns `/opt/CORE_LOGICS`.

## Security guardrails (non-negotiable)

Before declaring any code task complete, run **`aidc-scan`** (on PATH inside
the container) and fix every finding above LOW. It scopes itself to your
changed files and picks the right scanners automatically — semgrep + secrets
always; shellcheck/bandit/gosec/cargo-audit/bundle-audit/npm-audit when the
matching files changed; dependency vetting (`vet`) and the SBOM/license gate
only when manifests or the LICENSE changed. `aidc-scan --all` scans the whole
repo; individual scanners remain available directly (see `docs/security.md`
in the aidc repo for the full matrix).

Non-negotiable regardless of change size: never dismiss findings as "out of
scope" or "pre-existing" without explicit user confirmation — fix or flag,
never silently skip. When findings exist, the work is not done: fix them,
re-run `aidc-scan`, and only then report the task as complete. If anything
looks like a live credential, also run `trufflehog filesystem --no-update .`.

A Stop hook enforces this mechanically for Claude Code: finishing while
`aidc-scan` reports findings is blocked with the findings attached. Do not
try to bypass the hook; fix the findings.

## Pre-completion review (non-negotiable for code changes)

Deterministic gates — tests, coverage, `aidc-scan` — cannot catch semantic
bugs: unreachable fallbacks, double-counted aggregations, code that
contradicts the change's own stated intent. Before declaring any code task
complete, review the full diff (`git diff <base>` plus untracked files)
against the checklist below, in two stages:

1. **Self-review** — re-read your own diff, checklist item by item.
2. **Fresh-eyes review** — hand a fresh subagent (the `Task` tool) only the
   diff, the task description, and the repo's guidance docs — never your
   implementation reasoning — and ask it to find checklist violations.
   Triage every finding: fix the real ones, refute the rest with specifics.

Checklist (distilled from real bugs AI PR reviewers caught after the fact):

- **Fallback-defeating error paths**: no early return or error branch makes
  a designed or documented fallback unreachable.
- **Aggregations over shared resources**: per-client/per-process counters
  are deduplicated by identity; a record with missing or unknown attribution
  is skipped, never counted against every candidate.
- **Intent traceability**: every normative statement written for this change
  (commit-message draft, PR body, README/docs sections touched) is checked
  against the diff.
- **Repo directives**: every explicit, checkable directive in the target
  repo's AGENTS.md / CONTRIBUTING (naming, docstrings, structure) is
  verified against the diff.
- **Test hermeticity**: new tests pass on any machine — no dependence on
  host-installed tools or hardware; tool lookup is injectable so
  absence-cases test cleanly.
- **Lookup tables**: device/capability/compatibility tables are verified
  against a source, not memory.

Then record the outcome:

    aidc-review-record "findings fixed; deferrals with reasons"

A Stop hook enforces the record mechanically for Claude Code: finishing with
unreviewed changes is blocked until `aidc-review-record` runs, and any edit
after the review invalidates the record — re-review and re-record. Fix every
real finding, or surface it to the user with your reasoning; do not try to
bypass the hook. Docs-only changes skip the gate.

## Testing & coverage

Every code change ships with tests. Aim for full coverage of the lines you add or change — cover the happy path, edge cases, and error handling, not just the obvious case. If a line is genuinely untestable, say why in the change.

Run the project's coverage tool and confirm the changed code is exercised before declaring work complete:

- **Go**: `go test -cover ./...`
- **Python**: `pytest --cov` (`coverage run -m pytest` + `coverage report`)
- **Rust**: `cargo llvm-cov` (or `cargo tarpaulin`)
- **Node**: `npm test -- --coverage` (`jest --coverage` / `vitest run --coverage`)
- **Ruby**: SimpleCov via `bundle exec rspec`

Coverage tools that aren't pre-installed can be added per project in `.devcontainer/project-setup.sh`.

## Documentation & changelog

Scale the paperwork to the change:

- **Trivial changes** (typo, comment, formatting — no logic, no dependencies,
  no security surface): no changelog or session-log entry required.
- **Everything else** updates **both** changelog files:
  - `CHANGELOG.md` — one high-level bullet under the right heading, in
    [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.
  - `DETAILED_CHANGELOG.md` — a dated long-form entry (what / why / how /
    commands / verification / notes), newest first.

When you do document, document properly: record the exact commands run, the
reasoning behind decisions, errors hit and how they were resolved — enough
for someone to audit, reproduce, or roll back the change without re-deriving
it.

## Session log convention

Working sessions that change behavior or configuration write a log to
`logs/YYYY-MM-DD-<slug>.md` (session date + short kebab-case slug). Read-only
or purely conversational sessions don't need one. Existing entries are the
template — match their structure: symptom → diagnosis → change (with diff) →
commands → verification → notes. See `logs/README.md`.
<!-- aidc:core-logics:end -->
