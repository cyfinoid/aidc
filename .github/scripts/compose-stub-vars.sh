#!/usr/bin/env bash
#
# Print the AIDC_* variables in a compose file that need a stub value before
# `docker compose config` can render it without a live aidc environment — one
# per line, deduplicated.
#
# Usage: compose-stub-vars.sh <compose-file>
#
# Only the bare `${AIDC_FOO}` form is emitted. That is how the compose template
# writes host bind-mount sources: a host path has no sensible default, so the
# caller must supply one. Anything written `${AIDC_FOO:-default}` is omitted on
# purpose so its own default renders — those are the non-path knobs, and three
# of them are numeric (`pids_limit`, `mem_limit`, `cpus`). Handing those a
# directory path makes compose fail a type cast rather than render:
#
#   error while interpolating services.workspace.cpus: failed to cast to
#   expected type: strconv.ParseFloat: parsing "/tmp/stub": invalid syntax
#
# This rule previously lived as a copy-pasted `grep -o '\${AIDC_[A-Z_]*'` in
# both validate-scaffold.sh and the aidc-e2e hardening-posture step, and was
# wrong in both. It lives here once so a third caller cannot diverge again.
#
# Exit codes: 0 success (including "no matches" — an empty list is valid),
# 2 usage error. Bash-3.2-safe (macOS system bash).
set -euo pipefail

if [[ $# -ne 1 || ! -f "${1:-}" ]]; then
  echo "usage: compose-stub-vars.sh <compose-file>" >&2
  exit 2
fi

# grep exits 1 on no match, which `set -o pipefail` would turn into a failure;
# an empty list is a legitimate result, so absorb it explicitly rather than
# masking the whole pipeline with `|| true`.
matches="$(grep -oE '\$\{AIDC_[A-Z_]+\}' "$1" || true)"
[[ -n "$matches" ]] || exit 0

printf '%s\n' "$matches" | sed -e 's/^\${//' -e 's/}$//' | sort -u
