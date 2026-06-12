# Install & daily use

## Prereqs

- macOS
- Docker running (Docker Desktop / OrbStack / Colima)
- git

`aidc` is macOS-only by design. The host-side bits (clipboard bridge, Keychain integration, LaunchAgent, profile aliases in `~/.local/bin`) assume a Mac.

## Install

```bash
./install.sh
```

Ensure `~/.local/bin` is on `PATH`.

## Per-repo bootstrap

```bash
cd /path/to/your/repo
aidc init          # one-time scaffold
aidc up            # build + start container
```

`aidc init` writes `.devcontainer/`, `.ai-container/`, `CLAUDE.md`, `AGENTS.md`, and a Cursor rule. They are added to `.git/info/exclude` so the repo stays clean.

## Daily commands

| Command | What it does |
|---|---|
| `aidc shell` | zsh inside the container |
| `aidc exec -- <cmd>` | one-shot command inside the container |
| `aidc claude` | start Claude Code (default Anthropic) |
| `aidc claude --profile <name>` | start Claude against a host-defined profile |
| `aidc codex` | start OpenAI Codex |
| `aidc opencode` | start OpenCode |
| `aidc cursor-agent` | start Cursor Agent |
| `aidc cursor` | open host Cursor on the repo |
| `aidc status` | container + config/mounts status for this folder |
| `aidc status --global` | one-line summary of every aidc container on this host |
| `aidc down` | stop the container, keep volumes |
| `aidc rebuild` | rebuild the image and restart |
| `aidc destroy` | remove container + volumes + image (prompts; `-f` to skip) |

## What lives where (inside the container)

```
/workspace                       your repo (rw bind)
/workspace/.devcontainer         scaffold (ro bind)
/opt/CORE_LOGICS                 shared cross-repo notes (rw, git worktree)
/home/vscode/.claude             Claude state (named volume)
/home/vscode/.codex              Codex state (named volume)
/home/vscode/.config/opencode    OpenCode state (named volume)
/commandhistory                  bash + zsh history (named volume)
/host-seed/{claude,codex,opencode,gitconfig}   read-only host seeds
```

`GIT_CONFIG_GLOBAL=/home/vscode/.gitconfig.local` — host gitconfig is seed-only, in-container `git config --global` writes land in the overlay (ephemeral across rebuilds).

## Per-project customisation

### Automatic toolchain detection

aidc inspects the repo on every `aidc up` and installs matching toolchains:

| Marker file(s) | Toolchain |
|---|---|
| `go.mod` | Go — apt `golang-go` |
| `Cargo.toml`, `rust-toolchain.toml`, `rust-toolchain` | Rust stable via rustup (minimal profile) |
| `Gemfile` | Ruby — apt `ruby-full` |
| `pom.xml`, `build.gradle`, `build.gradle.kts` | JDK — apt `default-jdk` |
| `composer.json` | PHP CLI — apt `php-cli` |
| `package.json`, `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `bun.lockb` | Node 22 (already in base) |
| `requirements.txt`, `uv.lock`, `pyproject.toml`, `Pipfile`, `Pipfile.lock`, `poetry.lock` | Python 3.13 via uv (already in base) |

Node and Python markers don't trigger a language install (the base image already has them) — they're listed so you can see in the build log what aidc detected, and so explicit `AIDC_TOOLCHAINS=node,python` works for clarity. The Python detection still installs `bandit`; see [security.md](security.md#per-toolchain-linters-auto-installed).

The detected list is passed as a Docker `--build-arg AIDC_TOOLCHAINS=go,rust,...` so it caches per combination — switching between repos doesn't rebuild.

**Override** in `.ai-container/project.env`:

```bash
AIDC_TOOLCHAINS=go,ruby      # force-install this list, ignore detection
AIDC_TOOLCHAINS=             # disable installs entirely (empty value, still set)
```

### Custom setup hook

For anything beyond the standard toolchains (specific versions, extra CLIs, language servers), edit `.devcontainer/project-setup.sh` — a stub seeded on first `aidc init`. It's user-owned — aidc creates it once and never touches it again. Use it to install per-project extras:

```bash
# .devcontainer/project-setup.sh
#!/usr/bin/env bash
set -euo pipefail

sudo apt-get update
sudo apt-get install -y --no-install-recommends golang-go
go install golang.org/x/tools/gopls@latest
```

Runs as `vscode` at image build time, with passwordless `sudo` available for system packages. The `COPY` is the last layer in the Dockerfile, so edits invalidate **only** the project-setup layer — the heavy base layers (apt, uv/Python, npm globals, pmg/vet/gryph/rtk) stay cached.

After editing, `aidc rebuild` (or just `aidc up` — `--build` is implicit) picks up the change.

It's `.gitignore`'d via `.git/info/exclude` along with the rest of `.devcontainer/`. `git add -f .devcontainer/project-setup.sh` if you want to track it.

## Cleaning up

```bash
aidc down                                    # stop, keep state
aidc destroy                                 # wipe container + volumes + image
aidc destroy --purge-worktree                # also drop ~/.local/share/aidc/core-worktrees/<slug> and its branch
aidc destroy --purge-scaffold                # also remove .devcontainer/, .ai-container/, CLAUDE.md, AGENTS.md, cursor rule
aidc destroy -f --purge-worktree --purge-scaffold   # full uninstall for this repo, no prompt
```
