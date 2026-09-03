# Install & daily use

## Prereqs

- macOS (primary platform) or Linux (experimental — see the matrix below)
- Docker running (Docker Desktop / OrbStack / Colima on macOS; the docker
  engine + compose plugin on Linux)
- git

### Platform support

aidc is **macOS-first**. The container side is Linux either way; what differs
is the host integration:

| Feature | macOS | Linux host |
|---|---|---|
| Container lifecycle (`init`/`up`/`scan`/agents/…) | ✅ | ✅ (exercised in CI on ubuntu) |
| Claude token from Keychain | ✅ | ❌ — export `CLAUDE_CODE_OAUTH_TOKEN` yourself (or log in interactively once; it persists in the volume) |
| Clipboard bridge (`pbpaste` in-container) | ✅ | ❌ (LaunchAgent + `pbpaste` are macOS-only) |
| Claude profile aliases / completions in `~/.local/bin` | ✅ | ✅ |
| `--isolate-vm` | Lima | Firecracker (rough edges expected) |

On Linux, `aidc doctor` reports the unavailable host features as
informational lines, not failures.

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
| `aidc grok` | start Grok Build |
| `aidc omp` | start omp (oh-my-pi) |
| `aidc cursor-agent` | start Cursor Agent |
| `aidc cursor` | open host Cursor on the repo |
| `aidc status` | container + config/mounts status for this folder |
| `aidc status --global` | one-line summary of every aidc container on this host |
| `aidc down` | stop the container, keep volumes |
| `aidc rebuild` | rebuild the image and restart |
| `aidc tools install [go\|rust\|java\|all]` | populate the shared read-only toolchain volume |
| `aidc tools status` | show which shared toolchains are installed |
| `aidc destroy` | remove container + volumes + image (prompts; `-f` to skip) |

## What lives where (inside the container)

```
/workspace                       your repo (rw bind)
/workspace/.devcontainer         scaffold (ro bind)
/opt/CORE_LOGICS                 shared cross-repo notes (rw, git worktree)
/home/vscode/.claude             Claude state (named volume)
/home/vscode/.codex              Codex state (named volume)
/home/vscode/.config/opencode    OpenCode state (named volume)
/home/vscode/.grok               Grok state (named volume)
/home/vscode/.omp                omp (oh-my-pi) state (named volume)
/commandhistory                  bash + zsh history (named volume)
/host-seed/{claude,codex,opencode,grok,omp,gitconfig}   read-only host seeds
```

`GIT_CONFIG_GLOBAL=/home/vscode/.gitconfig.local` — host gitconfig is seed-only, in-container `git config --global` writes land in the overlay (ephemeral across rebuilds).

## Per-project customisation

### Automatic toolchain detection

aidc inspects the repo on every `aidc up` and installs matching toolchains:

| Marker file(s) | Toolchain |
|---|---|
| `go.mod` | Go (+ `gosec`) — shared toolchain volume |
| `Cargo.toml`, `rust-toolchain.toml`, `rust-toolchain` | Rust stable (+ `cargo-audit`) — shared toolchain volume |
| `Gemfile` | Ruby — apt `ruby-full` |
| `pom.xml`, `build.gradle`, `build.gradle.kts` | JDK 21 — shared toolchain volume |
| `composer.json` | PHP CLI — apt `php-cli` |
| `package.json`, `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `bun.lockb` | Node 22 — nodesource apt (installed on detection) |
| `requirements.txt`, `uv.lock`, `pyproject.toml`, `Pipfile`, `Pipfile.lock`, `poetry.lock` | Python 3.13 via uv (already in base) |

Node is installed from the nodesource apt repo when the `node` toolchain is detected (or pinned via `AIDC_TOOLCHAINS=node`) — it's no longer baked into the base image, so projects that don't use Node don't carry it. Python 3.13 (uv-managed) stays in the base image; the Python marker still triggers a `bandit` install (see [security.md](security.md#per-toolchain-linters-auto-installed)).

The detected list is passed as a Docker `--build-arg AIDC_TOOLCHAINS=go,rust,...` so it caches per combination — switching between repos doesn't rebuild.

### Shared image + toolchain volume

aidc's image is split so N projects don't each carry a full ~3 GB copy:

- **Shared base image** (`aidc-base:<hash>`) — OS, uv/Python, the pinned security
  scanners, pmg, and the coding agents. Built **once** per content hash (of
  `.devcontainer/Dockerfile.base` + the `AIDC_AGENTS` selection) and reused by
  every project; the per-project image is a thin `FROM aidc-base` layer with just
  the detected toolchains and project-setup. Pin a custom base with
  `AIDC_BASE_IMAGE=<tag>` in `.ai-container/project.env`.
- **Shared toolchain volume** (`aidc_toolchains`) — Go, Rust, and the JDK (plus
  `gosec`/`cargo-audit`) live in **one** read-only Docker volume mounted at
  `/opt/toolchains` in every container, instead of being baked per project. It's
  populated automatically for detected go/rust/java toolchains on `aidc up`, or
  manually with `aidc tools install [go|rust|java|all]` (`aidc tools status` lists
  what's present). Because it's read-only and shared, revoke a bad toolchain once
  with `docker volume rm aidc_toolchains` and repopulate.

**Override** in `.ai-container/project.env`:

```bash
AIDC_TOOLCHAINS=go,ruby      # force-install this list, ignore detection
AIDC_TOOLCHAINS=             # disable installs entirely (empty value, still set)
AIDC_AGENTS=claude,codex     # slim the shared base to only these agents (builds
                             #   a base variant). Default 'all' bakes in every
                             #   agent once in the shared base (issue #7), so the
                             #   per-project cost of all agents is already zero.
AIDC_NO_BUILD=1              # never build implicitly — 'aidc up' fails fast if
                             #   the image is missing (build it with 'aidc rebuild')
AIDC_BASE_IMAGE=my-base:tag  # pin a custom shared base instead of the built
                             #   content-hashed aidc-base:<hash>
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

Runs as `vscode` at image build time, with passwordless `sudo` available for system packages. The `COPY` is the last layer in the Dockerfile, so edits invalidate **only** the project-setup layer — the heavy base layers (apt, uv/Python, native agent binaries, pmg/vet/rtk) stay cached.

After editing, run `aidc rebuild` to pick up the change — `aidc up` and the agent commands build only when the image is **missing** (fast path), so they won't rebuild an existing image on their own.

It's `.gitignore`'d via `.git/info/exclude` along with the rest of `.devcontainer/`. `git add -f .devcontainer/project-setup.sh` if you want to track it.

## Cleaning up

```bash
aidc down                                    # stop, keep state
aidc destroy                                 # wipe container + volumes + image
aidc destroy --purge-worktree                # also drop ~/.local/share/aidc/core-worktrees/<slug> and its branch
aidc destroy --purge-scaffold                # also remove .devcontainer/, .ai-container/, CLAUDE.md, AGENTS.md, cursor rule
aidc destroy -f --purge-worktree --purge-scaffold   # full uninstall for this repo, no prompt
```
