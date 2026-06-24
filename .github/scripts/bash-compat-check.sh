#!/usr/bin/env bash
#
# Runs INSIDE an official `bash:<version>` container (see bash-compat.yml) to
# catch shell-version incompatibilities that the shellcheck job can't:
#
#   * empty-array expansion under `set -u` — "${arr[@]}" aborts with
#     "unbound variable" on bash < 4.4 (e.g. macOS's system bash 3.2),
#     but is silently fine on the newer bash most Linux CI boxes run.
#
# This is a RUNTIME check: `bash -n` only parses, so it would miss the above.
# We therefore also execute the standalone install path that actually trips it.
set -euo pipefail

echo "::group::bash ${BASH_VERSION}"

# --- 1. Parse every shell script under this bash version --------------------
# `*.sh.tmpl` files hold mustache-style placeholders that won't parse, so the
# `*.sh` glob excludes them by design (mirrors shellcheck.yml). `!` (not `-not`)
# keeps this compatible with the container's busybox find.
targets=(bin/aidc)
while IFS= read -r f; do
  targets+=("$f")
done < <(find . -type f -name '*.sh' ! -path './.git/*' | sort)

for f in "${targets[@]}"; do
  echo "  parse: $f"
  bash -n "$f"
done

# --- 2. Execute the standalone install path ---------------------------------
# A fresh HOME has no Claude `*.env` profiles, so `sync-claude-aliases` builds
# an EMPTY `desired_aliases` array and then expands it — the exact path that
# crashed on bash 3.2. No Docker daemon or network is required for this path.
export HOME=/tmp/aidc-compat-home
export AIDC_BIN_DIR=/tmp/aidc-compat-bin
rm -rf "$HOME" "$AIDC_BIN_DIR"
mkdir -p "$HOME" "$AIDC_BIN_DIR"

echo "  smoke: aidc help"
bash bin/aidc help >/dev/null

echo "  smoke: aidc sync-claude-aliases (empty profile set)"
bash bin/aidc sync-claude-aliases

echo "OK: bash ${BASH_VERSION}"
echo "::endgroup::"
