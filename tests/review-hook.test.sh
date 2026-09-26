#!/usr/bin/env bash
#
# Unit tests for the pre-completion review gate:
#   - the Claude Code Stop hook
#     (templates/devcontainer/scripts/aidc-review-hook.sh.tmpl)
#   - the record helper
#     (templates/devcontainer/scripts/aidc-review-record.sh.tmpl)
#   - the two-guardrail settings seeding in bootstrap-state.sh.tmpl
#     (ensure_agent_guardrail_settings)
#
# The hook's workspace is overridden via AIDC_REVIEW_HOOK_WORKSPACE; the real
# record template is installed into the fixture workspace where the hook
# expects it. Run with: bash tests/review-hook.test.sh
# shellcheck disable=SC1090,SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/templates/devcontainer/scripts/aidc-review-hook.sh.tmpl"
RECORD="$REPO_ROOT/templates/devcontainer/scripts/aidc-review-record.sh.tmpl"
BOOTSTRAP="$REPO_ROOT/templates/devcontainer/scripts/bootstrap-state.sh.tmpl"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

# ── fixture workspace with the real record helper ────────────────────────────
WS="$TMP_ROOT/ws"
mkdir -p "$WS/.devcontainer/scripts" "$WS/.ai-container"
cp "$RECORD" "$WS/.devcontainer/scripts/aidc-review-record.sh"
chmod +x "$WS/.devcontainer/scripts/aidc-review-record.sh"
git -C "$WS" init -q
# Mirror a real scaffold: the aidc dirs are git-excluded, so state files never
# count as changes for the hook or the record helper.
printf '.devcontainer/\n.ai-container/\n' >>"$WS/.git/info/exclude"
git -C "$WS" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'base\n' >"$WS/file.go"
git -C "$WS" add -A
git -C "$WS" -c user.email=t@t -c user.name=t commit -q -m baseline

run_hook() { # [payload]
  local payload="${1:-{\}}"
  AIDC_REVIEW_HOOK_WORKSPACE="$WS" bash "$HOOK" <<<"$payload"
}
record() { # <summary>
  AIDC_REVIEW_HOOK_WORKSPACE="$WS" bash "$WS/.devcontainer/scripts/aidc-review-record.sh" "$1"
}

# 1. Clean tree -> allow.
if run_hook >/dev/null 2>&1; then
  ok "clean tree: allow"
else
  fail "clean tree case blocked the stop"
fi

# 2. Code change, no record -> exit 2 with the checklist on stderr; logged.
printf 'edit\n' >>"$WS/file.go"
rc=0
err="$(run_hook 2>&1 >/dev/null)" || rc=$?
if [[ "$rc" -eq 2 ]] \
   && printf '%s' "$err" | grep -q 'aidc-review: no pre-completion review' \
   && printf '%s' "$err" | grep -q 'fallback-defeating' \
   && printf '%s' "$err" | grep -q 'aidc-review-record'; then
  ok "unreviewed code change blocks with the checklist (exit 2)"
else
  fail "unreviewed case: rc=$rc err=$err"
fi
if grep -q 'blocked' "$WS/.ai-container/review-hook.log"; then
  ok "blocked outcome logged"
else
  fail "blocked outcome not logged"
fi

# 3. Docs-only change -> allow (the gate skips documentation diffs).
git -C "$WS" checkout -q -- file.go
printf 'notes\n' >"$WS/NOTES.md"
if run_hook >/dev/null 2>&1; then
  ok "docs-only change: allow"
else
  fail "docs-only case blocked the stop"
fi
rm "$WS/NOTES.md"

# 4. Mixed docs + code change -> still gated.
printf 'notes\n' >"$WS/NOTES.md"
printf 'edit\n' >>"$WS/file.go"
if run_hook >/dev/null 2>&1; then
  fail "mixed docs+code change was not gated"
else
  ok "mixed docs+code change: gated"
fi

# 5. Recording a review -> allow; the marker carries the summary.
if out="$(record "test review: checklist clean")" \
   && grep -q 'review recorded' <<<"$out" \
   && run_hook >/dev/null 2>&1; then
  ok "recorded review allows the stop"
else
  fail "record-then-stop case: marker=$(cat "$WS/.ai-container/review-done" 2>/dev/null)"
fi
if grep -q 'test review: checklist clean' "$WS/.ai-container/review-done" \
   && grep -q 'recorded test review' "$WS/.ai-container/review-hook.log"; then
  ok "marker and log carry the review summary"
else
  fail "review summary not persisted"
fi

# 6. Any edit after the review re-arms the gate (hash mismatch -> block).
printf 'edit2\n' >>"$WS/file.go"
if run_hook >/dev/null 2>&1; then
  fail "post-review edit did not re-arm the gate"
else
  ok "post-review edit re-arms the gate"
fi

# 7. Re-recording after the edit -> allow again.
if record "re-review after fix" >/dev/null && run_hook >/dev/null 2>&1; then
  ok "re-review after edit allows the stop"
else
  fail "re-record case"
fi
git -C "$WS" checkout -q -- file.go
rm -f "$WS/.ai-container/review-done" "$WS/NOTES.md"

# 8. Untracked code files count as changes and are coverable by a record.
printf 'package main\n' >"$WS/untracked.go"
if run_hook >/dev/null 2>&1; then
  fail "untracked code file was not gated"
else
  ok "untracked code file: gated"
fi
if record "untracked reviewed" >/dev/null && run_hook >/dev/null 2>&1; then
  ok "untracked code file: record satisfies the gate"
else
  fail "untracked record case"
fi
rm "$WS/untracked.go" "$WS/.ai-container/review-done"

# 9. Loop guard: stop_hook_active -> always allow.
if run_hook '{"stop_hook_active": true}' >/dev/null 2>&1; then
  ok "stop_hook_active: never blocks again"
else
  fail "loop-guard case"
fi

# 10. Knob off -> allow.
printf 'AIDC_ENFORCE_REVIEW_HOOK=0\n' >"$WS/.ai-container/project.env"
printf 'knob\n' >>"$WS/file.go"
if run_hook >/dev/null 2>&1; then
  ok "AIDC_ENFORCE_REVIEW_HOOK=0 disables the hook"
else
  fail "knob-off case"
fi
rm -f "$WS/.ai-container/project.env" "$WS/.ai-container/review-done"

# 11. Missing record helper -> fail open (blocking would only wedge the agent).
mv "$WS/.devcontainer/scripts/aidc-review-record.sh" "$TMP_ROOT/record-away"
if run_hook >/dev/null 2>&1; then
  ok "missing record helper fails open"
else
  fail "missing helper blocked the agent"
fi
if grep -q 'helper-missing' "$WS/.ai-container/review-hook.log"; then
  ok "helper-missing outcome logged"
else
  fail "helper-missing not logged"
fi
mv "$TMP_ROOT/record-away" "$WS/.devcontainer/scripts/aidc-review-record.sh"
git -C "$WS" checkout -q -- file.go

# ── record helper usage errors ───────────────────────────────────────────────
# 12. Empty/missing summary -> rc 1, marker untouched.
printf 'x\n' >>"$WS/file.go"
rc=0
err="$(record "   " 2>&1 >/dev/null)" || rc=$?
if [[ "$rc" -eq 1 ]] && printf '%s' "$err" | grep -q 'usage'; then
  ok "empty summary: usage error"
else
  fail "empty-summary case: rc=$rc err=$err"
fi

# 13. Nothing changed -> rc 1.
git -C "$WS" checkout -q -- file.go
rc=0
err="$(record "no-op" 2>&1 >/dev/null)" || rc=$?
if [[ "$rc" -eq 1 ]] && printf '%s' "$err" | grep -q 'nothing changed'; then
  ok "clean tree: record helper refuses"
else
  fail "nothing-changed case: rc=$rc err=$err"
fi

# 14. Outside a git repo -> rc 2.
git -C "$WS" mv -q file.go file.go 2>/dev/null || true
printf 'x\n' >>"$WS/file.go"
if AIDC_REVIEW_HOOK_WORKSPACE="$TMP_ROOT" \
     bash "$WS/.devcontainer/scripts/aidc-review-record.sh" "nope" >/dev/null 2>&1; then
  fail "non-repo workspace was accepted"
else
  ok "non-repo workspace: rc 2"
fi
git -C "$WS" checkout -q -- file.go

# ── shared --check mode (opencode plugin / cursor wrapper core) ──────────────
# 15. Trip: rc 1, checklist on stdout, tree signature on stderr.
printf 'check\n' >>"$WS/file.go"
rc=0
errfile="$TMP_ROOT/check-err"
out="$(AIDC_REVIEW_HOOK_WORKSPACE="$WS" bash "$HOOK" --check 2>"$errfile")" || rc=$?
if [[ "$rc" -eq 1 ]] \
   && printf '%s' "$out" | grep -q 'aidc-review: no pre-completion review' \
   && printf '%s' "$out" | grep -q 'aidc-review-record' \
   && grep -Eq '^sig [0-9a-f]{64}$' "$errfile"; then
  ok "15. --check trip: rc 1, checklist on stdout, sig on stderr"
else
  fail "--check trip case: rc=$rc out=$out err=$(cat "$errfile")"
fi

# 16. Allow after a record: rc 0, no output.
record "check-mode review" >/dev/null
out="$(AIDC_REVIEW_HOOK_WORKSPACE="$WS" bash "$HOOK" --check 2>/dev/null)" && rc=0 || rc=$?
if [[ "$rc" -eq 0 && -z "$out" ]]; then
  ok "16. --check allow: rc 0, silent"
else
  fail "--check allow case: rc=$rc out=$out"
fi

# 17. Docs-only: rc 0.
rm -f "$WS/.ai-container/review-done"
git -C "$WS" checkout -q -- file.go
printf 'notes\n' >"$WS/NOTES.md"
rc=0
AIDC_REVIEW_HOOK_WORKSPACE="$WS" bash "$HOOK" --check >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "17. --check docs-only: allow"
else
  fail "--check docs-only case: rc=$rc"
fi
rm "$WS/NOTES.md"

# 18. Missing helper: rc 2 (fail-open skip signal for callers).
printf 'check\n' >>"$WS/file.go"
mv "$WS/.devcontainer/scripts/aidc-review-record.sh" "$TMP_ROOT/record-away2"
rc=0
AIDC_REVIEW_HOOK_WORKSPACE="$WS" bash "$HOOK" --check >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 2 ]]; then
  ok "18. --check helper missing: rc 2 skip"
else
  fail "--check helper-missing case: rc=$rc"
fi
mv "$TMP_ROOT/record-away2" "$WS/.devcontainer/scripts/aidc-review-record.sh"
git -C "$WS" checkout -q -- file.go
rm -f "$WS/.ai-container/review-done"

# ── cursor stop-hook wrapper ─────────────────────────────────────────────────
WRAPPER="$WS/.devcontainer/scripts/aidc-review-gate-cursor.sh"
cp "$REPO_ROOT/templates/devcontainer/scripts/aidc-review-gate-cursor.sh.tmpl" "$WRAPPER"
chmod +x "$WRAPPER"
# The wrapper gates through the hook installed in the fixture workspace.
cp "$REPO_ROOT/templates/devcontainer/scripts/aidc-review-hook.sh.tmpl" \
  "$WS/.devcontainer/scripts/aidc-review-hook.sh"
chmod +x "$WS/.devcontainer/scripts/aidc-review-hook.sh"

# ── cursor stop-hook wrapper ─────────────────────────────────────────────────
WRAPPER="$WS/.devcontainer/scripts/aidc-review-gate-cursor.sh"
cp "$REPO_ROOT/templates/devcontainer/scripts/aidc-review-gate-cursor.sh.tmpl" "$WRAPPER"
chmod +x "$WRAPPER"

# 19. Completed + trip -> followup_message JSON carrying the checklist.
printf 'cursor\n' >>"$WS/file.go"
payload="{\"status\":\"completed\",\"workspace_roots\":[\"$WS\"],\"conversation_id\":\"c1\"}"
out="$(AIDC_REVIEW_HOOK_WORKSPACE="$WS" bash "$WRAPPER" <<<"$payload")"
if printf '%s' "$out" | python3 -c 'import json,sys
d = json.load(sys.stdin)
msg = d["followup_message"]
sys.exit(0 if "aidc-review: no pre-completion review" in msg and "aidc-review-record" in msg else 1)' 2>/dev/null; then
  ok "19. cursor wrapper: trip emits followup_message with checklist"
else
  fail "cursor wrapper trip case: out=$out"
fi

# 20. Non-completed status -> silent allow.
out="$(AIDC_REVIEW_HOOK_WORKSPACE="$WS" \
  bash "$WRAPPER" <<<"{\"status\":\"error\",\"workspace_roots\":[\"$WS\"]}")"
if [[ -z "$out" ]]; then
  ok "20. cursor wrapper: error status allows silently"
else
  fail "cursor wrapper error-status case: out=$out"
fi

# 21. Completed + allowed (record present) -> silent.
record "cursor review" >/dev/null
out="$(AIDC_REVIEW_HOOK_WORKSPACE="$WS" bash "$WRAPPER" <<<"$payload")"
if [[ -z "$out" ]]; then
  ok "21. cursor wrapper: recorded review allows silently"
else
  fail "cursor wrapper allow case: out=$out"
fi
rm -f "$WS/.ai-container/review-done"
git -C "$WS" checkout -q -- file.go

# ── cursor hooks.json merge (bootstrap) ──────────────────────────────────────
# 22. Adds the stop entry, preserves rtk/user entries, idempotent.
. "$BOOTSTRAP" 2>/dev/null || true   # guarded dispatch: safe to source
home_dir="$TMP_ROOT/home"
scripts_dir="$WS/.devcontainer/scripts"
CURSOR_HOOKS="$home_dir/.cursor/hooks.json"
mkdir -p "$home_dir/.cursor"
printf '{\n  "version": 1,\n  "hooks": {\n    "preToolUse": [\n      {"command": "rtk hook cursor", "matcher": "Shell"}\n    ]\n  }\n}\n' >"$CURSOR_HOOKS"
wire_aidc_review_cursor
wire_aidc_review_cursor
if python3 - "$CURSOR_HOOKS" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
stops = cfg["hooks"].get("stop", [])
pre = cfg["hooks"].get("preToolUse", [])
ok = (
    len([e for e in stops if "aidc-review-gate-cursor.sh" in e.get("command", "")]) == 1
    and all(e.get("loop_limit") == 5 for e in stops)
    and len(pre) == 1 and pre[0]["command"] == "rtk hook cursor"
    and cfg.get("version") == 1
)
sys.exit(0 if ok else 1)
PY
then
  ok "22. cursor hooks.json merge: stop entry added, rtk preserved, idempotent"
else
  fail "cursor hooks.json merge case: $(cat "$CURSOR_HOOKS")"
fi

# 23. No wrapper in scaffold -> wiring is a no-op (fail-open for non-aidc).
# shellcheck disable=SC2034  # consumed by the sourced wire function as a global
scripts_dir="$TMP_ROOT/nowhere"
printf '{\n  "version": 1,\n  "hooks": {"preToolUse": [{"command": "rtk hook cursor"}]}\n}\n' >"$CURSOR_HOOKS"
wire_aidc_review_cursor
if python3 -c 'import json,sys
cfg = json.load(open(sys.argv[1]))
sys.exit(0 if "stop" not in cfg["hooks"] else 1)' "$CURSOR_HOOKS" 2>/dev/null; then
  ok "23. cursor wiring without wrapper: no-op"
else
  fail "cursor no-wrapper case: $(cat "$CURSOR_HOOKS")"
fi

# ── settings.json seeding (bootstrap) ────────────────────────────────────────
SETTINGS="$TMP_ROOT/settings.json"
SCAN_CMD="/workspace/.devcontainer/scripts/aidc-scan-hook.sh"
REVIEW_CMD="/workspace/.devcontainer/scripts/aidc-review-hook.sh"
count_hook() { # <command> -> number of matching Stop hook entries
  jq --arg c "$1" '[.hooks.Stop[]?.hooks[]? | select(.command == $c)] | length' "$SETTINGS"
}

# 15. Seeding into a missing file creates BOTH guardrail hooks + MCP posture.
rm -f "$SETTINGS"
ensure_agent_guardrail_settings "$SETTINGS"
if [[ "$(count_hook "$SCAN_CMD")" == "1" ]] \
   && [[ "$(count_hook "$REVIEW_CMD")" == "1" ]] \
   && jq -e '.enableAllProjectMcpServers == false' "$SETTINGS" >/dev/null; then
  ok "24. seeding creates both Stop hooks + MCP posture"
else
  fail "seeded settings: $(cat "$SETTINGS")"
fi

# 16. Idempotent, and user hooks survive.
jq '.hooks.PreToolUse = [{"matcher":"Bash","hooks":[{"type":"command","command":"rtk hook"}]}]' \
  "$SETTINGS" >"$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
ensure_agent_guardrail_settings "$SETTINGS"
ensure_agent_guardrail_settings "$SETTINGS"
if [[ "$(count_hook "$SCAN_CMD")" == "1" ]] \
   && [[ "$(count_hook "$REVIEW_CMD")" == "1" ]] \
   && jq -e '.hooks.PreToolUse[0].hooks[0].command == "rtk hook"' "$SETTINGS" >/dev/null; then
  ok "25. seeding is idempotent and preserves other hooks"
else
  fail "idempotence: scan=$(count_hook "$SCAN_CMD") review=$(count_hook "$REVIEW_CMD")"
fi

# 17. Scan knob off removes only the scan hook.
AIDC_ENFORCE_SCAN_HOOK=0 ensure_agent_guardrail_settings "$SETTINGS"
if [[ "$(count_hook "$SCAN_CMD")" == "0" ]] && [[ "$(count_hook "$REVIEW_CMD")" == "1" ]]; then
  ok "26. AIDC_ENFORCE_SCAN_HOOK=0 removes only the scan hook"
else
  fail "scan-knob removal: scan=$(count_hook "$SCAN_CMD") review=$(count_hook "$REVIEW_CMD")"
fi

# 18. Both knobs off removes both hooks; the emptied Stop event is pruned and
#     user hooks survive.
AIDC_ENFORCE_SCAN_HOOK=0 AIDC_ENFORCE_REVIEW_HOOK=0 ensure_agent_guardrail_settings "$SETTINGS"
if [[ "$(count_hook "$SCAN_CMD")" == "0" ]] && [[ "$(count_hook "$REVIEW_CMD")" == "0" ]] \
   && jq -e '.hooks | has("Stop") | not' "$SETTINGS" >/dev/null \
   && jq -e '.hooks.PreToolUse[0].hooks[0].command == "rtk hook"' "$SETTINGS" >/dev/null; then
  ok "27. both knobs off: both hooks removed, Stop pruned, user hooks kept"
else
  fail "knob removal: scan=$(count_hook "$SCAN_CMD") review=$(count_hook "$REVIEW_CMD") settings=$(cat "$SETTINGS")"
fi

# 19. Re-seeding with both knobs default restores both hooks.
ensure_agent_guardrail_settings "$SETTINGS"
if [[ "$(count_hook "$SCAN_CMD")" == "1" ]] && [[ "$(count_hook "$REVIEW_CMD")" == "1" ]]; then
  ok "28. re-seeding restores both hooks"
else
  fail "restore case"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
