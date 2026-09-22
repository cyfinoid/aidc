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

# ── auto-detection helpers ──────────────────────────────────────────────────
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# 8. docker_is_usable reflects `docker info` (stub docker on PATH via a shim dir).
BIN="$TMP_ROOT/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/docker"; chmod +x "$BIN/docker"
if ( PATH="$BIN:$PATH"; aidc::docker_is_usable ); then ok "docker_is_usable true when docker info succeeds"; else fail "expected usable"; fi
printf '#!/usr/bin/env bash\nexit 1\n' >"$BIN/docker"; chmod +x "$BIN/docker"
if ( PATH="$BIN:$PATH"; aidc::docker_is_usable ); then fail "expected not usable"; else ok "docker_is_usable false when docker info fails"; fi

# 9. detect_alt_providers finds 'apple' only when docker+container CLIs AND the
#    socktainer socket are all present.
if command -v python3 >/dev/null 2>&1; then
  SOCK="$TMP_ROOT/container.sock"
  python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$SOCK"
  printf '#!/usr/bin/env bash\ntrue\n' >"$BIN/docker"; chmod +x "$BIN/docker"
  printf '#!/usr/bin/env bash\ntrue\n' >"$BIN/container"; chmod +x "$BIN/container"
  got="$( PATH="$BIN:/usr/bin:/bin"; AIDC_APPLE_CONTAINER_SOCKET="$SOCK" aidc::detect_alt_providers )"
  [[ "$got" == "apple" ]] && ok "detect_alt_providers finds apple (docker+container+socket)" || fail "detect apple: got '$got'"
  got="$( PATH="$BIN:/usr/bin:/bin"; AIDC_APPLE_CONTAINER_SOCKET="$TMP_ROOT/missing.sock" aidc::detect_alt_providers )"
  [[ -z "$got" ]] && ok "detect_alt_providers empty when socket absent" || fail "detect no-socket: got '$got'"
  rm -f "$BIN/container"
  got="$( PATH="$BIN:/usr/bin:/bin"; AIDC_APPLE_CONTAINER_SOCKET="$SOCK" aidc::detect_alt_providers )"
  [[ -z "$got" ]] && ok "detect_alt_providers empty when container CLI absent" || fail "detect no-container: got '$got'"
else
  ok "detect_alt_providers socket case skipped (no python3)"
fi

# 10. persist_docker_provider appends then replaces the active line.
CFG="$TMP_ROOT/config.env"; printf '# comment\n' >"$CFG"
AIDC_GLOBAL_CONFIG="$CFG" aidc::persist_docker_provider apple
grep -qx "AIDC_DOCKER_PROVIDER=apple" "$CFG" && ok "persist appends AIDC_DOCKER_PROVIDER" || fail "persist append: $(cat "$CFG")"
AIDC_GLOBAL_CONFIG="$CFG" aidc::persist_docker_provider docker
if grep -qx "AIDC_DOCKER_PROVIDER=docker" "$CFG" && [[ "$(grep -c '^AIDC_DOCKER_PROVIDER=' "$CFG")" == "1" ]]; then
  ok "persist replaces the existing active line (no duplicate)"
else
  fail "persist replace: $(cat "$CFG")"
fi

# ── ensure_docker_provider branches ──────────────────────────────────────────
# Stub only the environment seams (docker/alt/tty); persistence is exercised for
# real against a temp global config so we test the actual write path.
ECFG="$TMP_ROOT/ensure-cfg.env"
prep() { unset AIDC_PROVIDER_RESOLVED AIDC_DOCKER_PROVIDER DOCKER_HOST 2>/dev/null || true; : >"$ECFG"; }
persisted() { grep -qx "AIDC_DOCKER_PROVIDER=$1" "$ECFG"; }
USABLE=1; aidc::docker_is_usable() { [[ "$USABLE" -eq 1 ]]; }
ALTS="apple"; aidc::detect_alt_providers() { printf '%s' "$ALTS"; }
TTY=1; aidc::is_interactive() { [[ "$TTY" -eq 1 ]]; }
export AIDC_GLOBAL_CONFIG="$ECFG"

# 11. Explicit provider is honored without probing or persisting.
prep; AIDC_DOCKER_PROVIDER=apple; USABLE=0
aidc::ensure_docker_provider >/dev/null 2>&1
if [[ "${DOCKER_HOST:-}" == "unix://$HOME/.socktainer/container.sock" ]] && ! persisted apple; then
  ok "explicit provider applied, not persisted, no probe"
else
  fail "explicit: DH='${DOCKER_HOST:-}' cfg='$(cat "$ECFG")'"
fi

# 12. Docker usable → stays docker, no prompt, no DOCKER_HOST.
prep; USABLE=1
aidc::ensure_docker_provider </dev/null >/dev/null 2>&1
[[ -z "${DOCKER_HOST:-}" ]] && ! persisted apple && ok "docker usable → stays docker" || fail "usable: DH='${DOCKER_HOST:-}'"

# 13. Docker down + alt + non-interactive → warn, no switch.
prep; USABLE=0; TTY=0
out="$(aidc::ensure_docker_provider </dev/null 2>&1)"
if [[ -z "${DOCKER_HOST:-}" && -z "${AIDC_DOCKER_PROVIDER:-}" ]] && printf '%s' "$out" | grep -qi "set AIDC_DOCKER_PROVIDER"; then
  ok "docker down + non-interactive → hint, no switch"
else
  fail "non-interactive: DH='${DOCKER_HOST:-}' prov='${AIDC_DOCKER_PROVIDER:-}' out='$out'"
fi

# 14. Docker down + alt + interactive + 'y' → switch to apple, apply, persist.
prep; USABLE=0; TTY=1
aidc::ensure_docker_provider <<<"y" >/dev/null 2>&1
if [[ "${AIDC_DOCKER_PROVIDER:-}" == "apple" && "${DOCKER_HOST:-}" == "unix://$HOME/.socktainer/container.sock" ]] && persisted apple; then
  ok "interactive 'y' → switches + applies + persists apple"
else
  fail "yes: prov='${AIDC_DOCKER_PROVIDER:-}' DH='${DOCKER_HOST:-}' cfg='$(cat "$ECFG")'"
fi

# 15. Docker down + alt + interactive + 'n' → stays docker, nothing persisted.
prep; USABLE=0; TTY=1
aidc::ensure_docker_provider <<<"n" >/dev/null 2>&1
[[ -z "${DOCKER_HOST:-}" && -z "${AIDC_DOCKER_PROVIDER:-}" ]] && ! persisted apple \
  && ok "interactive 'n' → declines, stays docker" || fail "no: DH='${DOCKER_HOST:-}' prov='${AIDC_DOCKER_PROVIDER:-}'"

# 16. Once-guard: a second call does not re-probe/re-prompt.
prep; USABLE=0; TTY=1; PROBES=0
aidc::docker_is_usable() { PROBES=$((PROBES+1)); [[ "$USABLE" -eq 1 ]]; }
aidc::ensure_docker_provider <<<"n" >/dev/null 2>&1   # resolves (declines), sets guard
aidc::ensure_docker_provider </dev/null >/dev/null 2>&1  # guarded → apply only
[[ "$PROBES" -eq 1 ]] && ok "once-guard: probe runs at most once per invocation" || fail "guard: probes=$PROBES"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
