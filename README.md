# aidc

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Status: alpha](https://img.shields.io/badge/status-alpha-orange.svg)](#status)
[![macOS only](https://img.shields.io/badge/platform-macOS-lightgrey.svg)](#prereqs)

**aidc** — short for **AI Dev Container** — is a one-command devcontainer wrapper for AI coding agents (`claude`, `codex`, `opencode`, `cursor-agent`). It scaffolds a hardened Linux container per repo, mounts your code at `/workspace`, persists agent state in named Docker volumes (so agents don't read your `~/.ssh` or your shell history), and bakes in always-on security scanners and supply-chain guardrails.

If you're already running these agents directly on your Mac and have been quietly nervous about it, this is for you.

## Status

Pre-1.0, rolling-release, personal-ish. The author uses it daily; the API may still shift. Issues welcome; PRs at the maintainer's discretion. See [`SECURITY.md`](SECURITY.md) for vuln disclosure.

## Prereqs

- **macOS** (host-side bits assume Mac — Keychain, LaunchAgent, `pbpaste`, `~/.local/bin` aliases)
- **Docker** running (Docker Desktop / OrbStack / Colima)
- **git**

## Install

```bash
git clone https://github.com/cyfinoid/aidc.git
cd aidc
./install.sh
```

Make sure `~/.local/bin` is on your `PATH`.

## Quick start

```bash
cd /path/to/cloned/repo
aidc init          # one-time scaffold; writes .devcontainer/, .ai-container/, CLAUDE.md, AGENTS.md
aidc claude        # auto-runs `aidc up` if needed, then drops you into Claude Code in the container
```

Tool commands (`aidc claude` / `codex` / `opencode` / `cursor-agent`) auto-bootstrap the container on first run.

## What aidc actually does

- creates local-only `.devcontainer/`, `.ai-container/`, `CLAUDE.md`, `AGENTS.md`, and `.cursor/rules/00-core-logics.mdc`
- mounts project code only at `/workspace`; overlays `/workspace/.devcontainer` read-only inside the container
- persists tool state in per-repo Docker volumes instead of mounting whole host homes
- seeds selected config from host read-only mounts on first startup
- creates one `CORE_LOGICS` git worktree per repo and mounts it at `/opt/CORE_LOGICS` for shared cross-repo notes
- detects the project's language toolchains (Go, Rust, Ruby, Java, PHP, Node, Python) and installs them automatically
- bakes always-on security scanners (`semgrep`, `gitleaks`, `trufflehog`) plus per-toolchain linters (`gosec`, `bandit`, `cargo-audit`, `bundler-audit`) into the image
- seeds a non-negotiable "Security guardrails" block into `CLAUDE.md` / `AGENTS.md` for every project
- ships SafeDep's `pmg` / `vet` / `gryph` for supply-chain interception and `rtk` for token-saving CLI proxying
- offers an opt-in default-deny egress firewall with a sane allowlist

## Documentation

- [`docs/install.md`](docs/install.md) — prereqs, install, daily commands, what lives where, per-project customisation, cleanup
- [`docs/claude-profiles.md`](docs/claude-profiles.md) — alternate Claude API targets, local-model profiles, one-time OAuth login, session sync
- [`docs/security.md`](docs/security.md) — scanners, supply-chain guardrails, agent guardrails (gryph + rtk), opt-in egress firewall
- [`docs/clipboard-bridge.md`](docs/clipboard-bridge.md) — host-clipboard → container PNG paste bridge
- [`CHANGELOG.md`](CHANGELOG.md)
- [`SECURITY.md`](SECURITY.md) — how to report vulnerabilities in aidc itself

## Commands

```bash
aidc init [path]
aidc up
aidc down
aidc rebuild
aidc status [--global]
aidc destroy [-f] [--purge-worktree] [--purge-scaffold]
aidc shell
aidc exec -- <command>...
aidc claude [--profile NAME] [--provider NAME] [--list-profiles] [-- ...]
aidc codex [-- ...]
aidc opencode [-- ...]
aidc cursor-agent [-- ...]
aidc cursor
aidc sync-claude-aliases
aidc sync-config <claude|codex|opencode|all>
aidc sync-sessions [claude|codex|opencode|all]
```

`aidc status` shows the container + mounts/config for the current folder. `--global` lists every aidc container on the host with disk/CPU/memory and a totals line.

`--provider` remains as a compatibility alias for `--profile`.

## Notes

- Generated files are added to `.git/info/exclude` when the target directory is a git repo, so your project stays clean.
- Container egress is open by default; set `AIDC_ENABLE_EGRESS_FIREWALL=1` in `.ai-container/project.env` for a default-deny allowlist. See [`docs/security.md`](docs/security.md#optional-egress-firewall).
- Generated Claude alias wrappers are `aidc`-managed and live in `~/.local/bin` by default.

## 🤖 AI-Assisted Development
This project was developed with the assistance of AI tools, most notably Cursor IDE and Claude Code. These tools helped accelerate development and improve velocity. All AI-generated code has been carefully reviewed and validated through human inspection to ensure it aligns with the project's intended functionality and quality standards.

## License

GPL-3.0-only. See [`LICENSE`](LICENSE).
