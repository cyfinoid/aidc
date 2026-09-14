#!/usr/bin/env bash
#
# Unit tests for strip_host_hooks() in the devcontainer bootstrap script.
#
# Sources the template (made importable by its exec-guard) and exercises the
# hook-stripping logic on fixture settings.json blobs: gryph/cot commands are
# removed, rtk + user hooks are preserved, emptied events are pruned, the
# transform is idempotent, and malformed/missing input doesn't crash.
#
# Run:   .github/scripts/test-bootstrap-state.sh
# CI:    wired into .github/workflows/shellcheck.yml
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
tmpl="$repo_root/templates/devcontainer/scripts/bootstrap-state.sh.tmpl"

# Source the prod template. Its exec-guard stops the init/sync dispatch from
# firing; we only want the strip_host_hooks() definition.
# shellcheck source=../../../templates/devcontainer/scripts/bootstrap-state.sh.tmpl
# shellcheck disable=SC1090
source "$tmpl"

pass=0
fail=0
assert_eq() { # <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    printf '  ok   %s\n' "$1"; pass=$((pass + 1))
  else
    printf '  FAIL %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3" >&2
    fail=$((fail + 1))
  fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- Case 1: mixed PreToolUse keeps rtk, drops gryph; cot/gryph events pruned
f1="$tmp/c1.json"
cat >"$f1" <<'JSON'
{
  "model": "opus",
  "hooks": {
    "PreToolUse": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "gryph _hook claude-code PreToolUse"}]},
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "rtk hook claude"}]}
    ],
    "UserPromptSubmit": [
      {"hooks": [{"type": "command", "command": "/Users/ion1/.cot/bin/cot hook claude"}]}
    ],
    "Stop": [
      {"hooks": [{"type": "command", "command": "cot hook claude"}]}
    ],
    "Notification": [
      {"hooks": [{"type": "command", "command": "gryph _hook claude-code Notification"}]}
    ]
  }
}
JSON
strip_host_hooks "$f1"
assert_eq "only PreToolUse event survives" '["PreToolUse"]' "$(jq -c '.hooks | keys' "$f1")"
assert_eq "PreToolUse keeps rtk entry only" \
  '[{"matcher":"Bash","hooks":[{"type":"command","command":"rtk hook claude"}]}]' \
  "$(jq -c '.hooks.PreToolUse' "$f1")"
assert_eq "non-hook keys preserved" 'opus' "$(jq -r '.model' "$f1")"

# --- Case 2: a user hook next to a host hook in the same entry is preserved --
f2="$tmp/c2.json"
cat >"$f2" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "*", "hooks": [
        {"type": "command", "command": "gryph _hook claude-code PreToolUse"},
        {"type": "command", "command": "/usr/local/bin/myfmt --check"}
      ]}
    ]
  }
}
JSON
strip_host_hooks "$f2"
assert_eq "user hook preserved" '/usr/local/bin/myfmt --check' \
  "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$f2")"

# --- Case 3: idempotent — a second pass is a byte-for-byte no-op -------------
strip_host_hooks "$f1"
cp "$f1" "$tmp/c1.once"
strip_host_hooks "$f1"
if cmp -s "$tmp/c1.once" "$f1"; then
  assert_eq "idempotent on re-run" "same" "same"
else
  assert_eq "idempotent on re-run" "same" "different"
fi

# --- Case 4: nothing to strip -> file bytes unchanged -----------------------
f4="$tmp/c4.json"
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"rtk hook claude"}]}]}}' >"$f4"
before="$(cat "$f4")"
strip_host_hooks "$f4"
assert_eq "no rewrite when nothing matches" "$before" "$(cat "$f4")"

# --- Case 5: malformed JSON exits 0 and leaves the file untouched -----------
f5="$tmp/c5.json"
printf 'this is not json' >"$f5"
strip_host_hooks "$f5" && rc=0 || rc=$?
assert_eq "malformed JSON exits 0" '0' "$rc"
assert_eq "malformed file untouched" 'this is not json' "$(cat "$f5")"

# --- Case 6: missing file is a no-op (exit 0) -------------------------------
strip_host_hooks "$tmp/does-not-exist.json" && rc=0 || rc=$?
assert_eq "missing file exits 0" '0' "$rc"

# --- ensure_rtk_sandbox_write -----------------------------------------------
rtk_dir="$tmp/rtk-data"

# Case 7: empty settings gains sandbox.filesystem.allowWrite
f7="$tmp/c7.json"
printf '{}' >"$f7"
ensure_rtk_sandbox_write "$f7" "$rtk_dir"
assert_eq "empty settings gets allowWrite" "$rtk_dir" \
  "$(jq -r '.sandbox.filesystem.allowWrite[0]' "$f7")"

# Case 8: existing allowWrite entries are preserved, path appended
f8="$tmp/c8.json"
printf '{"sandbox":{"filesystem":{"allowWrite":["/tmp/build"]}}}' >"$f8"
ensure_rtk_sandbox_write "$f8" "$rtk_dir"
assert_eq "existing allowWrite preserved+appended" \
  '["/tmp/build","'"$rtk_dir"'"]' \
  "$(jq -c '.sandbox.filesystem.allowWrite' "$f8")"

# Case 9: idempotent when the path is already listed
cp "$f8" "$tmp/c8.once"
ensure_rtk_sandbox_write "$f8" "$rtk_dir"
if cmp -s "$tmp/c8.once" "$f8"; then
  assert_eq "allowWrite idempotent" "same" "same"
else
  assert_eq "allowWrite idempotent" "same" "different"
fi

# Case 10: malformed JSON / missing file are no-ops
f10="$tmp/c10.json"
printf 'not json' >"$f10"
ensure_rtk_sandbox_write "$f10" "$rtk_dir" && rc=0 || rc=$?
assert_eq "sandbox patch malformed JSON exits 0" '0' "$rc"
assert_eq "sandbox patch malformed file untouched" 'not json' "$(cat "$f10")"
ensure_rtk_sandbox_write "$tmp/no-such-settings.json" "$rtk_dir" && rc=0 || rc=$?
assert_eq "sandbox patch missing file exits 0" '0' "$rc"

# Case 11: non-dict sandbox is left alone (don't clobber)
f11="$tmp/c11.json"
printf '{"sandbox":"off"}' >"$f11"
ensure_rtk_sandbox_write "$f11" "$rtk_dir"
assert_eq "non-dict sandbox untouched" '{"sandbox":"off"}' "$(cat "$f11")"

echo
echo "passed=$pass failed=$fail"
[[ "$fail" -eq 0 ]] || exit 1
