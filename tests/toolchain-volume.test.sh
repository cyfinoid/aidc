#!/usr/bin/env bash
#
# Unit tests for the Wave 3 image split (issue #7) and shared toolchain volume
# (issue #9):
#
#   - aidc::base_image_tag is a stable content hash of Dockerfile.base + the
#     AIDC_AGENTS selection (changing either changes the tag).
#   - aidc::toolchain_image_tag is per-language and stable.
#   - aidc::ensure_base_image honors an explicit AIDC_BASE_IMAGE and does not
#     rebuild when the image already exists; falls back to the hash tag +
#     builds when missing.
#   - aidc::cmd_tools routes install/status and rejects bad languages.
#   - aidc::tools_status reports "not created" when the volume is absent.
#
# docker + compose-env are stubbed so the test is hermetic (no daemon).
#
# Run with: bash tests/toolchain-volume.test.sh
# shellcheck disable=SC1091,SC2317,SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export AIDC_ROOT="$REPO_ROOT"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

. "$REPO_ROOT/lib/aidc.sh"

# ── base_image_tag: content + AIDC_AGENTS hash ──
ws="$TMP_ROOT/ws"
mkdir -p "$ws/.devcontainer"
printf 'FROM scratch\nRUN echo base\n' >"$ws/.devcontainer/Dockerfile.base"

AIDC_AGENTS="all"  tag_all="$(aidc::base_image_tag "$ws")"
AIDC_AGENTS="claude" tag_claude="$(aidc::base_image_tag "$ws")"
if [[ "$tag_all" =~ ^aidc-base:[0-9a-f]{12}$ ]]; then
  ok "base_image_tag has the aidc-base:<12hex> shape"
else
  fail "unexpected base tag: $tag_all"
fi
[[ "$tag_all" != "$tag_claude" ]] \
  && ok "AIDC_AGENTS selection changes the base tag" \
  || fail "base tag ignored AIDC_AGENTS ($tag_all == $tag_claude)"

AIDC_AGENTS="all"; tag_before="$(aidc::base_image_tag "$ws")"
printf 'FROM scratch\nRUN echo changed\n' >"$ws/.devcontainer/Dockerfile.base"
tag_after="$(aidc::base_image_tag "$ws")"
[[ "$tag_before" != "$tag_after" ]] \
  && ok "editing Dockerfile.base changes the base tag" \
  || fail "base tag ignored file content"

# ── toolchain_image_tag: per-language, stable ──
t_go="$(aidc::toolchain_image_tag go)"
t_rust="$(aidc::toolchain_image_tag rust)"
if [[ "$t_go" =~ ^aidc-toolchain-store-go:[0-9a-f]{12}$ ]]; then
  ok "toolchain_image_tag has the store-<lang>:<hash> shape"
else
  fail "unexpected toolchain tag: $t_go"
fi
[[ "$t_go" != "$t_rust" && "${t_go%%:*}" != "${t_rust%%:*}" ]] \
  && ok "toolchain tags differ by language" \
  || fail "toolchain tags not language-scoped ($t_go / $t_rust)"
[[ "$t_go" == "$(aidc::toolchain_image_tag go)" ]] \
  && ok "toolchain_image_tag is stable" \
  || fail "toolchain tag not stable"

# ── ensure_base_image: docker stubbed ──
DOCKER_LOG="$TMP_ROOT/docker.log"
: >"$DOCKER_LOG"
INSPECT_RC=0
aidc::export_compose_env() { :; }
aidc::log() { :; }
docker() {
  if [[ "$1" == "image" && "$2" == "inspect" ]]; then return "$INSPECT_RC"; fi
  printf '%s\n' "$*" >>"$DOCKER_LOG"
  return 0
}

# explicit AIDC_BASE_IMAGE + image present → no build
: >"$DOCKER_LOG"; INSPECT_RC=0
export AIDC_BASE_IMAGE="custom-base:pinned"
aidc::ensure_base_image "$ws"
if ! grep -q '^build' "$DOCKER_LOG" && [[ "$AIDC_BASE_IMAGE" == "custom-base:pinned" ]]; then
  ok "ensure_base_image reuses an explicit AIDC_BASE_IMAGE without building"
else
  fail "ensure_base_image rebuilt or dropped the explicit base: $(cat "$DOCKER_LOG")"
fi

# no override + image missing → build the hash-tagged base
: >"$DOCKER_LOG"; INSPECT_RC=1
unset AIDC_BASE_IMAGE
AIDC_AGENTS="all"
aidc::ensure_base_image "$ws"
if grep -q '^build ' "$DOCKER_LOG" && [[ "${AIDC_BASE_IMAGE:-}" =~ ^aidc-base:[0-9a-f]{12}$ ]]; then
  ok "ensure_base_image builds + exports the hash tag when the base is missing"
else
  fail "ensure_base_image did not build/export: base='${AIDC_BASE_IMAGE:-}' log=$(cat "$DOCKER_LOG")"
fi
unset AIDC_BASE_IMAGE

# ── cmd_tools install routing (stub only the volume populator) ──
TOOLS_INSTALLED=""
aidc::ensure_toolchain_volume() { TOOLS_INSTALLED+="$1 "; }

TOOLS_INSTALLED=""; aidc::cmd_tools install all
[[ "$TOOLS_INSTALLED" == "go rust java " ]] \
  && ok "tools install all → go rust java" \
  || fail "install all routed wrong: '$TOOLS_INSTALLED'"

TOOLS_INSTALLED=""; aidc::cmd_tools install rust
[[ "$TOOLS_INSTALLED" == "rust " ]] \
  && ok "tools install rust → rust" \
  || fail "install rust routed wrong: '$TOOLS_INSTALLED'"

out="$( (aidc::cmd_tools install bogus) 2>&1 )" && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'usage: aidc tools install' \
  && ok "tools install <bad-lang> is rejected" \
  || fail "bad lang not rejected: rc=$rc $out"

# ── cmd_tools status → real tools_status, with the volume absent ──
VOLUME_RC=1
docker() {
  if [[ "$1" == "volume" && "$2" == "inspect" ]]; then return "$VOLUME_RC"; fi
  return 0
}
out="$(aidc::cmd_tools status 2>&1)"
printf '%s' "$out" | grep -q 'shared toolchain volume' \
  && ok "tools status routes to tools_status" \
  || fail "status not routed: $out"
printf '%s' "$out" | grep -q 'not created yet' \
  && ok "tools_status reports the volume is not created yet" \
  || fail "tools_status missing-volume message wrong: $out"
out="$(aidc::cmd_tools 2>&1)"
printf '%s' "$out" | grep -q 'shared toolchain volume' \
  && ok "bare 'tools' defaults to status" \
  || fail "bare tools not defaulting to status: $out"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
