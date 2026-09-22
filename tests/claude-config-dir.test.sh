#!/usr/bin/env bash
#
# Unit tests for the Claude Code global-config persistence wiring.
#
# Claude writes its global config to ~/.claude.json — a *sibling* of ~/.claude,
# so outside the claude_home volume that mounts ~/.claude. Left at the default
# it lives in the container layer and is wiped on every recreation. The fix
# points CLAUDE_CONFIG_DIR at the volume dir so .claude.json lands inside it.
# This test pins:
#   1. compose.yaml.tmpl exports CLAUDE_CONFIG_DIR = the claude_home volume dir,
#   2. that dir is exactly where the claude_home volume is mounted (so the
#      relocation actually lands inside the persisted volume),
#   3. the aidc-bootstrap-claude config-path derivation shipped in
#      Dockerfile.base.tmpl honors CLAUDE_CONFIG_DIR (and falls back cleanly).
#
# Run with: bash tests/claude-config-dir.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE="$REPO_ROOT/templates/devcontainer/compose.yaml.tmpl"
DOCKERFILE="$REPO_ROOT/templates/devcontainer/Dockerfile.base.tmpl"

VOL_DIR="/home/vscode/.claude"

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

# 1. compose sets CLAUDE_CONFIG_DIR to the volume dir.
if grep -Eq "^[[:space:]]*CLAUDE_CONFIG_DIR:[[:space:]]*${VOL_DIR}[[:space:]]*$" "$COMPOSE"; then
  ok "compose.yaml.tmpl sets CLAUDE_CONFIG_DIR=$VOL_DIR"
else
  fail "compose.yaml.tmpl does not set CLAUDE_CONFIG_DIR=$VOL_DIR"
fi

# 2. The claude_home volume is mounted at that same dir — otherwise the config
#    would be relocated somewhere that still isn't persisted.
if grep -Eq "target:[[:space:]]*${VOL_DIR}[[:space:]]*$" "$COMPOSE"; then
  ok "claude_home volume target matches CLAUDE_CONFIG_DIR (config lands in the volume)"
else
  fail "no volume mounted at $VOL_DIR — CLAUDE_CONFIG_DIR would not be persisted"
fi

# 3. Behavioral: the exact config-path derivation shipped in the Dockerfile must
#    honor CLAUDE_CONFIG_DIR when set and fall back to ~/.claude.json when not.
#    Extract the two `config=` lines verbatim and eval them under both states so
#    the test exercises the shipped code, not a paraphrase.
mapfile -t cfg_lines < <(grep -E '^config=' "$DOCKERFILE")
if [[ "${#cfg_lines[@]}" -ne 2 ]]; then
  fail "expected 2 'config=' lines in Dockerfile.base.tmpl, found ${#cfg_lines[@]}"
else
  ok "Dockerfile.base.tmpl derives the config path in 2 steps (env + fallback)"

  derive_config() {
    local HOME="$1"
    # shellcheck disable=SC2030,SC2031
    if [[ -n "${2:-}" ]]; then
      export CLAUDE_CONFIG_DIR="$2"
    else
      unset CLAUDE_CONFIG_DIR
    fi
    local config
    eval "${cfg_lines[0]}"
    eval "${cfg_lines[1]}"
    printf '%s' "$config"
  }

  got="$(derive_config /home/vscode "$VOL_DIR")"
  if [[ "$got" == "$VOL_DIR/.claude.json" ]]; then
    ok "with CLAUDE_CONFIG_DIR set → $got"
  else
    fail "with CLAUDE_CONFIG_DIR set, derived '$got' (want $VOL_DIR/.claude.json)"
  fi

  got="$(derive_config /home/someone "")"
  if [[ "$got" == "/home/someone/.claude.json" ]]; then
    ok "with CLAUDE_CONFIG_DIR unset → falls back to \$HOME/.claude.json"
  else
    fail "with CLAUDE_CONFIG_DIR unset, derived '$got' (want /home/someone/.claude.json)"
  fi
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
