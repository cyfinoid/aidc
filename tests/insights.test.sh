#!/usr/bin/env bash
#
# Unit tests for aidc insights (lib/aidc/status.sh) over fixture transcripts
# and a fixture scan-hook log. Run with: bash tests/insights.test.sh
# shellcheck disable=SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

. "$REPO_ROOT/lib/aidc.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

WS="$TMP_ROOT/ws"
mkdir -p "$WS/.ai-container"
aidc::default_workspace() { printf '%s\n' "$WS"; }

CLAUDE_ROOT="$TMP_ROOT/claude-projects"
export AIDC_INSIGHTS_CLAUDE_ROOT="$CLAUDE_ROOT"

# 1. Nothing synced, no log: friendly empties, exit 0.
out="$(aidc::cmd_insights)" || fail "insights crashed on empty state"
if printf '%s' "$out" | grep -q 'claude sessions: 0' \
   && printf '%s' "$out" | grep -q 'none synced yet' \
   && printf '%s' "$out" | grep -q 'no scan-hook activity'; then
  ok "empty state reports friendly zeros"
else
  fail "empty state: $out"
fi

# 2. Fixture transcripts are counted, top projects listed.
mkdir -p "$CLAUDE_ROOT/-workspace-projA" "$CLAUDE_ROOT/-workspace-projB"
printf '{"type":"user"}\n' >"$CLAUDE_ROOT/-workspace-projA/s1.jsonl"
printf '{"type":"user"}\n' >"$CLAUDE_ROOT/-workspace-projA/s2.jsonl"
printf '{"type":"user"}\n' >"$CLAUDE_ROOT/-workspace-projB/s3.jsonl"
out="$(aidc::cmd_insights)"
if printf '%s' "$out" | grep -q 'claude sessions: 3' \
   && printf '%s' "$out" | grep -q '2  -workspace-projA' \
   && printf '%s' "$out" | grep -q '1  -workspace-projB'; then
  ok "session counts + top projects"
else
  fail "counts: $out"
fi

# 3. Scan-hook log outcomes tallied.
cat >"$WS/.ai-container/scan-hook.log" <<'EOF'
2026-07-01T10:00:00Z clean
2026-07-02T10:00:00Z findings {"failures":1}
2026-07-03T10:00:00Z clean
2026-07-03T11:00:00Z error rc=2 (fail-open)
EOF
out="$(aidc::cmd_insights)"
if printf '%s' "$out" | grep -q 'clean passes:    2' \
   && printf '%s' "$out" | grep -q 'blocked (found): 1' \
   && printf '%s' "$out" | grep -q 'infra errors:    1'; then
  ok "scan-hook outcomes tallied"
else
  fail "hook tally: $out"
fi

# 4. --since filters the hook log (lexical ISO compare).
out="$(aidc::cmd_insights --since 2026-07-03)"
if printf '%s' "$out" | grep -q 'clean passes:    1' \
   && printf '%s' "$out" | grep -q 'blocked (found): 0'; then
  ok "--since filters hook outcomes"
else
  fail "since filter: $out"
fi

# 5. --since without a date is a usage error.
rc=0
(aidc::cmd_insights --since) >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] && ok "--since without a date fails" || fail "--since accepted no date"

# 6. Unknown flag names the valid ones.
out="$( (aidc::cmd_insights --bogus) 2>&1 )" || true
if printf '%s' "$out" | grep -q -- '--since'; then
  ok "unknown flag error names --since"
else
  fail "unknown flag: $out"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
