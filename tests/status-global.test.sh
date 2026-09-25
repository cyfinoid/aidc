#!/usr/bin/env bash
#
# Unit tests for the `docker disk` block in 'aidc status --global'
# (aidc::status_host_disk, remaster): the deduplicated host disk picture that
# answers the "every image is 3.39GB" illusion from the per-image numbers.
#
# Hermetic: a fake `docker` on PATH replays canned outputs for the ps/inspect/
# stats/system-df calls cmd_status_global makes; nothing touches a daemon.
#
# Run with: bash tests/status-global.test.sh
# shellcheck disable=SC2034,SC2317
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

# ── fake docker ───────────────────────────────────────────────────────────────
# One running + one exited aidc container, one image, canned `system df`.
cat >"$STUB_DIR/docker" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "ps -a")
    printf 'abc123456789|aidc_projone|running|/Users/me/WORK/projone/.devcontainer\n'
    printf 'def987654321|aidc_projtwo|exited|/Users/me/WORK/projtwo/.devcontainer\n'
    ;;
  "container ls")
    printf 'abc123456789|388MB (virtual 3.78GB)\ndef987654321|418kB (virtual 3.39GB)\n'
    ;;
  "image ls")
    if [[ "${3:-}" == "-f" ]]; then exit 0; fi
    printf 'sha256:111111111111|3.39GB\n'
    ;;
  "stats --no-stream")
    printf 'abc123456789|2.88%%|1012MiB / 15.66GiB|38\n'
    ;;
  "system df")
    printf 'Images|17.55GB|8.704GB (49%%)\nContainers|18.95GB|4.962GB (26%%)\nLocal Volumes|6.482GB|62.21MB (0%%)\nBuild Cache|4.706GB|4.706GB (100%%)\n'
    ;;
  "inspect")
    if [[ "$*" == *".Image"* ]]; then
      printf 'sha256:111111111111\n'
    elif [[ "$*" == *".State.StartedAt"* ]]; then
      printf '2026-09-24T19:54:11.000000000Z\n'
    elif [[ "$*" == *".State.FinishedAt"* ]]; then
      printf '2026-09-23T23:05:02.000000000Z\n'
    else
      printf '0\n'
    fi
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "$STUB_DIR/docker"
export PATH="$STUB_DIR:$PATH"

. "$REPO_ROOT/lib/aidc.sh"

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

# ── 1. the deduplicated block renders with all four rows ──────────────────────
out="$(aidc::cmd_status_global 2>&1)"
for needle in \
  "docker disk" \
  "double-count shared layers" \
  "Images" \
  "Containers" \
  "Local Volumes" \
  "Build Cache"; do
  if printf '%s' "$out" | grep -qF "$needle"; then
    ok "block contains: $needle"
  else
    fail "missing '$needle' in:\n$out"
  fi
done

# ── 2. reclaimable percentages are stripped, notes point at the right knob ────
if printf '%s' "$out" | grep -Eq 'Images +17\.55GB +\(reclaimable 8\.704GB.*aidc clean'; then
  ok "Images row shows size + reclaimable, no (49%) suffix"
else
  fail "Images row malformed:\n$(printf '%s' "$out" | grep Images)"
fi
if printf '%s' "$out" | grep -qF "'aidc clean --cache' reclaims"; then
  ok "Build Cache row points at 'aidc clean --cache'"
else
  fail "Build Cache note missing"
fi
if printf '%s' "$out" | grep -qF "not touched by cleanup"; then
  ok "volumes row marked as persisted state"
else
  fail "volumes note missing"
fi

# ── 3. the misleading per-image number is still labeled as such ───────────────
if printf '%s' "$out" | grep -qF "image 3.39GB"; then
  ok "per-image size still shown (context preserved)"
else
  fail "expected per-image size line"
fi

# ── 4. empty `system df` output (broken/absent daemon data) skips the block ───
cat >"$STUB_DIR/docker" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "ps -a") exit 0 ;;
  "system df") exit 0 ;;
  *) exit 0 ;;
esac
EOF
out="$(aidc::cmd_status_global 2>&1)"
if printf '%s' "$out" | grep -qF "docker disk"; then
  fail "block rendered with no df data"
else
  ok "block skipped when docker reports nothing"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
