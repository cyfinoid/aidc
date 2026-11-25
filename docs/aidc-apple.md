# aidc-apple — aidc on Apple `container`, natively

`bin/aidc-apple` runs the full aidc workflow on Apple's native
[`container`](https://github.com/apple/container) runtime — **no socktainer, no
Docker API, no fallback, no alternative engines**. macOS 26 + Apple Silicon
only. The shim-based path (`AIDC_DOCKER_PROVIDER=apple`, see
[apple-container.md](apple-container.md)) remains available for stock `aidc`;
`aidc-apple` is the pure-native alternative for when you want to drive Apple's
runtime directly.

## What it is (and how it reuses aidc)

aidc-apple is `aidc` with the engine swapped: the launcher sources the normal
aidc modules, then `lib/aidc/apple.sh` redefines the handful of engine
chokepoints (`aidc::compose`, the image/volume helpers, status/clean/doctor
rows, the docker-shaped stock helpers) with native implementations. Everything
engine-agnostic is shared verbatim — scaffold (`init`), config, agent auth
seeding, session sync, the scan/review guardrails, `sync-config`, `insights` —
so the credential contract and project layout are identical to the docker
path. Same commands, same behavior:

```sh
aidc-apple init            # in a repo; same scaffold as aidc (no docker needed)
aidc-apple up              # first run builds base + project images (BuildKit)
aidc-apple opencode        # interactive agent attach (native TTY exec)
aidc-apple status          # config + native container state
aidc-apple down            # stop (state volumes kept)
aidc-apple destroy -f      # remove container + project volumes + project image
```

All other commands (`rebuild`, `rescan`, `shell`, `exec`, every agent command,
`tools install`, `clean`, `doctor`, `sync-*`, `sbom`, `scan`, `ci`, …) work as
with `aidc`. Stock helpers that assume docker are overridden too: `init` no
longer requires the docker CLI, `AIDC_ISOLATE_VM` no longer builds a
Lima/Firecracker VM (no-op — the per-container VM already isolates), the
toolchain-volume pre-flight and doctor's container row are native, and
`status` never reads the Docker store's volumes.

## Why native

- **No shim in the middle**: no socktainer version-matching, no partial
  Docker-API emulation — the CLI Apple ships is the contract.
- **Native TTY exec** (`container exec -t -i`), the thing every agent session
  depends on.
- **BuildKit builder with explicit resources**: `container build` runs in a
  builder you can size (`AIDC_APPLE_BUILDER_CPUS/MEMORY`, default 4/4G) — no
  1–2 GiB silent build ceiling.
- **ext4 volumes with journaling control** (`journal=ordered` by default) —
  crash-safer agent state without full-journal write amplification.
- **Per-container VM isolation by design** — `--isolate-vm` is redundant and
  ignored with a warning.

## Mapping

| aidc (compose) | aidc-apple (native) |
|---|---|
| `docker compose up -d [--build]` | `container volume create` ×10 → `container build` (base + thin) → `container run -d` with the equivalent flag set |
| `docker compose down` | `container stop -t 10` + `container delete` |
| `docker compose down -v --rmi local` | … + delete the 9 project volumes + the project image (base and `aidc_toolchains` are kept) |
| `docker compose exec [-T]` | `container exec -i / -t -i` — **always** `--user 1000:1000 -w /workspace` (a root `-T` exec would leave root-owned files, e.g. the `/dev/shm` OAuth token at 0600, unreadable by the agent); docker-style bare `-e KEY` is expanded host-side to `KEY=VALUE` (Apple documents exec `-e` as key=value only; unset keys are omitted) |
| `docker build` + build args | `container build --build-arg …` (same Dockerfiles aidc generates) |
| named volumes (9 state stores) | `container volume create --opt journal=ordered` (same `aidc_<slug>_*` names) |
| `external: aidc_toolchains` (ro) | `container run --mount type=volume,…,readonly` |
| `init: true`, `user: aidc` | `--init`, init pinned to root (`--user 0:0` — the image ends `USER aidc`, which would break the chown) → `chown` volume roots → `runuser` drop to uid 1000 |
| `mem_limit` / `cpus` / `pids_limit` | `-m` / `-c` (VM-sized, whole vCPUs, **create-time**: changing the knobs recreates the container) / no equivalent |
| `shm_size` | `--shm-size 1G` (native improvement — the compose template sets none) |
| `cap_add: NET_ADMIN,NET_RAW` (firewall) | `--cap-add NET_ADMIN --cap-add NET_RAW` |
| `security_opt: no-new-privileges` | **no equivalent** — warned once and dropped (VM isolation is the boundary) |
| loopback port publish (opencode-web) | `-p 127.0.0.1:<port>:<port>` (container is recreated when the port layout changes) |
| `clean` | stale `aidc-base:` / `aidc-toolchain-store:` tags reclaimed with `--apply` (keeper set = the CWD project's current base + current toolchain tags + all project images; a sibling project pinned to a different base rebuilds it on demand); state volumes are never pruned |

The engine gate is strict by design: a missing `container` CLI or stopped
services (`container system start`) aborts with an explanation — never a
fallback.

## Resource model — there is no "unlimited"

Each container is its own VM; memory is allocated at creation and an unset
value means roughly 1 GiB, which would OOM aidc builds. aidc-apple therefore
always applies explicit resources (conservative defaults, per the project's
decision):

| Knob | Default | Notes |
|---|---|---|
| `AIDC_MEM_LIMIT` (or `AIDC_APPLE_MEMORY`) | `4G` | stock aidc knob wins when set non-zero |
| `AIDC_CPU_LIMIT` (or `AIDC_APPLE_CPUS`) | `4` | whole vCPUs; fractional values truncate (Apple floors) |
| `AIDC_APPLE_SHM` | `1G` | `/dev/shm` for token delivery |
| `AIDC_APPLE_BUILDER_CPUS` / `_MEMORY` | `4` / `4G` | BuildKit builder sizing |
| `AIDC_APPLE_JOURNAL` | `ordered` | ext4 journaling mode for state volumes |
| `AIDC_APPLE_DROP_USER` | `1` | `0` = run everything as root (escape hatch if `runuser` misbehaves on your image) |

`pids_limit` has no Apple equivalent (no cgroup pids controller inside a VM);
the VM boundary and memory cap are the resource limits.

## Known gaps / hardware-validation checklist

Grounded in the 2026-10-23 hardware probe (container 1.6.0, builder shim
0.13.2): **`FROM <local tag>` resolves natively** (the decisive question —
the base→thin scheme works, unlike socktainer's builder), and the practical
Dockerfile ceiling is **between 13,976 bytes (builds) and 15,956 (fails)**
— the file ships base64-encoded in a gRPC header (apple/container#735), so
the CLI's own 16,384-raw-byte check overstates the budget. aidc-apple
handles both automatically:

- **Minification** (comments/blanks/indent outside heredocs; whole-line
  comments inside, shebangs kept) — the 29 KB base template → ~16 KB.
- **Chunked builds**: anything still over `AIDC_APPLE_DOCKERFILE_BUDGET`
  (default 13,500) is split at SAFE instruction boundaries and the chunks
  are tagged + chained via `FROM <chunk-tag>` — never inside RUN
  continuations or heredoc bodies, never separating a stage definition from
  its `COPY --from` consumers (a rebase rewrites the split's `FROM` onto
  the previous chunk and re-declares earlier ARGs, which would otherwise
  silently expand empty). The real base template builds as 2 chunks.
- **The untagged-landing bug**: `container build -t X` exits 0 but leaves
  the image UNTAGGED (`untagged@sha256:…` in the store). aidc-apple
  snapshots untagged digests, tags the single fresh one (`container image
  tag`), and refuses ambiguity.

**Socktainer coexistence warning**: both stacks drive the SAME apple/
container engine, and a running socktainer reconfigures its init/DNS (its
server listens on :2054) — native `container run` then panics with
"DNS_UPSTREAM env var must be set". `aidc-apple` warns when it detects the
socktainer socket; stop the service (`brew services stop socktainer`) when
going native. (If the panic persists after stopping, run
`container system property list` and clear whatever it left behind.)

Still to verify on hardware (the runtime checklist — the build pipeline is
now believed complete):

1. **Nested bind** — `/workspace/.devcontainer` (read-only) mounted over the
   `/workspace` bind, as compose does. **Confirmed working on hardware
   (2026-10-23: the run passed mount validation up to the gitconfig check).**
2. **Single-file binds are not supported** ("path … is not a directory" —
   confirmed 2026-10-23). Handled automatically: the gitconfig seed (the only
   file bind) is staged into `~/.config/aidc/seeds/<slug>/gitconfig.d/`, that
   directory is bound ro at `/host-seed/gitconfig.d`, and the entrypoint
   symlinks `/host-seed/gitconfig` to the file inside — the shared
   bootstrap's contract is unchanged. Snapshot semantics: a host gitconfig
   edit needs a re-`up` (the docker path binds the live file).
3. **`--mount type=volume,…,readonly`** for the shared toolchain store.
4. **The root-init + drop entrypoint** — `--user 0:0` honored, `chown`, then
   `runuser --preserve-environment` to uid 1000 (if the drop fails,
   `AIDC_APPLE_DROP_USER=0` is the escape hatch while it's reported).
5. **`exec --user 1000:1000 -w /workspace`** — scripted (`-T`) and interactive
   alike; confirm the `/dev/shm` token file lands uid-1000-readable.
6. **Loopback-only `-p 127.0.0.1:PORT:PORT`** — reachable from the host, not
   the LAN (`aidc-apple opencode-web`). (Validated PASS through socktainer —
   same underlying engine.)
7. Host-side permissions: uid 1000 inside the VM writing to macOS-owned bind
   sources (Apple's mount machinery, same one socktainer uses).

Run `scripts/validate-apple-container.sh` (the socktainer validator) as a
cross-check: it exercises the same mount/exec/publish semantics through the
shim; rows that pass there but fail natively point at CLI-flag differences
worth filing.

## Relationship to the socktainer provider

| | stock `aidc` + `AIDC_DOCKER_PROVIDER=apple` | `aidc-apple` |
|---|---|---|
| engine | Apple container **via socktainer** (Docker API shim) | Apple container **directly** |
| surface | everything compose does (through the shim's partial API) | the native flag set above |
| extra moving part | socktainer (version-matched) | none |
| fallback | docker provider available | **none, by design** |

Both share the scaffold, volumes naming, and state files, but their images and
volumes live in different stores (Apple's vs Docker's) — switching between
them for one project means a fresh `up` (state volumes are not migrated).
