#!/usr/bin/env bash
#
# Unit tests for 'aidc clean' (stale-image GC, remaster branch).
#
# Hermetic: aidc::clean_docker (the only docker entry point in clean.sh) is
# overridden with a fixture that replays canned `docker` outputs and records
# every mutating call. aidc::toolchain_image_tag is overridden with fixed
# current-hash tags so the test doesn't depend on the real template contents.
#
# Run with: bash tests/clean.test.sh
# shellcheck disable=SC2034,SC1090,SC1091,SC2317
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Stub `docker` on PATH: cmd_clean probes `command -v docker` and must not
# fail on hosts without docker (and must not touch a real daemon anywhere).
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT
printf '#!/usr/bin/env bash\necho "stub docker: unexpected call: $*" >&2\nexit 1\n' >"$STUB_DIR/docker"
chmod +x "$STUB_DIR/docker"
export PATH="$STUB_DIR:$PATH"

. "$REPO_ROOT/lib/aidc.sh"

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

# ── fixture machinery ─────────────────────────────────────────────────────────
CLEAN_CALLS=""          # every mutating docker invocation, space-joined
RMI_FAIL_REFS=" "       # refs that should fail to remove
CLEAN_LS_ROWS=""        # rows for `image ls --format ...`
CLEAN_INSPECT_ROWS=""   # rows for `image inspect --format ...`
CLEAN_DANGLING=""       # ids for `image ls -f dangling=true -q`

aidc::clean_docker() {
  case "$1 $2" in
    "image ls")
      if [[ "${3:-}" == "-f" ]]; then
        printf '%b\n' "$CLEAN_DANGLING"
      else
        printf '%b\n' "$CLEAN_LS_ROWS"
      fi
      ;;
    "image inspect")
      printf '%b\n' "$CLEAN_INSPECT_ROWS"
      ;;
    "system df")
      printf 'Images|5|12.4GB|8GB (64%%)\nContainers|2|1MB|0B (0%%)\n'
      ;;
    "rmi -f")
      local target="${3:-}"
      CLEAN_CALLS+=" rmi:$target"
      if [[ "$RMI_FAIL_REFS" == *" $target "* ]]; then
        return 1
      fi
      ;;
    "image prune")
      CLEAN_CALLS+=" prune-dangling"
      ;;
    "builder prune")
      CLEAN_CALLS+=" prune-cache"
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

# Fixed "current" toolchain store tags, independent of the real templates.
aidc::toolchain_image_tag() {
  printf 'aidc-toolchain-store-%s:111100000001' "$1"
}

# Standard fixture: two bases (one referenced by a thin image, one stale),
# a custom unhashed base (never aidc-owned), a current + a stale toolchain
# store, an unrelated image, and one dangling id.
load_fixture() {
  CLEAN_LS_ROWS="aidc-base:aaaaaaaaaaaa|idbase1|2.84GB\
\naidc-base:bbbbbbbbbbbb|idbase2|2.9GB\
\naidc-base:custom|idcustom|2.5GB\
\naidc-toolchain-store-go:111100000001|idtgo|1.1GB\
\naidc-toolchain-store-go:222200000002|idtgoold|1.0GB\
\nubuntu:24.04|idubuntu|78MB\
\n<none>:<none>|iddangling|2.9GB"
  CLEAN_INSPECT_ROWS="idbase1|aidc-base:aaaaaaaaaaaa\
\nidbase2|\
\nidcustom|\
\nidtgo|\
\nidtgoold|\
\nidubuntu|"
  CLEAN_DANGLING="iddangling"
  CLEAN_CALLS=""
  RMI_FAIL_REFS=" "
}

# ── 1. dry run lists only unreferenced hashed bases + stale stores ───────────
load_fixture
out="$(aidc::cmd_clean 2>&1)"
if printf '%s' "$out" | grep -q 'aidc-base:bbbbbbbbbbbb' \
  && printf '%s' "$out" | grep -q 'aidc-toolchain-store-go:222200000002'; then
  ok "dry run lists stale base and stale toolchain store"
else
  fail "dry run output missing stale refs:\n$out"
fi
if printf '%s' "$out" | grep -q 'aidc-base:aaaaaaaaaaaa' \
  || printf '%s' "$out" | grep -q 'aidc-base:custom' \
  || printf '%s' "$out" | grep -q '111100000001'; then
  fail "dry run listed a referenced/custom/current image:\n$out"
else
  ok "dry run keeps referenced base, custom tag, current store"
fi
if [[ -z "$CLEAN_CALLS" ]]; then
  ok "dry run issues no mutating docker calls"
else
  fail "dry run mutated docker state:$CLEAN_CALLS"
fi
printf '%s' "$out" | grep -q 'dry run' \
  && ok "dry run announces itself" \
  || fail "dry run banner missing:\n$out"

# ── 2. apply removes exactly the stale refs + dangling prune ─────────────────
load_fixture
aidc::cmd_clean --apply -f >/dev/null 2>&1
for want in "rmi:aidc-base:bbbbbbbbbbbb" "rmi:aidc-toolchain-store-go:222200000002" "prune-dangling"; do
  if [[ "$CLEAN_CALLS" == *"$want"* ]]; then
    ok "apply performs $want"
  else
    fail "apply missing $want (calls:$CLEAN_CALLS)"
  fi
done
for taboo in "idbase1" "idcustom" "idubuntu" "aaaaaaaaaaaa" "111100000001"; do
  if [[ "$CLEAN_CALLS" != *"$taboo"* ]]; then
    ok "apply never touches $taboo"
  else
    fail "apply touched protected ref $taboo (calls:$CLEAN_CALLS)"
  fi
done

# ── 3. rmi failure is counted, not fatal ──────────────────────────────────────
load_fixture
RMI_FAIL_REFS=" aidc-base:bbbbbbbbbbbb "
out="$(aidc::cmd_clean --apply -f 2>&1)"
if printf '%s' "$out" | grep -q '1 failed' \
  && printf '%s' "$out" | grep -q 'could not remove aidc-base:bbbbbbbbbbbb'; then
  ok "failed rmi is reported and counted"
else
  fail "expected 1 failed removal, got:\n$out"
fi

# ── 4. nothing stale -> early exit, no mutations ──────────────────────────────
CLEAN_LS_ROWS="aidc-base:aaaaaaaaaaaa|idbase1|2.84GB\naidc-toolchain-store-go:111100000001|idtgo|1.1GB"
CLEAN_INSPECT_ROWS="idbase1|aidc-base:aaaaaaaaaaaa\nidtgo|"
CLEAN_DANGLING=""
CLEAN_CALLS=""
out="$(aidc::cmd_clean 2>&1)"
if printf '%s' "$out" | grep -qi 'nothing to clean' && [[ -z "$CLEAN_CALLS" ]]; then
  ok "all-in-use image set exits cleanly with no mutations"
else
  fail "expected early exit without mutations, got:\n$out"
fi

# ── 5. dangling-only set still prunes on apply ────────────────────────────────
CLEAN_LS_ROWS="ubuntu:24.04|idubuntu|78MB\n<none>:<none>|iddangling|100MB"
CLEAN_INSPECT_ROWS="idubuntu|"
CLEAN_DANGLING="iddangling"
CLEAN_CALLS=""
aidc::cmd_clean --apply -f >/dev/null 2>&1
if [[ "$CLEAN_CALLS" == *"prune-dangling"* ]]; then
  ok "dangling-only cleanup prunes dangling images"
else
  fail "expected prune-dangling, got:$CLEAN_CALLS"
fi

# ── 6. --cache adds builder prune (and it can be requested alone) ─────────────
CLEAN_LS_ROWS="ubuntu:24.04|idubuntu|78MB"
CLEAN_INSPECT_ROWS="idubuntu|"
CLEAN_DANGLING=""
CLEAN_CALLS=""
aidc::cmd_clean --apply -f --cache >/dev/null 2>&1
if [[ "$CLEAN_CALLS" == *"prune-cache"* ]]; then
  ok "--cache prunes the build cache"
else
  fail "expected prune-cache, got:$CLEAN_CALLS"
fi

# ── 7. prompt gate: default reply aborts ──────────────────────────────────────
load_fixture
CLEAN_CALLS=""
out="$(printf 'n\n' | aidc::cmd_clean --apply 2>&1)"
if printf '%s' "$out" | grep -q 'aborted' && [[ -z "$CLEAN_CALLS" ]]; then
  ok "--apply without -f prompts and aborts on 'n'"
else
  fail "expected abort without mutations, got:\n$out (calls:$CLEAN_CALLS)"
fi

# ── 8. help and flag validation ───────────────────────────────────────────────
aidc::cmd_clean --help >/dev/null 2>&1 \
  && ok "--help exits 0" \
  || fail "--help failed"
aidc::cmd_clean -h >/dev/null 2>&1 \
  && ok "-h exits 0" \
  || fail "-h failed"
( aidc::cmd_clean --bogus ) >/dev/null 2>&1 \
  && fail "unknown flag accepted" \
  || ok "unknown flag is rejected"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
