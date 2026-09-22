#!/usr/bin/env bash
#
# Unit tests for `aidc destroy --purge-scaffold` (aidc::destroy_scaffold).
#
# The documented contract (docs/install.md) is that --purge-scaffold removes
# .devcontainer/ entirely. It removes AIDC_MANAGED_PATHS and then `rmdir`s the
# directories — non-recursively, so anything left behind silently keeps the
# whole tree alive. Two aidc-created files are deliberately *not* managed
# (.devcontainer/project-setup.sh is user-owned via copy_template_once, .env is
# regenerated on every up/rebuild), and leaving them made the purge a no-op for
# .devcontainer/ — the e2e caught it as "destroy --purge-scaffold left
# .devcontainer behind".
#
# These cases also pin the deliberate non-goal: a file the *user* put in
# .devcontainer/ is theirs, so the directory must survive rather than be
# deleted out from under them.
#
# Run with: bash tests/destroy-scaffold.test.sh
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

# Build a scaffold fixture: every managed path, plus the two unmanaged
# aidc-created files, plus the user-owned docs that must survive.
make_ws() {
  local ws="$1" p
  mkdir -p "$ws"
  for p in "${AIDC_MANAGED_PATHS[@]}"; do
    mkdir -p "$ws/$(dirname "$p")"
    : >"$ws/$p"
  done
  printf '#!/usr/bin/env bash\n: \n' >"$ws/.devcontainer/project-setup.sh"
  printf 'AIDC_WORKSPACE=/somewhere\n' >"$ws/.devcontainer/.env"
  printf '# changelog\n' >"$ws/CHANGELOG.md"
  printf '# detailed\n' >"$ws/DETAILED_CHANGELOG.md"
}

# ── 1. The whole .devcontainer/ tree is gone after a purge ──────────────────
ws="$TMP_ROOT/full"
make_ws "$ws"
aidc::destroy_scaffold "$ws" >/dev/null 2>&1
if [[ ! -e "$ws/.devcontainer" ]]; then
  ok "purge removes .devcontainer/ entirely"
else
  fail "left behind: $(find "$ws/.devcontainer" -mindepth 1 | tr '\n' ' ')"
fi

# 2. The two unmanaged aidc-created files specifically — the regression.
if [[ ! -e "$ws/.devcontainer/project-setup.sh" && ! -e "$ws/.devcontainer/.env" ]]; then
  ok "purge removes the unmanaged project-setup.sh and .env"
else
  fail "unmanaged aidc files survived the purge"
fi

# 3. The other scaffold directories go too.
if [[ ! -e "$ws/.ai-container" && ! -e "$ws/.cursor" ]]; then
  ok "purge removes .ai-container/ and .cursor/"
else
  fail ".ai-container or .cursor survived"
fi

# 4. User-owned seeded docs at the repo root are untouched (destroy must never
#    take the project's own history with it).
if [[ -f "$ws/CHANGELOG.md" && -f "$ws/DETAILED_CHANGELOG.md" ]]; then
  ok "purge leaves user-owned CHANGELOG/DETAILED_CHANGELOG"
else
  fail "purge removed user-owned documentation"
fi

# ── 5. A file the user dropped in .devcontainer/ keeps the directory ────────
# Deliberate non-goal: rmdir, not rm -rf. Their file, their directory.
ws="$TMP_ROOT/foreign"
make_ws "$ws"
printf 'mine\n' >"$ws/.devcontainer/my-notes.txt"
aidc::destroy_scaffold "$ws" >/dev/null 2>&1
if [[ -d "$ws/.devcontainer" && -f "$ws/.devcontainer/my-notes.txt" ]]; then
  ok "a user's own file in .devcontainer/ survives (dir not force-removed)"
else
  fail "user file in .devcontainer/ was deleted by the purge"
fi

# 6. ...but the managed content around it is still cleaned out.
if [[ ! -e "$ws/.devcontainer/Dockerfile" && ! -e "$ws/.devcontainer/scripts" ]]; then
  ok "managed files still removed alongside a surviving user file"
else
  fail "managed scaffold survived next to the user file"
fi

# ── 7. Idempotent: a second purge on an already-clean tree is a no-op ───────
rc=0
aidc::destroy_scaffold "$TMP_ROOT/full" >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "re-running the purge on a clean tree exits 0"
else
  fail "second purge failed with rc=$rc"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
