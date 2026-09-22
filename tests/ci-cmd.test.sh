#!/usr/bin/env bash
#
# Unit tests for `aidc ci` — the host-side wrapper around the scaffolded
# .devcontainer/scripts/aidc-ci.sh engine. Sources the real library and
# calls aidc::cmd_ci directly (tests/insights.test.sh pattern); docker is
# never touched: ensure_container_running is stubbed and aidc::compose
# captures its argv (the tests/sync-sessions.test.sh stub pattern).
#
# Run with: bash tests/ci-cmd.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

. "$REPO_ROOT/lib/aidc.sh"

aidc::default_workspace()      { printf '%s' "/some/ws"; }
aidc::ensure_container_running() { :; }

# Capture the compose argv instead of touching docker. compose_exec passes:
# <workspace> exec ${AIDC_EXEC_ENV_ARGS[@]} workspace <cmd...> — record the
# env args and the trailing command separately.
CAP_ENV=""
CAP_CMD=""
COMPOSE_RC=0
aidc::compose() {
  shift  # drop the workspace arg
  local -a rest=("$@")
  CAP_ENV=""
  CAP_CMD=""
  local i saw_exec=0 saw_ws=0
  for i in "${rest[@]}"; do
    if [[ "$saw_exec" == "0" ]]; then
      [[ "$i" == "exec" ]] && saw_exec=1
      continue
    fi
    if [[ "$saw_ws" == "0" && "$i" == "workspace" ]]; then
      saw_ws=1
      continue
    fi
    if [[ "$saw_ws" == "0" ]]; then
      # -e KEY pairs (and any future flags) before the container name
      CAP_ENV+="$i "
      continue
    fi
    CAP_CMD+="$i "
  done
  return "$COMPOSE_RC"
}

run_cmd_ci() {
  set +e
  aidc::cmd_ci "$@"
  CMD_RC=$?
  set -e
}

# ── 1. execs the scaffolded engine with flags verbatim ──────────────────────
run_cmd_ci --list
if [[ "$CMD_RC" == "0" ]] \
   && grep -q '^bash /workspace/.devcontainer/scripts/aidc-ci.sh --list $' <<<"$CAP_CMD"; then
  ok "aidc ci --list execs the scaffolded engine with the flag verbatim"
else
  fail "exec line wrong (rc=$CMD_RC, cmd='$CAP_CMD')"
fi

# ── 2. leading -- is stripped once ──────────────────────────────────────────
run_cmd_ci -- --strict
if [[ "$CMD_RC" == "0" ]] \
   && grep -q '^bash /workspace/.devcontainer/scripts/aidc-ci.sh --strict $' <<<"$CAP_CMD"; then
  ok "leading -- is stripped; args after it pass through"
else
  fail "-- handling wrong (rc=$CMD_RC, cmd='$CAP_CMD')"
fi

# ── 3. multi-flag pass-through ──────────────────────────────────────────────
run_cmd_ci --workflow 'shellcheck*' --job sbom
if [[ "$CMD_RC" == "0" ]] \
   && grep -q '^bash /workspace/.devcontainer/scripts/aidc-ci.sh --workflow shellcheck\* --job sbom $' <<<"$CAP_CMD"; then
  ok "multiple flags pass through verbatim (glob unquoted by the capture, args intact)"
else
  fail "multi-flag pass-through wrong (rc=$CMD_RC, cmd='$CAP_CMD')"
fi

# ── 4. env forwarding only when set ─────────────────────────────────────────
AIDC_CI_PROJECT="" AIDC_CI_PYTHON="" run_cmd_ci --list
if [[ "$CAP_ENV" == "" ]]; then
  ok "no -e forwarding when AIDC_CI_PROJECT/AIDC_CI_PYTHON are unset"
else
  fail "unexpected env forwarding: '$CAP_ENV'"
fi
AIDC_CI_PROJECT="/tmp/p" AIDC_CI_PYTHON="/tmp/py" run_cmd_ci --list
if [[ "$CAP_ENV" == "-e AIDC_CI_PROJECT -e AIDC_CI_PYTHON " ]]; then
  ok "AIDC_CI_PROJECT/AIDC_CI_PYTHON forwarded as -e pairs when set"
else
  fail "env forwarding wrong: '$CAP_ENV'"
fi

# ── 5. engine exit code propagates ──────────────────────────────────────────
COMPOSE_RC=1
run_cmd_ci --strict
if [[ "$CMD_RC" == "1" ]]; then
  ok "engine exit code propagates through aidc::cmd_ci"
else
  fail "rc propagation broken (rc=$CMD_RC, expected 1)"
fi
COMPOSE_RC=0

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
