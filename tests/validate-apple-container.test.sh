#!/usr/bin/env bash
#
# Unit tests for scripts/validate-apple-container.sh (hermetic).
#
# The validator's job is to drive a real Docker API through socktainer, which
# no unit test can do. What these tests cover instead is the script's own
# logic: prerequisite gating, each probe's pass/fail/skip decision, exit-code
# accounting, flag handling, and DOCKER_HOST precedence. The engine is a stub
# `docker` on PATH whose behavior is steered by VAL_* env knobs (same approach
# as the curl stub in update-pins.test.sh); a real unix socket is bound with
# python3 (same trick as docker-provider.test.sh — cases needing it are
# skipped when python3 is absent, e.g. inside bash-compat images).
#
# Run with: bash tests/validate-apple-container.test.sh
# shellcheck disable=SC2034,SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATOR="$REPO_ROOT/scripts/validate-apple-container.sh"

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
STUB_DIR="$TMP_ROOT/bin"; mkdir -p "$STUB_DIR"
STATE="$TMP_ROOT/state"; mkdir -p "$STATE"

# Curated coreutils PATH: the validator must run against ONLY the stubs + the
# neutral tools it needs. Including /usr/bin would leak the host's docker/curl
# (CI runners have docker preinstalled) and break the absence tests.
CORE_BIN="$TMP_ROOT/corebin"; mkdir -p "$CORE_BIN"
for t in bash env mktemp mkdir rm chmod date sed tail cat tr cut head grep \
         sleep dirname hostname awk; do
  p="$(command -v "$t" 2>/dev/null || true)"
  [[ -n "$p" ]] && ln -sf "$p" "$CORE_BIN/$t"
done

# Real unix socket for the socktainer-socket prereq (python3 when available).
SOCK="$TMP_ROOT/container.sock"
HAVE_PY=0
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$SOCK" 2>/dev/null && HAVE_PY=1
fi

# ── stubs ───────────────────────────────────────────────────────────────────

cat >"$STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
# docker stub for validate-apple-container tests. VAL_* knobs:
#   VAL_API_FAIL        docker info fails
#   VAL_NO_COMPOSE      compose plugin missing
#   VAL_BUILD_FAIL      docker build fails
#   VAL_UP_FAIL         compose up fails
#   VAL_VOLCREATE_FAIL  volume create fails
#   VAL_DROP_VOL        compose up wipes named-volume state (persist bug)
#   VAL_MARKER_MISSING  multi-stage artifact missing
#   VAL_RO_WRITABLE    ro bind accepts writes (should not)
#   VAL_EXT_MISSING    /ext not mounted
#   VAL_EXT_WRITABLE   external ro volume accepts writes (should not)
#   VAL_P1COMM         PID 1 comm           (default docker-init)
#   VAL_IDU            id -u                (default 1000)
#   VAL_PIDSMAX        pids.max             (default 128; explicit empty = read fails)
#   VAL_MEMMAX         memory.max           (default 268435456; explicit empty = read fails)
#   VAL_CPUMAX         cpu.max              (default "150000 100000"; explicit empty = read fails)
#   VAL_PIDS_INSP / VAL_MEM_INSP / VAL_CPU_INSP   docker inspect values
#   VAL_SHM_FAIL       /dev/shm probe fails
#   VAL_NET_FAIL       nslookup/wget fail
#   VAL_TTY_OK         tty exec prints tty-ok
#   VAL_CAP            CapEff hex           (default has NET_ADMIN+NET_RAW)
#   VAL_IP_LINK_FAIL   functional ip link add fails (informational only)
#   VAL_NNP            NoNewPrivs line      (default "NoNewPrivs:    1")
state="${VAL_STATE:?}"

if [[ "$1" == "compose" ]]; then
  shift
  # Scan the whole arg list: subcommand = first of the known tokens, -f VALUE
  # gives the compose dir (exec probes map container paths to its fixtures).
  sub=""; fdir=""
  prev=""
  for a in "$@"; do
    [[ "$prev" == "-f" ]] && fdir="$(dirname "$a")"
    prev="$a"
    case "$a" in
      version|up|down|ps|exec) [[ -z "$sub" ]] && sub="$a" ;;
    esac
  done
  case "$sub" in
    version) [[ -n "${VAL_NO_COMPOSE:-}" ]] && exit 1
             echo "Docker Compose version v2.30.0-val"; exit 0 ;;
    up)      [[ -n "${VAL_UP_FAIL:-}" ]] && exit 1
             [[ -n "${VAL_DROP_VOL:-}" ]] && rm -f "$state/marker"
             exit 0 ;;
    down)    # -v drops volumes (clears state); a plain `down` must keep them.
             # Token-match -v: the validator's workdir path contains "aidc-val"
             # so a substring test would wipe state on every plain `down` too.
             vflag=0
             for a in "$@"; do [[ "$a" == "-v" ]] && vflag=1; done
             if [[ "$vflag" == "1" ]]; then rm -rf "$state"; mkdir -p "$state"; fi
             exit 0 ;;
    ps)      for a in "$@"; do [[ "$a" == "-q" ]] && { echo abc123val; exit 0; } done
             exit 0 ;;
    exec)
      rest=(); found=0
      for a in "$@"; do
        [[ "$a" == "exec" ]] && { found=1; continue; }
        [[ "$found" == "1" ]] && rest+=("$a")
      done
      # Drop flags + the service name; `-u <uid>` also swallows its value.
      cmd=(); skip_next=0
      for a in "${rest[@]}"; do
        if [[ "$skip_next" == "1" ]]; then skip_next=0; continue; fi
        case "$a" in
          -u) skip_next=1; continue ;;
          -T) continue ;;
          workspace) continue ;;
        esac
        cmd+=("$a")
      done
      if [[ "${cmd[0]}" == "awk" ]];  then printf '%s\n' "${VAL_CAP:-00000000a80435fb}"; exit 0; fi
      if [[ "${cmd[0]}" == "grep" ]]; then printf '%s\n' "${VAL_NNP:-NoNewPrivs:    1}"; exit 0; fi
      code="${cmd[2]}"   # sh -c '<code>'
      case "$code" in
        'test -f /probe-marker && printf aidcval')
          [[ -n "${VAL_MARKER_MISSING:-}" ]] && exit 1; printf 'aidcval' ;;
        'printf aidcval > /workspace/from-container.txt')
          [[ -n "${VAL_BINDRW_FAIL:-}" ]] && exit 1
          printf 'aidcval' >"$fdir/ws/from-container.txt" ;;
        'test "$(cat /workspace/from-host.txt)" = from-host')
          [[ "$(cat "$fdir/ws/from-host.txt" 2>/dev/null)" == "from-host" ]] ;;
        'touch /ro-dir/x 2>/dev/null')   [[ -n "${VAL_RO_WRITABLE:-}" ]] ;;
        'test -d /ext')                  [[ -z "${VAL_EXT_MISSING:-}" ]] ;;
        'touch /ext/x 2>/dev/null')      [[ -n "${VAL_EXT_WRITABLE:-}" ]] ;;
        'cat /proc/1/comm')              printf '%s\n' "${VAL_P1COMM:-docker-init}" ;;
        'id -u')                         printf '%s\n' "${VAL_IDU:-1000}" ;;
        'cat /sys/fs/cgroup/pids.max')
          v="${VAL_PIDSMAX-128}";    [[ -n "$v" ]] && printf '%s\n' "$v" || exit 1 ;;
        'cat /sys/fs/cgroup/memory.max')
          v="${VAL_MEMMAX-268435456}"; [[ -n "$v" ]] && printf '%s\n' "$v" || exit 1 ;;
        'cat /sys/fs/cgroup/cpu.max')
          v="${VAL_CPUMAX-150000 100000}"; [[ -n "$v" ]] && printf '%s\n' "$v" || exit 1 ;;
        dd*)                             [[ -z "${VAL_SHM_FAIL:-}" ]] ;;
        nslookup*)                       [[ -z "${VAL_NET_FAIL:-}" ]] ;;
        wget*)                           [[ -z "${VAL_NET_FAIL:-}" ]] ;;
        '[ -t 0 ] && [ -t 1 ] && printf tty-ok')
          [[ "${VAL_TTY_OK:-0}" == "1" ]] && printf 'tty-ok' ;;
        'ip link add aidcval0 type dummy && ip link del aidcval0')
          [[ -z "${VAL_IP_LINK_FAIL:-}" ]] ;;
        'printf aidcval > /persist/marker.txt')   printf 'aidcval' >"$state/marker" ;;
        'test "$(cat /persist/marker.txt)" = aidcval')
          [[ "$(cat "$state/marker" 2>/dev/null)" == "aidcval" ]] ;;
        *) echo "docker-stub: unhandled exec code: $code" >&2; exit 64 ;;
      esac
      exit $? ;;
    *) echo "docker-stub: unhandled compose subcommand: $sub ($*)" >&2; exit 64 ;;
  esac
fi

case "$1" in
  --version) echo "Docker version 27.0.0-val, build stub"; exit 0 ;;
  info)
    [[ -n "${VAL_API_FAIL:-}" ]] && exit 1
    if [[ "$2" == "--format" ]]; then echo "27.0.0-val"; fi
    exit 0 ;;
  build)
    # Build-driver simulation knobs (in addition to VAL_BUILD_FAIL):
    #   VAL_BUILD_NOLOAD   plain build exits 0 but does NOT load into the
    #                      store (docker-container driver signature); --load does.
    #   VAL_LOAD_FAIL      the --load build fails outright.
    #   VAL_FROMLOCAL_FAIL a build whose -f is Dockerfile.fromlocal fails.
    [[ -z "${VAL_BUILD_FAIL:-}" ]] || exit 1
    a_prev=""; btag=""; saw_load=0; bdf=""
    for a in "$@"; do
      if [[ "$a_prev" == "-t" ]]; then btag="$a"; a_prev="$a"; continue; fi
      if [[ "$a_prev" == "-f" ]]; then bdf="$a"; a_prev="$a"; continue; fi
      case "$a" in
        -t|-f) a_prev="$a" ;;
        --load) saw_load=1 ;;
        *) a_prev="$a" ;;
      esac
    done
    [ -n "$btag" ] || exit 0
    if [[ "$bdf" == *Dockerfile.fromlocal* ]]; then
      [ -z "${VAL_FROMLOCAL_FAIL:-}" ] || exit 1
    elif [ "$saw_load" = "1" ]; then
      [ -z "${VAL_LOAD_FAIL:-}" ] || exit 1
    else
      if [ -n "${VAL_BUILD_NOLOAD:-}" ]; then
        # Emit the real docker-container-driver warning: the script's FAIL
        # detail keys on it (built-but-not-loaded vs plain failure).
        echo "WARNING: No output specified with docker-container driver. Build result will only remain in the build cache." >&2
        exit 0
      fi
    fi
    echo "$btag" >>"$state/images"; exit 0 ;;
  images)
    # `images -q <tag>`: prints the tag iff it is in the store (state file) —
    # the build rows key on real store presence, not a constant.
    [ "$2" = "-q" ] || exit 0
    grep -x "$3" "$state/images" 2>/dev/null; exit 0 ;;
  volume) if [[ "$2" == "create" ]]; then
            [[ -n "${VAL_VOLCREATE_FAIL:-}" ]] && exit 1
            # Record the requested name NEXT TO the state dir (not inside):
            # the compose `down -v` arm wipes $state wholesale (its runtime-
            # state simulation), and the validator's cleanup runs `down -v`
            # — an in-state log would be deleted before the suite reads it.
            echo "create $3" >>"$state.volcreates"
            echo "$3"
          fi
          exit 0 ;;
  inspect)
    [[ -n "${VAL_API_FAIL:-}" ]] && exit 1
    case "$3" in
      *PidsLimit*) echo "${VAL_PIDS_INSP:-128}" ;;
      *Memory*)    echo "${VAL_MEM_INSP:-268435456}" ;;
      *NanoCpus*)  echo "${VAL_CPU_INSP:-1500000000}" ;;
      *)           echo "0" ;;
    esac
    exit 0 ;;
  rmi) exit 0 ;;
  *) echo "docker-stub: unhandled: $*" >&2; exit 64 ;;
esac
STUB
chmod +x "$STUB_DIR/docker"

make_container_stub() {
  cat >"$STUB_DIR/container" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --version) echo "container 1.2.3-val" ;;
  system)    [[ -z "${VAL_CONTAINER_SYS_FAIL:-}" ]] ;;
  *)         exit 0 ;;
esac
STUB
  chmod +x "$STUB_DIR/container"
}
make_container_stub

make_curl_stub() {
  cat >"$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
url=""
for a in "$@"; do
  case "$a" in
    --version) echo "curl 8.0.0-val (stub)"; exit 0 ;;
    http*)     url="$a" ;;
  esac
done
if [[ "$url" == *127.0.0.1* ]]; then
  if [[ "${VAL_CURL_LOOP_OK:-1}" == "1" ]]; then printf 'aidcval'; exit 0; fi
  exit 7
fi
[[ "${VAL_CURL_LAN_OK:-0}" == "1" ]] && exit 0   # LAN reachable = scoping bug
exit 7
STUB
  chmod +x "$STUB_DIR/curl"
}
make_curl_stub

STUB_PATH="$STUB_DIR:$CORE_BIN"

# Run the validator (engine stage only) with stubs; captures output + rc.
# `env -u DOCKER_HOST` keeps a developer's exported DOCKER_HOST from steering
# the validator (its "explicit DOCKER_HOST wins" path is tested explicitly).
# `${env_args[@]+"${env_args[@]}"}` guards the empty-array expansion — the
# suite must run on macOS system bash 3.2 where it aborts under `set -u`.
run_val() { # run_val [PATH=...] [VAR=val...] -- [validator args...]
  local use_path="$STUB_PATH" env_args=() out rc=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      PATH=*)  use_path="${1#PATH=}"; shift ;;
      --)      shift; break ;;
      *=*)     env_args+=("$1"); shift ;;
      *)       break ;;
    esac
  done
  out="$(env -u DOCKER_HOST PATH="$use_path" AIDC_APPLE_CONTAINER_SOCKET="$SOCK" \
         VAL_STATE="$STATE" ${env_args[@]+"${env_args[@]}"} \
         "$VALIDATOR" --skip-aidc "$@" </dev/null 2>&1)" || rc=$?
  LAST_OUT="$out"; LAST_RC="$rc"
}

has_row() { # has_row <status> <row>
  printf '%s' "$LAST_OUT" | grep -Eq "^[[:space:]]*$1[[:space:]]+$2([[:space:]]|\$)"
}

# ── 1. usage errors ──────────────────────────────────────────────────────────
run_val --bogus
[[ "$LAST_RC" == "2" ]] && ok "unknown flag → exit 2" || fail "bogus flag rc=$LAST_RC"
LAST_OUT="$(PATH="$STUB_PATH" "$VALIDATOR" --help 2>&1)" || true
if printf '%s' "$LAST_OUT" | grep -q -- '--skip-aidc'; then
  ok "--help prints usage"
else
  fail "--help output: $LAST_OUT"
fi

# ── 2. prerequisite gating ───────────────────────────────────────────────────
# Each missing/broken piece aborts BEFORE any engine probe runs. The PATH is
# the curated stub+coreutils set, so "docker missing" really means missing —
# the host's /usr/bin/docker (present on CI runners) never leaks in.
run_val "PATH=$CORE_BIN"
if has_row FAIL docker-cli && [[ "$LAST_RC" == "1" ]]; then
  ok "missing docker CLI → FAIL row + exit 1"
else
  fail "docker-cli gating: rc=$LAST_RC out=$LAST_OUT"
fi

if [[ $HAVE_PY -eq 1 ]]; then
  run_val VAL_NO_COMPOSE=1
  has_row FAIL compose-plugin && ok "missing compose plugin → FAIL row" || fail "compose gating: $LAST_OUT"

  # container CLI absent: stub everything EXCEPT container.
  rm -f "$STUB_DIR/container"
  run_val
  has_row FAIL container-cli && ok "missing container CLI → FAIL row" || fail "container-cli gating: $LAST_OUT"
  make_container_stub

  run_val "AIDC_APPLE_CONTAINER_SOCKET=$TMP_ROOT/no-such.sock" --socket "$TMP_ROOT/no-such.sock"
  has_row FAIL socktainer-socket && ok "missing socket → FAIL row" || fail "socket gating: $LAST_OUT"

  run_val VAL_API_FAIL=1
  if has_row FAIL docker-api && [[ "$LAST_RC" == "1" ]]; then
    ok "dead API → FAIL row + exit 1"
  else
    fail "api gating: rc=$LAST_RC out=$LAST_OUT"
  fi
  if printf '%s' "$LAST_OUT" | grep -q 'engine probes'; then
    fail "engine probes ran despite dead API"
  else
    ok "engine probes skipped when API dead"
  fi

  # curl absent (port-probe tool): gating FAIL, engine probes never run.
  rm -f "$STUB_DIR/curl"
  run_val
  if has_row FAIL curl-cli && [[ "$LAST_RC" == "1" ]] \
     && ! printf '%s' "$LAST_OUT" | grep -q 'engine probes'; then
    ok "missing curl → FAIL row + exit 1, probes skipped"
  else
    fail "curl gating: rc=$LAST_RC out=$LAST_OUT"
  fi
  make_curl_stub
else
  ok "prereq gating (compose/socket/api/curl) skipped (no python3)"
fi

# ── 3. happy path (stubs all green) ─────────────────────────────────────────
if [[ $HAVE_PY -eq 1 ]]; then
  run_val
  if [[ "$LAST_RC" == "0" ]] \
     && has_row PASS docker-build && has_row PASS docker-build-load \
     && has_row PASS build-from-local && has_row PASS build-artifact \
     && has_row PASS bind-mount-rw && has_row PASS bind-mount-ro \
     && has_row PASS external-volume-ro && has_row PASS init-true \
     && has_row PASS user-nonroot && has_row PASS pids-limit \
     && has_row PASS mem-limit && has_row PASS cpu-limit \
     && has_row PASS dev-shm && has_row PASS dns-egress \
     && has_row PASS named-volume-persist \
     && has_row PASS port-publish-loopback && has_row PASS cap-add-net \
     && has_row PASS security-opt-nnp \
     && printf '%s' "$LAST_OUT" | grep -Eq '^[[:space:]]*(PASS|SKIP)[[:space:]]+port-lan-refused' \
     && has_row SKIP compose-exec-tty \
     && printf '%s' "$LAST_OUT" | grep -q 'summary: .* 0 failed' \
     && printf '%s' "$LAST_OUT" | grep -q 'skipped (--skip-aidc)' \
     && ! printf '%s' "$LAST_OUT" | grep -q 'aidc-doctor'; then
    ok "happy path: all engine rows PASS, tty SKIP, aidc stage skipped, exit 0"
  else
    fail "happy path rc=$LAST_RC out=$LAST_OUT"
  fi

  run_val VAL_TTY_OK=1 AIDC_VAL_FORCE_TTY=1
  has_row PASS compose-exec-tty && ok "forced-tty happy → tty row PASS" || fail "tty pass: $LAST_OUT"

  run_val VAL_TTY_OK=0 AIDC_VAL_FORCE_TTY=1
  if has_row FAIL compose-exec-tty && [[ "$LAST_RC" == "1" ]]; then
    ok "broken TTY exec → FAIL + exit 1"
  else
    fail "tty fail: rc=$LAST_RC out=$LAST_OUT"
  fi

  # Socket auto-detection (Homebrew service path): with no explicit socket
  # env, the first EXISTING candidate is used. The empty override disables
  # run_val's explicit env so the resolver runs.
  run_val "AIDC_APPLE_CONTAINER_SOCKET=" "AIDC_APPLE_CONTAINER_SOCKET_CANDIDATES=$TMP_ROOT/missing.sock:$SOCK"
  if printf '%s' "$LAST_OUT" | grep -q "socket present: $SOCK" && [[ "$LAST_RC" == "0" ]]; then
    ok "socket candidates: brew-style path auto-detected when first is absent"
  else
    fail "candidates: $(printf '%s' "$LAST_OUT" | grep -i socktainer)"
  fi
else
  ok "happy path skipped (no python3)"
fi

# ── 4. per-probe failure injection (each knob → exactly that row FAIL) ──────
if [[ $HAVE_PY -eq 1 ]]; then
  check_fail() { # check_fail <row> <ENV=VAL>...
    local row="$1"; shift
    run_val "$@"
    if has_row FAIL "$row" && [[ "$LAST_RC" == "1" ]]; then
      ok "knob $* → $row FAIL"
    else
      fail "$row injection: rc=$LAST_RC rows=$(printf '%s' "$LAST_OUT" | grep FAIL | tr '\n' ';')"
    fi
  }
  check_fail docker-build          VAL_BUILD_FAIL=1
  check_fail build-artifact        VAL_MARKER_MISSING=1
  check_fail bind-mount-rw         VAL_BINDRW_FAIL=1
  check_fail bind-mount-ro         VAL_RO_WRITABLE=1
  check_fail external-volume-ro    VAL_EXT_WRITABLE=1
  check_fail external-volume-ro    VAL_EXT_MISSING=1
  check_fail init-true             VAL_P1COMM=sleep
  check_fail user-nonroot          VAL_IDU=0
  check_fail pids-limit            VAL_PIDSMAX=max VAL_PIDS_INSP=0
  check_fail mem-limit             VAL_MEMMAX= VAL_MEM_INSP=0
  check_fail cpu-limit             VAL_CPUMAX= VAL_CPU_INSP=0
  check_fail dev-shm               VAL_SHM_FAIL=1
  check_fail dns-egress            VAL_NET_FAIL=1
  check_fail named-volume-persist  VAL_DROP_VOL=1
  check_fail cap-add-net           VAL_CAP=00000000a80425fb
  check_fail security-opt-nnp      VAL_NNP='NoNewPrivs:    0'
  check_fail port-publish-loopback VAL_CURL_LOOP_OK=0
  check_fail compose-up            VAL_UP_FAIL=1
  check_fail compose-up            VAL_VOLCREATE_FAIL=1

  # Build-driver semantics (the socktainer hardware finding): plain build not
  # loaded into the store, --load works, FROM-local resolves → stacks must
  # fall back to the --load-built image and the FAIL detail must name the driver.
  run_val VAL_BUILD_NOLOAD=1
  if has_row FAIL docker-build \
     && printf '%s' "$LAST_OUT" | grep -q 'docker-container BuildKit driver' \
     && has_row PASS docker-build-load && has_row PASS build-from-local \
     && has_row PASS compose-up && [[ "$LAST_RC" == "1" ]]; then
    ok "socktainer sim: plain build not loaded → actionable FAIL; --load + FROM-local carry the stacks"
  else
    fail "noload sim: rc=$LAST_RC $(printf '%s' "$LAST_OUT" | grep -E 'docker-build|build-from-local|compose-up' | head -4 | tr '\n' ';')"
  fi

  run_val VAL_LOAD_FAIL=1
  if has_row FAIL docker-build-load && has_row PASS build-from-local && has_row PASS compose-up; then
    ok "--load unsupported: row reports it; stacks run the plain-built image"
  else
    fail "load-fail sim: $(printf '%s' "$LAST_OUT" | grep -E 'docker-build-load|build-from-local|compose-up' | head -3 | tr '\n' ';')"
  fi

  run_val VAL_FROMLOCAL_FAIL=1
  if has_row FAIL build-from-local && printf '%s' "$LAST_OUT" | grep -q 'CANNOT work' \
     && has_row PASS compose-up; then
    ok "FROM-local broken: row says the aidc base→thin scheme cannot work via this shim"
  else
    fail "fromlocal-fail sim: $(printf '%s' "$LAST_OUT" | grep -E 'build-from-local|compose-up' | head -3 | tr '\n' ';')"
  fi

  # YAML seam (AIDC_VAL_WORKDIR): inspect the generated probe files — the
  # port command must be a quoted flow sequence; a plain scalar with ': '
  # broke a real compose parser (v1 hardware finding). Also pin the external
  # volume name to the compose declaration: `external: true` references the
  # literal name, and a drift (v1: aidcval-ext-vol vs aidcval_ext) only
  # surfaces on a real engine once the image resolves.
  WDDIR="$TMP_ROOT/wd"
  run_val "AIDC_VAL_WORKDIR=$WDDIR"
  if [[ "$LAST_RC" == "0" ]] \
     && grep -q 'command: \["sh", "-c",' "$WDDIR/port-compose.yaml" \
     && ! grep -q 'command: sh -c' "$WDDIR/port-compose.yaml" \
     && grep -q 'image: aidc-val-probe:' "$WDDIR/main/compose.yaml" \
     && grep -q '^  aidcval_ext:$' "$WDDIR/main/compose.yaml" \
     && grep -q 'aidcval_ext' "$STATE.volcreates"; then
    ok "generated YAML + external volume name pinned to the compose declaration"
  else
    fail "yaml seam: rc=$LAST_RC ext=$(grep aidcval_ext "$WDDIR/main/compose.yaml" 2>/dev/null | head -1) created=$(tail -1 "$STATE.volcreates" 2>/dev/null)"
  fi

  # Inspect-only path: cgroup read fails but inspect carries the row (the OR
  # is deliberate — enforcement via shim with imperfect reporting still passes,
  # and the detail string records both values for the matrix).
  run_val VAL_PIDSMAX=
  if has_row PASS pids-limit && printf '%s' "$LAST_OUT" | grep -q "pids-limit.*inspect='128'" \
     && [[ "$LAST_RC" == "0" ]]; then
    ok "pids-limit passes via inspect when cgroup read fails (detail keeps both)"
  else
    fail "pids inspect fallback: rc=$LAST_RC $(printf '%s' "$LAST_OUT" | grep pids-limit)"
  fi

  # Stack-down cascade: compose-up failure marks every dependent row FAIL.
  run_val VAL_UP_FAIL=1
  if printf '%s' "$LAST_OUT" | grep -q 'not validated'; then
    ok "stack-down cascade reports dependent rows"
  else
    fail "cascade missing: $LAST_OUT"
  fi

  # LAN reachability: published port answerable on a non-loopback address must
  # FAIL the scoping row (only meaningful where hostname -I yields an IPv4).
  # `|| true` guards the pipe: BSD/macOS hostname has no -I (exit 1) and would
  # abort the suite under set -e -o pipefail. IPv4-filtered: an IPv6-first
  # listing would make curl fail URL *parsing* (exit 3) — indistinguishable
  # from a refusal — and false-PASS the row.
  LAN_IP="$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$/) {print $i; exit}}' || true)"
  if [[ -n "$LAN_IP" ]]; then
    check_fail port-lan-refused VAL_CURL_LAN_OK=1
  else
    ok "LAN-scoping injection skipped (hostname -I empty)"
  fi

  # Functional ip-link check is informational: bits set but ip fails → PASS.
  run_val VAL_IP_LINK_FAIL=1
  if has_row PASS cap-add-net && [[ "$LAST_RC" == "0" ]]; then
    ok "cap bits set + ip link unavailable → still PASS (informational)"
  else
    fail "ip-link informational: rc=$LAST_RC out=$LAST_OUT"
  fi

  # DOCKER_HOST precedence: preset value wins, --socket ignored.
  run_val "VAL_STATE=$STATE" DOCKER_HOST=tcp://9.9.9.9:1 --socket /nonexistent.sock
  if printf '%s' "$LAST_OUT" | grep -q 'honored verbatim' && [[ "$LAST_RC" == "0" ]]; then
    ok "explicit DOCKER_HOST honored, --socket ignored"
  else
    fail "DOCKER_HOST precedence: rc=$LAST_RC out=$LAST_OUT"
  fi

  # --socket flag: explicit path passes the socket prereq despite the env var
  # pointing elsewhere.
  run_val "AIDC_APPLE_CONTAINER_SOCKET=$TMP_ROOT/other.sock" --socket "$SOCK"
  if printf '%s' "$LAST_OUT" | grep -q "socket present: $SOCK" && [[ "$LAST_RC" == "0" ]]; then
    ok "--socket flag overrides AIDC_APPLE_CONTAINER_SOCKET"
  else
    fail "--socket flag: rc=$LAST_RC $(printf '%s' "$LAST_OUT" | grep -i socktainer)"
  fi
else
  ok "failure-injection suite skipped (no python3)"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
