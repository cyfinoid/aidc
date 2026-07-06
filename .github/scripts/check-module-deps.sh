#!/usr/bin/env bash
#
# Layering guard for the lib/aidc/ modules:
#   1. modules never source anything — only lib/aidc.sh composes them;
#   2. every aidc:: function is defined exactly once across the lib tree.
# Run from the repo root (CI: shellcheck workflow).
set -euo pipefail

fails=0

# 1. Modules never source shell code (runtime sourcing of *.env data files —
#    config.env / project.env / profile envs — is fine and expected).
for f in lib/aidc/*.sh; do
  if grep -nE '^\s*(source |\. ).*(\.sh|AIDC_LIB_DIR)' "$f"; then
    echo "FAIL: $f sources shell code — only lib/aidc.sh composes modules" >&2
    fails=$((fails + 1))
  fi
done

# 2. No duplicate function definitions.
dupes="$(grep -hoE '^aidc::[a-z_0-9]+\(\)' lib/aidc.sh lib/aidc/*.sh | sort | uniq -d)"
if [[ -n "$dupes" ]]; then
  echo "FAIL: duplicate function definitions:" >&2
  printf '%s\n' "$dupes" >&2
  fails=$((fails + 1))
fi

# 3. The entry point still loads every module exactly once.
for mod in lib/aidc/*.sh; do
  base="aidc/$(basename "$mod")"
  count="$(grep -cF "\$AIDC_LIB_DIR/$base\"" lib/aidc.sh || true)"
  if [[ "$count" -ne 1 ]]; then
    echo "FAIL: lib/aidc.sh sources $base $count times (expected 1)" >&2
    fails=$((fails + 1))
  fi
done

if [[ "$fails" -gt 0 ]]; then
  echo "check-module-deps: $fails violation(s)" >&2
  exit 1
fi
echo "check-module-deps: layering OK ($(ls lib/aidc/*.sh | wc -l | tr -d ' ') modules)"
