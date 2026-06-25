# Changelog

All notable changes to aidc are tracked here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project does not yet cut tagged releases, so all entries live under **Unreleased** until the first tag.

## [Unreleased]

### Added

- **Automatic session sync.** In-container agent transcripts now sync to the host on container start (down→up transition), agent exit, `aidc down`, and `aidc destroy` (synced before `-v` removes the volumes), so `/insights` stays current without a manual `aidc sync-sessions`. The start sync is the recovery path for ungraceful exits (crash / `docker kill`) the on-exit hooks can't cover. Toggle with `AIDC_AUTO_SYNC_SESSIONS` host-wide in `~/.config/aidc/config.env` or per project in `.ai-container/project.env` (per-folder overrides global). The agent's exit code is preserved across the post-run sync.
- **Host-wide config file.** New `~/.config/aidc/config.env` holds universal aidc defaults for every project; `.ai-container/project.env` is sourced after it and overrides per folder. Seeded (fully commented) on first run.
- **`aidc rescan` command.** Re-detects project languages and rebuilds so a repo that started empty (or single-language) picks up the matching toolchains and security scanners once code lands. Prints detected vs. effective (overridden) toolchains before building.
- **`shell` toolchain → shellcheck.** `aidc::detect_toolchains` now detects shell scripts (any `*.sh` file, or an extensionless executable with a shell shebang such as `bin/aidc`) and installs `shellcheck` via a new `shell)` arm in the Dockerfile toolchain block.
- **Project documentation seeds.** `aidc init` now seeds `CHANGELOG.md`, `DETAILED_CHANGELOG.md`, and `logs/README.md` into each project once (never overwritten, and intentionally not git-excluded so they are committed). The scaffolded `CLAUDE.md`/`AGENTS.md` guidance gains **Testing & coverage**, **Documentation & changelog**, **Documentation requirements**, and **Session log convention** sections, plus a `shellcheck` line in the security guardrails.
- **Grok Build agent.** `aidc grok` launches xAI's Grok Build CLI inside the container, with a `grok_home` named volume (`~/.grok`), a read-only `/host-seed/grok` seed mount, `sync_grok` seeding in `bootstrap-state.sh`, and `aidc sync-config`/`sync-sessions` support. Grok reads the same generated `AGENTS.md`.
- **GPL-3.0 license.** `LICENSE` at repo root.
- **Vulnerability disclosure policy.** `SECURITY.md` documents scope, reporting channels, and timelines.
- **Shellcheck CI.** `.github/workflows/shellcheck.yml` lints `bin/aidc`, `install.sh`, `lib/aidc.sh`, and `templates/**/*.sh`, plus syntax-checks the Python clipboard server.
- **Split docs.** `HOW_TO_USE.md` broken into `docs/install.md`, `docs/claude-profiles.md`, `docs/security.md`, and `docs/clipboard-bridge.md` for easier linking and discoverability. README rewritten as a true landing page with quick-start, status, and prereqs upfront.
- **Security guardrails — always-on scanners.** `semgrep` (SAST), `gitleaks` and `trufflehog` (secrets) are now baked into every aidc image.
- **Per-toolchain security linters.** When aidc detects a language toolchain, it now also installs the standard linter for that language: `gosec` (Go), `bandit` (Python), `cargo-audit` (Rust), `bundler-audit` (Ruby). Node uses the built-in `npm audit`; Java and PHP rely on semgrep.
- **`AIDC_SECURITY_TOOLS` build arg.** Opt-in heavier tooling per project via `.ai-container/project.env`. Supported: `grype`, `syft`, `checkov`, `bandit`. Mirrors the `AIDC_TOOLCHAINS` pattern; unknown values warn and skip.
- **Agent-enforced guardrails.** `AGENTS.md.tmpl` and `CLAUDE.md.tmpl` now ship a "Security guardrails (non-negotiable)" block inside the aidc-managed marker. Instructs agents to run the relevant scanners on every code change and fix findings above LOW before declaring work complete. User content outside the markers is preserved on scaffold refresh.
- **`aidc status` command.** Per-folder view: container state (running/stopped/not-created) with disk, CPU, memory, PIDs, uptime, plus a config & mounts section listing bind sources (with empty-placeholder annotation) and named volumes.
- **`aidc status --global` command.** Fleet view: every aidc container on the host with workspace path, disk, CPU, memory, PIDs, started/exited timestamp, and a totals line. Filters by `^aidc_` compose project label so non-aidc containers are excluded. Batches `docker container ls --size` and `docker stats --no-stream` for one fork per call instead of N.
- **Local-model Claude profiles.** `localhost.env.example` (targets `host.docker.internal:PORT` for a server on this Mac) and `localnetwork.env.example` (Tailscale MagicDNS / `100.x.y.z` peer; copy to `localnetwork-<engine>.env` for multiple peers).
- **Firewall: Tailscale CGNAT egress.** `init-firewall.sh` and template now permit all-port egress to `100.64.0.0/10`, so tailnet peers stay reachable when `AIDC_ENABLE_EGRESS_FIREWALL=1`.
- **Firewall: `semgrep.dev` in default allowlist.** Needed for `semgrep scan --config auto` rule fetch when the firewall is on.

### Changed

- **Coding agents now install as native prebuilt binaries.** `claude`, `codex`, and `opencode` switched from a root `npm install -g` to each vendor's native `curl | sh` installer (into `~/.local/bin`), dropping the Node runtime dependency for the agents and shrinking the npm supply-chain surface. Removes the only build step that ran package-manager installs *before* `pmg setup install`.
- **pmg wired in before any user-level install.** `pmg setup install` is now the first `USER vscode` build step. Interception is documented as riding on the `~/.pmg/bin` PATH shims (first on `ENV PATH`) rather than the rc-file aliases pmg also writes — build `RUN` steps and exec'd agents never source rc files. `docs/security.md` now describes the shared-credentials seed-mount/env-passthrough matrix.
- **Pinned `gitleaks` and `vet` versions** in `templates/devcontainer/Dockerfile.tmpl` (`v8.30.1` and `v1.17.3` respectively). Defaults were `latest`, which resolved at build time and defeated the surrounding base-image SHA pin. Repin instructions are in the Dockerfile.
- **README** and the docs/ tree brought into sync with the above. README's command list includes `aidc status`, `aidc down`, `aidc destroy`, `aidc exec`, and `aidc sync-sessions`. `docs/security.md` covers the scanners, supply-chain guardrails, and egress firewall; `docs/claude-profiles.md` covers the local-model profiles (`localhost.env.example`, `localnetwork.env.example`).

- **VM Claude hooks are now rtk-only.** The host-seed `settings.json` carries hooks for host-only tools (`gryph`, and `cot` on a hard-coded macOS path) that are pointless or broken inside the container. `bootstrap-state.sh` now strips just those entries on every `sync_claude` (preserving rtk and any user hooks; self-heals volumes seeded by an older bootstrap), and `install_agent_hooks` wires only `rtk init --global --auto-patch --hook-only` (non-interactive; installs just the hook without re-writing `CLAUDE.md`/`RTK.md`). In-container session transcripts already auto-sync to the host on start/exit, so agent observability stays host-side.

### Fixed

- **RTK install path.** Dockerfile previously set `RTK_INSTALL_DIR=/usr/local/bin` on the wrong side of the pipe (`VAR=val cmd1 | cmd2` scopes `VAR` to `cmd1`), so the installer fell back to `$HOME/.local/bin` while running as root — the binary landed in `/root/.local/bin/rtk` and was invisible to the `vscode` user. Env var moved onto the `sh` side of the pipe.

### Removed

- **AWS Bedrock and Google Vertex support.** `/host-auth/aws` and `/host-auth/gcloud` bind mounts dropped. `AIDC_AWS_SOURCE`, `AIDC_GCLOUD_SOURCE`, `bedrock.env.example`, and `vertex.env.example` removed. AWS- and Google-specific keys (`AWS_PROFILE`, `AWS_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_DEFAULT_REGION`, `ANTHROPIC_VERTEX_PROJECT_ID`, `CLOUD_ML_REGION`, `GOOGLE_APPLICATION_CREDENTIALS`, `GOOGLE_CLOUD_PROJECT`) dropped from `AIDC_PASSTHROUGH_ENV_KEYS`.

- **gryph removed from the image.** SafeDep's `gryph` agent-audit layer is no longer installed (Dockerfile) or hooked (`gryph install` dropped from `bootstrap-state.sh`); host-side hooks for it are stripped from the seeded `settings.json`. `cot` was never in the image (its hook command pointed at a macOS-only binary path) and is likewise stripped. Agent observability is host-side now that sessions auto-sync on container start and exit.

[Unreleased]: https://github.com/cyfinoid/aidc/commits/main
