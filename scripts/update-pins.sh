#!/usr/bin/env bash
#
# Refresh the version + SHA256 pins in templates/devcontainer/Dockerfile.tmpl.
#
# For every checksum-pinned tool: resolve the latest GitHub release tag, fetch
# the vendor's checksums file (or hash the artifact locally when the vendor
# publishes none), and print the up-to-date ARG lines. For version-pinned
# agents (no vendor checksums): print the latest version ARG lines.
#
# Usage:
#   scripts/update-pins.sh            # print fresh ARG lines (review mode)
#   scripts/update-pins.sh --write    # apply them to the Dockerfile template
#
# The rendered .devcontainer/Dockerfile refreshes from the template on the
# next `aidc up` / `aidc rebuild`, so only the template is rewritten here.
# Network: GitHub + vendor download endpoints. Bash-3.2-safe.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCKERFILE="${AIDC_PINS_DOCKERFILE:-$REPO_ROOT/templates/devcontainer/Dockerfile.tmpl}"

WRITE=0
case "${1:-}" in
  --write) WRITE=1 ;;
  "") ;;
  *) echo "usage: update-pins.sh [--write]" >&2; exit 2 ;;
esac

[[ -f "$DOCKERFILE" ]] || { echo "Dockerfile template not found: $DOCKERFILE" >&2; exit 1; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

latest_tag() { # <owner/repo> -> tag (e.g. v1.2.3)
  curl -fsSI -o /dev/null -w '%{redirect_url}' "https://github.com/$1/releases/latest" \
    | sed 's|.*/||'
}

checksum_for() { # <checksums-url> <asset-name> -> sha256
  curl -fsSL "$1" | awk -v a="$2" '$2 == a { print $1; exit }'
}

# Collected "NAME=value" pin lines, printed at the end / applied with --write.
PINS=()
add_pin() { PINS+=("$1=$2"); }

note() { printf '# %s\n' "$1" >&2; }

# --- checksum-pinned tools ----------------------------------------------------

pin_github_tool() { # <arg-prefix> <owner/repo> <checksums-file-pattern> <asset-amd64> <asset-arm64>
  # Patterns may contain {tag} and {ver} (tag without leading v).
  local prefix="$1" repo="$2" ck_pat="$3" asset_amd="$4" asset_arm="$5"
  local tag ver ck_url sha_amd sha_arm
  tag="$(latest_tag "$repo")"
  [[ -n "$tag" ]] || { echo "could not resolve latest tag for $repo" >&2; return 1; }
  ver="${tag#v}"
  ck_url="https://github.com/$repo/releases/download/$tag/$(printf '%s' "$ck_pat" | sed "s/{tag}/$tag/g; s/{ver}/$ver/g")"
  sha_amd="$(checksum_for "$ck_url" "$(printf '%s' "$asset_amd" | sed "s/{tag}/$tag/g; s/{ver}/$ver/g")")"
  sha_arm="$(checksum_for "$ck_url" "$(printf '%s' "$asset_arm" | sed "s/{tag}/$tag/g; s/{ver}/$ver/g")")"
  [[ -n "$sha_amd" && -n "$sha_arm" ]] || { echo "missing checksum entries for $repo $tag" >&2; return 1; }
  add_pin "${prefix}_VERSION" "$tag"
  add_pin "${prefix}_SHA256_AMD64" "$sha_amd"
  add_pin "${prefix}_SHA256_ARM64" "$sha_arm"
  note "$repo -> $tag"
}

pin_git_delta() {
  # dandavison/delta publishes no checksums file: hash the .deb artifacts.
  local tag tmp sha_amd sha_arm
  tag="$(latest_tag dandavison/delta)"
  [[ -n "$tag" ]] || { echo "could not resolve latest delta tag" >&2; return 1; }
  tmp="$(mktemp -d)"
  curl -fsSL "https://github.com/dandavison/delta/releases/download/$tag/git-delta_${tag}_amd64.deb" -o "$tmp/amd64.deb"
  curl -fsSL "https://github.com/dandavison/delta/releases/download/$tag/git-delta_${tag}_arm64.deb" -o "$tmp/arm64.deb"
  sha_amd="$(sha256_of "$tmp/amd64.deb")"
  sha_arm="$(sha256_of "$tmp/arm64.deb")"
  rm -rf "$tmp"
  add_pin "GIT_DELTA_VERSION" "$tag"
  add_pin "GIT_DELTA_SHA256_AMD64" "$sha_amd"
  add_pin "GIT_DELTA_SHA256_ARM64" "$sha_arm"
  note "dandavison/delta -> $tag (hashed locally; no vendor checksums file)"
}

# --- version-pinned agents (no vendor checksums to embed) ----------------------

pin_agents() {
  local v
  v="$(curl -fsSL https://downloads.claude.ai/claude-code-releases/latest 2>/dev/null || true)"
  if [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    add_pin "CLAUDE_VERSION" "$v"; note "claude -> $v"
  else
    echo "warn: could not resolve latest claude version (skipped)" >&2
  fi
  v="$(latest_tag openai/codex)"; v="${v#rust-v}"
  [[ -n "$v" ]] && { add_pin "CODEX_VERSION" "$v"; note "codex -> $v"; }
  v="$(latest_tag anomalyco/opencode)"; v="${v#v}"
  [[ -n "$v" ]] && { add_pin "OPENCODE_VERSION" "$v"; note "opencode -> $v"; }
  v="$(curl -fsSL https://x.ai/cli/stable 2>/dev/null || true)"
  if [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    add_pin "GROK_VERSION" "$v"; note "grok -> $v"
  else
    echo "warn: could not resolve latest grok version (skipped)" >&2
  fi
  # cursor: no version pin available from the vendor — nothing to update.
}

# --- run ------------------------------------------------------------------------

pin_git_delta
pin_github_tool "PMG"        "safedep/pmg"               "checksums.txt"                     "pmg_Linux_x86_64.tar.gz"                "pmg_Linux_arm64.tar.gz"
pin_github_tool "VET"        "safedep/vet"               "checksums.txt"                     "vet_Linux_x86_64.tar.gz"                "vet_Linux_arm64.tar.gz"
pin_github_tool "TRUFFLEHOG" "trufflesecurity/trufflehog" "trufflehog_{ver}_checksums.txt"   "trufflehog_{ver}_linux_amd64.tar.gz"    "trufflehog_{ver}_linux_arm64.tar.gz"
pin_github_tool "GITLEAKS"   "gitleaks/gitleaks"          "gitleaks_{ver}_checksums.txt"     "gitleaks_{ver}_linux_x64.tar.gz"        "gitleaks_{ver}_linux_arm64.tar.gz"
pin_github_tool "SYFT"       "anchore/syft"               "syft_{ver}_checksums.txt"         "syft_{ver}_linux_amd64.tar.gz"          "syft_{ver}_linux_arm64.tar.gz"
pin_github_tool "GRYPE"      "anchore/grype"              "grype_{ver}_checksums.txt"        "grype_{ver}_linux_amd64.tar.gz"         "grype_{ver}_linux_arm64.tar.gz"
pin_github_tool "RTK"        "rtk-ai/rtk"                 "checksums.txt"                    "rtk-x86_64-unknown-linux-musl.tar.gz"   "rtk-aarch64-unknown-linux-gnu.tar.gz"
pin_agents

printf '\n'
for pin in "${PINS[@]}"; do
  printf 'ARG %s\n' "$pin"
done

if [[ "$WRITE" -eq 1 ]]; then
  tmp="$(mktemp)"
  cp "$DOCKERFILE" "$tmp"
  changed=0
  for pin in "${PINS[@]}"; do
    name="${pin%%=*}"
    value="${pin#*=}"
    if grep -q "^ARG ${name}=" "$tmp"; then
      awk -v n="$name" -v v="$value" '
        $0 ~ "^ARG "n"=" { print "ARG "n"="v; next }
        { print }
      ' "$tmp" >"$tmp.new" && mv "$tmp.new" "$tmp"
      changed=1
    else
      echo "warn: ARG $name not found in $DOCKERFILE (skipped)" >&2
    fi
  done
  if [[ "$changed" -eq 1 ]]; then
    mv "$tmp" "$DOCKERFILE"
    echo "updated: $DOCKERFILE" >&2
    echo "next: rebuild (aidc rebuild) and commit the template change" >&2
  else
    rm -f "$tmp"
    echo "no ARG lines updated" >&2
  fi
fi
