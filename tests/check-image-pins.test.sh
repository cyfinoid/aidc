#!/usr/bin/env bash
#
# Unit tests for .github/scripts/check-image-pins.sh.
#
# Stubs `docker` so no image/daemon is needed: the stub prints a canned
# version string per binary, driven by a fixture map file.
# Run with: bash tests/check-image-pins.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECKER="$REPO_ROOT/.github/scripts/check-image-pins.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

STUB_DIR="$TMP_ROOT/bin"
mkdir -p "$STUB_DIR"

# docker stub: `docker run --rm <image> <bin> ...` -> looks up <bin> in the
# version map and prints "<bin> <version>". Unknown bin exits 127.
cat >"$STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
bin=""
seen_image=0
for a in "$@"; do
  case "$a" in
    run|--rm) continue ;;
    *)
      if [[ "$seen_image" -eq 0 ]]; then seen_image=1; continue; fi
      bin="$a"; break ;;
  esac
done
v="$(grep "^$bin=" "$STUB_MAP" | cut -d= -f2)"
[[ -n "$v" ]] || exit 127
printf '%s %s\n' "$bin" "$v"
STUB
chmod +x "$STUB_DIR/docker"
export PATH="$STUB_DIR:$PATH"

# Fixture Dockerfile with pins.
DF="$TMP_ROOT/Dockerfile.tmpl"
cat >"$DF" <<'EOF'
ARG GIT_DELTA_VERSION=0.18.2
ARG PMG_VERSION=v0.21.3
ARG VET_VERSION=v1.17.3
ARG TRUFFLEHOG_VERSION=v3.95.8
ARG GITLEAKS_VERSION=v8.30.1
ARG SYFT_VERSION=v1.18.1
ARG GRYPE_VERSION=v0.87.0
ARG RTK_VERSION=v0.43.0
ARG CLAUDE_VERSION=2.1.201
ARG CODEX_VERSION=0.142.5
ARG OPENCODE_VERSION=1.17.13
ARG GROK_VERSION=0.2.87
ARG OMP_VERSION=18.1.5
EOF

# Version map matching the pins exactly.
MAP_GOOD="$TMP_ROOT/map-good"
cat >"$MAP_GOOD" <<'EOF'
delta=0.18.2
pmg=0.21.3
vet=1.17.3
trufflehog=3.95.8
gitleaks=8.30.1
syft=1.18.1
grype=0.87.0
rtk=0.43.0
claude=2.1.201
codex=0.142.5
opencode=1.17.13
grok=0.2.87
omp=18.1.5
EOF

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

# 1. All versions match -> exit 0.
if STUB_MAP="$MAP_GOOD" bash "$CHECKER" fake-image:ci "$DF" >/dev/null 2>&1; then
  ok "matching versions pass"
else
  fail "matching versions were rejected"
fi

# 2. One mismatched version -> exit 1 and the tool is named.
MAP_BAD="$TMP_ROOT/map-bad"
sed 's/^gitleaks=.*/gitleaks=9.99.9/' "$MAP_GOOD" >"$MAP_BAD"
out=""
rc=0
out="$(STUB_MAP="$MAP_BAD" bash "$CHECKER" fake-image:ci "$DF" 2>&1)" || rc=$?
if [[ "$rc" -eq 1 ]] && printf '%s' "$out" | grep -q 'FAIL: gitleaks'; then
  ok "version mismatch is caught and named"
else
  fail "mismatch case: rc=$rc out=$out"
fi

# 3. Missing binary in image -> exit 1.
MAP_MISSING="$TMP_ROOT/map-missing"
grep -v '^rtk=' "$MAP_GOOD" >"$MAP_MISSING"
rc=0
STUB_MAP="$MAP_MISSING" bash "$CHECKER" fake-image:ci "$DF" >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 1 ]]; then
  ok "missing binary is caught"
else
  fail "missing binary: expected exit 1, got $rc"
fi

# 4. Missing ARG in dockerfile -> exit 1.
DF_SPARSE="$TMP_ROOT/Dockerfile.sparse"
grep -v '^ARG SYFT_VERSION=' "$DF" >"$DF_SPARSE"
rc=0
STUB_MAP="$MAP_GOOD" bash "$CHECKER" fake-image:ci "$DF_SPARSE" >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 1 ]]; then
  ok "missing ARG is caught"
else
  fail "missing ARG: expected exit 1, got $rc"
fi

# 5. Usage error -> exit 2 family (missing args).
rc=0
bash "$CHECKER" >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then
  ok "missing image argument fails"
else
  fail "missing image argument unexpectedly passed"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
