#!/usr/bin/env bash
#
# Validate the files `aidc init` scaffolds into a project.
#
# Usage: validate-scaffold.sh <scaffolded-project-dir>
#
# Checks (each skipped with a note when its tool is unavailable, so the
# script is useful both on full CI runners and on minimal hosts):
#   - required scaffold files exist
#   - every scaffolded shell script parses (`bash -n`) and passes shellcheck
#   - .ai-container/project.env sources cleanly in a clean env under `set -u`
#   - .devcontainer/devcontainer.json is valid JSON
#   - .devcontainer/compose.yaml renders with `docker compose config`
#   - the Dockerfile passes BuildKit lint (`docker build --check`)
#
# Exit codes: 0 all checks passed (or skipped), 1 at least one failure,
# 2 usage error. Bash-3.2-safe (macOS system bash).
set -euo pipefail

if [[ $# -ne 1 || ! -d "${1:-}" ]]; then
  echo "usage: validate-scaffold.sh <scaffolded-project-dir>" >&2
  exit 2
fi
proj="$(cd "$1" && pwd)"

failures=0
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }
ok()   { printf 'ok:   %s\n' "$1"; }
skip() { printf 'skip: %s\n' "$1"; }

# --- 1. required files -------------------------------------------------------
required_files=(
  .devcontainer/Dockerfile
  .devcontainer/compose.yaml
  .devcontainer/compose.firewall.yaml
  .devcontainer/compose.hardened.yaml
  .devcontainer/devcontainer.json
  .devcontainer/scripts/bootstrap-state.sh
  .devcontainer/scripts/init-firewall.sh
  .ai-container/project.env
)
missing=0
for f in "${required_files[@]}"; do
  if [[ -f "$proj/$f" ]]; then
    ok "present: $f"
  else
    fail "missing required scaffold file: $f"
    missing=1
  fi
done
if [[ "$missing" -eq 1 ]]; then
  printf 'core scaffold files missing — aborting further checks\n' >&2
  exit 1
fi

# --- 2. shell syntax + shellcheck -------------------------------------------
# All scaffolded shell: .devcontainer (managed + seeded project-setup.sh)
# and scripts/ci when present.
scan_dirs=()
[[ -d "$proj/.devcontainer" ]] && scan_dirs+=("$proj/.devcontainer")
[[ -d "$proj/scripts/ci" ]] && scan_dirs+=("$proj/scripts/ci")

shell_files=()
# (no `sort -z` — BSD/macOS sort lacks it; ordering is cosmetic here)
while IFS= read -r -d '' f; do
  shell_files+=("$f")
done < <(find "${scan_dirs[@]}" -type f -name '*.sh' -print0)

if [[ "${#shell_files[@]}" -eq 0 ]]; then
  fail "no scaffolded shell scripts found under .devcontainer/ or scripts/ci/"
else
  for f in "${shell_files[@]}"; do
    if bash -n "$f" 2>/dev/null; then
      ok "bash -n: ${f#"$proj"/}"
    else
      bash -n "$f" 2>&1 | sed 's/^/  /' >&2 || true
      fail "bash -n: ${f#"$proj"/}"
    fi
  done

  if command -v shellcheck >/dev/null 2>&1; then
    # Same severity as the repo's shellcheck workflow.
    if shellcheck --severity=warning "${shell_files[@]}"; then
      ok "shellcheck (${#shell_files[@]} scripts)"
    else
      fail "shellcheck reported findings in scaffolded scripts"
    fi
  else
    skip "shellcheck not installed"
  fi
fi

# --- 3. project.env sources cleanly ------------------------------------------
# A clean env + `set -u` catches references to undefined variables and any
# syntax damage from a bad merge/edit.
if env -i HOME="${HOME:-/tmp}" bash -uc ". '$proj/.ai-container/project.env'" 2>/dev/null; then
  ok "project.env sources cleanly under set -u"
else
  env -i HOME="${HOME:-/tmp}" bash -uc ". '$proj/.ai-container/project.env'" 2>&1 | sed 's/^/  /' >&2 || true
  fail "project.env does not source cleanly"
fi

# --- 4. devcontainer.json is valid JSON --------------------------------------
devjson="$proj/.devcontainer/devcontainer.json"
if command -v jq >/dev/null 2>&1; then
  if jq -e . "$devjson" >/dev/null 2>&1; then
    ok "devcontainer.json is valid JSON (jq)"
  else
    fail "devcontainer.json is not valid JSON"
  fi
elif command -v python3 >/dev/null 2>&1; then
  if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$devjson" 2>/dev/null; then
    ok "devcontainer.json is valid JSON (python3)"
  else
    fail "devcontainer.json is not valid JSON"
  fi
else
  skip "neither jq nor python3 available for JSON validation"
fi

# --- 5. compose file renders --------------------------------------------------
# Stub every ${AIDC_*} variable the compose file references so `config` can
# render without a live aidc environment. Values are throwaway paths.
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  stub_dir="$(mktemp -d)"
  trap 'rm -rf "$stub_dir"' EXIT
  compose_env=()
  while IFS= read -r var; do
    [[ -n "$var" ]] || continue
    compose_env+=("$var=$stub_dir")
  done < <(grep -o '\${AIDC_[A-Z_]*' "$proj/.devcontainer/compose.yaml" \
             | sed 's/^\${//' | sort -u)
  if env COMPOSE_PROJECT_NAME=aidc_scaffold_validate \
       ${compose_env[@]+"${compose_env[@]}"} \
       docker compose -f "$proj/.devcontainer/compose.yaml" config -q; then
    ok "compose.yaml renders (docker compose config)"
  else
    fail "compose.yaml failed docker compose config"
  fi
  # The hardening overrides must also merge cleanly onto the base file
  # (firewall grants caps; hardened sets no-new-privileges — mutually
  # exclusive at runtime, but each must render).
  for override in compose.firewall.yaml compose.hardened.yaml; do
    [[ -f "$proj/.devcontainer/$override" ]] || continue
    if env COMPOSE_PROJECT_NAME=aidc_scaffold_validate \
         ${compose_env[@]+"${compose_env[@]}"} \
         docker compose -f "$proj/.devcontainer/compose.yaml" \
           -f "$proj/.devcontainer/$override" config -q; then
      ok "$override merges onto compose.yaml"
    else
      fail "$override failed to merge onto compose.yaml"
    fi
  done
else
  skip "docker compose not available — compose.yaml render not checked"
fi

# --- 6. Dockerfile BuildKit lint ----------------------------------------------
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if docker build --check "$proj/.devcontainer" >/dev/null 2>&1; then
    ok "Dockerfile passes docker build --check"
  else
    docker build --check "$proj/.devcontainer" 2>&1 | sed 's/^/  /' >&2 || true
    fail "Dockerfile failed docker build --check"
  fi
else
  skip "docker daemon not available — Dockerfile lint not checked"
fi

# --- summary -------------------------------------------------------------------
if [[ "$failures" -gt 0 ]]; then
  printf '\nvalidate-scaffold: %d failure(s)\n' "$failures" >&2
  exit 1
fi
printf '\nvalidate-scaffold: all checks passed\n'
