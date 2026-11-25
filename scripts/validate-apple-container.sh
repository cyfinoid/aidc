#!/usr/bin/env bash
#
# Validate Apple `container` + socktainer as an aidc Docker provider.
#
# Drives the exact Docker/Compose surface aidc leans on (see the compatibility
# matrix in docs/apple-container.md) through a socktainer Docker-API socket and
# reports PASS/FAIL/SKIP per matrix row, so the results can be pasted straight
# into the matrix / the follow-up issue. Two stages:
#
#   1. Engine probes (always run): multi-stage build, bind mounts (rw + ro),
#      named + external volumes, init/user, resource limits, /dev/shm, DNS +
#      HTTPS egress, compose exec (incl. TTY), loopback port publish, cap_add
#      (NET_ADMIN/NET_RAW), security_opt (no-new-privileges).
#   2. aidc end-to-end (unless --skip-aidc): doctor → init → up → mount checks
#      → volume persistence across down/up → teardown, in a scratch repo,
#      using THIS checkout's bin/aidc.
#
# Interactive-only items (agent TTY attach, opencode-web in a browser) are
# printed as a manual checklist at the end — a script cannot validate them.
#
# Usage:
#   scripts/validate-apple-container.sh [--socket PATH] [--skip-aidc] [--keep]
#
#     --socket PATH   socktainer socket. Default: $AIDC_APPLE_CONTAINER_SOCKET,
#                     or the first existing socket among the known locations
#                     (~/.socktainer for manual runs, the Homebrew service
#                     path for `brew services start socktainer`). Ignored
#                     when DOCKER_HOST is already set (an explicit DOCKER_HOST
#                     wins, like aidc).
#     --skip-aidc     engine probes only.
#     --keep          keep probe artifacts (containers/volumes/image/workdir)
#                     for inspection instead of cleaning up.
#
# Exit: 0 = no FAIL rows, 1 = at least one FAIL, 2 = usage error.
# Bash-3.2-safe (macOS system bash).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AIDC_BIN="$REPO_ROOT/bin/aidc"

usage() {
  sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Socktainer socket resolution, mirroring aidc::apple_container_socket: an
# explicit --socket / AIDC_APPLE_CONTAINER_SOCKET wins; otherwise the first
# EXISTING socket among the known locations (manual run → ~/.socktainer,
# `brew services` → /opt/homebrew/var/run/socktainer/.socktainer). The
# candidate list is overridable for tests.
resolve_socket() {
  local candidates="${AIDC_APPLE_CONTAINER_SOCKET_CANDIDATES:-$HOME/.socktainer/container.sock:/opt/homebrew/var/run/socktainer/.socktainer/container.sock:/usr/local/var/run/socktainer/.socktainer/container.sock}"
  local c
  # ':'→' ' then default-IFS word splitting — same rationale as
  # aidc::apple_container_socket (no IFS tampering; set -f keeps candidates
  # literal even if they contain glob characters).
  set -f
  for c in ${candidates//:/ }; do
    [[ -S "$c" ]] && { set +f; printf '%s' "$c"; return 0; }
  done
  set +f
  printf '%s' "$HOME/.socktainer/container.sock"
}

SOCKET="${AIDC_APPLE_CONTAINER_SOCKET:-$(resolve_socket)}"
SKIP_AIDC=0
KEEP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --socket)    [[ $# -ge 2 ]] || { echo "validate-apple-container: --socket needs a PATH" >&2; exit 2; }
                 SOCKET="$2"; shift 2 ;;
    --skip-aidc) SKIP_AIDC=1; shift ;;
    --keep)      KEEP=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           echo "validate-apple-container: unknown flag: $1 (valid: --socket, --skip-aidc, --keep)" >&2; exit 2 ;;
  esac
done

# AIDC_VAL_WORKDIR (test seam, like AIDC_VAL_FORCE_TTY): run in a caller-owned
# directory instead of a fresh mktemp — lets suites inspect the generated
# probe files. A caller-owned workdir is never rm -rf'd by cleanup.
CREATED_WORK=0
if [[ -n "${AIDC_VAL_WORKDIR:-}" ]]; then
  WORK="$AIDC_VAL_WORKDIR"
  mkdir -p "$WORK"
else
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/aidc-val.XXXXXX")"
  CREATED_WORK=1
fi
# The probe containers (uid 1000, and -u 0 for the ro-ness probes) must be able
# to traverse into the workdir and write into ./ws: mktemp's default 0700
# would make the bind probes test host ACLs instead of mount semantics
# (exactly the false-PASS/FAIL class this validator exists to avoid).
chmod 755 "$WORK"
LOGS="$WORK/logs"; mkdir -p "$LOGS"
PROJ_MAIN="aidcval-main"
PROJ_CAPS="aidcval-caps"
PROJ_NNP="aidcval-nnp"
PROJ_PORT="aidcval-port"
# MUST match the compose declaration below exactly: an `external: true`
# volume is referenced by its literal name (compose does not prefix it).
# v1 used aidcval-ext-vol and compose failed with `external volume
# "aidcval_ext" not found` — surfaced only on hardware once the image
# resolved (stubbed tests never validate compose semantics).
EXT_VOL="aidcval_ext"
PORT=47654   # deliberately obscure: must be free on the loopback interface
IMAGE_TAG="aidc-val-probe:$(date +%s)"
LOAD_TAG="${IMAGE_TAG}-load"          # defined up front: the cleanup trap
FROMLOCAL_TAG="${IMAGE_TAG}-fromlocal" # references them even on early exits
SCRATCH_INITED=0

# Result bookkeeping: counters only (rows print as they are decided; nothing
# iterates a record list afterwards).
PASSES=0; FAILS=0; SKIPS=0

report() { # report <pass|fail|skip> <row> <detail>
  local status="$1" name="$2" detail="$3"
  case "$status" in
    pass) printf '  PASS  %-26s %s\n' "$name" "$detail"; PASSES=$((PASSES + 1)) ;;
    fail) printf '  FAIL  %-26s %s\n' "$name" "$detail"; FAILS=$((FAILS + 1)) ;;
    skip) printf '  SKIP  %-26s %s\n' "$name" "$detail"; SKIPS=$((SKIPS + 1)) ;;
  esac
}

# Run a command, capture combined output to $LOGS/<tag>.log, preserve its rc.
# Only ever call this inside an if/while condition — a bare failing call would
# trip set -e by design.
run_log() { # run_log <tag> <cmd...>
  local tag="$1"; shift
  "$@" >"$LOGS/$tag.log" 2>&1 || return $?
  return 0
}

# Print the tail of a probe log (context on FAIL). `|| true` is load-bearing:
# under set -e -o pipefail a missing log (probe never ran) would otherwise
# abort the whole validator.
log_tail() { tail -5 "$LOGS/$1.log" 2>/dev/null | sed 's/^/        /' || true; }

cleanup() {
  local rc=$?
  trap - EXIT
  # If the aidc stage got as far as init, its scratch compose project may own
  # containers/volumes that compose down on OUR projects won't touch. Best
  # effort destroy (only while it's still an aidc project — a successful
  # teardown row purges the scaffold and resets the flag); if that fails,
  # retain the workdir so the user can clean up by hand (rm -rf'ing it would
  # orphan the project's resources).
  if [[ $SKIP_AIDC -eq 0 && "${SCRATCH_INITED:-0}" == "1" ]] \
     && [[ -f "$WORK/scratch/.ai-container/project.env" ]]; then
    if ! (cd "$WORK/scratch" 2>/dev/null && AIDC_DOCKER_PROVIDER=apple \
          "$AIDC_BIN" destroy -f >/dev/null 2>&1); then
      printf '\nwarning: could not auto-destroy the aidc scratch project — cleaning it by hand:\n'
      printf '  cd %s/scratch && %s destroy -f\n' "$WORK" "$AIDC_BIN"
      KEEP=1
    fi
  fi
  if [[ $KEEP -eq 1 ]]; then
    printf '\n[--keep] artifacts retained:\n  workdir: %s\n  image:   %s\n  logs:    %s\n' "$WORK" "$IMAGE_TAG" "$LOGS"
    return "$rc"
  fi
  local p
  for p in "$PROJ_MAIN" "$PROJ_CAPS" "$PROJ_NNP" "$PROJ_PORT"; do
    docker compose --project-name "$p" down -v --remove-orphans >/dev/null 2>&1 || true
  done
  docker volume rm -f "$EXT_VOL" >/dev/null 2>&1 || true   # external: compose down -v never touches it
  docker rmi -f "$IMAGE_TAG" "$LOAD_TAG" "$FROMLOCAL_TAG" >/dev/null 2>&1 || true
  [[ "$CREATED_WORK" == "1" ]] && rm -rf "$WORK"
  return "$rc"
}
trap cleanup EXIT

# ── Stage 0: prerequisites ──────────────────────────────────────────────────

printf 'aidc Apple-container validation\n'
DOCKER_HOST_PRESET=0
if [[ -n "${DOCKER_HOST:-}" ]]; then
  DOCKER_HOST_PRESET=1
  printf 'DOCKER_HOST already set (%s) — honored verbatim, --socket ignored (same rule as aidc)\n' "$DOCKER_HOST"
else
  export DOCKER_HOST="unix://$SOCKET"
  printf 'DOCKER_HOST=%s (from --socket / AIDC_APPLE_CONTAINER_SOCKET)\n' "$DOCKER_HOST"
fi
printf 'workdir %s\n\n' "$WORK"

printf 'prerequisites\n'
if command -v docker >/dev/null 2>&1; then
  report pass docker-cli "$(docker --version 2>/dev/null | head -1)"
else
  report fail docker-cli "docker CLI not found — install it (socktainer provides the engine, not the CLI)"
  exit 1
fi
if docker compose version >/dev/null 2>&1; then
  report pass compose-plugin "$(docker compose version 2>/dev/null | head -1)"
else
  report fail compose-plugin "docker compose plugin missing — aidc is a docker-compose tool"
  exit 1
fi
if command -v container >/dev/null 2>&1; then
  report pass container-cli "$(container --version 2>/dev/null | head -1 || echo "'container' CLI present")"
else
  report fail container-cli "'container' CLI not found — install github.com/apple/container (macOS 26 + Apple Silicon)"
  exit 1
fi
if [[ $DOCKER_HOST_PRESET -eq 1 ]]; then
  # An explicit DOCKER_HOST wins (aidc's rule): the socktainer socket path is
  # irrelevant — the API check below, through the preset host, is the gate.
  report skip socktainer-socket "DOCKER_HOST preset — socket path not checked"
elif [[ -S "$SOCKET" ]]; then
  report pass socktainer-socket "socket present: $SOCKET"
else
  report fail socktainer-socket "no socket at $SOCKET — start socktainer (version-matched to 'container')"
  exit 1
fi
if run_log prereq-api docker info; then
  report pass docker-api "Docker API responds through the socket ($(docker info --format '{{.ServerVersion}}' 2>/dev/null || echo 'version?'))"
else
  report fail docker-api "docker info failed through $DOCKER_HOST — start/version-match socktainer"
  log_tail prereq-api
  exit 1
fi
if command -v curl >/dev/null 2>&1; then
  report pass curl-cli "$(curl --version 2>/dev/null | head -1 | cut -c1-60)"
else
  report fail curl-cli "curl not found — needed for the port-publish probe"
  exit 1
fi
# Informational, not gating: socktainer is the thing aidc talks to, but
# `container system status` output helps triage.
if container system status >"$LOGS/container-status.log" 2>&1; then
  printf '        container system: ok (details: logs/container-status.log)\n'
else
  printf '        container system: not reporting ok — see logs/container-status.log\n'
fi

# ── Stage 1: engine probes ──────────────────────────────────────────────────
# One small alpine image built once via a MULTI-STAGE Dockerfile (aidc's base
# image is multi-stage; COPY --from must survive the shim), then four tiny
# compose projects exercising the exact knobs in templates/devcontainer/*.tmpl.

printf '\nengine probes\n'

mkdir -p "$WORK/img" "$WORK/main/ws" "$WORK/main/ro"
chmod 777 "$WORK/main/ws"   # uid-1000 write probe tests the mount, not host ACLs
cat >"$WORK/img/Dockerfile" <<'EOF'
FROM alpine:3.20 AS stage
RUN printf 'aidcval' > /marker
FROM alpine:3.20
COPY --from=stage /marker /probe-marker
EOF

# 1. Build rows — the aidc dependency chain, decomposed. A shim's builder may
#    (a) not load plain `docker build` results into the image store (the
#    docker-container BuildKit driver's signature), (b) support --load, and
#    (c) still fail to resolve FROM <local tag> in a LATER build (registry-
#    only resolution) — which is precisely what aidc's base→thin scheme needs.
#    STACK_TAG picks the best available content image for the stacks below.
IMG_ID=""
if run_log build docker build -q -t "$IMAGE_TAG" "$WORK/img"; then
  IMG_ID="$(docker images -q "$IMAGE_TAG" 2>/dev/null)"
fi
if [[ -n "$IMG_ID" ]]; then
  report pass docker-build "multi-stage build ok; image in store (${IMG_ID:0:12})"
elif grep -qi "No output specified" "$LOGS/build.log" 2>/dev/null; then
  report fail docker-build "built but NOT loaded into the image store (docker-container BuildKit driver) — see docker-build-load"
else
  report fail docker-build "multi-stage docker build failed"
  log_tail build
fi

if run_log build-load docker build --load -q -t "$LOAD_TAG" "$WORK/img" \
   && [[ -n "$(docker images -q "$LOAD_TAG" 2>/dev/null)" ]]; then
  report pass docker-build-load "--load build lands in the image store"
else
  report fail docker-build-load "'docker build --load' failed or image not in store"
  log_tail build-load
fi

FROM_BASE=""
[[ -n "$(docker images -q "$LOAD_TAG" 2>/dev/null)" ]] && FROM_BASE="$LOAD_TAG"
[[ -z "$FROM_BASE" && -n "$IMG_ID" ]] && FROM_BASE="$IMAGE_TAG"
if [[ -n "$FROM_BASE" ]]; then
  printf 'FROM %s\nRUN printf aidcval > /fromlocal-marker\n' "$FROM_BASE" \
    >"$WORK/img/Dockerfile.fromlocal"
  if run_log build-fromlocal docker build -q -t "$FROMLOCAL_TAG" -f "$WORK/img/Dockerfile.fromlocal" "$WORK/img" \
     && [[ -n "$(docker images -q "$FROMLOCAL_TAG" 2>/dev/null)" ]]; then
    report pass build-from-local "FROM $FROM_BASE resolves — aidc's base→thin scheme is viable"
  else
    report fail build-from-local "FROM $FROM_BASE did not resolve — aidc's base→thin build scheme CANNOT work via this shim as-is"
    log_tail build-fromlocal
  fi
else
  report fail build-from-local "no locally stored base image to FROM (see rows above)"
fi

# Stacks run the best available content image: plain → --load → from-local.
STACK_TAG="$IMAGE_TAG"
[[ -z "$IMG_ID" ]] && STACK_TAG="$LOAD_TAG"
[[ -z "$(docker images -q "$STACK_TAG" 2>/dev/null)" ]] && STACK_TAG="$FROMLOCAL_TAG"

# The main stack mirrors compose.yaml.tmpl's security-relevant surface:
# init, non-root user, resource caps, rw + ro bind mounts, a project named
# volume, and an external read-only volume (the aidc_toolchains shape).
cat >"$WORK/main/compose.yaml" <<EOF
services:
  workspace:
    image: $STACK_TAG
    init: true
    user: "1000:1000"
    working_dir: /workspace
    command: sleep infinity
    pids_limit: 128
    mem_limit: 256m
    cpus: "1.5"
    volumes:
      - ./ws:/workspace
      - ./ro:/ro-dir:ro
      - probe_vol:/persist
      - aidcval_ext:/ext:ro
volumes:
  probe_vol:
  aidcval_ext:
    external: true
EOF

cat >"$WORK/caps-compose.yaml" <<EOF
services:
  workspace:
    image: $STACK_TAG
    command: sleep infinity
    cap_add:
      - NET_ADMIN
      - NET_RAW
EOF

cat >"$WORK/nnp-compose.yaml" <<EOF
services:
  workspace:
    image: $STACK_TAG
    command: sleep infinity
    security_opt:
      - no-new-privileges:true
EOF

# Loopback-only publish (compose.opencode-web.yaml.tmpl shape). busybox nc
# serves one request per loop iteration. The command is a YAML FLOW SEQUENCE
# with a double-quoted scalar: the payload contains ": " (a plain scalar
# would break YAML parsing — a real compose rejected v1's unquoted form) and
# YAML double-quote escapes turn \r\n into literal CRLF, exactly what the
# response needs.
cat >"$WORK/port-compose.yaml" <<EOF
services:
  workspace:
    image: ${STACK_TAG:-$IMAGE_TAG}
    command: ["sh", "-c", "while true; do { printf \"HTTP/1.0 200 OK\r\nContent-Length: 7\r\n\r\naidcval\"; sleep 1; } | nc -l -p $PORT; done"]
    ports:
      - "127.0.0.1:$PORT:$PORT"
EOF

main() { docker compose -f "$WORK/main/compose.yaml" --project-name "$PROJ_MAIN" "$@"; }
stack_exec() { # stack_exec <tag> <sh-code> — non-TTY exec on the main stack
  local tag="$1" code="$2"
  main exec -T workspace sh -c "$code" >"$LOGS/$tag.log" 2>&1
}
# Read-only-ness probes run as root: a uid-1000 `touch` on a ro bind can fail
# with EACCES for ownership reasons alone (host-owned 0755 dir), which would
# false-PASS the very rows this validator exists to pin down. Root gets EROFS
# iff the mount is genuinely read-only, regardless of ownership; on a writable
# bind root succeeds (Docker Desktop-style sharing maps it to the host user).
root_exec() { # root_exec <tag> <sh-code> — same, as uid 0
  local tag="$1" code="$2"
  main exec -u 0 -T workspace sh -c "$code" >"$LOGS/$tag.log" 2>&1
}

# The external volume must exist BEFORE compose up (external: true means
# compose will not create it — same contract as aidc_toolchains).
if run_log vol-create docker volume create "$EXT_VOL"; then
  printf '        external volume %s created\n' "$EXT_VOL"
else
  report fail compose-up "docker volume create $EXT_VOL failed (external-volume precondition)"
  log_tail vol-create
fi

# 2. Main stack up. Everything in the block below depends on it.
STACK_UP=0
if run_log up-main main up -d --quiet-pull; then
  STACK_UP=1
  report pass compose-up "stack up ok (image + rw/ro binds + named + external volume)"
else
  report fail compose-up "compose up failed — every dependent row below is unvalidated"
  log_tail up-main
fi

if [[ $STACK_UP -eq 1 ]]; then
  # Multi-stage artifact actually landed (COPY --from proof).
  if stack_exec marker 'test -f /probe-marker && printf aidcval' \
     && [[ "$(cat "$LOGS/marker.log")" == "aidcval" ]]; then
    report pass build-artifact "COPY --from marker present in final image"
  else
    report fail build-artifact "multi-stage artifact missing (/probe-marker)"
  fi

  # 3. rw bind mount, both directions.
  printf 'from-host' >"$WORK/main/ws/from-host.txt"
  if stack_exec bind-rw-write 'printf aidcval > /workspace/from-container.txt' \
     && [[ "$(cat "$WORK/main/ws/from-container.txt" 2>/dev/null || true)" == "aidcval" ]] \
     && stack_exec bind-rw-read 'test "$(cat /workspace/from-host.txt)" = from-host'; then
    report pass bind-mount-rw "writes visible both directions (workspace mount)"
  else
    report fail bind-mount-rw "rw bind mount broken host<->container"
    log_tail bind-rw-write; log_tail bind-rw-read
  fi

  # 4. ro bind mount must REJECT writes (the .devcontainer overlay contract).
  if root_exec bind-ro 'touch /ro-dir/x 2>/dev/null'; then
    report fail bind-mount-ro "write SUCCEEDED on a read-only bind (mount is not ro!)"
  else
    report pass bind-mount-ro "read-only bind rejects writes (.devcontainer overlay)"
  fi

  # 5. External read-only volume (aidc_toolchains shape): mounted, and ro.
  if stack_exec ext-ro 'test -d /ext'; then
    if root_exec ext-ro-write 'touch /ext/x 2>/dev/null'; then
      report fail external-volume-ro "write SUCCEEDED on the external ro volume"
    else
      report pass external-volume-ro "external volume mounted read-only"
    fi
  else
    report fail external-volume-ro "/ext not mounted (external volume)"
    log_tail ext-ro
  fi

  # 6. init:true — PID 1 must be the init shim, not our `sleep infinity`.
  P1=""
  if stack_exec p1 'cat /proc/1/comm'; then P1="$(cat "$LOGS/p1.log")"; fi
  P1="$(printf '%s' "$P1" | tr -d '[:space:]')"
  if [[ -n "$P1" && "$P1" != "sleep" && "$P1" != "sh" ]]; then
    report pass init-true "PID 1 comm is '$P1' (docker-init shim, not sleep)"
  else
    report fail init-true "PID 1 comm is '${P1:-<none>}' — init:true ignored (zombie-reaping lost)"
  fi

  # 7. user: aidc runs as uid 1000 (compose `user: aidc`).
  UID_OUT=""
  if stack_exec idu 'id -u'; then UID_OUT="$(cat "$LOGS/idu.log")"; fi
  UID_OUT="$(printf '%s' "$UID_OUT" | tr -d '[:space:]')"
  if [[ "$UID_OUT" == "1000" ]]; then
    report pass user-nonroot "container runs as uid 1000 (aidc user)"
  else
    report fail user-nonroot "id -u returned '${UID_OUT:-<none>}' (expected 1000)"
  fi

  # 8. Resource limits — cgroup files are the runtime proof; docker inspect
  # shows what landed in the container config. PASS on either, report both
  # (a shim that enforces but mis-reports inspect is a reporting gap, not a
  # security one — the detail string keeps the distinction auditable).
  CID="$(main ps -q workspace 2>/dev/null || true)"
  PIDS_CG=""
  if stack_exec pids 'cat /sys/fs/cgroup/pids.max'; then PIDS_CG="$(tr -d '[:space:]' <"$LOGS/pids.log")"; fi
  PIDS_INSP="$(docker inspect -f '{{.HostConfig.PidsLimit}}' "$CID" 2>/dev/null || true)"
  if [[ "$PIDS_CG" == "128" || "$PIDS_INSP" == "128" ]]; then
    report pass pids-limit "pids.max='$PIDS_CG' inspect='$PIDS_INSP' (want 128)"
  else
    report fail pids-limit "pids.max='$PIDS_CG' inspect='$PIDS_INSP' (want 128)"
  fi
  MEM_CG=""
  if stack_exec mem 'cat /sys/fs/cgroup/memory.max'; then MEM_CG="$(tr -d '[:space:]' <"$LOGS/mem.log")"; fi
  MEM_INSP="$(docker inspect -f '{{.HostConfig.Memory}}' "$CID" 2>/dev/null || true)"
  if [[ "$MEM_CG" == "268435456" || "$MEM_INSP" == "268435456" ]]; then
    report pass mem-limit "memory.max='$MEM_CG' inspect='$MEM_INSP' (want 268435456 = 256m)"
  else
    report fail mem-limit "memory.max='$MEM_CG' inspect='$MEM_INSP' (want 268435456 = 256m)"
  fi
  CPU_CG=""
  if stack_exec cpu 'cat /sys/fs/cgroup/cpu.max'; then CPU_CG="$(tr -d '[:space:]' <"$LOGS/cpu.log")"; fi
  CPU_INSP="$(docker inspect -f '{{.HostConfig.NanoCpus}}' "$CID" 2>/dev/null || true)"
  if [[ "$CPU_CG" == "150000100000" || "$CPU_INSP" == "1500000000" ]]; then
    report pass cpu-limit "cpu.max='$CPU_CG' inspect='$CPU_INSP' (want 1.5 cpu)"
  else
    report fail cpu-limit "cpu.max='$CPU_CG' inspect='$CPU_INSP' (want 1.5 cpu)"
  fi

  # 9. /dev/shm writable with real capacity (Claude OAuth token delivery).
  if stack_exec shm 'dd if=/dev/zero of=/dev/shm/aidcval bs=1048576 count=8 2>/dev/null && test -s /dev/shm/aidcval && rm -f /dev/shm/aidcval'; then
    report pass dev-shm "8MiB tmpfs write/read/unlink ok (token delivery path)"
  else
    report fail dev-shm "/dev/shm unusable — Claude OAuth token delivery would break"
    log_tail shm
  fi

  # 10. DNS + HTTPS egress (package installs, agent API calls).
  if stack_exec dns 'nslookup deb.debian.org >/dev/null' \
     && stack_exec egress 'wget -q -O /dev/null https://deb.debian.org/'; then
    report pass dns-egress "DNS resolves, HTTPS egress works"
  else
    report fail dns-egress "DNS or HTTPS egress broken inside the container"
    log_tail dns; log_tail egress
  fi

  # 11. compose exec WITH a TTY — every `aidc <agent>` attach depends on it.
  # Can only be probed from an interactive terminal (compose allocates a TTY
  # only when its own stdin is one); AIDC_VAL_FORCE_TTY=1 overrides for tests.
  if [[ -t 0 || "${AIDC_VAL_FORCE_TTY:-0}" == "1" ]]; then
    TTY_OUT=""
    main exec workspace sh -c '[ -t 0 ] && [ -t 1 ] && printf tty-ok' >"$LOGS/exec-tty.log" 2>&1 \
      && TTY_OUT="$(cat "$LOGS/exec-tty.log")" || true
    if [[ "$(printf '%s' "$TTY_OUT" | tr -d '[:space:]')" == "tty-ok" ]]; then
      report pass compose-exec-tty "exec attaches with a working TTY (agent sessions)"
    else
      report fail compose-exec-tty "TTY exec broken — every aidc <agent> attach would fail"
      log_tail exec-tty
    fi
  else
    report skip compose-exec-tty "needs an interactive terminal — rerun from your shell, or validate via 'aidc opencode' below"
  fi

  # 12. Named volume survives `down` (no -v) → `up` (state-volume contract).
  # Runs LAST inside the block: it tears the stack down and back up. Runs as
  # root: a fresh volume's root is root-owned, so a uid-1000 write would fail
  # with EACCES on ANY engine — persistence is the property under test (real
  # aidc pre-creates uid-1000-owned mount targets in its image instead).
  if root_exec vol-write 'printf aidcval > /persist/marker.txt' \
     && main down >"$LOGS/vol-down.log" 2>&1 \
     && main up -d --quiet-pull >"$LOGS/vol-up2.log" 2>&1 \
     && root_exec vol-read 'test "$(cat /persist/marker.txt)" = aidcval'; then
    report pass named-volume-persist "volume content survives down/up"
  else
    report fail named-volume-persist "named volume did not persist across down/up"
    log_tail vol-write; log_tail vol-read
  fi
else
  for dep in build-artifact bind-mount-rw bind-mount-ro external-volume-ro \
             init-true user-nonroot pids-limit mem-limit cpu-limit dev-shm \
             dns-egress compose-exec-tty named-volume-persist; do
    report fail "$dep" "not validated — main stack is not running"
  done
fi

# 13. Loopback port publish (opencode-web shape): reachable on 127.0.0.1 …
if run_log port-up docker compose -f "$WORK/port-compose.yaml" --project-name "$PROJ_PORT" up -d --quiet-pull; then
  BODY=""; i=0
  while [[ $i -lt 10 && -z "$BODY" ]]; do
    BODY="$(curl -s --noproxy '*' --max-time 3 "http://127.0.0.1:$PORT/" 2>/dev/null || true)"
    i=$((i + 1)); [[ -z "$BODY" ]] && sleep 1
  done
  if [[ "$BODY" == "aidcval" ]]; then
    report pass port-publish-loopback "127.0.0.1:$PORT reachable"
    # … and NOT reachable on a LAN address (the loopback-only contract).
    # Separate row: "no host IP found" is a SKIP (scope unverified), never a
    # silent pass — the opencode-web contract is loopback-ONLY.
    HOST_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
    if [[ -z "$HOST_IP" ]] && command -v hostname >/dev/null 2>&1; then
      # IPv4-filtered: an IPv6-first `hostname -I` listing would make curl
      # fail URL parsing (exit 3) — indistinguishable from a refusal — and
      # false-PASS this row.
      HOST_IP="$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$/) {print $i; exit}}' || true)"
    fi
    if [[ -z "$HOST_IP" ]]; then
      report skip port-lan-refused "no host IP discoverable — verify manually from another device"
    elif curl -s --noproxy '*' --max-time 3 "http://$HOST_IP:$PORT/" >/dev/null 2>&1; then
      report fail port-lan-refused "ALSO reachable on $HOST_IP — publish is not loopback-scoped!"
    else
      report pass port-lan-refused "$HOST_IP:$PORT correctly refused"
    fi
  else
    report fail port-publish-loopback "nothing served on 127.0.0.1:$PORT after ${i} attempts"
    report skip port-lan-refused "loopback unreachable — scoping moot"
    log_tail port-up
  fi
else
  report fail port-publish-loopback "port-publish compose up failed"
  report skip port-lan-refused "port stack not running"
  log_tail port-up
fi

# 14. cap_add NET_ADMIN/NET_RAW (egress-firewall override shape).
if run_log caps-up docker compose -f "$WORK/caps-compose.yaml" --project-name "$PROJ_CAPS" up -d --quiet-pull; then
  CAP="$(docker compose -f "$WORK/caps-compose.yaml" --project-name "$PROJ_CAPS" \
          exec -T workspace awk '/CapEff/{print $2}' /proc/self/status 2>"$LOGS/caps.log" || true)"
  CAP="$(printf '%s' "$CAP" | tr -d '[:space:]')"
  # NET_ADMIN is bit 12, NET_RAW bit 13.
  NA=$(( (0x${CAP:-0} >> 12) & 1 )); NR=$(( (0x${CAP:-0} >> 13) & 1 ))
  if [[ "$NA" == "1" && "$NR" == "1" ]]; then
    # Functional NET_ADMIN proof (informational — busybox ip may lack `link add`).
    if docker compose -f "$WORK/caps-compose.yaml" --project-name "$PROJ_CAPS" \
       exec -T workspace sh -c 'ip link add aidcval0 type dummy && ip link del aidcval0' >/dev/null 2>&1; then
      report pass cap-add-net "CapEff=$CAP (NET_ADMIN+NET_RAW); functional ip-link add/del ok"
    else
      report pass cap-add-net "CapEff=$CAP (NET_ADMIN+NET_RAW set); busybox 'ip link add' unavailable for a functional check"
    fi
  else
    report fail cap-add-net "CapEff=${CAP:-<none>} — NET_ADMIN(bit12)=$NA NET_RAW(bit13)=$NR"
  fi
else
  report fail cap-add-net "cap_add compose up failed"
  log_tail caps-up
fi

# 15. security_opt no-new-privileges (hardened-override shape).
if run_log nnp-up docker compose -f "$WORK/nnp-compose.yaml" --project-name "$PROJ_NNP" up -d --quiet-pull; then
  NNP="$(docker compose -f "$WORK/nnp-compose.yaml" --project-name "$PROJ_NNP" \
         exec -T workspace grep '^NoNewPrivs:' /proc/self/status 2>"$LOGS/nnp.log" || true)"
  if printf '%s' "$NNP" | grep -q 'NoNewPrivs:[[:space:]]*1'; then
    report pass security-opt-nnp "NoNewPrivs:1 in the container"
  else
    report fail security-opt-nnp "NoNewPrivs not 1 (${NNP:-<none>}) — security_opt ignored"
  fi
else
  report fail security-opt-nnp "security_opt compose up failed"
  log_tail nnp-up
fi

# ── Stage 2: aidc end-to-end (this checkout, scratch repo) ──────────────────

if [[ $SKIP_AIDC -eq 1 ]]; then
  printf '\naidc end-to-end: skipped (--skip-aidc)\n'
else
  printf '\naidc end-to-end (scratch repo; first up builds the shared base image — this can take minutes)\n'
  run_aidc() { AIDC_DOCKER_PROVIDER=apple "$AIDC_BIN" "$@" </dev/null >>"$LOGS/aidc.log" 2>&1 || return $?; }

  if run_aidc doctor; then
    report pass aidc-doctor "exit 0 (see logs/aidc.log; the experimental WARN is expected)"
  else
    report fail aidc-doctor "'aidc doctor' failed"
    tail -15 "$LOGS/aidc.log" 2>/dev/null | sed 's/^/        /'
  fi

  SCRATCH="$WORK/scratch"; mkdir -p "$SCRATCH"
  if git -C "$SCRATCH" init -q \
     && git -C "$SCRATCH" -c user.email=aidc@local -c user.name=aidc \
          commit -q --allow-empty -m "aidc validation scratch"; then
    if (cd "$SCRATCH" && run_aidc init); then
      SCRATCH_INITED=1
      report pass aidc-init "scaffold written in scratch repo"
    else
      report fail aidc-init "'aidc init' failed"
      tail -15 "$LOGS/aidc.log" 2>/dev/null | sed 's/^/        /'
    fi
  else
    report fail aidc-init "could not prepare scratch git repo"
  fi

  if (cd "$SCRATCH" && run_aidc up); then
    report pass aidc-up "container built + started (real aidc Dockerfile, volumes, mounts)"
  else
    report fail aidc-up "'aidc up' failed"
    tail -30 "$LOGS/aidc.log" 2>/dev/null | sed 's/^/        /'
  fi

  if (cd "$SCRATCH" && run_aidc exec -- sh -c \
       'test -d /workspace/.devcontainer && test -d /opt/CORE_LOGICS && test -d /host-seed/claude'); then
    report pass aidc-mounts "workspace/.devcontainer(ro)/CORE_LOGICS/host-seed mounts present"
  else
    report fail aidc-mounts "expected aidc mounts missing inside the container"
  fi

  if (cd "$SCRATCH" && run_aidc exec -- sh -c 'printf aidcval > /home/aidc/.claude/marker.txt') \
     && (cd "$SCRATCH" && run_aidc down) \
     && (cd "$SCRATCH" && run_aidc up) \
     && (cd "$SCRATCH" && run_aidc exec -- sh -c 'test "$(cat /home/aidc/.claude/marker.txt)" = aidcval'); then
    report pass aidc-volume-persist "claude_home volume survives aidc down/up"
  else
    report fail aidc-volume-persist "volume state lost across aidc down/up"
  fi

  if (cd "$SCRATCH" && run_aidc down) \
     && (cd "$SCRATCH" && run_aidc destroy -f --purge-scaffold); then
    SCRATCH_INITED=0   # teardown owned the cleanup; don't re-destroy in the trap
    report pass aidc-teardown "down + destroy clean"
  else
    report fail aidc-teardown "'aidc down'/'aidc destroy' failed"
  fi
fi

# ── Summary ─────────────────────────────────────────────────────────────────

printf '\nsummary: %d passed, %d failed, %d skipped\n' "$PASSES" "$FAILS" "$SKIPS"
printf 'paste the rows above into the matrix in docs/apple-container.md (or the follow-up issue).\n'
printf 'manual checklist (cannot be scripted):\n'
printf '  - cd into any aidc project; AIDC_DOCKER_PROVIDER unset or =apple\n'
printf '    aidc opencode   # interactive agent attach — TTY, prompt, file edit round-trip\n'
printf '  - aidc opencode-web   # then open http://127.0.0.1:4096/ in a host browser;\n'
printf '                       # also confirm it is NOT reachable from another device\n'
if [[ $FAILS -gt 0 ]]; then
  [[ $KEEP -eq 0 ]] && printf 'probe logs discarded (workdir removed); rerun with --keep to retain them\n'
  exit 1
fi
exit 0
