# Detailed Changelog

The long-form companion to `CHANGELOG.md`. Where `CHANGELOG.md` says *what*
changed in one line, this file records *why* and *how* — enough for a future
reader to audit, reproduce, or roll back any change without re-deriving it.

Add a new entry (newest first) for every meaningful change.

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
- Docs: `docs/claude-profiles.md` Option A rewritten (the `~/.zshrc` export is
  now optional); `docs/security.md` documents the on-demand lookup and the
  per-container passthrough override.

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
