#!/usr/bin/env bash
#
# Unit tests for aidc upgrade + the conservative implicit-scaffold behavior
# (lib/aidc.sh). Pure filesystem — no docker, no network.
#
# Run with: bash tests/upgrade.test.sh
# shellcheck disable=SC2034,SC1091,SC2317
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

. "$REPO_ROOT/lib/aidc.sh"
AIDC_ROOT="$REPO_ROOT"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

WS="$TMP_ROOT/ws"

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

aidc::default_workspace() { printf '%s\n' "$WS"; }

make_scaffold() {
  rm -rf "$WS"
  mkdir -p "$WS/.ai-container"
  aidc::write_project_env "$WS/.ai-container/project.env" "$WS" \
    "fixture-00000000" "$TMP_ROOT/core" "project/fixture" "$TMP_ROOT/worktree"
  AIDC_SCAFFOLD_MODE=overwrite
  aidc::refresh_scaffold "$WS" "fixture-00000000" "$TMP_ROOT/core" "project/fixture" "$TMP_ROOT/worktree"
}

# 1. Fresh scaffold: upgrade reports current and changes nothing.
make_scaffold
before="$(find "$WS" -type f -exec md5sum {} + | sort)"
out="$(aidc::cmd_upgrade </dev/null)" || fail "upgrade on fresh scaffold exited non-zero"
after="$(find "$WS" -type f -exec md5sum {} + | sort)"
if printf '%s' "$out" | grep -q 'already current' && [[ "$before" == "$after" ]]; then
  ok "fresh scaffold: already current, nothing changed"
else
  fail "fresh scaffold: out='$out'"
fi

# 2. Locally-edited managed file: listed with a diff; -y applies with backup.
make_scaffold
printf '\n# LOCAL-EDIT\n' >>"$WS/.devcontainer/Dockerfile"
out="$(aidc::cmd_upgrade --dry-run </dev/null)"
if printf '%s' "$out" | grep -q 'update: .devcontainer/Dockerfile' \
   && printf '%s' "$out" | grep -q -- '-# LOCAL-EDIT' \
   && printf '%s' "$out" | grep -q 'dry run'; then
  ok "edited managed file listed with unified diff (dry run)"
else
  fail "dry-run listing: $out"
fi
if grep -q 'LOCAL-EDIT' "$WS/.devcontainer/Dockerfile"; then
  ok "dry run left the file untouched"
else
  fail "dry run modified the file"
fi
out="$(aidc::cmd_upgrade -y </dev/null)"
if ! grep -q 'LOCAL-EDIT' "$WS/.devcontainer/Dockerfile" \
   && cmp -s "$REPO_ROOT/templates/devcontainer/Dockerfile.tmpl" "$WS/.devcontainer/Dockerfile"; then
  ok "-y restores the managed file to the template"
else
  fail "apply did not restore the Dockerfile"
fi
backup_file="$(find "$WS/.ai-container/backup" -name Dockerfile 2>/dev/null | head -1)"
if [[ -n "$backup_file" ]] && grep -q 'LOCAL-EDIT' "$backup_file"; then
  ok "local edit preserved in a backup"
else
  fail "backup missing or without the local edit"
fi

# 3. Stale stamp only: upgrade proceeds and preserves user project.env settings.
make_scaffold
sed_i() { local f="$1"; shift; local tmp; tmp="$(mktemp)"; sed "$@" "$f" >"$tmp"; mv "$tmp" "$f"; }
sed_i "$WS/.ai-container/project.env" 's/^AIDC_VERSION=.*/AIDC_VERSION=0.0.1/'
printf 'AIDC_ENABLE_EGRESS_FIREWALL=1\n' >>"$WS/.ai-container/project.env"
out="$(aidc::cmd_upgrade -y </dev/null)"
stamp="$(sed -n 's/^AIDC_VERSION=\(.*\)$/\1/p' "$WS/.ai-container/project.env")"
if [[ "$stamp" == "$AIDC_VERSION" ]]; then
  ok "stale stamp updated to current version"
else
  fail "stamp not updated: $stamp"
fi
if grep -q '^AIDC_ENABLE_EGRESS_FIREWALL=1$' "$WS/.ai-container/project.env"; then
  ok "user project.env settings survive the stamp update"
else
  fail "user project.env setting lost"
fi

# 4. Missing managed file: reported as create and recreated on apply.
make_scaffold
rm "$WS/.devcontainer/compose.firewall.yaml"
out="$(aidc::cmd_upgrade --dry-run </dev/null)"
if printf '%s' "$out" | grep -q 'create: .devcontainer/compose.firewall.yaml'; then
  ok "missing managed file reported as create"
else
  fail "missing file not reported: $out"
fi
aidc::cmd_upgrade -y </dev/null >/dev/null
if [[ -f "$WS/.devcontainer/compose.firewall.yaml" ]]; then
  ok "missing managed file recreated on apply"
else
  fail "missing file not recreated"
fi

# 5. Non-interactive without -y refuses to apply.
make_scaffold
printf '\n# EDIT2\n' >>"$WS/.devcontainer/compose.yaml"
rc=0
(aidc::cmd_upgrade </dev/null) >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'EDIT2' "$WS/.devcontainer/compose.yaml"; then
  ok "non-interactive apply without -y refused"
else
  fail "non-interactive apply: rc=$rc"
fi

# 6. User-owned files are untouched by apply.
make_scaffold
printf '# my setup\n' >>"$WS/.devcontainer/project-setup.sh"
printf '\n# my changelog note\n' >>"$WS/CHANGELOG.md"
printf '\n# EDIT3\n' >>"$WS/.devcontainer/Dockerfile"   # force an update
aidc::cmd_upgrade -y </dev/null >/dev/null
if grep -q 'my setup' "$WS/.devcontainer/project-setup.sh" \
   && grep -q 'my changelog note' "$WS/CHANGELOG.md"; then
  ok "user-owned files untouched by apply"
else
  fail "user-owned file was modified"
fi

# 7. Marker-merge: user content outside the block survives apply.
make_scaffold
printf '\n## My project notes\ndo not lose this\n' >>"$WS/CLAUDE.md"
printf '\n# EDIT4\n' >>"$WS/.devcontainer/Dockerfile"
aidc::cmd_upgrade -y </dev/null >/dev/null
if grep -q 'do not lose this' "$WS/CLAUDE.md" \
   && grep -Fq "$AIDC_MERGE_MARKER_START" "$WS/CLAUDE.md"; then
  ok "user CLAUDE.md content survives; managed block present"
else
  fail "CLAUDE.md merge lost content"
fi

# 8. Implicit path (create mode) never rewrites existing files, only creates
#    missing ones, and the stale notice names 'aidc upgrade'.
make_scaffold
printf '\n# KEEP-ME\n' >>"$WS/.devcontainer/Dockerfile"
rm "$WS/.devcontainer/compose.hardened.yaml"
claude_md_before="$(cat "$WS/CLAUDE.md")"
aidc::ensure_host_config_dirs() { :; }
aidc::ensure_claude_profile_examples() { :; }
aidc::ensure_core_repo() { :; }
aidc::ensure_core_worktree() { printf '%s\n' "$TMP_ROOT/worktree"; }
out="$(aidc::ensure_workspace_ready "$WS")"
if grep -q 'KEEP-ME' "$WS/.devcontainer/Dockerfile"; then
  ok "implicit path preserves local edits (create mode)"
else
  fail "implicit path rewrote an edited file"
fi
if [[ -f "$WS/.devcontainer/compose.hardened.yaml" ]]; then
  ok "implicit path creates missing files"
else
  fail "implicit path did not create the missing file"
fi
if [[ "$(cat "$WS/CLAUDE.md")" == "$claude_md_before" ]]; then
  ok "implicit path leaves merged files byte-identical"
else
  fail "implicit path rewrote CLAUDE.md"
fi
if printf '%s' "$out" | grep -q "aidc upgrade"; then
  ok "stale notice names aidc upgrade"
else
  fail "stale notice missing: $out"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
