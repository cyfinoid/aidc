#!/usr/bin/env bash
#
# Unit tests for `aidc sync-sessions` transcript path rewriting.
#
#   - aidc::sync_session_tool rewrites the in-container mount root (/workspace)
#     to the real host workspace path in synced *.json / *.jsonl transcripts,
#     so logs copied to the host reference paths that exist on this machine.
#   - only JSON/JSONL files are rewritten; other files are left byte-for-byte.
#   - the rewrite is a no-op when the workspace already is /workspace.
#   - workspace paths containing sed-significant characters (&, |, \) survive.
#
# The container plumbing (compose exec + the tar stream) is stubbed so the test
# is hermetic and needs neither Docker nor a running container: the stubbed
# aidc::compose emits a tar of a local fixture tree, which the real extract +
# rewrite path then process.
#
# Run with: bash tests/sync-sessions.test.sh
# shellcheck disable=SC1091
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

# Container plumbing stubs. Function names resolve at call time, so redefining
# after sourcing is enough. The fixture the "container" ships is per-test.
FIXTURE_SRC=""
aidc::compose_capture() { return 0; }              # test -d "$container_src" passes
aidc::compose() { tar -C "$FIXTURE_SRC" -cf - .; }  # emit the fixture as the tar stream
aidc::log() { :; }

# Build a fresh container-side fixture and point HOME at a clean host tree.
# Sets FIXTURE_SRC, HOME and host_dst (claude transcripts) in the caller's
# shell — must NOT run in a subshell or the exports are lost.
setup_case() {
  local case="$1"
  FIXTURE_SRC="$TMP_ROOT/$case/src"
  export HOME="$TMP_ROOT/$case/home"
  mkdir -p "$FIXTURE_SRC" "$HOME"
  host_dst="$HOME/.claude/projects"
}

# ── 1. /workspace paths are rewritten to the host workspace in .jsonl/.json ──
setup_case rewrite
printf '{"cwd":"/workspace/app","file":"/workspace/app/main.go"}\n' >"$FIXTURE_SRC/a.jsonl"
printf '{"root":"/workspace"}\n' >"$FIXTURE_SRC/b.json"
ws="/home/alice/projects/app"
aidc::sync_session_tool "$ws" claude
if grep -q '"cwd":"/home/alice/projects/app/app"' "$host_dst/a.jsonl" \
   && grep -q '"file":"/home/alice/projects/app/app/main.go"' "$host_dst/a.jsonl" \
   && grep -q '"root":"/home/alice/projects/app"' "$host_dst/b.json"; then
  ok "/workspace rewritten to host path in .jsonl and .json"
else
  fail "rewrite did not produce host paths: $(cat "$host_dst"/*.json*)"
fi

# ── 2. non-JSON files are left untouched ──
setup_case skip-other
printf 'see /workspace/app\n' >"$FIXTURE_SRC/notes.txt"
aidc::sync_session_tool "/home/alice/app" claude
if grep -q 'see /workspace/app' "$host_dst/notes.txt"; then
  ok "non-JSON files are not rewritten"
else
  fail "notes.txt was modified: $(cat "$host_dst/notes.txt")"
fi

# ── 3. no-op when the workspace already is /workspace ──
setup_case noop
printf '{"file":"/workspace/x"}\n' >"$FIXTURE_SRC/c.jsonl"
aidc::sync_session_tool "/workspace" claude
if grep -q '{"file":"/workspace/x"}' "$host_dst/c.jsonl"; then
  ok "no rewrite when workspace is /workspace"
else
  fail "unexpected rewrite for /workspace workspace: $(cat "$host_dst/c.jsonl")"
fi

# ── 4. sed-significant characters in the host path survive ──
setup_case special
printf '{"file":"/workspace/x"}\n' >"$FIXTURE_SRC/d.jsonl"
ws='/home/a&b/c|d/e\f'
aidc::sync_session_tool "$ws" claude
if grep -Fq '{"file":"/home/a&b/c|d/e\f/x"}' "$host_dst/d.jsonl"; then
  ok "workspace path with & | \\ is inserted literally"
else
  fail "special-char host path mangled: $(cat "$host_dst/d.jsonl")"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
