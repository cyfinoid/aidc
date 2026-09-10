#!/usr/bin/env bash
#
# Unit tests for the aidc-ci engine (templates/devcontainer/scripts/
# aidc-ci.sh.tmpl — executed directly from templates/, the same hermetic
# pattern as tests/aidc-scan.test.sh). Drives the real engine against
# fixture workflows under tests/fixtures/local-ci/ with --capability
# overrides so nothing depends on whether the host actually has docker/gh
# (GitHub runners have both; the devcontainer has neither).
#
# Hermeticity notes:
#   - each case gets a fixture dir holding ONLY the workflows it names
#     (broken.yml would poison plan-loading for every other case, so it is
#     copied only for its own case);
#   - --work-dir under TMP_ROOT (explicit dirs are never auto-removed) lets
#     cases assert on RUNNER_TEMP contents and artifacts;
#   - the one real-repo case uses --list only (parses, executes nothing),
#     with AIDC_CI_PROJECT pinning the project so the case is CWD-independent.
#
# Run with: bash tests/local-ci.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER="$REPO_ROOT/templates/devcontainer/scripts/aidc-ci.sh.tmpl"
FIXTURES="$REPO_ROOT/tests/fixtures/local-ci"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

# mkfixdir <name> <fixture...> — dir holding only the named fixture workflows
mkfixdir() {
  local d="$TMP_ROOT/fx-$1"; shift
  mkdir -p "$d"
  local f
  for f in "$@"; do
    cp "$FIXTURES/$f.yml" "$d/"
  done
  printf '%s' "$d"
}

# run_runner <work-dir> <args...> — captures output into $wd/out.txt, sets RUN_RC
run_runner() {
  local wd="$1"; shift
  set +e
  bash "$RUNNER" --work-dir "$wd" "$@" >"$wd/out.txt" 2>&1
  RUN_RC=$?
  set -e
}

# ── 1. --list smoke against the real repo workflows ─────────────────────────
LIST_OUT="$(AIDC_CI_PROJECT="$REPO_ROOT" bash "$RUNNER" --list 2>&1)" || true
if grep -qE '^shellcheck  .*triggers: push pull_request$' <<<"$LIST_OUT" \
   && grep -qE '^  job shellcheck +legs:1 steps:[0-9]+$' <<<"$LIST_OUT" \
   && grep -q 'Run rtk savings unit tests' <<<"$LIST_OUT"; then
  ok "--list on real workflows shows shellcheck (1 job, run-step batch names)"
else
  fail "--list output unexpected: $(head -5 <<<"$LIST_OUT")"
fi
if grep -q '^release' <<<"$LIST_OUT"; then
  fail "--list should exclude tag-filtered release from the default selection"
else
  ok "--list excludes tag-only release from the default set"
fi
LIST_ALL="$(AIDC_CI_PROJECT="$REPO_ROOT" bash "$RUNNER" --all --list 2>&1)" || true
if grep -q '^release  .*push:tags' <<<"$LIST_ALL"; then
  ok "--all lists release with its push:tags trigger"
else
  fail "--all should list release (push:tags)"
fi

# ── 2. trigger filtering + --all on fixtures ────────────────────────────────
D="$(mkfixdir basic pass schedule-only)"
LIST2="$("$RUNNER" --workflows-dir "$D" --list 2>&1)" || true
if grep -q 'pass-fixture' <<<"$LIST2" && ! grep -q 'schedule-fixture' <<<"$LIST2"; then
  ok "schedule-only workflow excluded from the default set (push/PR workflows stay)"
else
  fail "default trigger filtering wrong on fixtures"
fi
LIST3="$("$RUNNER" --workflows-dir "$D" --all --list 2>&1)" || true
if grep -q 'schedule-fixture' <<<"$LIST3" && grep -q 'nightly' <<<"$LIST3"; then
  ok "--all includes the schedule-only workflow"
else
  fail "--all should include schedule-fixture/nightly"
fi

# ── 3. pass/fail semantics + job abort + if: always() ───────────────────────
WD="$TMP_ROOT/c3"; mkdir -p "$WD"
D="$(mkfixdir passfail fail pass)"
run_runner "$WD" --workflows-dir "$D" --capability docker=off --capability gh=off
OUT="$(cat "$WD/out.txt")"
if [[ "$RUN_RC" == "1" ]] && grep -q 'FAIL 1. boom (rc=3)' <<<"$OUT" \
   && grep -q 'SKIP 2. never-reached — job already failed' <<<"$OUT" \
   && grep -q 'PASS 3. cleanup' <<<"$OUT" \
   && grep -q 'cleanup-ran' <<<"$OUT"; then
  ok "failing step aborts the job; if: always() cleanup still runs; rc=1"
else
  fail "fail.yml semantics wrong (rc=$RUN_RC): $(grep -E 'FAIL|SKIP|PASS' <<<"$OUT" | head -5)"
fi

WD="$TMP_ROOT/c3b"; mkdir -p "$WD"
run_runner "$WD" --workflows-dir "$TMP_ROOT/fx-passfail" --workflow 'pass*' --capability docker=off
if [[ "$RUN_RC" == "0" ]] && grep -q 'TOTAL: 2 pass, 0 fail, 0 skip' <<<"$(cat "$WD/out.txt")"; then
  ok "passing-only selection: rc=0"
else
  fail "pass-only run should be rc=0 with 2 passes (rc=$RUN_RC)"
fi

# ── 4. matrix expansion + ${{ matrix.* }} substitution ──────────────────────
WD="$TMP_ROOT/c4"; mkdir -p "$WD"
D="$(mkfixdir matrix matrix)"
run_runner "$WD" --workflows-dir "$D" --capability docker=off
if [[ "$RUN_RC" == "0" ]] \
   && grep -q 'job mx (leg: bash=3.2)' <<<"$(cat "$WD/out.txt")" \
   && grep -q 'job mx (leg: bash=5.2)' <<<"$(cat "$WD/out.txt")" \
   && [[ "$(cat "$WD/tmp/seen-3.2" 2>/dev/null)" == "3.2" ]] \
   && [[ "$(cat "$WD/tmp/seen-5.2" 2>/dev/null)" == "5.2" ]]; then
  ok "matrix expands to legs and \${{ matrix.bash }} substitutes per leg"
else
  fail "matrix expansion/substitution broken (rc=$RUN_RC, seen-3.2='$(cat "$WD/tmp/seen-3.2" 2>/dev/null)')"
fi

# ── 5. os matrix: macos leg skips, ubuntu leg runs ──────────────────────────
WD="$TMP_ROOT/c5"; mkdir -p "$WD"
D="$(mkfixdir osmatrix os-matrix)"
run_runner "$WD" --workflows-dir "$D" --capability docker=off
if [[ "$RUN_RC" == "0" ]] \
   && grep -q 'SKIP job e2e (leg: os=macos-latest) — non-Linux runner image' <<<"$(cat "$WD/out.txt")" \
   && grep -q 'PASS 1. greet' <<<"$(cat "$WD/out.txt")"; then
  ok "non-Linux matrix leg skips; ubuntu leg runs"
else
  fail "os-matrix gating wrong (rc=$RUN_RC)"
fi

# ── 6. env layering + GITHUB_ENV / GITHUB_PATH propagation ──────────────────
WD="$TMP_ROOT/c6"; mkdir -p "$WD"
D="$(mkfixdir env env)"
run_runner "$WD" --workflows-dir "$D" --capability docker=off
ENV_SEEN="$(cat "$WD/tmp/env-seen" 2>/dev/null || true)"
TOOL_SEEN="$(cat "$WD/tmp/tool-seen" 2>/dev/null || true)"
if [[ "$RUN_RC" == "0" ]] \
   && grep -q 'wf=from-workflow job=from-job step=from-step' <<<"$ENV_SEEN" \
   && grep -q 'genv=42' <<<"$ENV_SEEN" \
   && [[ "$TOOL_SEEN" == "fake-tool-ran" ]]; then
  ok "workflow/job/step env layer + GITHUB_ENV var + GITHUB_PATH dir all propagate to later steps"
else
  fail "env propagation broken (rc=$RUN_RC, env-seen='$ENV_SEEN', tool-seen='$TOOL_SEEN')"
fi

# ── 7. uses: dispatch (checkout, artifact copy, cache, unknown) ─────────────
WD="$TMP_ROOT/c7"; mkdir -p "$WD/artifacts"
D="$(mkfixdir uses uses)"
run_runner "$WD" --workflows-dir "$D" --artifacts-dir "$WD/artifacts" --capability docker=off
if [[ "$RUN_RC" == "0" ]] \
   && grep -q 'checkout (no-op' <<<"$(cat "$WD/out.txt")" \
   && grep -q "artifact 'my-artifact' copied (1 path(s))" <<<"$(cat "$WD/out.txt")" \
   && grep -q 'actions/cache needs GitHub/docker infrastructure' <<<"$(cat "$WD/out.txt")" \
   && grep -q 'unknown action: some-vendor/unknown-action' <<<"$(cat "$WD/out.txt")" \
   && [[ "$(cat "$WD/artifacts/my-artifact/art.txt" 2>/dev/null)" == "artifact-body" ]]; then
  ok "uses: checkout no-op, artifact copied (\${{ runner.temp }} expanded), cache + unknown skip"
else
  fail "uses dispatch wrong (rc=$RUN_RC): $(grep -E 'SKIP|PASS|FAIL' "$WD/out.txt" | head -6)"
fi

# ── 8. docker capability gating + --strict ──────────────────────────────────
WD="$TMP_ROOT/c8"; mkdir -p "$WD"
D="$(mkfixdir docker docker-step)"
run_runner "$WD" --workflows-dir "$D" --capability docker=off --capability gh=off
if [[ "$RUN_RC" == "0" ]] && grep -q 'SKIP 2. build — needs docker (capability off)' <<<"$(cat "$WD/out.txt")" \
   && grep -q 'SKIP 3. scan — needs docker (capability off)' <<<"$(cat "$WD/out.txt")"; then
  ok "docker-gated step skips with capability off; docker: image scheme gates too; rc=0"
else
  fail "docker gating wrong (rc=$RUN_RC)"
fi
WD="$TMP_ROOT/c8s"; mkdir -p "$WD"
run_runner "$WD" --workflows-dir "$TMP_ROOT/fx-docker" --capability docker=off --strict
if [[ "$RUN_RC" == "1" ]]; then
  ok "--strict turns the skip into rc=1"
else
  fail "--strict should exit 1 on skips (rc=$RUN_RC)"
fi

# ── 9. unsupported expression skips loudly ──────────────────────────────────
WD="$TMP_ROOT/c9"; mkdir -p "$WD"
D="$(mkfixdir badexpr bad-expr)"
run_runner "$WD" --workflows-dir "$D" --capability docker=off
if [[ "$RUN_RC" == "0" ]] \
   && grep -q 'SKIP 1. uses-secret — unsupported expression' <<<"$(cat "$WD/out.txt")"; then
  ok "secrets expression refuses to expand; step skips loudly, rc stays 0"
else
  fail "bad-expr handling wrong (rc=$RUN_RC)"
fi

# ── 10. --job filter ────────────────────────────────────────────────────────
WD="$TMP_ROOT/c10"; mkdir -p "$WD"
D="$(mkfixdir jobfilter fail pass)"
run_runner "$WD" --workflows-dir "$D" --workflow 'fail*' --job bad --capability docker=off
if [[ "$RUN_RC" == "1" ]] && grep -q 'job bad' <<<"$(cat "$WD/out.txt")" \
   && ! grep -q 'job ok' <<<"$(cat "$WD/out.txt")"; then
  ok "--job filters to the named job only"
else
  fail "--job filter wrong (rc=$RUN_RC)"
fi

# ── 11. malformed YAML → exit 2 with file+reason ────────────────────────────
D="$(mkfixdir broken broken)"
WD="$TMP_ROOT/c11"; mkdir -p "$WD"
run_runner "$WD" --workflows-dir "$D"
if [[ "$RUN_RC" == "2" ]] && grep -q "aidc-ci: .*/broken.yml:" <<<"$(cat "$WD/out.txt")"; then
  ok "malformed workflow YAML: exit 2 naming the file"
else
  fail "broken.yml should exit 2 with file-named error (rc=$RUN_RC)"
fi

# ── 12. python+pyyaml missing → exit 2 with remediation ─────────────────────
WD="$TMP_ROOT/c12"; mkdir -p "$WD"
set +e
AIDC_CI_PYTHON=/nonexistent-python bash "$RUNNER" --work-dir "$WD" \
  --workflows-dir "$TMP_ROOT/fx-broken" >"$WD/out12.txt" 2>&1
RC12=$?
set -e
if [[ "$RC12" == "2" ]] && grep -q 'no python3-with-pyaml found' "$WD/out12.txt" \
   && grep -q 'AIDC_CI_PYTHON' "$WD/out12.txt"; then
  ok "unusable AIDC_CI_PYTHON: exit 2 with remediation (exclusive probe, no fallback)"
else
  fail "parser-missing path wrong (rc=$RC12)"
fi

# ── 13. refs-following gate pinned in the runner source ─────────────────────
# Behavioral proof is the dogfood replay of a workflow invoking a script in
# .github/scripts/ that uses docker unguarded: such a step must SKIP, while
# a script that probes `command -v docker` (self-degrading) must run.
# Hermetic fixtures can't cover this — refs resolve against the real
# project workspace — so the mechanism is pinned here.
if grep -q 'ref_needs_docker' "$RUNNER" \
   && grep -qF '.github/scripts/[A-Za-z0-9_./-]+\.sh' "$RUNNER" \
   && grep -qF "! grep -qF 'command -v docker'" "$RUNNER" \
   && grep -qF 'docker:[[:alnum:]]' "$RUNNER"; then
  ok "gate follows .github/scripts refs (guard-exempt) and the docker: scheme"
else
  fail "refs-following / docker:-scheme gate missing from runner source"
fi

# ── 14. AIDC_CI_PROJECT override: temp git repo, origin remote, widened ctx ─
PROJ="$TMP_ROOT/proj14"
mkdir -p "$PROJ/.github/workflows"
cp "$FIXTURES/ctx.yml" "$PROJ/.github/workflows/"
git -C "$PROJ" init -q -b main
git -C "$PROJ" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x
git -C "$PROJ" remote add origin https://github.com/acme/widget.git
WD="$TMP_ROOT/c14"; mkdir -p "$WD"
set +e
AIDC_CI_PROJECT="$PROJ" bash "$RUNNER" --work-dir "$WD" --capability docker=off >"$WD/out.txt" 2>&1
RC14=$?
set -e
if [[ "$RC14" == "0" ]] && grep -q "workspace=$PROJ" <<<"$(cat "$WD/out.txt")" \
   && [[ "$(cat "$WD/tmp/ctx-repo" 2>/dev/null)" == "repo=acme/widget" ]] \
   && [[ "$(cat "$WD/tmp/ctx-ref_name" 2>/dev/null)" == "ref_name=main" ]] \
   && [[ "$(cat "$WD/tmp/ctx-actor" 2>/dev/null)" == "actor=local" ]] \
   && [[ "$(cat "$WD/tmp/ctx-head_ref" 2>/dev/null)" == "head_ref=[]" ]]; then
  ok "AIDC_CI_PROJECT targets the temp repo; github.repository/ref_name/actor/head_ref expand from it"
else
  fail "project override wrong (rc=$RC14, repo='$(cat "$WD/tmp/ctx-repo" 2>/dev/null)', ref_name='$(cat "$WD/tmp/ctx-ref_name" 2>/dev/null)')"
fi

# ── 15. git-toplevel detection (no env override) ────────────────────────────
WD="$TMP_ROOT/c15"; mkdir -p "$WD"
set +e
( cd "$PROJ" && bash "$RUNNER" --work-dir "$WD" --capability docker=off ) >"$WD/out.txt" 2>&1
RC15=$?
set -e
if [[ "$RC15" == "0" ]] && grep -q "workspace=$PROJ" <<<"$(cat "$WD/out.txt")" \
   && grep -q 'TOTAL: 1 pass, 0 fail, 0 skip' <<<"$(cat "$WD/out.txt")"; then
  ok "project resolved from the git toplevel of the working dir"
else
  fail "toplevel detection wrong (rc=$RC15)"
fi

# ── 16. bad AIDC_CI_PROJECT → exit 2 ────────────────────────────────────────
WD="$TMP_ROOT/c16"; mkdir -p "$WD"
set +e
AIDC_CI_PROJECT=/nonexistent bash "$RUNNER" --work-dir "$WD" >"$WD/out.txt" 2>&1
RC16=$?
set -e
if [[ "$RC16" == "2" ]] && grep -q 'AIDC_CI_PROJECT: not a directory' <<<"$(cat "$WD/out.txt")"; then
  ok "bad AIDC_CI_PROJECT: exit 2 with a named reason"
else
  fail "bad project path should exit 2 (rc=$RC16)"
fi

# ── 17. ${{ env.* }} expansion + undefined-key loud SKIP ────────────────────
WD="$TMP_ROOT/c17"; mkdir -p "$WD"
D="$(mkfixdir envctx env-ctx)"
run_runner "$WD" --workflows-dir "$D" --capability docker=off
if [[ "$RUN_RC" == "0" ]] \
   && [[ "$(cat "$WD/tmp/env-ctx-seen" 2>/dev/null)" == "wf-value" ]] \
   && grep -q 'SKIP 2. missing-env-ctx — ${{ env.* }} key not defined in the merged env' <<<"$(cat "$WD/out.txt")"; then
  ok "\${{ env.* }} expands from the merged env; undefined env key skips loudly"
else
  fail "env-ctx handling wrong (rc=$RUN_RC, seen='$(cat "$WD/tmp/env-ctx-seen" 2>/dev/null)')"
fi

# ── 18. ${{ needs.* }} loud SKIP ────────────────────────────────────────────
WD="$TMP_ROOT/c18"; mkdir -p "$WD"
D="$(mkfixdir needsexpr needs-expr)"
run_runner "$WD" --workflows-dir "$D" --capability docker=off
if [[ "$RUN_RC" == "0" ]] \
   && grep -q 'job down declares needs:up' <<<"$(cat "$WD/out.txt")" \
   && grep -q 'SKIP 1. uses-needs — needs.* outputs unavailable locally' <<<"$(cat "$WD/out.txt")"; then
  ok "needs.* expressions skip loudly; needs note printed per job"
else
  fail "needs handling wrong (rc=$RUN_RC)"
fi

# ── 19. upload → download artifact round-trip + missing-artifact SKIP ───────
WD="$TMP_ROOT/c19"; mkdir -p "$WD"
D="$(mkfixdir download download download-missing)"
run_runner "$WD" --workflows-dir "$D" --artifacts-dir "$WD/artifacts" --capability docker=off
if [[ "$RUN_RC" == "0" ]] \
   && grep -q "artifact 'dl-artifact' downloaded to" <<<"$(cat "$WD/out.txt")" \
   && grep -q 'PASS 4. verify' <<<"$(cat "$WD/out.txt")" \
   && grep -q "SKIP 1. actions/download-artifact@2222.* — artifact 'never-uploaded' not found" <<<"$(cat "$WD/out.txt")"; then
  ok "download-artifact: round-trip lands on disk; missing artifact skips loudly"
else
  fail "download-artifact handling wrong (rc=$RUN_RC): $(grep -E 'SKIP|PASS|FAIL' "$WD/out.txt" | head -6)"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
