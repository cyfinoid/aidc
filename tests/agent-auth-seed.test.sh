#!/usr/bin/env bash
#
# Unit tests for the agent credential-seed wiring in
# templates/devcontainer/scripts/bootstrap-state.sh.tmpl. The script is
# source-safe (its init/sync dispatch is guarded by a BASH_SOURCE check), so we
# source it, stub the copy primitives to record (source -> target) pairs, and
# assert each sync_<agent> seeds its real credential store — in particular that
# opencode's auth lands in the XDG *data* dir, and that cursor seeds settings
# only (its token is Keychain-bound, not seedable).
#
# Run with: bash tests/agent-auth-seed.test.sh
# shellcheck disable=SC2034,SC1090,SC1091,SC2317
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMPL="$REPO_ROOT/templates/devcontainer/scripts/bootstrap-state.sh.tmpl"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

# Source the bootstrap script with a controlled HOME; the guarded dispatch does
# not run on source.
export AIDC_CONTAINER_HOME="$TMP_ROOT/home"
mkdir -p "$AIDC_CONTAINER_HOME"
. "$TMPL"

# Replace the copy primitives with recorders (call-time resolved, so this wins).
CALLS=""
ensure_dir() { :; }
copy_file_from_seed() { CALLS+="FILE|$1|$2"$'\n'; }
copy_dir_from_seed()  { CALLS+="DIR|$1|$2"$'\n'; }
# sync_claude also runs these real file/python helpers — neutralize them so the
# seed wiring is all we exercise.
strip_host_hooks() { :; }
ensure_agent_guardrail_settings() { :; }

seeds() { printf '%s' "$CALLS" | grep -Fq "$1"; }
run()   { CALLS=""; "$1"; }

H="$AIDC_CONTAINER_HOME"

# 1. opencode seeds auth.json in the XDG DATA dir (the fix), plus its config.
run sync_opencode
if seeds "FILE|/host-seed/opencode-data/auth.json|$H/.local/share/opencode/auth.json"; then
  ok "sync_opencode seeds auth.json into ~/.local/share/opencode (data dir)"
else
  fail "opencode auth seed missing:\n$CALLS"
fi
seeds "FILE|/host-seed/opencode/opencode.json|$H/.config/opencode/opencode.json" \
  && ok "sync_opencode still seeds opencode.json (config)" || fail "opencode config seed missing"

# 2. codex/grok/omp seed their real credential files (regression guard).
run sync_codex
seeds "FILE|/host-seed/codex/auth.json|$H/.codex/auth.json" && ok "sync_codex seeds auth.json" || fail "codex auth: $CALLS"
run sync_grok
seeds "FILE|/host-seed/grok/auth.json|$H/.grok/auth.json" && ok "sync_grok seeds auth.json" || fail "grok auth: $CALLS"
run sync_omp
seeds "FILE|/host-seed/omp/agent/agent.db|$H/.omp/agent/agent.db" && ok "sync_omp seeds agent.db (auth store)" || fail "omp auth: $CALLS"

# 3. cursor seeds settings ONLY — never a token file (Keychain-bound).
run sync_cursor
if seeds "FILE|/host-seed/cursor/cli-config.json|$H/.cursor/cli-config.json" \
   && ! printf '%s' "$CALLS" | grep -Eiq "auth|token|credential"; then
  ok "sync_cursor seeds cli-config.json only (no token file)"
else
  fail "cursor seed unexpected:\n$CALLS"
fi

# 4. 'all' wires every agent, including the opencode data-dir auth.
CALLS=""; sync_tool all
seeds "FILE|/host-seed/opencode-data/auth.json|$H/.local/share/opencode/auth.json" \
  && ok "sync_tool all includes opencode data-dir auth" || fail "all missing opencode-data auth"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
