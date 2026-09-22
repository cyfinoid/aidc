#!/usr/bin/env bash
#
# Unit tests for the fast-path build skip (PR #14 / issue #13).
#
#   - aidc::image_exists is true only when compose resolves an image name AND
#     `docker image inspect` succeeds.
#   - aidc::compose_up builds only when the image is missing; a present image
#     starts the container without --build (the fast path).
#   - AIDC_NO_BUILD=1 never builds: it starts a present image and dies fast
#     when the image is missing.
#
# docker/compose are stubbed so the test is hermetic (no daemon needed).
#
# Run with: bash tests/compose-up.test.sh
# shellcheck disable=SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

. "$REPO_ROOT/lib/aidc.sh"

# ── image_exists (real function): needs a resolved image name AND a successful
#    inspect. Stub compose_capture (image-name resolver) and docker (inspect). ──
IMG_NAME="aidc-ws:latest"
INSPECT_RC=0
aidc::compose_capture() { [[ -n "$IMG_NAME" ]] && printf '%s\n' "$IMG_NAME"; return 0; }
docker() { if [[ "$1" == "image" && "$2" == "inspect" ]]; then return "$INSPECT_RC"; fi; return 0; }

IMG_NAME="aidc-ws:latest"; INSPECT_RC=0
if aidc::image_exists /ws; then ok "image_exists true when name resolves and inspect succeeds"; else fail "expected true"; fi

IMG_NAME="aidc-ws:latest"; INSPECT_RC=1
if aidc::image_exists /ws; then fail "expected false when inspect fails"; else ok "image_exists false when inspect fails"; fi

IMG_NAME=""; INSPECT_RC=0
if aidc::image_exists /ws; then fail "expected false when no image name"; else ok "image_exists false when compose resolves no image"; fi

# ── compose_up: stub aidc::compose to record the subcommand, and aidc::image_exists
#    to drive the branch (its own behavior is covered above). ──
COMPOSE_CALL=""
aidc::compose() { shift; COMPOSE_CALL="$*"; }
IMAGE_PRESENT=1
aidc::image_exists() { [[ "$IMAGE_PRESENT" -eq 1 ]]; }
BASE_CURRENT=1
aidc::image_base_is_current() { [[ "$BASE_CURRENT" -eq 1 ]]; }

COMPOSE_CALL=""; IMAGE_PRESENT=1; BASE_CURRENT=1
AIDC_NO_BUILD=0 aidc::compose_up /ws
if [[ "$COMPOSE_CALL" == "up -d workspace" ]]; then
  ok "image present + base current → 'up -d workspace' (no rebuild)"
else
  fail "expected fast path, got: $COMPOSE_CALL"
fi

COMPOSE_CALL=""; IMAGE_PRESENT=1; BASE_CURRENT=0
AIDC_NO_BUILD=0 aidc::compose_up /ws
if [[ "$COMPOSE_CALL" == "up -d --build workspace" ]]; then
  ok "image present but base stale → 'up -d --build workspace' (rebuild)"
else
  fail "expected rebuild on stale base, got: $COMPOSE_CALL"
fi

COMPOSE_CALL=""; IMAGE_PRESENT=0; BASE_CURRENT=1
AIDC_NO_BUILD=0 aidc::compose_up /ws
if [[ "$COMPOSE_CALL" == "up -d --build workspace" ]]; then
  ok "image missing → 'up -d --build workspace'"
else
  fail "expected build path, got: $COMPOSE_CALL"
fi

COMPOSE_CALL=""; IMAGE_PRESENT=1
AIDC_NO_BUILD=1 aidc::compose_up /ws
if [[ "$COMPOSE_CALL" == "up -d workspace" ]]; then
  ok "AIDC_NO_BUILD=1 + image present → start without build"
else
  fail "expected no-build start, got: $COMPOSE_CALL"
fi

COMPOSE_CALL=""; IMAGE_PRESENT=0
out="$( (AIDC_NO_BUILD=1 aidc::compose_up /ws) 2>&1 )" && rc=0 || rc=$?
if [[ "$rc" -ne 0 && -z "$COMPOSE_CALL" ]] && printf '%s' "$out" | grep -q 'AIDC_NO_BUILD=1 but no image'; then
  ok "AIDC_NO_BUILD=1 + image missing → dies without building"
else
  fail "expected fail-fast, got rc=$rc call='$COMPOSE_CALL': $out"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
