# `aidc ci` — run the project's GitHub workflows locally (opt-in)

When aidc wraps a project that has GitHub Actions workflows, `aidc ci`
replays the push/PR-triggered ones **natively inside the project
container**, with no GitHub round-trip, no Docker emulation, and no
modification to the workflow files — project CI exercised before you push:

```bash
aidc ci                                # from the host, against the current project
aidc ci --list                         # show the plan, run nothing
aidc ci --workflow 'tests*'            # filter by workflow file basename
aidc ci --workflow 'tests*' --job lint # filter to one job
aidc ci --all                          # adds tag/schedule-only workflows
```

The same engine is on the container PATH as `aidc-ci` (a symlink
`bootstrap-state.sh` maintains at `~/.local/bin/aidc-ci`), so an
in-container shell — or any agent working in the container — can run it
directly:

```bash
aidc-ci --workflow 'tests*' --isolate-home
```

**This feature is opt-in, not enabled by default.** The engine ships as a
scaffolded script (`.devcontainer/scripts/aidc-ci.sh`, copied in by
`aidc init`/`aidc upgrade`); it is inert until a human (or an agent told
to) invokes it. Nothing runs it automatically: no hook, no workflow, no
bootstrap or session-lifecycle step calls it. The PATH symlink bootstrap
installs is a pointer, not an invocation.

## Why native replay (and not act)

The devcontainer has no Docker socket, so `act`-style emulation (which
runs jobs in containers) is impossible in-container. Most project CI is
`run:`-heavy — validation lives in scripts the workflow calls — so
replaying the `run:` steps natively covers nearly everything. Steps or
jobs that genuinely need Docker, the `gh` CLI, or GitHub-only actions are
**SKIPped loudly** (listed with the reason, and the run still exits 0)
instead of being silently mis-run.

Docker need is detected by **usage**, not the bare word: `docker
<subcommand>` invocations and the `docker:<image>` source scheme (grype/
syft resolve it via the daemon) gate the step — while steps that merely
mention docker in a comment or guard (`command -v docker …`) run, so their
own self-degradation logic fires exactly as it would on a real macOS
runner. The same check follows `.github/scripts/*.sh` references one
level: a script that uses docker *unguarded* gates the step invoking it,
while a self-degrading script still runs. References beyond that scope
(`scripts/**`, vendor code) are deliberately **not** followed — a step
that uses docker through them runs and fails honestly, which is a correct
failure, not a mis-skip.

## Where the project comes from

The engine runs *inside* the project container, where the project is
`/workspace` — but it is resolution-order driven, not hardcoded, so it
works from any mount/working dir (and on the host against a checkout):

1. `$AIDC_CI_PROJECT` if set (must exist, else exit 2),
2. else the `git` toplevel of the current directory,
3. else `/workspace` if it is a directory,
4. else a usage error telling you to set `AIDC_CI_PROJECT` or cd into the
   project.

`GITHUB_WORKSPACE`, `GITHUB_SHA`, `GITHUB_REF`, and `GITHUB_REPOSITORY`
(default `local/<basename>`, overridden by the project's `origin` remote)
are derived from the resolved project via `git`.

## Dependencies

- bash ≥ 4 (the engine uses associative arrays; it merely *parses* under
  bash 3.2, which keeps `validate-scaffold.sh`'s `bash -n` happy on macOS
  hosts), `jq`, `git`
- python3 with PyYAML, resolved at runtime via:
  `$AIDC_CI_PYTHON` (exclusive — when set, only that interpreter is tried) →
  `python3` if it can `import yaml` → `uv run --with pyyaml` →
  `pmg uv run --with pyyaml`. All failing → exit 2 with per-platform
  remediation (in the devcontainer the `pmg uv` leg satisfies it).

Both `AIDC_CI_PROJECT` and `AIDC_CI_PYTHON` are forwarded by the
`aidc ci` host wrapper only when set (the `AIDC_CI_ENV_KEYS` passthrough
set).

## Flags

| flag | meaning |
|---|---|
| `--list` | print the execution plan (workflows → jobs → legs → steps), run nothing |
| `--workflow <glob>` | filter by workflow file basename (`'tests*'`) |
| `--job <id>` | filter to one job id |
| `--all` | include tag/schedule-only workflows |
| `--event <name>` | simulate this event for `github.event_name` comparisons (default `push`) |
| `--strict` | treat SKIPs as failures (exit 1) |
| `--capability n=on\|off` | override the docker/gh probe (repeatable) — used by the self-test for hermeticity |
| `--env K=V` | extra env for every step; wins over workflow/job/step env (repeatable) |
| `--isolate-home` | run steps under a throwaway HOME — recommended for workflows whose steps install things |
| `--workflows-dir <dir>` | parse workflows from another dir (used by the self-test) |
| `--artifacts-dir <dir>` | where `upload-artifact` copies land (default `<work-dir>/artifacts`) |
| `--work-dir <dir>` | scratch dir (default: `mktemp -d`, auto-removed; an explicit dir is never auto-removed) |
| `--keep` | keep the auto-created scratch dir (path printed) |

Exit codes: `0` = only passes/skips · `1` = any real step failure (any skip
too, under `--strict`) · `2` = usage / dependency / YAML error (naming the
file). `aidc ci` propagates the engine's exit code.

## Environment fidelity

Per step the engine builds the environment the way a GitHub runner would:
GITHUB stubs (`CI`, `GITHUB_ACTIONS`, `GITHUB_WORKSPACE`, `RUNNER_TEMP`,
`GITHUB_ENV`, `GITHUB_PATH`, `GITHUB_REF`, `GITHUB_REF_NAME`,
`GITHUB_SHA`, `GITHUB_EVENT_NAME`, `GITHUB_REPOSITORY`,
`GITHUB_HEAD_REF`/`GITHUB_BASE_REF` empty — push semantics — and
`GITHUB_ACTOR`, default `local`), then workflow `env:`, job `env:`, values
accumulated from `GITHUB_ENV`/`GITHUB_PATH` earlier in the job, step
`env:`, and finally `--env` overrides. Steps execute with
`bash --noprofile --norc -eo pipefail` in the project workspace (or the
step's `working-directory:`), output tee'd into per-step logs under the
work dir. Matrix strategies expand to per-leg runs.

`${{ }}` expression support (each in the 4 spacing variants GitHub
accepts):

- `matrix.*` per leg
- `runner.os` (→ `Linux`), `runner.temp`
- `github.event_name`, `github.ref`, `github.ref_name`, `github.sha`,
  `github.repository`, `github.actor`; `github.head_ref`/`base_ref`
  expand to empty strings (push semantics)
- `env.*` — resolved in a **second pass after the merged env is known**,
  so `${{ env.NAME }}` in a step body, `if:` condition, `working-directory:`,
  or `with:` picks up values set by earlier steps through `GITHUB_ENV`.
  A surviving `${{ env.K }}` whose key is not in the merged env SKIPs the
  step loudly.

Anything else (`secrets.*`, `${{ github.token }}`, `hashFiles(...)`)
never expands: the step SKIPs loudly rather than running with a literal
`${{ … }}` string. Step bodies containing `${{ needs.* }}` SKIP with the
reason `needs.* outputs unavailable locally (declaration order, no DAG)`.

`if:` supports the subset most repos use: `always()`, `runner.os == …`,
`github.event_name == …`; anything else SKIPs. `continue-on-error` is
honored; a failing step aborts the job's later steps while `if: always()`
steps still run.

`uses:` dispatch knows: `actions/checkout` (no-op — the project is already
the workspace), `actions/upload-artifact` (copies `with.path` into the
artifacts dir), `actions/download-artifact` (copies
`<artifacts-dir>/<name>` into `with.path`, default the workspace — a
missing artifact SKIPs loudly, telling you to run the uploading workflow
first), cache/buildx/scorecard/codeql (SKIP). Unknown actions SKIP with
their name.

## Deliberate divergences from a real runner

Know them before you trust a green run:

- **Steps run in the project worktree and inherit the caller's
  environment.** Workflows that write files leave them in the tree —
  commit or stash first, and clean up after. On GitHub these land on an
  ephemeral runner.
- **Stricter shell**: `-e -o pipefail` is applied to every step (GitHub's
  default bash is `-e` only).
- **HOME is yours by default** — use `--isolate-home` for workflows that
  install things.
- `needs:` runs in declaration order (no DAG), noted per job.
- Artifacts live on the local filesystem, not in GitHub's artifact store
  — upload then download within the same `--artifacts-dir` round-trips.

## Limitations (all fail loud, never silent)

- Only the `${{ }}` expressions listed above expand; anything else → SKIP.
- Only the `if:` subset above evaluates; anything else → SKIP.
- Matrix `include:`/`exclude:` and non-list axes → the whole job SKIPs as
  unsupported.

## Dogfooding on the aidc repo itself

The aidc repo is its own reference customer. Verified outcomes running
the engine against this repo's workflows (docker/gh absent, Linux):

| workflow | local outcome |
|---|---|
| `shellcheck` | **fully native** — apt shellcheck install, repo lint, `py_compile`, and every `tests/*.test.sh` batch runs for real (22/22 steps pass, including the aidc-ci self-tests) |
| `bash-compat` | all matrix legs SKIP — the check executes `docker run bash:<version>` containers |
| `aidc-e2e` | ubuntu leg runs: install.sh, docker-free smoke, alias lifecycle, toolchain detection, init/upgrade steps (which self-degrade without a docker CLI, exactly as on the macOS CI leg); buildx/compose/destroy steps SKIP; the macOS leg and the `runner.os == 'macOS'` pin step SKIP (condition false) |
| `image-size` | the scaffold step runs (it writes `work/` **into your worktree** — see divergences); build / PR-comment / budget steps SKIP (docker/gh) |
| `sbom` | job `sbom` fully native: pinned syft + grype install (same ARG pins as the image), SBOM generation + license gate, artifact copy into the artifacts dir; job `image-scan` runs checkout + the pinned grype install, then SKIPs build / image-pins / scan / upload (docker) |
| `scorecard` | every step SKIPs — GitHub-only actions (`ossf/scorecard-action`, SARIF upload targets the Security tab) |
| `release` | selected only with `--all` — its push trigger is tag-filtered (`v*`), so a branch-push replay excludes it |

Note: this repo's own `.devcontainer/scripts/` is a gitignored, read-only
(in-container) dogfood copy refreshed **host-side** by `aidc upgrade` —
after adding or changing the engine template, run `aidc upgrade` in the
repo checkout (or rebuild) before `aidc ci` will pick it up.

The self-test (`tests/local-ci.test.sh` + `tests/ci-cmd.test.sh`, wired
into the `shellcheck` CI workflow) pins the engine's behavior down with
fixture workflows under `tests/fixtures/local-ci/`, and the host
subcommand's exec/env/exit-code contract respectively.
