#!/usr/bin/env bash
#
# Unit tests for aidc::compose_file_args (lib/aidc.sh): the conditional
# compose -f chain that grants firewall capabilities / no-new-privileges
# hardening only when their knobs are set.
#
# Run with: bash tests/compose-file-args.test.sh
# shellcheck disable=SC2034,SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

. "$REPO_ROOT/lib/aidc.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

WS="$TMP_ROOT/ws"
mkdir -p "$WS/.devcontainer"
touch "$WS/.devcontainer/compose.yaml" \
      "$WS/.devcontainer/compose.firewall.yaml" \
      "$WS/.devcontainer/compose.hardened.yaml" \
      "$WS/.devcontainer/compose.opencode-web.yaml"

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

# Renders AIDC_COMPOSE_FILE_ARGS as a comparable one-line string.
args_str() {
  local out="" a
  for a in "${AIDC_COMPOSE_FILE_ARGS[@]}"; do
    case "$a" in
      -f) out="$out -f" ;;
      *)  out="$out ${a##*/}" ;;
    esac
  done
  printf '%s' "${out# }"
}

# 1. Defaults: base file only.
unset AIDC_ENABLE_EGRESS_FIREWALL AIDC_NO_NEW_PRIVILEGES 2>/dev/null || true
aidc::compose_file_args "$WS"
if [[ "$(args_str)" == "-f compose.yaml" ]]; then
  ok "default: base compose file only"
else
  fail "default: got '$(args_str)'"
fi

# 2. Firewall on: firewall override joins.
AIDC_ENABLE_EGRESS_FIREWALL=1
unset AIDC_NO_NEW_PRIVILEGES 2>/dev/null || true
aidc::compose_file_args "$WS"
if [[ "$(args_str)" == "-f compose.yaml -f compose.firewall.yaml" ]]; then
  ok "firewall=1 adds compose.firewall.yaml"
else
  fail "firewall: got '$(args_str)'"
fi

# 3. no-new-privileges on (firewall off): hardened override joins.
AIDC_ENABLE_EGRESS_FIREWALL=0
AIDC_NO_NEW_PRIVILEGES=1
aidc::compose_file_args "$WS"
if [[ "$(args_str)" == "-f compose.yaml -f compose.hardened.yaml" ]]; then
  ok "no-new-privileges=1 adds compose.hardened.yaml"
else
  fail "hardened: got '$(args_str)'"
fi

# 4. Both on: firewall wins, hardened skipped with a warning.
AIDC_ENABLE_EGRESS_FIREWALL=1
AIDC_NO_NEW_PRIVILEGES=1
warn_out="$(aidc::compose_file_args "$WS" 2>&1 >/dev/null || true)"
aidc::compose_file_args "$WS" 2>/dev/null
if [[ "$(args_str)" == "-f compose.yaml -f compose.firewall.yaml" ]]; then
  ok "firewall+hardened: firewall wins, hardened skipped"
else
  fail "conflict: got '$(args_str)'"
fi
if printf '%s' "$warn_out" | grep -qi 'skipped'; then
  ok "conflict emits a warning"
else
  fail "conflict warning missing (got: '$warn_out')"
fi

# 5. Old scaffold without the override files: base only, no crash.
WS2="$TMP_ROOT/ws-old"
mkdir -p "$WS2/.devcontainer"
touch "$WS2/.devcontainer/compose.yaml"
AIDC_ENABLE_EGRESS_FIREWALL=1
AIDC_NO_NEW_PRIVILEGES=1
aidc::compose_file_args "$WS2" 2>/dev/null
if [[ "$(args_str)" == "-f compose.yaml" ]]; then
  ok "missing override files degrade to base only"
else
  fail "old scaffold: got '$(args_str)'"
fi

# 6. opencode-web on (others off): the web override joins.
unset AIDC_ENABLE_EGRESS_FIREWALL AIDC_NO_NEW_PRIVILEGES 2>/dev/null || true
AIDC_OPENCODE_WEB=1
aidc::compose_file_args "$WS"
if [[ "$(args_str)" == "-f compose.yaml -f compose.opencode-web.yaml" ]]; then
  ok "opencode-web=1 adds compose.opencode-web.yaml"
else
  fail "opencode-web: got '$(args_str)'"
fi

# 7. opencode-web off: base only (no accidental publish).
AIDC_OPENCODE_WEB=0
aidc::compose_file_args "$WS"
if [[ "$(args_str)" == "-f compose.yaml" ]]; then
  ok "opencode-web=0 leaves base only"
else
  fail "opencode-web off: got '$(args_str)'"
fi

# 8. opencode-web on but the override file is missing: degrade to base only.
AIDC_OPENCODE_WEB=1
aidc::compose_file_args "$WS2"
if [[ "$(args_str)" == "-f compose.yaml" ]]; then
  ok "opencode-web missing override degrades to base only"
else
  fail "opencode-web old scaffold: got '$(args_str)'"
fi
unset AIDC_OPENCODE_WEB 2>/dev/null || true

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
