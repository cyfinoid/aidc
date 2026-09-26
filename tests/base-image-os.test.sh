#!/usr/bin/env bash
#
# Structural guard for the self-owned OS base (the retired devcontainers-base
# swap). The devcontainers base silently provided the aidc user, sudo,
# git, openssh-client and the zsh config; this template now owns all of it,
# and the dangerous failure mode is a future "trim" removing one of those
# invisible dependencies (the same class as the git-delta ln failure that
# base-image-stages.test.sh guards). These checks parse the templates
# directly so CI (which has no docker either) catches regressions:
#
#   1. both templates pin the same ubuntu:26.04 index digest;
#   2. no mcr.microsoft.com/devcontainers reference remains;
#   3. the previously-inherited packages (git, sudo, openssh-client, less,
#      procps) are explicit in the base apt list;
#   4. the aidc user (uid/gid 1000), NOPASSWD sudoers, git safe.directory,
#      and the .zshrc are provisioned in the `base` stage, before `USER aidc`;
#   5. the toolchain template installs curl + ca-certificates (stock ubuntu
#      lacks them; every toolchain arm fetches over TLS).
#
# Run with: bash tests/base-image-os.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASE_TEMPL="$REPO_ROOT/templates/devcontainer/Dockerfile.base.tmpl"
TOOL_TEMPL="$REPO_ROOT/templates/devcontainer/Dockerfile.toolchain.tmpl"

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

# Non-comment template lines (comments may legitimately mention the retired
# base as provenance; assertions must only see operative lines).
strip_comments() { grep -vE '^[[:space:]]*#' "$@"; }

for f in "$BASE_TEMPL" "$TOOL_TEMPL"; do
  [[ -f "$f" ]] || { fail "template missing: $f"; }
done
if [[ "$failed" -gt 0 ]]; then printf '\n0 passed, %d failed\n' "$failed"; exit 1; fi

# ── 1. same ubuntu:26.04 digest pin in both templates ────────────────────────
# Anchored to FROM/ARG pin lines (comments stripped) so a stale comment
# mentioning the digest cannot satisfy the assertion.
digest_of() { strip_comments "$1" | grep -oE '^(FROM |ARG [A-Za-z_]+=)ubuntu:26\.04@sha256:[0-9a-f]{64}' | head -1 | grep -oE 'sha256:[0-9a-f]{64}'; }
base_digest="$(digest_of "$BASE_TEMPL")"
tool_digest="$(digest_of "$TOOL_TEMPL")"
if [[ -n "$base_digest" ]]; then
  ok "Dockerfile.base pins ubuntu:26.04 by digest"
else
  fail "Dockerfile.base: no ubuntu:26.04@sha256:<64hex> FROM pin found"
fi
if [[ "$base_digest" == "$tool_digest" && -n "$tool_digest" ]]; then
  ok "Dockerfile.toolchain pins the same base digest"
else
  fail "Dockerfile.toolchain base digest missing or differs from Dockerfile.base ('$tool_digest' vs '$base_digest')"
fi

# ── 2. no devcontainers-base references left in non-comment template lines ────
if strip_comments "$REPO_ROOT"/templates/devcontainer/*.tmpl \
     | grep -qE 'mcr\.microsoft\.com|devcontainers/base'; then
  fail "devcontainer templates still reference the retired devcontainers base"
else
  ok "no mcr.microsoft.com/devcontainers references in templates/devcontainer/"
fi

# ── 3. previously-inherited packages are explicit in the base apt list ───────
# Lines inside the apt block look like "      git \" (trailing continuation
# backslash optional so a package can legitimately become the last entry).
for pkg in git sudo openssh-client less procps zsh; do
  if grep -qE "^[[:space:]]+$pkg([[:space:]]*\\\\)?$" "$BASE_TEMPL"; then
    ok "base apt list installs $pkg (was inherited from devcontainers base)"
  else
    fail "base apt list missing $pkg — an invisible devcontainers-base dependency would regress"
  fi
done

# ── 4. user/sudo/git/zsh provisioning inside the base stage, before USER aidc ─
user_line="$(grep -n '^USER aidc' "$BASE_TEMPL" | head -1 | cut -d: -f1)"
for pat in 'userdel --remove ubuntu' \
           'groupadd --gid 1000 aidc' \
           'useradd --uid 1000 --gid aidc --create-home --shell /usr/bin/zsh aidc' \
           'aidc ALL=(root) NOPASSWD:ALL' \
           'git config --system --add safe.directory' \
           '/home/aidc/.zshrc'; do
  line="$(grep -n "$pat" "$BASE_TEMPL" | head -1 | cut -d: -f1)"
  if [[ -n "$line" && -n "$user_line" && "$line" -lt "$user_line" ]]; then
    ok "provisioned in base stage before USER aidc: $pat"
  else
    fail "missing or after USER aidc: $pat (USER aidc would fail or sudo would be absent)"
  fi
done
grep -q 'HISTFILE=/commandhistory/.zsh_history' "$BASE_TEMPL" \
  && ok ".zshrc wires history to the persistent /commandhistory volume" \
  || fail ".zshrc HISTFILE missing (zsh would silently drop history)"

# ── 5. toolchain template fetches over TLS from stock ubuntu ──────────────────
if grep -q 'apt-get install -y --no-install-recommends ca-certificates curl' "$TOOL_TEMPL"; then
  ok "toolchain template installs curl + ca-certificates"
else
  fail "toolchain template missing curl/ca-certificates (stock ubuntu base lacks them; every arm curls over TLS)"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
