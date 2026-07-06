#!/usr/bin/env bash
#
# Unit tests for scripts/update-pins.sh.
#
# Stubs `curl` on PATH so no network is touched: release-tag redirects,
# vendor checksums files, artifact downloads, and agent version endpoints all
# come from fixtures below. Run with: bash tests/update-pins.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPDATE_PINS="$REPO_ROOT/scripts/update-pins.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

STUB_DIR="$TMP_ROOT/bin"
mkdir -p "$STUB_DIR"

# Fixture checksum values (obviously fake, 64 hex chars each).
FAKE_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
FAKE_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# curl stub: dispatches on the request URL. Handles the three shapes
# update-pins.sh uses: `-w %{redirect_url}` HEAD probes, `-o <dest>`
# downloads, and body-to-stdout fetches.
cat >"$STUB_DIR/curl" <<STUB
#!/usr/bin/env bash
url=""; dest=""; want_redirect=0
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) dest="\$2"; shift 2 ;;
    -w) [[ "\$2" == *redirect_url* ]] && want_redirect=1; shift 2 ;;
    http*) url="\$1"; shift ;;
    *) shift ;;
  esac
done
emit() { if [[ -n "\$dest" && "\$dest" != /dev/null ]]; then printf '%s' "\$1" >"\$dest"; else printf '%s' "\$1"; fi; }
if [[ "\$want_redirect" -eq 1 ]]; then
  case "\$url" in
    */dandavison/delta/*)          printf 'https://github.com/dandavison/delta/releases/tag/0.19.0' ;;
    */safedep/pmg/*)               printf 'https://github.com/safedep/pmg/releases/tag/v0.30.0' ;;
    */safedep/vet/*)               printf 'https://github.com/safedep/vet/releases/tag/v2.0.0' ;;
    */trufflesecurity/trufflehog/*) printf 'https://github.com/trufflesecurity/trufflehog/releases/tag/v4.0.0' ;;
    */gitleaks/gitleaks/*)         printf 'https://github.com/gitleaks/gitleaks/releases/tag/v9.0.0' ;;
    */anchore/syft/*)              printf 'https://github.com/anchore/syft/releases/tag/v2.0.0' ;;
    */anchore/grype/*)             printf 'https://github.com/anchore/grype/releases/tag/v1.0.0' ;;
    */rtk-ai/rtk/*)                printf 'https://github.com/rtk-ai/rtk/releases/tag/v0.50.0' ;;
    */openai/codex/*)              printf 'https://github.com/openai/codex/releases/tag/rust-v1.0.0' ;;
    */anomalyco/opencode/*)        printf 'https://github.com/anomalyco/opencode/releases/tag/v2.0.0' ;;
    *) exit 22 ;;
  esac
  exit 0
fi
case "\$url" in
  *git-delta_0.19.0_amd64.deb) emit "DELTA-AMD64-CONTENT" ;;
  *git-delta_0.19.0_arm64.deb) emit "DELTA-ARM64-CONTENT" ;;
  */safedep/pmg/*/checksums.txt) emit "$FAKE_A  pmg_Linux_x86_64.tar.gz
$FAKE_B  pmg_Linux_arm64.tar.gz
" ;;
  */safedep/vet/*/checksums.txt) emit "$FAKE_A  vet_Linux_x86_64.tar.gz
$FAKE_B  vet_Linux_arm64.tar.gz
" ;;
  */trufflehog_4.0.0_checksums.txt) emit "$FAKE_A  trufflehog_4.0.0_linux_amd64.tar.gz
$FAKE_B  trufflehog_4.0.0_linux_arm64.tar.gz
" ;;
  */gitleaks_9.0.0_checksums.txt) emit "$FAKE_B  gitleaks_9.0.0_linux_arm64.tar.gz
$FAKE_A  gitleaks_9.0.0_linux_x64.tar.gz
" ;;
  */syft_2.0.0_checksums.txt) emit "$FAKE_A  syft_2.0.0_linux_amd64.tar.gz
$FAKE_B  syft_2.0.0_linux_arm64.tar.gz
" ;;
  */grype_1.0.0_checksums.txt) emit "$FAKE_A  grype_1.0.0_linux_amd64.tar.gz
$FAKE_B  grype_1.0.0_linux_arm64.tar.gz
" ;;
  */rtk-ai/rtk/*/checksums.txt) emit "$FAKE_A  rtk-x86_64-unknown-linux-musl.tar.gz
$FAKE_B  rtk-aarch64-unknown-linux-gnu.tar.gz
" ;;
  *downloads.claude.ai*latest) emit "3.0.0" ;;
  *x.ai/cli/stable) emit "1.2.3" ;;
  *) exit 22 ;;
esac
STUB
chmod +x "$STUB_DIR/curl"
export PATH="$STUB_DIR:$PATH"

# Fixture Dockerfile with one ARG line per pin the script manages.
FIXTURE_DF="$TMP_ROOT/Dockerfile.tmpl"
cat >"$FIXTURE_DF" <<'EOF'
FROM scratch
ARG GIT_DELTA_VERSION=0.18.2
ARG GIT_DELTA_SHA256_AMD64=old
ARG GIT_DELTA_SHA256_ARM64=old
ARG PMG_VERSION=v0.21.3
ARG PMG_SHA256_AMD64=old
ARG PMG_SHA256_ARM64=old
ARG VET_VERSION=v1.17.3
ARG VET_SHA256_AMD64=old
ARG VET_SHA256_ARM64=old
ARG TRUFFLEHOG_VERSION=v3.95.8
ARG TRUFFLEHOG_SHA256_AMD64=old
ARG TRUFFLEHOG_SHA256_ARM64=old
ARG GITLEAKS_VERSION=v8.30.1
ARG GITLEAKS_SHA256_AMD64=old
ARG GITLEAKS_SHA256_ARM64=old
ARG SYFT_VERSION=v1.18.1
ARG SYFT_SHA256_AMD64=old
ARG SYFT_SHA256_ARM64=old
ARG GRYPE_VERSION=v0.87.0
ARG GRYPE_SHA256_AMD64=old
ARG GRYPE_SHA256_ARM64=old
ARG RTK_VERSION=v0.43.0
ARG RTK_SHA256_AMD64=old
ARG RTK_SHA256_ARM64=old
ARG CLAUDE_VERSION=2.1.201
ARG CODEX_VERSION=0.142.5
ARG OPENCODE_VERSION=1.17.13
ARG GROK_VERSION=0.2.87
EOF

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

# Expected local hashes for the delta fixture "downloads".
sha_of_string() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
DELTA_SHA_AMD="$(sha_of_string 'DELTA-AMD64-CONTENT')"
DELTA_SHA_ARM="$(sha_of_string 'DELTA-ARM64-CONTENT')"

# 1. Print mode emits the expected ARG lines.
out="$(AIDC_PINS_DOCKERFILE="$FIXTURE_DF" bash "$UPDATE_PINS" 2>/dev/null)"
expect() {
  if printf '%s\n' "$out" | grep -qFx "$1"; then
    ok "prints: $1"
  else
    fail "missing line: $1"
  fi
}
expect "ARG GIT_DELTA_VERSION=0.19.0"
expect "ARG GIT_DELTA_SHA256_AMD64=$DELTA_SHA_AMD"
expect "ARG GIT_DELTA_SHA256_ARM64=$DELTA_SHA_ARM"
expect "ARG PMG_VERSION=v0.30.0"
expect "ARG PMG_SHA256_AMD64=$FAKE_A"
expect "ARG PMG_SHA256_ARM64=$FAKE_B"
expect "ARG TRUFFLEHOG_VERSION=v4.0.0"
expect "ARG GITLEAKS_SHA256_AMD64=$FAKE_A"
expect "ARG RTK_VERSION=v0.50.0"
expect "ARG CLAUDE_VERSION=3.0.0"
expect "ARG CODEX_VERSION=1.0.0"
expect "ARG OPENCODE_VERSION=2.0.0"
expect "ARG GROK_VERSION=1.2.3"

# 2. Print mode does not modify the Dockerfile.
if grep -q '^ARG PMG_VERSION=v0.21.3$' "$FIXTURE_DF"; then
  ok "print mode leaves the Dockerfile untouched"
else
  fail "print mode modified the Dockerfile"
fi

# 3. --write applies every pin to the Dockerfile.
AIDC_PINS_DOCKERFILE="$FIXTURE_DF" bash "$UPDATE_PINS" --write >/dev/null 2>&1
wexpect() {
  if grep -qFx "$1" "$FIXTURE_DF"; then
    ok "written: $1"
  else
    fail "not written: $1"
  fi
}
wexpect "ARG PMG_VERSION=v0.30.0"
wexpect "ARG PMG_SHA256_ARM64=$FAKE_B"
wexpect "ARG GIT_DELTA_SHA256_AMD64=$DELTA_SHA_AMD"
wexpect "ARG SYFT_VERSION=v2.0.0"
wexpect "ARG GRYPE_VERSION=v1.0.0"
wexpect "ARG CLAUDE_VERSION=3.0.0"
if grep -q '=old$' "$FIXTURE_DF"; then
  fail "stale 'old' checksum values remain after --write"
else
  ok "no stale checksum values remain"
fi

# 4. Non-ARG lines survive --write untouched.
if grep -qFx 'FROM scratch' "$FIXTURE_DF"; then
  ok "non-ARG lines preserved"
else
  fail "non-ARG content was damaged"
fi

# 5. Unknown flag exits 2.
rc=0
bash "$UPDATE_PINS" --bogus >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 2 ]]; then
  ok "unknown flag exits 2"
else
  fail "unknown flag: expected exit 2, got $rc"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
