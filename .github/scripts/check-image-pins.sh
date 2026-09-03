#!/usr/bin/env bash
#
# Assert every pinned tool inside a built aidc image reports its pinned
# version. Reads the `ARG <TOOL>_VERSION=` defaults from the Dockerfile
# template and substring-matches each tool's version output. The pinned tools
# live in the shared base template (Dockerfile.base.tmpl) since the image split.
#
# Usage: check-image-pins.sh <image-ref> [dockerfile]
set -euo pipefail

image="${1:?usage: check-image-pins.sh <image-ref> [dockerfile]}"
df="${2:-templates/devcontainer/Dockerfile.base.tmpl}"
[[ -f "$df" ]] || { echo "dockerfile not found: $df" >&2; exit 2; }

arg_value() { sed -n "s/^ARG $1=\(.*\)$/\1/p" "$df" | head -1; }

failures=0
check() { # <label> <arg-name> <binary>
  local label="$1" arg="$2" bin="$3"
  local want got
  want="$(arg_value "$arg")"
  want="${want#v}"
  if [[ -z "$want" ]]; then
    echo "FAIL: $label: ARG $arg not found in $df"
    failures=$((failures + 1))
    return
  fi
  # Vendors disagree on `--version` vs a `version` subcommand — try both.
  if ! got="$(docker run --rm "$image" "$bin" --version 2>&1)"; then
    if ! got="$(docker run --rm "$image" "$bin" version 2>&1)"; then
      echo "FAIL: $label: could not get a version from '$bin' in $image"
      printf '%s\n' "$got" | head -3 | sed 's/^/  /'
      failures=$((failures + 1))
      return
    fi
  fi
  case "$got" in
    *"$want"*)
      echo "ok: $label $want"
      ;;
    *)
      echo "FAIL: $label: expected $want, got: $(printf '%s' "$got" | head -1)"
      failures=$((failures + 1))
      ;;
  esac
}

check git-delta  GIT_DELTA_VERSION  delta
check pmg        PMG_VERSION        pmg
check vet        VET_VERSION        vet
check trufflehog TRUFFLEHOG_VERSION trufflehog
check gitleaks   GITLEAKS_VERSION   gitleaks
check syft       SYFT_VERSION       syft
check grype      GRYPE_VERSION      grype
check rtk        RTK_VERSION        rtk
check claude     CLAUDE_VERSION     claude
check codex      CODEX_VERSION      codex
check opencode   OPENCODE_VERSION   opencode
check grok       GROK_VERSION       grok
check omp        OMP_VERSION        omp
# cursor-agent: no vendor version pin — logged at build time instead.

if [[ "$failures" -gt 0 ]]; then
  echo "check-image-pins: $failures mismatch(es)" >&2
  exit 1
fi
echo "check-image-pins: all pinned versions match"
