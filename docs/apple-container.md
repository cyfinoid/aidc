# Apple `container` as an aidc Docker provider (experimental)

> **Status: EXPERIMENTAL / UNVERIFIED.** This path was implemented against the
> documented behavior of Apple's [`container`](https://github.com/apple/container)
> and the [`socktainer`](https://github.com/socktainer/socktainer) Docker-API
> shim, but it has **not** been validated end-to-end on hardware yet (it needs
> macOS 26 + Apple Silicon). `aidc doctor` prints a matching WARN. If you run it,
> please work the [validation checklist](#validation-checklist) and report gaps.
>
> **No shim wanted?** [`aidc-apple`](aidc-apple.md) drives the same Apple
> `container` runtime natively (no socktainer, no Docker API, no fallback)
> with the full aidc command surface.

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
- [`apple/container`](https://github.com/apple/container) installed (`container` on PATH). Note: `brew install socktainer` pulls a version-matched `container` in as a dependency — the easiest way to get the pair right.
- [`socktainer`](https://github.com/socktainer/socktainer) running, **version-matched
  to your `container` release** (a mismatched socktainer will fail in subtle ways).
- The `docker` CLI + Compose plugin (socktainer provides the *engine*, not the CLI).

**Socket location.** Where the socket lands depends on how you run socktainer,
and aidc auto-detects (first existing wins; override with
`AIDC_APPLE_CONTAINER_SOCKET`):

| How you run it | Socket |
|---|---|
| `socktainer` from your own shell | `~/.socktainer/container.sock` |
| `brew services start socktainer` | `/opt/homebrew/var/run/socktainer/.socktainer/container.sock` |

(aidc also checks the Intel-brew prefix `/usr/local/var/run/…` defensively,
but the formula is arm64-only — no supported install uses it.)

Do **not** export `DOCKER_HOST` globally unless you want *every* docker command
on the host to go through socktainer — aidc (and the validator) set it
per-invocation themselves.

## Setup

1. Install and start `apple/container`; confirm `container system status`.
2. Install and start `socktainer`; note its socket (default
   `~/.socktainer/container.sock`).
3. Point aidc at it. Two ways:

   **Automatic (default).** Leave `AIDC_DOCKER_PROVIDER` unset. When you run a
   container command and Docker's engine isn't reachable, aidc detects that
   `container` + socktainer are available and **asks** whether to use Apple
   container:

   ```
   [aidc] Docker is not available, but apple is. Use apple for this and future runs? [y/N]
   ```

   Answer `y` and aidc switches for this run **and saves
   `AIDC_DOCKER_PROVIDER=apple` to `~/.config/aidc/config.env`** so it won't ask
   again (edit/remove that line to revert). In non-interactive/CI runs aidc
   never prompts — it prints a hint and stays on Docker.

   **Explicit.** Set it yourself, host-wide in `~/.config/aidc/config.env`
   (recommended) or per project in `.ai-container/project.env`:

   ```sh
   AIDC_DOCKER_PROVIDER=apple
   # Optional — override if socktainer listens elsewhere:
   # AIDC_APPLE_CONTAINER_SOCKET=$HOME/.socktainer/container.sock
   ```

   An explicit value (or an explicit `DOCKER_HOST` in your environment) is
   honored verbatim — aidc neither probes nor prompts.
4. `aidc doctor` — confirms the `container` CLI, the socktainer socket, and that
   the Docker API responds through it (and prints the experimental WARN). With
   the automatic path, doctor also flags when an alternative engine is available
   while Docker is down.
5. `aidc up` / `aidc claude` (etc.) as usual.

### Adding another provider

Detection is a small registry in `aidc::detect_alt_providers` (`lib/aidc/config.sh`)
paired with an arm in `aidc::apply_docker_provider`. To add e.g. `podman`, add a
probe (docker CLI + a docker-compatible `podman.sock`) that prints the name, and
an `apply` arm that exports `DOCKER_HOST` at that socket. Everything else — the
prompt, persistence, doctor — is provider-agnostic.

`aidc status` shows a `provider` line while a non-default provider is active.

> `AIDC_DOCKER_PROVIDER=apple` **supersedes `AIDC_ISOLATE_VM`**: Apple `container`
> already isolates each container in its own VM, so aidc ignores `--isolate-vm`
> (with a warning) rather than stacking a redundant Lima/Firecracker VM.

## Compatibility matrix

aidc leans on a specific slice of the Docker/Compose surface. Each row is
verified through socktainer; record the result and open a follow-up issue for
any gap. **Bind mounts and `compose exec` TTY are the highest-risk items.**

First real-hardware run (2026-10-22, socktainer 1.6.0 + `container` 1.6.0,
macOS 26, arm64): **the build pipeline is the blocker**. Second run
(2026-10-23) confirmed it decisively (`--load` works; `FROM <local>` does
not) and validated the first runtime rows. **Verdict: aidc's base→thin image
scheme cannot work through the shim as-is** — the recommendation is the
native `aidc-apple` path (see [aidc-apple.md](aidc-apple.md)), whose builder
is Apple's own.

| aidc feature | Where it's used | Status |
|---|---|---|
| `docker build` (plain) | `ensure_base_image`, compose `build` | **FAIL — docker-container BuildKit driver: the built image is NOT loaded into the local store** (stays in build cache). Confirmed twice. |
| `docker build --load` | workaround for the above | **PASS — the image lands in the store** (2026-10-23) |
| `FROM <local tag>` (base→thin) | aidc's two-layer image scheme | **FAIL — confirmed: FROM resolves registries-only** (`pull access denied … docker.io/library/…`). Even with `--load`, a later build cannot base on a locally stored tag. aidc through the shim would need a local registry or single-file builds — engine-level, not an aidc bug. |
| Host **bind mounts** (workspace, ro `.devcontainer`, CORE_LOGICS, `/host-seed/*`, gitconfig, clipboard) | `compose.yaml` volumes | ? (one more validator run — run 2's main stack hit a validator-side external-volume name bug, since fixed) |
| Named volumes (`claude_home`, …) | `compose.yaml` volumes | ? (same) |
| `external:` volume (`aidc_toolchains`) | shared toolchain store | ? (same) |
| `docker compose exec` **with TTY** | every `aidc <agent>` / `shell` / `exec` | ? (same) |
| Port publish (loopback) | `aidc opencode-web` | **PASS — 127.0.0.1 reachable, LAN address correctly refused** (2026-10-23) |
| `/dev/shm` (tmpfs) | Claude OAuth token delivery | ? (same) |
| `init: true`, `user: aidc` | base compose | ? (same) |
| `pids_limit`, `mem_limit`, `cpus` | resource caps | ? (same) |
| `cap_add` (NET_ADMIN/NET_RAW) | firewall override | **PASS — CapEff bits set** (2026-10-23; busybox `ip link add` unavailable for the functional check, informational) |
| `security_opt: no-new-privileges` | hardened override | **FAIL — ignored** (NoNewPrivs stays 0; engine-level — Apple container has no equivalent, the same gap the native path documents) |
| Container DNS / networking | egress, package installs | ? (registry pulls + busybox nc serving worked during the port probe — promising but not the full row) |
| `aidc doctor` / `aidc init` / teardown | host-side | **PASS** (exit 0, scaffold written, clean `down`/`destroy`) |
| `aidc up` (thin `FROM aidc-base:<hash>`) | end-to-end | **FAIL — the FROM-local blocker above** |

## Validation checklist

**Automated.** On macOS 26 + Apple Silicon, with `container` + a version-matched
`socktainer` installed, run from an aidc checkout:

```sh
scripts/validate-apple-container.sh          # add --keep to retain artifacts on failure
```

It drives the full matrix below through the socktainer socket — engine probes
(build, mounts, volumes, init/user, limits, `/dev/shm`, DNS/egress, TTY exec,
loopback port publish, `cap_add`, `security_opt`) plus an aidc end-to-end pass
(`doctor` → `init` → `up` → mounts → volume persistence → teardown) in a
scratch repo, and prints one PASS/FAIL/SKIP row per matrix row to paste
straight into the table (or the follow-up issue). Notes:

- Run it **from an interactive terminal** — the `compose exec` TTY probe (every
  `aidc <agent>` attach depends on it) is skipped otherwise.
- The first `aidc up` in the end-to-end stage builds the shared base image;
  that can take minutes.
- Resource-limit rows report both the in-container cgroup value and
  `docker inspect` — enforcement is what matters; a mismatched inspect value on
  an enforcing shim is a reporting gap, not a security one.

**Manual (cannot be scripted).**

1. `AIDC_DOCKER_PROVIDER=apple aidc doctor` → provider detected, socket OK, API responds.
2. In any aidc project: `aidc opencode` → interactive agent attach with a
   working TTY (prompt, file-edit round-trip).
3. `aidc opencode-web` → open http://127.0.0.1:4096/ in a host browser; confirm
   it is NOT reachable from another machine on the LAN.
4. Fill in the matrix above (paste the script's rows); flip the `aidc doctor`
   note from "experimental/unverified" to the verified support level; file
   issues for gaps.

## Known caveats

- **The builder is a docker-container BuildKit driver** (first hardware run,
  2026-10-22): plain `docker build -t X` exits 0 but the image stays in the
  build cache — it never reaches the local image store, so compose tries to
  pull `X` from Docker Hub (401) and later builds resolve `FROM <local tag>`
  from registries only. Aidc's base+thin scheme is blocked until a workaround
  is characterized (`--load`? a local registry?) — the validator's
  `docker-build-load` and `build-from-local` rows exist for exactly this.
- socktainer/`container` version drift is a common failure mode — keep them matched
  (`brew install socktainer` pulls a version-matched `container`).
- Community shims evolve quickly; treat the matrix as a point-in-time snapshot.
- Host paths with spaces can trip Compose variable substitution generally.
