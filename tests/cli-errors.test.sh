#!/usr/bin/env bash
#
# Unit tests for CLI polish (lib/aidc.sh + completions/):
#   - unknown-command suggestions
#   - missing vs corrupt project.env errors
#   - completion table kept in sync with the dispatcher (drift guard)
#   - bash completion function produces candidates
#   - docs contain no dead relative links
#
# Run with: bash tests/cli-errors.test.sh
# shellcheck disable=SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

# 1. Unknown command suggests close matches + help/doctor.
out="$( (bash "$REPO_ROOT/bin/aidc" statu) 2>&1 )" || true
if printf '%s' "$out" | grep -q 'did you mean:.*status' \
   && printf '%s' "$out" | grep -q 'aidc help' \
   && printf '%s' "$out" | grep -q 'aidc doctor'; then
  ok "typo'd command suggests the right one"
else
  fail "suggestion output: $out"
fi
out="$( (bash "$REPO_ROOT/bin/aidc" zzzzqq) 2>&1 )" || true
if printf '%s' "$out" | grep -q 'unknown command' \
   && printf '%s' "$out" | grep -q 'aidc help'; then
  ok "hopeless typo still points at help"
else
  fail "no-suggestion output: $out"
fi

# 2. Missing vs corrupt project.env produce different, actionable errors.
. "$REPO_ROOT/lib/aidc.sh"
ws="$TMP_ROOT/nope"
mkdir -p "$ws"
out="$( (aidc::load_project_env "$ws") 2>&1 )" || true
if printf '%s' "$out" | grep -q "not an aidc project" \
   && printf '%s' "$out" | grep -q "aidc init"; then
  ok "missing project.env says: not initialized, run init"
else
  fail "missing case: $out"
fi
mkdir -p "$ws/.ai-container"
printf 'AIDC_BAD="$UNDEFINED_VAR_FOR_TEST"\n' >"$ws/.ai-container/project.env"
out="$( (aidc::load_project_env "$ws") 2>&1 )" || true
if printf '%s' "$out" | grep -q "corrupt project env" \
   && printf '%s' "$out" | grep -q "backup"; then
  ok "corrupt project.env says: corrupt, restore/backup"
else
  fail "corrupt case: $out"
fi

# 3. Drift guard: every dispatcher command appears in the completion table
#    and in the suggestion list.
dispatch_cmds="$(awk '/^aidc::main\(\)/,/^\}/' "$REPO_ROOT/lib/aidc.sh" \
  | grep -oE '^    [a-z][a-z|-]*(\|[^)]*)?\)' \
  | tr -d ' )' | tr '|' '\n' | grep -v '^-' | sort -u)"
comp_table="$(sed -n 's/^_aidc_commands="\(.*\)"$/\1/p' "$REPO_ROOT/completions/aidc.bash")"
suggest_table="$(sed -n 's/.*local known="\(.*\)"$/\1/p' "$REPO_ROOT/lib/aidc.sh")"
missing=""
for c in $dispatch_cmds; do
  case " $comp_table " in *" $c "*) ;; *) missing="$missing completion:$c" ;; esac
  case " $suggest_table " in *" $c "*) ;; *) missing="$missing suggest:$c" ;; esac
done
if [[ -z "$missing" ]]; then
  ok "completion + suggestion tables cover all $(echo "$dispatch_cmds" | wc -l | tr -d ' ') dispatcher commands"
else
  fail "tables out of sync with dispatcher:$missing"
fi

# 4. Completion function yields candidates for a partial command.
comp_out="$(bash -c '
  . "'"$REPO_ROOT"'/completions/aidc.bash"
  COMP_WORDS=(aidc s)
  COMP_CWORD=1
  _aidc
  printf "%s\n" "${COMPREPLY[@]}"
')"
if printf '%s\n' "$comp_out" | grep -qx 'status' \
   && printf '%s\n' "$comp_out" | grep -qx 'scan' \
   && printf '%s\n' "$comp_out" | grep -qx 'shell'; then
  ok "bash completion completes 's' to status/scan/shell/…"
else
  fail "completion candidates: $comp_out"
fi
comp_out="$(bash -c '
  . "'"$REPO_ROOT"'/completions/aidc.bash"
  COMP_WORDS=(aidc destroy -)
  COMP_CWORD=2
  _aidc
  printf "%s\n" "${COMPREPLY[@]}"
')"
if printf '%s\n' "$comp_out" | grep -qx -- '--purge-scaffold'; then
  ok "bash completion completes destroy flags"
else
  fail "destroy flag candidates: $comp_out"
fi

# 5. No dead relative links in README + docs.
dead=""
for src in "$REPO_ROOT/README.md" "$REPO_ROOT"/docs/*.md; do
  base="$(dirname "$src")"
  while IFS= read -r link; do
    target="${link%%#*}"
    [[ -n "$target" ]] || continue
    [[ -e "$base/$target" || -e "$REPO_ROOT/$target" ]] \
      || dead="$dead ${src#"$REPO_ROOT"/}->$link"
  done < <(
    grep -oE '\]\((\.\./)?[A-Za-z0-9_./-]+\.(md|sh|yml|yaml|json|tsv)(#[A-Za-z0-9-]*)?\)' "$src" 2>/dev/null \
      | sed 's/^](//; s/)$//'
  )
done
if [[ -z "$dead" ]]; then
  ok "no dead relative links in README/docs"
else
  fail "dead links:$dead"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
