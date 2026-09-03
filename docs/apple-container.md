# Apple `container` as an aidc Docker provider (experimental)

> **Status: EXPERIMENTAL / UNVERIFIED.** This path was implemented against the
> documented behavior of Apple's [`container`](https://github.com/apple/container)
> and the [`socktainer`](https://github.com/socktainer/socktainer) Docker-API
> shim, but it has **not** been validated end-to-end on hardware yet (it needs
> macOS 26 + Apple Silicon). `aidc doctor` prints a matching WARN. If you run it,
> please work the [validation checklist](#validation-checklist) and report gaps.

## What this is

Apple's `container` runs Linux containers in **per-container lightweight VMs** on
Apple Silicon. It is OCI-compatible (so aidc's images run under it) but it is a
**Docker *replacement*, not a Docker engine**: it has its own CLI and **no native
docker-compose and no native Docker API**. aidc is built entirely on
`docker compose`, so aidc talks to Apple `container` through a **Docker-API socket
shim** — [`socktainer`](https://github.com/socktainer/socktainer) — which exposes
a Unix socket the stock `docker` / `docker compose` CLIs can drive.

Because aidc always shells out to `docker`/`docker compose` with the inherited
environment, pointing `DOCKER_HOST` at that socket redirects **every** aidc call
transparently — the same mechanism aidc uses for Lima under `--isolate-vm`. The
`AIDC_DOCKER_PROVIDER=apple` switch just sets that `DOCKER_HOST` for you.

## Requirements

- **macOS 26 (Tahoe)** and **Apple Silicon** (`container`'s networking/DNS needs 26).
- [`apple/container`](https://github.com/apple/container) installed (`container` on PATH).
- [`socktainer`](https://github.com/socktainer/socktainer) running, **version-matched
  to your `container` release** (a mismatched socktainer will fail in subtle ways).
- The `docker` CLI + Compose plugin (socktainer provides the *engine*, not the CLI).

## Setup

1. Install and start `apple/container`; confirm `container system status`.
2. Install and start `socktainer`; note its socket (default
   `~/.socktainer/container.sock`).
3. Tell aidc to use it — host-wide in `~/.config/aidc/config.env` (recommended)
   or per project in `.ai-container/project.env`:

   ```sh
   AIDC_DOCKER_PROVIDER=apple
   # Optional — override if socktainer listens elsewhere:
   # AIDC_APPLE_CONTAINER_SOCKET=$HOME/.socktainer/container.sock
   ```

   An explicit `DOCKER_HOST` in your environment always wins over this switch.
4. `aidc doctor` — confirms the `container` CLI, the socktainer socket, and that
   the Docker API responds through it (and prints the experimental WARN).
5. `aidc up` / `aidc claude` (etc.) as usual.

`aidc status` shows a `provider` line while a non-default provider is active.

> `AIDC_DOCKER_PROVIDER=apple` **supersedes `AIDC_ISOLATE_VM`**: Apple `container`
> already isolates each container in its own VM, so aidc ignores `--isolate-vm`
> (with a warning) rather than stacking a redundant Lima/Firecracker VM.

## Compatibility matrix (fill in on real hardware)

aidc leans on a specific slice of the Docker/Compose surface. Each row must be
verified through socktainer; record the result and open a follow-up issue for any
gap. **Bind mounts and `compose exec` TTY are the highest-risk items.**

| aidc feature | Where it's used | Status |
|---|---|---|
| `docker build` (base + thin images) | `ensure_base_image`, compose `build` | ? |
| Host **bind mounts** (workspace, ro `.devcontainer`, CORE_LOGICS, `/host-seed/*`, gitconfig, clipboard) | `compose.yaml` volumes | ? |
| Named volumes (`claude_home`, …) | `compose.yaml` volumes | ? |
| `external:` volume (`aidc_toolchains`) | shared toolchain store | ? |
| `docker compose exec` **with TTY** | every `aidc <agent>` / `shell` / `exec` | ? |
| Port publish (loopback) | `aidc opencode-web` | ? |
| `/dev/shm` (tmpfs) | Claude OAuth token delivery | ? |
| `init: true`, `user: vscode` | base compose | ? |
| `pids_limit`, `mem_limit`, `cpus` | resource caps | ? |
| `cap_add` (NET_ADMIN/NET_RAW) | firewall override | ? |
| `security_opt: no-new-privileges` | hardened override | ? |
| Container DNS / networking | egress, package installs | ? |

## Validation checklist

On macOS 26 + Apple Silicon, with `container` + a version-matched `socktainer`:

1. `AIDC_DOCKER_PROVIDER=apple aidc doctor` → provider detected, socket OK, API responds.
2. `aidc up` in a sample repo → container starts; `/workspace` and the `/host-seed/*`
   mounts are present (`aidc shell`, `ls /workspace /host-seed`).
3. `aidc claude` (or another agent) → `compose exec` attaches with a working TTY.
4. `aidc opencode-web` → the loopback port is reachable from a host browser.
5. `aidc down` / `aidc destroy` → clean teardown, volumes handled.
6. Fill in the matrix above; flip the `aidc doctor` note from
   "experimental/unverified" to the verified support level; file issues for gaps.

## Known caveats

- socktainer/`container` version drift is a common failure mode — keep them matched.
- Community shims evolve quickly; treat the matrix as a point-in-time snapshot.
- Host paths with spaces can trip Compose variable substitution generally.
