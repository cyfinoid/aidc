#!/usr/bin/env bash
#
# Probe Apple's native builder for the facts that decide how aidc-apple must
# build images (run on macOS 26 + Apple Silicon; needs `container`):
#
#   0. host pull   — can the HOST pull an image at all (registry + engine up)?
#   1. tiny build  — a ~50-byte Dockerfile builds (passes the header check and
#                    actually runs; hangs here = registry metadata from the
#                    builder VM is wedged, NOT a size problem).
#   2. FROM-local  — can a later build `FROM` a locally tagged image? (aidc's
#                    base→thin dependency; socktainer's builder cannot.)
#   3. size cap    — the REAL Dockerfile size ceiling. The CLI rejects ≥16384
#                    raw bytes with a clear error, but the Dockerfile ships
#                    base64-encoded in a gRPC header, so files under that
#                    check can still fail with "Stream unexpectedly closed"
#                    (apple/container#735). This ladder finds the practical max.
#
# Every step is time-boxed (default 120s; --timeout N): a wedged build
# reports HANG (with the tail of its log, which names the step) instead of
# sticking the whole probe.
#
# Usage: scripts/probe-apple-builder.sh [--timeout SECS] [--keep]
# Bash-3.2-safe (macOS has no `timeout(1)` — the wrapper below is pure bash).
set -euo pipefail

KEEP=0
STEP_TIMEOUT=120
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) STEP_TIMEOUT="$2"; shift 2 ;;
    --keep)    KEEP=1; shift ;;
    *) printf 'usage: probe-apple-builder.sh [--timeout SECS] [--keep]\n' >&2; exit 2 ;;
  esac
done
STAMP="$(date +%s)"
P="aidc-probe-$STAMP"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/aidc-bprobe.XXXXXX")"
cleanup() {
  local rc=$?
  trap - EXIT
  if [[ "$KEEP" != "1" ]]; then
    local t
    for t in "$P-tiny" "$P-fromlocal" "$P-ladder"; do
      container image delete "$t" >/dev/null 2>&1 || true
    done
    rm -rf "$TMP"
  fi
  return "$rc"
}
trap cleanup EXIT

pass=0; fail=0
res() { # res <pass|fail> <label>
  if [[ "$1" == "pass" ]]; then printf '  PASS  %s\n' "$2"; pass=$((pass+1))
  else printf '  FAIL  %s\n' "$2"; fail=$((fail+1)); fi
}
tail_log() { tail -4 "$1" 2>/dev/null | sed 's/^/        /'; }

# Time-boxed runner (rc 124 = timed out/HUNG). Output → <tag>.log.
# NB: rc is captured with the `|| rc=$?` idiom — `local rc=$?` after a
# failed `if` is a bash quirk that reads 0 (verified on 5.3; don't rely on
# it anywhere).
run_box() { # run_box <tag> <cmd...>
  local tag="$1"; shift
  "$@" >"$TMP/$tag.log" 2>&1 &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    waited=$((waited + 1))
    if [[ "$waited" -ge "$STEP_TIMEOUT" ]]; then
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
  done
  wait "$pid" 2>/dev/null || return $?
  return 0
}
build_box() { # build_box <tag> <tagname> <dockerfile>  → rc (124 = HANG)
  local tag="$1" name="$2" df="$3" rc=0
  printf '  ....  %s (up to %ss)\n' "$tag" "$STEP_TIMEOUT"
  run_box "$tag" container build -t "$name" -f "$df" "$TMP" || rc=$?
  if [[ "$rc" == "0" ]]; then
    if aidc_probe_image_present "$name"; then
      return 0
    fi
    printf '        (build exited 0 but %s not found in the store)\n' "$name"
    printf '        build log tail (where did the output go?):\n'
    tail_log "$TMP/$tag.log"
    printf '        store contents (name-format evidence):\n'
    container image list 2>/dev/null | head -5 | sed 's/^/          /'
    printf '        builder now: %s\n' "$(container builder status 2>/dev/null | tail -1 || echo '?')"
    return 1
  fi
  if [[ "$rc" == "124" ]]; then
    printf '  HANG  %s — timed out after %ss; log tail:\n' "$tag" "$STEP_TIMEOUT"
  else
    printf '  FAIL  %s (rc=%s); log tail:\n' "$tag" "$rc"
  fi
  tail_log "$TMP/$tag.log"
  return "$rc"
}

# Image-store presence, tolerant of the listing format for locally built
# images (name vs name:latest vs name:tag — normalize :latest both sides).
aidc_probe_image_present() {
  local want="$1"
  want="${want%:latest}"
  local listed
  while IFS= read -r listed; do
    [[ "${listed%:latest}" == "$want" ]] && return 0
  done < <(container image list --quiet 2>/dev/null)
  return 1
}

printf 'apple builder probe (timeouts %ss; gRPC-header cap + FROM-local)\n' "$STEP_TIMEOUT"
printf 'builder: %s\n\n' "$(container builder status 2>/dev/null | tail -1 || echo 'not running')"

# 0. Host-side pull (registry + engine sanity, no builder involved).
printf '  ....  host-side pull alpine:3.20 (up to %ss)\n' "$STEP_TIMEOUT"
pull_rc=0
run_box pull container image pull alpine:3.20 || pull_rc=$?
if [[ "$pull_rc" == "0" ]]; then
  res pass "host-side pull works (registry reachable from the host)"
elif [[ "$pull_rc" == "124" ]]; then
  res fail "host-side pull HUNG — engine networking wedged; try: container system stop && container system start"
  tail_log "$TMP/pull.log"
else
  res fail "host-side pull failed; log tail:"
  tail_log "$TMP/pull.log"
fi

# 1. Tiny build — exercises the header check AND the registry resolve from
#    the builder VM. A hang here is a builder-network problem, not size.
printf 'FROM alpine:3.20\nRUN printf probe > /probe-marker\n' >"$TMP/tiny"
if build_box tiny "$P-tiny" "$TMP/tiny"; then
  res pass "tiny build works (header ok; builder can resolve/pull alpine)"
else
  res fail "tiny build — if the log tail shows 'load metadata for docker.io/…' the BUILDER VM cannot reach the registry (reset: container builder stop && container builder delete --force, then container system stop/start)"
  printf '\nsummary: the builder cannot build anything until this passes; size/FROM-local are moot\n'
  exit 1
fi

# 2. FROM-local: base the next build on the locally tagged tiny image.
printf 'FROM %s\nRUN cat /probe-marker >/dev/null && cp /probe-marker /probe2\n' "$P-tiny" >"$TMP/fromlocal"
FROMLOCAL=0
if build_box fromlocal "$P-fromlocal" "$TMP/fromlocal"; then
  res pass "FROM <local tag> resolves — aidc's base→thin scheme is viable natively"
  FROMLOCAL=1
else
  res fail "FROM <local tag> does NOT resolve — multi-file image layering impossible; aidc needs single-file builds"
fi

# 3. Size ladder: NON-comment bytes only (every byte load-bearing).
printf 'size ladder (raw non-comment bytes → build result, %ss each):\n' "$STEP_TIMEOUT"
max_ok=0
for size in 8000 10000 12000 14000 16000 17000; do
  {
    printf 'FROM alpine:3.20\n'
    n=$(( (size - 20) / 99 ))
    i=0
    while [[ $i -lt $n ]]; do printf 'RUN printf %%s > /dev/null # padding-line-%04d-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' "$i"; i=$((i+1)); done
  } >"$TMP/s$size"
  actual="$(wc -c <"$TMP/s$size" | tr -d ' ')"
  ladder_rc=0
  run_box "ladder" container build -t "$P-ladder" -f "$TMP/s$size" "$TMP" || ladder_rc=$?
  if [[ "$ladder_rc" == "0" ]]; then
    printf '  ok    %6d bytes\n' "$actual"
    max_ok="$actual"
    container image delete "$P-ladder" >/dev/null 2>&1 || true
  elif [[ "$ladder_rc" == "124" ]]; then
    printf '  HANG  %6d bytes — builder wedged at this size; stopping the ladder\n' "$actual"
    tail_log "$TMP/ladder.log"
    break
  else
    printf '  FAIL  %6d bytes\n' "$actual"
  fi
done
if [[ "$max_ok" != "0" ]]; then
  res pass "largest passing Dockerfile: ${max_ok} raw bytes (base64 ≈ $(( max_ok * 4 / 3 )) header bytes)"
else
  res fail "even the 8K ladder file failed — see the lines above"
fi

printf '\nsummary: %d passed, %d failed; FROM-local=%s; max-ok=%s bytes\n' \
  "$pass" "$fail" "$FROMLOCAL" "${max_ok:-none}"
printf 'paste this into docs/aidc-apple.md (known-gaps #1/#2) or the follow-up issue.\n'
