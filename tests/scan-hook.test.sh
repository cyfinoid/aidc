#!/usr/bin/env bash
#
# Unit tests for the Claude Code Stop hook
# (templates/devcontainer/scripts/aidc-scan-hook.sh.tmpl) and the
# settings.json seeding in bootstrap-state.sh.tmpl
# (ensure_agent_guardrail_settings).
#
# The hook's workspace is overridden via AIDC_SCAN_HOOK_WORKSPACE; aidc-scan
# is stubbed inside the fixture workspace. Run with: bash tests/scan-hook.test.sh
# shellcheck disable=SC1090,SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/templates/devcontainer/scripts/aidc-scan-hook.sh.tmpl"
BOOTSTRAP="$REPO_ROOT/templates/devcontainer/scripts/bootstrap-state.sh.tmpl"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

# ── fixture workspace with a stubbed aidc-scan ───────────────────────────────
WS="$TMP_ROOT/ws"
mkdir -p "$WS/.devcontainer/scripts" "$WS/.ai-container"
git -C "$WS" init -q
# Real aidc projects git-exclude the scaffold dirs — mirror that, or the
# stub scanner itself would count as "changes".
printf '.devcontainer/\n.ai-container/\n' >>"$WS/.git/info/exclude"
git -C "$WS" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'base\n' >"$WS/file.txt"
git -C "$WS" add -A
git -C "$WS" -c user.email=t@t -c user.name=t commit -q -m baseline

cat >"$WS/.devcontainer/scripts/aidc-scan.sh" <<'STUB'
#!/usr/bin/env bash
echo run >>"$SCAN_CALLS"
exit "${SCAN_EXIT:-0}"
STUB
chmod +x "$WS/.devcontainer/scripts/aidc-scan.sh"

export SCAN_CALLS="$TMP_ROOT/scan-calls"
run_hook() { # [payload]
  local payload="${1:-{\}}"
  HOME="$TMP_ROOT/home" AIDC_SCAN_HOOK_WORKSPACE="$WS" \
    bash "$HOOK" <<<"$payload"
}
mkdir -p "$TMP_ROOT/home"

# 1. No changes in the tree -> allow, no scan.
: >"$SCAN_CALLS"
if run_hook >/dev/null 2>&1 && [[ ! -s "$SCAN_CALLS" ]]; then
  ok "clean tree: allow without scanning"
else
  fail "clean tree case"
fi

# 2. Changes + clean scan -> allow; second run debounced (no second scan).
printf 'edit\n' >>"$WS/file.txt"
: >"$SCAN_CALLS"
rm -rf "$TMP_ROOT/home/.cache"
if SCAN_EXIT=0 run_hook >/dev/null 2>&1 \
   && [[ "$(grep -c run "$SCAN_CALLS")" -eq 1 ]]; then
  ok "changed tree: scans once and allows on clean"
else
  fail "clean-scan case: calls=$(cat "$SCAN_CALLS")"
fi
if SCAN_EXIT=0 run_hook >/dev/null 2>&1 \
   && [[ "$(grep -c run "$SCAN_CALLS")" -eq 1 ]]; then
  ok "unchanged tree since clean pass: debounced"
else
  fail "debounce case: calls=$(wc -l <"$SCAN_CALLS")"
fi

# 3. Findings -> exit 2, findings on stderr; a further edit re-triggers.
printf 'edit2\n' >>"$WS/file.txt"
rc=0
err="$(SCAN_EXIT=1 run_hook 2>&1 >/dev/null)" || rc=$?
if [[ "$rc" -eq 2 ]] && printf '%s' "$err" | grep -q 'aidc-scan found'; then
  ok "findings block the stop (exit 2, findings on stderr)"
else
  fail "findings case: rc=$rc err=$err"
fi
if grep -q ' findings' "$WS/.ai-container/scan-hook.log"; then
  ok "blocked outcome logged"
else
  fail "findings not logged"
fi

# 4. Loop guard: stop_hook_active -> always allow, no scan.
: >"$SCAN_CALLS"
if SCAN_EXIT=1 run_hook '{"stop_hook_active": true}' >/dev/null 2>&1 \
   && [[ ! -s "$SCAN_CALLS" ]]; then
  ok "stop_hook_active: never blocks again"
else
  fail "loop-guard case"
fi

# 5. Scanner infrastructure error -> fail open (exit 0), logged.
rm -rf "$TMP_ROOT/home/.cache"
if SCAN_EXIT=2 run_hook >/dev/null 2>&1; then
  ok "scanner infra error fails open"
else
  fail "infra-error case blocked the agent"
fi
if grep -q 'error rc=2' "$WS/.ai-container/scan-hook.log"; then
  ok "infra error logged"
else
  fail "infra error not logged"
fi

# 6. Knob off -> allow, no scan.
printf 'AIDC_ENFORCE_SCAN_HOOK=0\n' >"$WS/.ai-container/project.env"
: >"$SCAN_CALLS"
if SCAN_EXIT=1 run_hook >/dev/null 2>&1 && [[ ! -s "$SCAN_CALLS" ]]; then
  ok "AIDC_ENFORCE_SCAN_HOOK=0 disables the hook"
else
  fail "knob-off case"
fi
rm -f "$WS/.ai-container/project.env"

# 7. Missing scan script -> fail open.
mv "$WS/.devcontainer/scripts/aidc-scan.sh" "$TMP_ROOT/scan-away"
if run_hook >/dev/null 2>&1; then
  ok "missing scanner fails open"
else
  fail "missing scanner blocked the agent"
fi
mv "$TMP_ROOT/scan-away" "$WS/.devcontainer/scripts/aidc-scan.sh"

# ── settings.json seeding (bootstrap) ────────────────────────────────────────
. "$BOOTSTRAP" 2>/dev/null || true   # guarded dispatch: safe to source
SETTINGS="$TMP_ROOT/settings.json"
HOOK_CMD="/workspace/.devcontainer/scripts/aidc-scan-hook.sh"

# 8. Seeding into a missing file creates hook + MCP posture.
rm -f "$SETTINGS"
AIDC_ENFORCE_SCAN_HOOK=1 ensure_agent_guardrail_settings "$SETTINGS"
if jq -e --arg c "$HOOK_CMD" \
     '.hooks.Stop[]?.hooks[]? | select(.command == $c)' "$SETTINGS" >/dev/null \
   && jq -e '.enableAllProjectMcpServers == false' "$SETTINGS" >/dev/null; then
  ok "seeding creates the Stop hook + MCP posture"
else
  fail "seeded settings: $(cat "$SETTINGS")"
fi

# 9. Idempotent, and user hooks survive.
jq '.hooks.PreToolUse = [{"matcher":"Bash","hooks":[{"type":"command","command":"rtk hook"}]}]' \
  "$SETTINGS" >"$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
AIDC_ENFORCE_SCAN_HOOK=1 ensure_agent_guardrail_settings "$SETTINGS"
AIDC_ENFORCE_SCAN_HOOK=1 ensure_agent_guardrail_settings "$SETTINGS"
count="$(jq --arg c "$HOOK_CMD" \
  '[.hooks.Stop[]?.hooks[]? | select(.command == $c)] | length' "$SETTINGS")"
if [[ "$count" == "1" ]] \
   && jq -e '.hooks.PreToolUse[0].hooks[0].command == "rtk hook"' "$SETTINGS" >/dev/null; then
  ok "seeding is idempotent and preserves other hooks"
else
  fail "idempotence: count=$count settings=$(cat "$SETTINGS")"
fi

# 10. Knob off removes only the aidc hook.
AIDC_ENFORCE_SCAN_HOOK=0 ensure_agent_guardrail_settings "$SETTINGS"
count="$(jq --arg c "$HOOK_CMD" \
  '[.hooks.Stop[]?.hooks[]? | select(.command == $c)] | length' "$SETTINGS")"
if [[ "$count" == "0" ]] \
   && jq -e '.hooks.PreToolUse[0].hooks[0].command == "rtk hook"' "$SETTINGS" >/dev/null; then
  ok "knob off removes the aidc hook, keeps user hooks"
else
  fail "removal: count=$count settings=$(cat "$SETTINGS")"
fi

# 11. Existing enableAllProjectMcpServers value is respected.
jq '.enableAllProjectMcpServers = true' "$SETTINGS" >"$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
AIDC_ENFORCE_SCAN_HOOK=1 ensure_agent_guardrail_settings "$SETTINGS"
if jq -e '.enableAllProjectMcpServers == true' "$SETTINGS" >/dev/null; then
  ok "explicit user MCP choice is not overridden"
else
  fail "MCP override case: $(cat "$SETTINGS")"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
