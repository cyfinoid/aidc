# Changelog

All notable changes to aidc are tracked here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project does not yet cut tagged releases, so all entries live under **Unreleased** until the first tag.

## [Unreleased]

### Added

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

- **Pinned `gitleaks` and `vet` versions** in `templates/devcontainer/Dockerfile.tmpl` (`v8.30.1` and `v1.17.3` respectively). Defaults were `latest`, which resolved at build time and defeated the surrounding base-image SHA pin. Repin instructions are in the Dockerfile.
- **README** and the docs/ tree brought into sync with the above. README's command list includes `aidc status`, `aidc down`, `aidc destroy`, `aidc exec`, and `aidc sync-sessions`. `docs/security.md` covers the scanners, supply-chain guardrails, and egress firewall; `docs/claude-profiles.md` covers the local-model profiles (`localhost.env.example`, `localnetwork.env.example`).

### Fixed

- **RTK install path.** Dockerfile previously set `RTK_INSTALL_DIR=/usr/local/bin` on the wrong side of the pipe (`VAR=val cmd1 | cmd2` scopes `VAR` to `cmd1`), so the installer fell back to `$HOME/.local/bin` while running as root — the binary landed in `/root/.local/bin/rtk` and was invisible to the `vscode` user. Env var moved onto the `sh` side of the pipe.

### Removed

- **AWS Bedrock and Google Vertex support.** `/host-auth/aws` and `/host-auth/gcloud` bind mounts dropped. `AIDC_AWS_SOURCE`, `AIDC_GCLOUD_SOURCE`, `bedrock.env.example`, and `vertex.env.example` removed. AWS- and Google-specific keys (`AWS_PROFILE`, `AWS_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_DEFAULT_REGION`, `ANTHROPIC_VERTEX_PROJECT_ID`, `CLOUD_ML_REGION`, `GOOGLE_APPLICATION_CREDENTIALS`, `GOOGLE_CLOUD_PROJECT`) dropped from `AIDC_PASSTHROUGH_ENV_KEYS`.

[Unreleased]: https://github.com/cyfinoid/aidc/commits/main
