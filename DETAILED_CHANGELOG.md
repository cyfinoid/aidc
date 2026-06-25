# Detailed Changelog

The long-form companion to `CHANGELOG.md`. Where `CHANGELOG.md` says *what*
changed in one line, this file records *why* and *how* — enough for a future
reader to audit, reproduce, or roll back any change without re-deriving it.

Add a new entry (newest first) for every meaningful change.

---

## 2026-06-25 — Usability hardening: auto-sync, rescan, shell toolchain, doc scaffolding

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
