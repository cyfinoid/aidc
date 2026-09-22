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

# Build a scaffold fixture in the state a *real* project reaches — not just
# what `aidc init` writes. The first version of this test only modelled init
# output, so .ai-container/ happened to be empty after project.env was removed
# and the bug hid a second time: in practice `aidc upgrade` leaves backup/ and
# the scan hook leaves scan-hook.log, either of which blocks the rmdir.
# Every aidc-written path under the scaffold dirs belongs here.
make_ws() {
  local ws="$1" p
  mkdir -p "$ws"
  for p in "${AIDC_MANAGED_PATHS[@]}"; do
    mkdir -p "$ws/$(dirname "$p")"
    : >"$ws/$p"
  done
  # .devcontainer/: aidc-created but unmanaged.
  printf '#!/usr/bin/env bash\n: \n' >"$ws/.devcontainer/project-setup.sh"
  printf 'AIDC_WORKSPACE=/somewhere\n' >"$ws/.devcontainer/.env"
  : >"$ws/.devcontainer/.env.aidc-tmp.4242"          # crashed atomic write
  # .ai-container/: aidc's own state dir, all of it.
  mkdir -p "$ws/.ai-container/backup/20260922-003016/.devcontainer"
  : >"$ws/.ai-container/backup/20260922-003016/.devcontainer/Dockerfile"
  printf 'scan log\n' >"$ws/.ai-container/scan-hook.log"
  : >"$ws/.ai-container/.aidc-stamp.abc123"          # crashed stamp rewrite
  # User-owned, must survive.
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
  fail ".ai-container or .cursor survived: $(find "$ws/.ai-container" "$ws/.cursor" -mindepth 1 2>/dev/null | tr '\n' ' ')"
fi

# 3b. Specifically the state files that blocked the rmdir in CI. `aidc upgrade`
#     writes backup/ and the scan hook writes scan-hook.log, so a purge on any
#     project that had ever been upgraded used to leave .ai-container/ behind.
if [[ ! -e "$ws/.ai-container/backup" && ! -e "$ws/.ai-container/scan-hook.log" ]]; then
  ok "purge removes upgrade backups and scan-hook.log"
else
  fail ".ai-container state files survived the purge"
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

# ── 8. Structural guard: every templated file must be destroyable ───────────
# The root cause of this whole class is a file aidc writes that no list knows
# how to remove. init-force.test.sh already guards map -> template-exists; this
# guards the other direction, map target -> AIDC_MANAGED_PATHS, so adding a new
# scaffold template without registering it can't silently break the purge
# again. Bash-3.2-safe: no associative arrays.
drift=0
for entry in "${AIDC_OVERWRITE_TEMPLATE_MAP[@]}"; do
  rest="${entry#*:}"
  target="${rest%%:*}"
  found=0
  for p in "${AIDC_MANAGED_PATHS[@]}"; do
    [[ "$p" == "$target" ]] && { found=1; break; }
  done
  if [[ "$found" -eq 0 ]]; then
    fail "templated file is not in AIDC_MANAGED_PATHS, so destroy cannot remove it: $target"
    drift=1
  fi
done
[[ "$drift" -eq 0 ]] && ok "every templated scaffold file is registered as a managed path"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
