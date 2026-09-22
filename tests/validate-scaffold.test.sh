#!/usr/bin/env bash
#
# Unit tests for .github/scripts/validate-scaffold.sh.
#
# Builds fixture scaffolds by rendering the repo's templates/ the same way
# `aidc init` does (template -> target path), then breaks individual files to
# prove each check fires. Rendering from templates/ (not the possibly-stale
# local .devcontainer/) means the test validates the actual source of truth.
# Docker-dependent checks are forced onto the skip path with a stub `docker`
# that always fails, so results are deterministic whether or not the host has
# Docker.
#
# Run with: bash tests/validate-scaffold.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATOR="$REPO_ROOT/.github/scripts/validate-scaffold.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Stub docker: `command -v docker` finds it, every invocation fails -> the
# validator takes its documented skip path for compose/build checks.
STUB_DIR="$TMP_ROOT/bin"
mkdir -p "$STUB_DIR"
printf '#!/usr/bin/env bash\nexit 1\n' >"$STUB_DIR/docker"
chmod +x "$STUB_DIR/docker"
export PATH="$STUB_DIR:$PATH"

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

make_fixture() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir/.devcontainer/scripts" "$dir/.ai-container" "$dir/scripts/ci"
  local t="$REPO_ROOT/templates"
  cp "$t/devcontainer/Dockerfile.tmpl"              "$dir/.devcontainer/Dockerfile"
  cp "$t/devcontainer/Dockerfile.base.tmpl"         "$dir/.devcontainer/Dockerfile.base"
  cp "$t/devcontainer/compose.yaml.tmpl"            "$dir/.devcontainer/compose.yaml"
  cp "$t/devcontainer/compose.firewall.yaml.tmpl"   "$dir/.devcontainer/compose.firewall.yaml"
  cp "$t/devcontainer/compose.hardened.yaml.tmpl"   "$dir/.devcontainer/compose.hardened.yaml"
  cp "$t/devcontainer/devcontainer.json.tmpl"       "$dir/.devcontainer/devcontainer.json"
  cp "$t/devcontainer/project-setup.sh.tmpl"        "$dir/.devcontainer/project-setup.sh"
  cp "$t/devcontainer/scripts/bootstrap-state.sh.tmpl" "$dir/.devcontainer/scripts/bootstrap-state.sh"
  cp "$t/devcontainer/scripts/init-firewall.sh.tmpl"   "$dir/.devcontainer/scripts/init-firewall.sh"
  cp "$t/devcontainer/scripts/aidc-ci.sh.tmpl"         "$dir/.devcontainer/scripts/aidc-ci.sh"
  local f
  for f in aidc-lib-common aidc-sbom-code aidc-sbom-image aidc-sbom-diff aidc-license-check aidc-sbom-all; do
    cp "$t/ci/${f}.sh.tmpl" "$dir/scripts/ci/${f}.sh"
  done
  # Minimal project.env in the shape aidc::write_project_env produces.
  cat >"$dir/.ai-container/project.env" <<'EOF'
# aidc-managed
AIDC_VERSION=0.0.0-test
AIDC_WORKSPACE=/tmp/fixture
AIDC_REPO_SLUG=fixture-00000000
AIDC_CORE_ROOT=/tmp/fixture-core
AIDC_CORE_BRANCH=project/fixture-00000000
AIDC_CORE_WORKTREE=/tmp/fixture-worktree
EOF
}

# 1. The repo's own rendered scaffold passes (docker checks skip).
fx="$TMP_ROOT/clean"
make_fixture "$fx"
if out="$("$VALIDATOR" "$fx" 2>&1)"; then
  if printf '%s' "$out" | grep -q 'all checks passed'; then
    ok "clean scaffold passes"
  else
    fail "clean scaffold: unexpected output: $out"
  fi
else
  fail "clean scaffold was rejected: $out"
fi

# 2. Shell syntax error is caught.
fx="$TMP_ROOT/broken-sh"
make_fixture "$fx"
printf '\nif [ broken\n' >>"$fx/.devcontainer/scripts/bootstrap-state.sh"
if "$VALIDATOR" "$fx" >/dev/null 2>&1; then
  fail "broken shell script was not caught"
else
  ok "broken shell script fails validation"
fi

# 3. Invalid devcontainer.json is caught.
fx="$TMP_ROOT/broken-json"
make_fixture "$fx"
printf '{ not json\n' >"$fx/.devcontainer/devcontainer.json"
if "$VALIDATOR" "$fx" >/dev/null 2>&1; then
  fail "invalid devcontainer.json was not caught"
else
  ok "invalid devcontainer.json fails validation"
fi

# 4. Missing required file is caught.
fx="$TMP_ROOT/missing-file"
make_fixture "$fx"
rm -f "$fx/.devcontainer/compose.yaml"
if "$VALIDATOR" "$fx" >/dev/null 2>&1; then
  fail "missing compose.yaml was not caught"
else
  ok "missing required file fails validation"
fi

# 5. project.env referencing an undefined variable is caught (set -u source).
fx="$TMP_ROOT/broken-env"
make_fixture "$fx"
printf 'AIDC_BROKEN="$UNDEFINED_VARIABLE_FOR_TEST"\n' >>"$fx/.ai-container/project.env"
if "$VALIDATOR" "$fx" >/dev/null 2>&1; then
  fail "project.env undefined-variable reference was not caught"
else
  ok "broken project.env fails validation"
fi

# 6. Usage error (no/invalid argument) exits 2.
rc=0
"$VALIDATOR" >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 2 ]]; then
  ok "missing argument exits 2"
else
  fail "missing argument: expected exit 2, got $rc"
fi

# ── 7. compose-stub-vars.sh: which vars get a stub path ─────────────────────
# The rule that matters: bind-mount sources (bare ${AIDC_FOO}) need a stub,
# defaulted knobs (${AIDC_FOO:-x}) must NOT get one — three of them are numeric
# and compose fails a type cast when handed a directory path. This used to be a
# copy-pasted grep in two places and was wrong in both.
STUB_VARS="$REPO_ROOT/.github/scripts/compose-stub-vars.sh"
fixture="$TMP_ROOT/compose-vars.yaml"
cat >"$fixture" <<'YAML'
services:
  workspace:
    pids_limit: ${AIDC_PIDS_LIMIT:-4096}
    mem_limit: ${AIDC_MEM_LIMIT:-0}
    cpus: ${AIDC_CPU_LIMIT:-0}
    image: ${AIDC_BASE_IMAGE:-aidc-base:latest}
    volumes:
      - ${AIDC_WORKSPACE}:/workspace
      - ${AIDC_HOST_SEED_CLAUDE}:/host-seed/claude
      - ${AIDC_WORKSPACE}:/dup
YAML
got="$("$STUB_VARS" "$fixture" | tr '\n' ' ')"
if [[ "$got" == "AIDC_HOST_SEED_CLAUDE AIDC_WORKSPACE " ]]; then
  ok "compose-stub-vars: only bare \${AIDC_*} bind sources, deduplicated"
else
  fail "compose-stub-vars: got '$got'"
fi

# The numeric knobs are the regression that broke CI — assert explicitly.
if ! "$STUB_VARS" "$fixture" | grep -qE 'AIDC_(PIDS|MEM|CPU)_LIMIT'; then
  ok "compose-stub-vars: numeric knobs excluded (keep their defaults)"
else
  fail "compose-stub-vars: a defaulted numeric knob would be stubbed with a path"
fi

# A compose file with no AIDC_* refs is a valid empty result, not a failure —
# grep exits 1 there and `set -o pipefail` would otherwise propagate it.
printf 'services:\n  workspace:\n    image: busybox\n' >"$TMP_ROOT/bare.yaml"
rc=0
out="$("$STUB_VARS" "$TMP_ROOT/bare.yaml")" || rc=$?
if [[ "$rc" -eq 0 && -z "$out" ]]; then
  ok "compose-stub-vars: no matches exits 0 with empty output"
else
  fail "compose-stub-vars no-match: rc=$rc out='$out'"
fi

rc=0
"$STUB_VARS" >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 2 ]]; then
  ok "compose-stub-vars: missing argument exits 2"
else
  fail "compose-stub-vars usage: expected exit 2, got $rc"
fi

# 8. The real template must keep rendering under this rule: every bare
#    ${AIDC_*} is reported, and nothing else is.
real="$REPO_ROOT/templates/devcontainer/compose.yaml.tmpl"
if [[ -f "$real" ]]; then
  n_stub="$("$STUB_VARS" "$real" | wc -l | tr -d ' ')"
  if [[ "$n_stub" -gt 0 ]] \
     && ! "$STUB_VARS" "$real" | grep -qE 'AIDC_(PIDS|MEM|CPU)_LIMIT|AIDC_BASE_IMAGE'; then
    ok "compose-stub-vars: real template splits into $n_stub path vars, no defaulted knobs"
  else
    fail "compose-stub-vars on real template: $("$STUB_VARS" "$real" | tr '\n' ' ')"
  fi
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
