#!/usr/bin/env bash
#
# Structural guard for the per-agent stage layout in Dockerfile.base.tmpl
# (remaster). The per-agent stages made two failure modes possible that the
# old monolithic RUN could not have, and the first real build caught one: the
# opencode stage's `ln -sf` failed because `~/.local/bin` — which the old RUN
# pre-created before installing — only comes into existence later, in the
# final `main` stage. These checks parse the template directly so CI (which
# has no docker either) catches regressions of exactly that class:
#
#   1. every agent has the -1/-0/sel stage trio;
#   2. every agent-*-1 stage pre-creates the dirs it writes to (mkdir first);
#   3. the WITH_* / version ARGs are declared BEFORE the first FROM (global
#      scope — stage-scoped ARGs are invisible to FROM selector lines);
#   4. the final `main` stage COPY-merges from every sel-* selector;
#   5. `bash -n` passes on every RUN block (comment-stripped, continuations
#      joined the way the Dockerfile parser does it).
#
# Run with: bash tests/base-image-stages.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DF="$REPO_ROOT/templates/devcontainer/Dockerfile.base.tmpl"

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

[[ -f "$DF" ]] || { fail "template missing: $DF"; printf '\n0 passed, 1 failed\n'; exit 1; }

# Render like the Dockerfile parser: strip comment lines, join continuations.
lines=()
buf=""
while IFS= read -r l; do
  [[ "$l" =~ ^[[:space:]]*# ]] && continue
  buf+="$l"
  if [[ "$buf" == *\\ ]]; then
    buf="${buf%\\} "
    continue
  fi
  lines+=("$buf")
  buf=""
done <"$DF"
[[ -n "$buf" ]] && lines+=("$buf")

# ── 1. stage trio per agent ───────────────────────────────────────────────────
AGENTS="opencode claude codex cursor-agent grok omp"
for a in $AGENTS; do
  miss=0
  grep -q "^FROM base AS agent-$a-1$" "$DF" || miss=1
  grep -q "^FROM base AS agent-$a-0$" "$DF" || miss=1
  grep -q "^FROM agent-$a-\${WITH_$(printf '%s' "$a" | tr 'a-z' 'A-Z' | tr '-' '_')} AS sel-$a$" "$DF" || miss=1
  [[ "$miss" -eq 0 ]] \
    && ok "$a: -1/-0/sel stage trio present" \
    || fail "$a: incomplete stage trio"
done

# ── 2. every agent-1 stage mkdirs its target dirs first ───────────────────────
# Joined continuation blocks; an agent stage body is everything between
# `FROM base AS agent-<a>-1` and the next FROM (ARG re-declaration first, then
# the RUN). The assertion is on the RUN's first command, not the body's first
# line — the ARG line legitimately precedes it.
for a in $AGENTS; do
  body=""
  keep=0
  for l in "${lines[@]}"; do
    if [[ "$l" == "FROM base AS agent-$a-1" ]]; then keep=1; continue; fi
    [[ "$keep" -eq 1 && "$l" == FROM* ]] && break
    if [[ "$keep" -eq 1 ]]; then body+="$l"$'\n'; fi
  done
  if [[ "$body" != *"RUN mkdir -p /home/vscode/.local/bin"* ]]; then
    fail "$a: agent-1 stage does not mkdir ~/.local/bin first (stale-image class of the opencode ln failure)"
    continue
  fi
  if [[ "$a" == "opencode" && "$body" != *"RUN mkdir -p /home/vscode/.local/bin /home/vscode/.opencode"* ]]; then
    fail "opencode: agent-1 stage does not pre-create ~/.opencode (the ln -sf target pair)"
    continue
  fi
  ok "$a: agent-1 stage is self-sufficient (mkdir first)"
done

# ── 3. global ARGs declared before the first FROM ─────────────────────────────
first_from_line="$(grep -n '^FROM ' "$DF" | head -1 | cut -d: -f1)"
for arg in AIDC_AGENTS WITH_CLAUDE WITH_CODEX WITH_OPENCODE WITH_CURSOR_AGENT WITH_GROK WITH_OMP \
           CLAUDE_VERSION CODEX_VERSION OPENCODE_VERSION GROK_VERSION OMP_VERSION; do
  arg_line="$(grep -n "^ARG $arg=" "$DF" | head -1 | cut -d: -f1)"
  if [[ -n "$arg_line" && "$arg_line" -lt "$first_from_line" ]]; then
    ok "ARG $arg is global-scope (before first FROM)"
  else
    fail "ARG $arg missing or declared after the first FROM (FROM selectors would not resolve)"
  fi
done

# ── 4. final main stage merges every selector ─────────────────────────────────
main_start="$(grep -n '^FROM base AS main$' "$DF" | cut -d: -f1)"
[[ -n "$main_start" ]] \
  && ok "final tagged stage is 'FROM base AS main'" \
  || fail "'FROM base AS main' missing"
main_body="$(tail -n "+${main_start:-1}" "$DF")"
for a in $AGENTS; do
  if printf '%s' "$main_body" | grep -q "COPY --from=sel-$a "; then
    ok "main stage merges sel-$a"
  else
    fail "main stage does not COPY from sel-$a (agent would silently never install)"
  fi
done

# ── 5. RUN blocks are valid shell ─────────────────────────────────────────────
synt=0
for l in "${lines[@]}"; do
  [[ "$l" == "RUN "* ]] || continue
  shell="${l#RUN }"
  # strip Run-flags (e.g. --mount=...) the way the builder consumes them
  while [[ "$shell" == --mount=* ]]; do shell="${shell#* }"; done
  if ! bash -n -c "$shell" 2>/dev/null; then
    fail "RUN block fails bash -n: ${shell:0:70}…"
    synt=1
  fi
done
[[ "$synt" -eq 0 ]] && ok "all RUN blocks pass bash -n"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
