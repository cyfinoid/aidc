# aidc

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Status: alpha](https://img.shields.io/badge/status-alpha-orange.svg)](#status)
[![macOS only](https://img.shields.io/badge/platform-macOS-lightgrey.svg)](#prereqs)

**aidc** — short for **AI Dev Container** — is a one-command devcontainer wrapper for AI coding agents (`claude`, `codex`, `opencode`, `grok`, `cursor-agent`). It scaffolds a hardened Linux container per repo, mounts your code at `/workspace`, persists agent state in named Docker volumes (so agents don't read your `~/.ssh` or your shell history), and bakes in always-on security scanners and supply-chain guardrails.

If you're already running these agents directly on your Mac and have been quietly nervous about it, this is for you.

## Status

Pre-1.0, rolling-release, personal-ish. The author uses it daily; the API may still shift. Issues welcome; PRs at the maintainer's discretion. See [`SECURITY.md`](SECURITY.md) for vuln disclosure.

## Prereqs

- **macOS** (host-side bits assume Mac — Keychain, LaunchAgent, `pbpaste`, `~/.local/bin` aliases)
- **Docker** running (Docker Desktop / OrbStack / Colima)
- **git**
- *(optional, high-security mode)* **Lima** on macOS or **Firecracker** on Linux — only needed if you enable `--isolate-vm`

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
aidc init          # one-time scaffold; writes .devcontainer/, .ai-container/, CLAUDE.md, AGENTS.md, CHANGELOG.md, DETAILED_CHANGELOG.md, logs/
aidc claude        # auto-runs `aidc up` if needed, then drops you into Claude Code in the container
```

Tool commands (`aidc claude` / `codex` / `opencode` / `grok` / `cursor-agent`) auto-bootstrap the container on first run.

## What aidc actually does

- creates local-only `.devcontainer/`, `.ai-container/`, `CLAUDE.md`, `AGENTS.md`, and `.cursor/rules/00-core-logics.mdc`
- mounts project code only at `/workspace`; overlays `/workspace/.devcontainer` read-only inside the container
- installs the coding agents (`claude`, `codex`, `opencode`, `grok`) as native prebuilt binaries — no npm-global, no Node runtime dependency for the agents themselves
- persists tool state in per-repo Docker volumes instead of mounting whole host homes
- seeds selected config from host read-only mounts on first startup
- creates one `CORE_LOGICS` git worktree per repo and mounts it at `/opt/CORE_LOGICS` for shared cross-repo notes
- detects the project's toolchains (Go, Rust, Ruby, Java, PHP, Node, Python — plus shell scripts) and installs them automatically; `aidc rescan` re-detects later for a repo that started empty
- bakes always-on security scanners (`semgrep`, `gitleaks`, `trufflehog`) plus per-toolchain linters (`gosec`, `bandit`, `cargo-audit`, `bundler-audit`, `shellcheck`) into the image
- seeds non-negotiable guidance into `CLAUDE.md` / `AGENTS.md` for every project — security guardrails, test-coverage discipline, and changelog/session-log conventions
- seeds committed project docs once, never overwriting your edits — `CHANGELOG.md`, `DETAILED_CHANGELOG.md`, and a `logs/` session journal
- auto-syncs in-container agent session transcripts back to the host on container start and exit, so the host's `/insights` stays current
- ships SafeDep's `pmg` / `vet` / `gryph` for supply-chain interception and `rtk` for token-saving CLI proxying
- offers an opt-in default-deny egress firewall with a sane allowlist

## Documentation

- [`docs/install.md`](docs/install.md) — prereqs, install, daily commands, what lives where, per-project customisation, cleanup
- [`docs/claude-profiles.md`](docs/claude-profiles.md) — alternate Claude API targets, local-model profiles, one-time OAuth login, session sync
- [`docs/security.md`](docs/security.md) — scanners, supply-chain guardrails, agent guardrails (gryph + rtk), opt-in egress firewall
- [`docs/clipboard-bridge.md`](docs/clipboard-bridge.md) — host-clipboard → container PNG paste bridge
- [`CHANGELOG.md`](CHANGELOG.md) — high-level release notes; [`DETAILED_CHANGELOG.md`](DETAILED_CHANGELOG.md) — long-form per-change rationale
- [`SECURITY.md`](SECURITY.md) — how to report vulnerabilities in aidc itself

## Commands

```bash
aidc init [path]
aidc up [--clipboard] [--isolate-vm]
aidc down
aidc rebuild [--clipboard] [--isolate-vm]
aidc rescan
aidc status [--global]
aidc destroy [-f] [--purge-worktree] [--purge-scaffold]
aidc shell
aidc exec -- <command>...
aidc claude [--profile NAME] [--provider NAME] [--list-profiles] [-- ...]
aidc codex [-- ...]
aidc opencode [-- ...]
aidc grok [-- ...]
aidc cursor-agent [-- ...]
aidc cursor
aidc sync-claude-aliases
aidc sync-config <claude|codex|opencode|grok|all>
aidc sync-sessions [claude|codex|opencode|grok|all]
```

`aidc status` shows the container + mounts/config for the current folder. `--global` lists every aidc container on the host with disk/CPU/memory and a totals line.

`aidc rescan` re-detects the project's languages and rebuilds, so a repo that started empty (or single-language) picks up the matching toolchains and security scanners once code lands. `shellcheck` installs automatically when shell scripts are present.

Session transcripts auto-sync from the container to the host on container start, agent exit, `aidc down`, and `aidc destroy` (before its volumes are removed), so `/insights` on the host stays current without a manual `aidc sync-sessions`. The start sync is the safety net for ungraceful exits (crash / `docker kill`) that the on-exit hooks miss — it catches up anything left in the volume.

Toggle it with `AIDC_AUTO_SYNC_SESSIONS`: set it host-wide in `~/.config/aidc/config.env` (universal default for every project) or per project in `.ai-container/project.env` (overrides the global default). `0` disables auto-sync; manual `aidc sync-sessions` always works regardless.

`--provider` remains as a compatibility alias for `--profile`.

## Isolation modes

aidc runs in one of two isolation modes. **Normal mode is the default and is what most people should use.**

### Normal mode (default)

Runs your project inside a Docker container. On macOS, Docker Desktop/OrbStack/Colima already wraps that container inside a Linux VM — your code is isolated from the host by both the container boundary *and* the VM boundary. All aidc containers share the same Docker VM, so they're isolated from each other by standard container namespacing (PID, network, filesystem, IPC) but not by a hypervisor boundary.

**This is fine for practically everyone.** The container + VM double boundary on macOS, combined with aidc's always-on scanners, read-only mounts, named volumes (no host home directory access), and optional egress firewall, already provides strong isolation between the AI agent and your host system.

### High-security mode (`--isolate-vm`)

Spawns each project in its own lightweight VM instead of sharing a single Docker VM.

| | Normal | High-security |
|---|---|---|
| **macOS** | Docker container inside shared Docker VM | Dedicated Lima VM per project |
| **Linux** | Docker container (shared kernel) | Dedicated Firecracker microVM per project |
| **Isolation boundary** | Container namespaces | Hypervisor (hardware-enforced) |
| **Per-project overhead** | ~50–100 MB RAM | ~512 MB–1 GB RAM + ~1 GB disk per VM |
| **Startup time** | ~2–5 s | ~10–30 s (VM boot + container init) |
| **Use when** | Everyday development | See below |

Enable it per-project:
```bash
aidc up --isolate-vm
# or persist it:
echo "AIDC_ISOLATE_VM=1" >> .ai-container/project.env
```

**Resource warning:** Each isolated VM consumes significantly more CPU, RAM, and disk than a shared Docker container. On a machine with 8 GB RAM, running more than 2–3 isolated projects simultaneously will be uncomfortable. Use this mode only when you have a clear reason.

### When high-security mode *might* make sense

- **You're running AI agents against proprietary or regulated codebases** (e.g., financial, healthcare, defense) where a container escape — even theoretical — is unacceptable.
- **You don't trust the Docker VM shared-tenant model** and want hardware-enforced hypervisor boundaries between projects.
- **You're on Linux** where normal Docker containers share the host kernel directly (no nested VM), so a kernel exploit in one container could affect the host and sibling containers.
- **You're running untrusted or third-party agent code** (custom MCP servers, community tool plugins) and want an additional containment layer.

### When high-security mode is almost certainly overkill

- **You're a solo developer on a personal machine.** The attacker model here is "the AI agent goes rogue" — and aidc's default container isolation, volume architecture, scanner enforcement, and optional egress firewall already handle that scenario well.
- **You're on macOS and already trust Docker Desktop / OrbStack.** Your containers are already inside a VM. A breakout requires two independent escapes (container → VM, then VM → host). Adding a per-project VM adds a third boundary, but the incremental security gain is small compared to the resource cost.
- **You're just trying aidc out.** Start with normal mode. You can always switch later with `aidc rebuild --isolate-vm`.

> **Note:** Linux + Firecracker support is included in the codebase but is not yet enabled by default. aidc currently ships as macOS-first. If you're on Linux and want to experiment, set `AIDC_ISOLATE_VM=1` and ensure `firecracker` is installed — but expect rough edges.

## Notes

- Generated files are added to `.git/info/exclude` when the target directory is a git repo, so your project stays clean. The seeded project docs (`CHANGELOG.md`, `DETAILED_CHANGELOG.md`, `logs/`) are *not* excluded — they belong to your repo and are meant to be committed.
- Settings can be set host-wide in `~/.config/aidc/config.env` (universal defaults for every project) or per project in `.ai-container/project.env`, which overrides the global default. Both files are sourced for env vars like `AIDC_AUTO_SYNC_SESSIONS`, `AIDC_ENABLE_EGRESS_FIREWALL`, and `AIDC_ISOLATE_VM`.
- Container egress is open by default; set `AIDC_ENABLE_EGRESS_FIREWALL=1` in `.ai-container/project.env` for a default-deny allowlist. See [`docs/security.md`](docs/security.md#optional-egress-firewall).
- The host-clipboard bridge is **off by default** — no host clipboard socket is mounted into the container. Opt in per (re)create with `aidc up --clipboard` / `aidc rebuild --clipboard`, or persist `AIDC_ENABLE_CLIPBOARD=1` in `.ai-container/project.env`. See [`docs/clipboard-bridge.md`](docs/clipboard-bridge.md).
- Per-project VM isolation (`--isolate-vm`) is **off by default** due to resource cost. Opt in per (re)create with `aidc up --isolate-vm` / `aidc rebuild --isolate-vm`, or persist `AIDC_ISOLATE_VM=1` in `.ai-container/project.env`. See [Isolation modes](#isolation-modes) above.
- Generated Claude alias wrappers are `aidc`-managed and live in `~/.local/bin` by default.

## 🤖 AI-Assisted Development
This project was developed with the assistance of AI tools, most notably Cursor IDE and Claude Code. These tools helped accelerate development and improve velocity. All AI-generated code has been carefully reviewed and validated through human inspection to ensure it aligns with the project's intended functionality and quality standards.

## License

GPL-3.0-only. See [`LICENSE`](LICENSE).
