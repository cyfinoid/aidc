#!/usr/bin/env bash
#
# Unit tests for `aidc sync-sessions` — transcript path rewriting and the
# opencode data-dir mapping.
#
#   - aidc::sync_session_tool rewrites the in-container mount root (/workspace)
#     to the real host workspace path in synced *.json / *.jsonl transcripts,
#     so logs copied to the host reference paths that exist on this machine.
#   - only JSON/JSONL files are rewritten; other files are left byte-for-byte.
#   - the rewrite is a no-op when the workspace already is /workspace.
#   - workspace paths containing sed-significant characters (&, |, \) survive.
#   - opencode sessions sync FROM the XDG data dir (~/.local/share/opencode —
#     never ~/.config/opencode, which opencode only uses for config), gated on
#     actual session artifacts (storage/ or opencode.db), excluding auth.json
#     (credentials never leave the container) and cache dirs, and land in an
#     aidc-owned host subtree (~/.local/share/aidc/sessions/opencode/<slug>/)
#     so the host's own opencode database is never clobbered. The binary
#     opencode.db is not sed-rewritten (only *.json/*.jsonl are).
#
# The container plumbing (compose exec + the tar stream) is stubbed so the test
# is hermetic and needs neither Docker nor a running container: the stubbed
# aidc::compose runs the same `tar`/`test` argv the container would see, but
# against a local fixture tree standing in for the container filesystem.
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
# after sourcing is enough. Both stubs receive the sync path's argv as
# `<ws> exec -T workspace <cmd...>`; they drop the compose prefix, rewrite any
# /home/vscode-prefixed path in <cmd> to point into the fixture tree (which
# mirrors the container's /home/vscode layout), and run the command locally —
# so the gate probe (`test ...`) and the tar stream behave as if in-container.
CONTAINER_ROOT=""
STUB_ARGV=()
stub_translate_argv() {
  STUB_ARGV=()
  local a
  for a in "$@"; do
    case "$a" in
      /home/vscode|/home/vscode/*) a="$CONTAINER_ROOT${a#/home/vscode}" ;;
    esac
    STUB_ARGV+=("$a")
  done
}
aidc::compose_capture() {
  shift 4  # <ws> exec -T workspace
  stub_translate_argv "$@"
  "${STUB_ARGV[@]}"
}
aidc::compose() {
  shift 4  # <ws> exec -T workspace
  stub_translate_argv "$@"
  "${STUB_ARGV[@]}"
}
aidc::log() { :; }

# Build a fresh container-side fixture (standing in for the container's
# /home/vscode) and point HOME at a clean host tree. Sets CONTAINER_ROOT, HOME
# and host_dst (claude transcripts) in the caller's shell — must NOT run in a
# subshell or the exports are lost.
setup_case() {
  local case="$1"
  CONTAINER_ROOT="$TMP_ROOT/$case/container-home"
  export HOME="$TMP_ROOT/$case/home"
  mkdir -p "$CONTAINER_ROOT" "$HOME"
  host_dst="$HOME/.claude/projects"
}

# ── 1. /workspace paths are rewritten to the host workspace in .jsonl/.json ──
setup_case rewrite
mkdir -p "$CONTAINER_ROOT/.claude/projects"
printf '{"cwd":"/workspace/app","file":"/workspace/app/main.go"}\n' >"$CONTAINER_ROOT/.claude/projects/a.jsonl"
printf '{"root":"/workspace"}\n' >"$CONTAINER_ROOT/.claude/projects/b.json"
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
mkdir -p "$CONTAINER_ROOT/.claude/projects"
printf 'see /workspace/app\n' >"$CONTAINER_ROOT/.claude/projects/notes.txt"
aidc::sync_session_tool "/home/alice/app" claude
if grep -q 'see /workspace/app' "$host_dst/notes.txt"; then
  ok "non-JSON files are not rewritten"
else
  fail "notes.txt was modified: $(cat "$host_dst/notes.txt")"
fi

# ── 3. no-op when the workspace already is /workspace ──
setup_case noop
mkdir -p "$CONTAINER_ROOT/.claude/projects"
printf '{"file":"/workspace/x"}\n' >"$CONTAINER_ROOT/.claude/projects/c.jsonl"
aidc::sync_session_tool "/workspace" claude
if grep -q '{"file":"/workspace/x"}' "$host_dst/c.jsonl"; then
  ok "no rewrite when workspace is /workspace"
else
  fail "unexpected rewrite for /workspace workspace: $(cat "$host_dst/c.jsonl")"
fi

# ── 4. sed-significant characters in the host path survive ──
setup_case special
mkdir -p "$CONTAINER_ROOT/.claude/projects"
printf '{"file":"/workspace/x"}\n' >"$CONTAINER_ROOT/.claude/projects/d.jsonl"
ws='/home/a&b/c|d/e\f'
aidc::sync_session_tool "$ws" claude
if grep -Fq '{"file":"/home/a&b/c|d/e\f/x"}' "$host_dst/d.jsonl"; then
  ok "workspace path with & | \\ is inserted literally"
else
  fail "special-char host path mangled: $(cat "$host_dst/d.jsonl")"
fi

# ── 5. opencode syncs from the XDG data dir, excluded files stay behind ──
# Mirror the container layout: ~/.local/share/opencode/{opencode.db,auth.json,log/…}.
setup_case opencode-data-dir
oc_data="$CONTAINER_ROOT/.local/share/opencode"
mkdir -p "$oc_data/log" "$oc_data/storage/session"
printf 'binary-db-bytes' >"$oc_data/opencode.db"
printf 'SECRET' >"$oc_data/auth.json"
printf 'logline\n' >"$oc_data/log/debug.log"
printf '{"cwd":"/workspace/app"}\n' >"$oc_data/storage/session/s1.json"
ws="/home/alice/projects/app"
aidc::sync_session_tool "$ws" opencode
# Expected host dst: ~/.local/share/aidc/sessions/opencode/<repo-slug>/ —
# resolve the slug dir via glob (one repo synced into this HOME).
oc_dst="$(echo "$HOME"/.local/share/aidc/sessions/opencode/*/)"
[[ -d "$oc_dst" ]] || oc_dst="$HOME/.local/share/aidc/sessions/opencode"
if [[ -f "$oc_dst/opencode.db" && -f "$oc_dst/storage/session/s1.json" ]] \
   && ! [[ -e "$oc_dst/auth.json" || -e "$oc_dst/log" ]] \
   && ! grep -rq 'SECRET' "$oc_dst"; then
  ok "opencode: db + storage synced from data dir, auth.json/log excluded"
else
  fail "opencode sync layout wrong: $(find "$HOME/.local/share/aidc" -mindepth 1 2>/dev/null | head -20)"
fi
# ...and the host's own opencode data dir is never a target:
if [[ ! -e "$HOME/.local/share/opencode" ]]; then
  ok "opencode: host's own ~/.local/share/opencode untouched"
else
  fail "opencode sync wrote into the host's own data dir"
fi
# JSON transcripts still get the /workspace rewrite…
if grep -q '"cwd":"/home/alice/projects/app/app"' "$oc_dst/storage/session/s1.json"; then
  ok "opencode: /workspace rewritten in synced storage JSON"
else
  fail "storage JSON not rewritten: $(cat "$oc_dst/storage/session/s1.json")"
fi
# …but the binary db must NOT be sed-rewritten (it would be corrupted):
if cmp -s <(printf 'binary-db-bytes') "$oc_dst/opencode.db"; then
  ok "opencode: binary opencode.db left byte-for-byte"
else
  fail "opencode.db was modified by the rewrite pass"
fi

# ── 6. opencode gate: data dir without session artifacts syncs nothing ──
setup_case opencode-empty
oc_data="$CONTAINER_ROOT/.local/share/opencode"
mkdir -p "$oc_data/log"
printf 'SECRET' >"$oc_data/auth.json"
aidc::sync_session_tool "/home/alice/app" opencode
if [[ ! -e "$HOME/.local/share/aidc" ]]; then
  ok "opencode: no session artifacts → nothing synced, no host dir created"
else
  fail "opencode synced (or created host dirs) despite having no sessions"
fi

# ── 7. opencode legacy layout: storage/ without opencode.db still syncs ──
setup_case opencode-legacy
oc_data="$CONTAINER_ROOT/.local/share/opencode"
mkdir -p "$oc_data/storage/session"
printf '{"info":"/workspace/x"}\n' >"$oc_data/storage/session/old.json"
aidc::sync_session_tool "/home/alice/app" opencode
oc_dst="$(echo "$HOME"/.local/share/aidc/sessions/opencode/*/)"
if [[ -f "$oc_dst/storage/session/old.json" ]] \
   && grep -Fq '"info":"/home/alice/app/x"' "$oc_dst/storage/session/old.json"; then
  ok "opencode: legacy storage/ layout synced + rewritten"
else
  fail "legacy storage/ sync failed: $(find "$HOME/.local/share/aidc" -type f 2>/dev/null)"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
