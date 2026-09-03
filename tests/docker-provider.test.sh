#!/usr/bin/env bash
#
# Unit tests for the Docker-provider switch (issue #25):
#   - aidc::apply_docker_provider routes DOCKER_HOST per AIDC_DOCKER_PROVIDER
#     (default 'docker' = no-op; 'apple' = socktainer socket; explicit DOCKER_HOST
#     wins; unknown warns).
#   - aidc::doctor_check_docker dispatches to the Apple-container checks and
#     flags them experimental when the provider is 'apple'.
#
# Run with: bash tests/docker-provider.test.sh
# shellcheck disable=SC2034,SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

. "$REPO_ROOT/lib/aidc.sh"

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

reset() { unset DOCKER_HOST AIDC_DOCKER_PROVIDER AIDC_APPLE_CONTAINER_SOCKET 2>/dev/null || true; }

# 1. Default provider (unset) is a no-op — DOCKER_HOST stays unset.
reset
aidc::apply_docker_provider
if [[ -z "${DOCKER_HOST:-}" ]]; then ok "default provider leaves DOCKER_HOST unset"; else fail "default set DOCKER_HOST='$DOCKER_HOST'"; fi

# 2. Explicit provider=docker is a no-op too.
reset
AIDC_DOCKER_PROVIDER=docker aidc::apply_docker_provider
if [[ -z "${DOCKER_HOST:-}" ]]; then ok "provider=docker is a no-op"; else fail "docker set DOCKER_HOST='$DOCKER_HOST'"; fi

# 3. provider=apple sets DOCKER_HOST to the default socktainer socket.
reset
AIDC_DOCKER_PROVIDER=apple aidc::apply_docker_provider
if [[ "${DOCKER_HOST:-}" == "unix://$HOME/.socktainer/container.sock" ]]; then
  ok "provider=apple sets the default socktainer DOCKER_HOST"
else
  fail "apple default DOCKER_HOST='${DOCKER_HOST:-}'"
fi

# 4. provider=apple honors a custom socket path.
reset
AIDC_DOCKER_PROVIDER=apple AIDC_APPLE_CONTAINER_SOCKET=/tmp/custom.sock aidc::apply_docker_provider
if [[ "${DOCKER_HOST:-}" == "unix:///tmp/custom.sock" ]]; then
  ok "provider=apple honors AIDC_APPLE_CONTAINER_SOCKET"
else
  fail "apple custom DOCKER_HOST='${DOCKER_HOST:-}'"
fi

# 5. An explicit DOCKER_HOST always wins (apple does not override it).
reset
DOCKER_HOST="tcp://1.2.3.4:2375"
AIDC_DOCKER_PROVIDER=apple aidc::apply_docker_provider
if [[ "$DOCKER_HOST" == "tcp://1.2.3.4:2375" ]]; then ok "explicit DOCKER_HOST wins over provider=apple"; else fail "apple clobbered DOCKER_HOST='$DOCKER_HOST'"; fi

# 6. Unknown provider warns and does not set DOCKER_HOST.
reset
warn_out="$(AIDC_DOCKER_PROVIDER=bogus aidc::apply_docker_provider 2>&1 || true)"
if printf '%s' "$warn_out" | grep -qi "unknown AIDC_DOCKER_PROVIDER" && [[ -z "${DOCKER_HOST:-}" ]]; then
  ok "unknown provider warns, leaves DOCKER_HOST unset"
else
  fail "unknown provider: out='$warn_out' DOCKER_HOST='${DOCKER_HOST:-}'"
fi

# 7. doctor: provider=apple dispatches to the experimental Apple-container checks.
reset
AIDC_DOCTOR_FAILS=0
AIDC_DOCTOR_WARNS=0
out="$(AIDC_DOCKER_PROVIDER=apple AIDC_APPLE_CONTAINER_SOCKET=/tmp/definitely-missing.sock aidc::doctor_check_docker 2>&1 || true)"
if printf '%s' "$out" | grep -qi "experimental" \
   && printf '%s' "$out" | grep -qi "apple-container" \
   && printf '%s' "$out" | grep -qi "socktainer"; then
  ok "doctor(provider=apple) reports experimental + apple-container + socktainer"
else
  fail "doctor apple output: $out"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
