# Detailed Changelog

The long-form companion to `CHANGELOG.md`. Where `CHANGELOG.md` says *what*
changed in one line, this file records *why* and *how* — enough for a future
reader to audit, reproduce, or roll back any change without re-deriving it.

Add a new entry (newest first) for every meaningful change.

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
