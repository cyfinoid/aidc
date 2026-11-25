#!/usr/bin/env bash
#
# Unit tests for lib/aidc/apple.sh — the native Apple `container` runtime
# behind bin/aidc-apple.
#
# The engine is a stubbed `container` function (same trick the other suites
# use for docker); a guard `docker` function records any invocation and the
# suite FAILS if it was ever called — aidc-apple must never touch a Docker
# API, socktainer or otherwise. HOME is redirected before sourcing so all
# host paths (config root, empty seeds, opencode data) are isolated.
#
# Covered: engine gate (no fallback, ever), naming, resource defaults (whole
# vCPU truncation), volume creation (journal=ordered), the full run-flag set
# (binds/volumes/env/limits/caps/port), the user-drop entrypoint, the compose
# gateway verbs (up fast-path + recreate, down keep-vs-wipe, exec TTY
# translation, ps/config), base-current fast path, toolchain population,
# clean/doctor rows, unknown-verb hard failure, and the no-docker invariant.
#
# Run with: bash tests/apple-native.test.sh
# shellcheck disable=SC2034,SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# lib reads AIDC_ROOT (normally set by the bin/ launcher) for template paths.
AIDC_ROOT="$REPO_ROOT"
export AIDC_ROOT

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
export HOME="$TMP_ROOT/home"
mkdir -p "$HOME"

# shellcheck disable=SC1091
. "$REPO_ROOT/lib/aidc.sh"
# Capture stock help before the apple module wraps it (mirrors bin/aidc-apple).
eval "aidc_apple::stock_help()$(declare -f aidc::cmd_help | sed '1d')"
export AIDC_RUNTIME=apple
# Mirror bin/aidc-apple: the provider machinery must stay inert so
# export_compose_env never probes docker (which would trip the no-docker
# guard below for a reason that isn't the module's fault).
export AIDC_DOCKER_PROVIDER=docker
export AIDC_PROVIDER_RESOLVED=1
# shellcheck disable=SC1090,SC1091
. "$REPO_ROOT/lib/aidc/apple.sh"

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

# ── fixtures ────────────────────────────────────────────────────────────────
ST="$TMP_ROOT/state"; mkdir -p "$ST"
: >"$ST/containers"; : >"$ST/running"; : >"$ST/images"; : >"$ST/volumes"
: >"$ST/log"; : >"$ST/run.args"; : >"$ST/build.args"; : >"$ST/exec.args"
DOCKER_CALLS=0

# Guard: aidc-apple must NEVER invoke docker (no shim, no fallback).
docker() {
  DOCKER_CALLS=$((DOCKER_CALLS + 1))
  echo "aidc-apple invoked docker: $*" >&2
  return 66
}

# The native engine, stubbed. State lives in $ST; knob envs:
#   APPLE_SYS_DOWN      system status fails
#   APPLE_BUILD_FAIL    builds fail
#   APPLE_RUN_FAIL      container run fails
#   APPLE_VOLCREATE_FAIL  volume create fails
# grep -vx returns 1 both on "no match" and on "match removed, empty result",
# so these arms move the temp file UNCONDITIONALLY (an empty post-delete file
# is valid) and skip flag args (grep would parse '-t' as its own option).
strip_line() { # strip_line <file> <line>
  [[ "$2" == -* ]] && return 0
  grep -vx -- "$2" "$1" >"$1.t" 2>/dev/null || true
  mv -f "$1.t" "$1"
}

container() {
  printf 'container %s\n' "$*" >>"$ST/log"
  local sub="$1"; shift
  case "$sub" in
    system)
      [[ "$1" == "status" ]] || return 0
      [[ -z "${APPLE_SYS_DOWN:-}" ]]
      ;;
    builder) return 0 ;;
    build)
      printf '%s\n' "--- $*" >>"$ST/build.args"
      [[ -z "${APPLE_BUILD_FAIL:-}" ]] || return 1
      local a prev="" tag=""
      for a in "$@"; do [[ "$prev" == "-t" ]] && tag="$a"; prev="$a"; done
      [[ -n "$tag" ]] || return 0
      # APPLE_BUILD_401_ONCE: the FIRST build fails with the store-index-lag
      # signature (own tag → docker.io 401); build_with_retry must recover.
      if [[ -n "${APPLE_BUILD_401_ONCE:-}" && ! -f "$ST/401-consumed" ]]; then
        : >"$ST/401-consumed"
        echo "Error: internalError: \"HTTP request to https://registry-1.docker.io/v2/library/${tag%%:*}/manifests/${tag#*:} failed with response: 401 Unauthorized\"" >&2
        return 1
      fi
      # APPLE_BUILD_UNTAGGED: simulate the confirmed shim bug — the build
      # lands the image UNTAGGED (untagged@sha256:fake-…); tag_fresh must
      # recover by tagging the single fresh digest.
      if [[ -n "${APPLE_BUILD_UNTAGGED:-}" ]]; then
        printf '%s\n' "untagged@sha256:fake-${tag//:/.}" >>"$ST/images"
      else
        printf '%s\n' "$tag" >>"$ST/images"
      fi
      ;;
    image)
      case "$1" in
        list) cat "$ST/images" ;;
        tag)
          printf 'image tag: %s -> %s\n' "$2" "$3" >>"$ST/imagetag.log"
          strip_line "$ST/images" "$2"
          printf '%s\n' "$3" >>"$ST/images"
          ;;
        delete) local t; for t in "$@"; do strip_line "$ST/images" "$t"; done ;;
      esac
      ;;
    volume)
      case "$1" in
        inspect) grep -qx "$2" "$ST/volumes" ;;
        create)
          [[ -z "${APPLE_VOLCREATE_FAIL:-}" ]] || return 1
          printf 'create %s\n' "$*" >>"$ST/volcreates"
          local name="${!#}"
          printf '%s\n' "$name" >>"$ST/volumes"
          ;;
        delete) local v; for v in "$@"; do strip_line "$ST/volumes" "$v"; done ;;
      esac
      ;;
    run)
      printf '%s\n' "--- $*" >>"$ST/run.args"
      [[ -z "${APPLE_RUN_FAIL:-}" ]] || return 1
      local rc=0
      if [[ "$*" == *"--entrypoint test"* ]]; then
        # Toolchain ready-marker probe — its rc must be the arm's rc (a later
        # no-op statement must not mask it).
        [[ -f "$ST/tc-ready" ]] || rc=1
      elif [[ "$*" == *"aidc-toolchain-store"* ]]; then
        : >"$ST/tc-ready"   # populate run
      fi
      local a prev="" cname=""
      for a in "$@"; do [[ "$prev" == "--name" ]] && cname="$a"; prev="$a"; done
      if [[ -n "$cname" ]]; then
        printf '%s\n' "$cname" >>"$ST/containers"
        # APPLE_RUN_DIES: the container starts (run rc 0) but never becomes
        # running — simulates the hardware crash-at-startup loop.
        [[ -n "${APPLE_RUN_DIES:-}" ]] || printf '%s\n' "$cname" >>"$ST/running"
      fi
      return "$rc"
      ;;
    list) cat "$ST/containers" ;;
    logs)
      # container logs [--boot] <name> — fixture streams for the crash dump.
      if [[ "$1" == "--boot" ]]; then cat "$ST/boot.log" 2>/dev/null; else cat "$ST/stdio.log" 2>/dev/null; fi
      ;;
    exec)
      printf '%s\n' "--- $*" >>"$ST/exec.args"
      [[ -z "${APPLE_EXEC_FAIL:-}" ]] || return 1
      grep -qx "$1" "$ST/running"
      ;;
    stop)
      local c
      for c in "$@"; do strip_line "$ST/running" "$c"; done
      ;;
    delete)
      local c
      for c in "$@"; do strip_line "$ST/running" "$c"; strip_line "$ST/containers" "$c"; done
      ;;
    *) return 1 ;;
  esac
}

# Fake project: project.env carries slug + worktree (mirrors scaffold.sh).
WS="$TMP_ROOT/ws"
mkdir -p "$WS/.ai-container" "$WS/.devcontainer" "$TMP_ROOT/corewt"
cat >"$WS/.ai-container/project.env" <<EOF
# aidc-managed
AIDC_VERSION=test
AIDC_WORKSPACE=$WS
AIDC_REPO_SLUG=demo
AIDC_CORE_ROOT=$TMP_ROOT/core
AIDC_CORE_BRANCH=main
AIDC_CORE_WORKTREE=$TMP_ROOT/corewt
EOF
touch "$WS/.devcontainer/Dockerfile" "$WS/.devcontainer/Dockerfile.base"

resets() {
  unset AIDC_MEM_LIMIT AIDC_CPU_LIMIT AIDC_APPLE_MEMORY AIDC_APPLE_CPUS \
        AIDC_ENABLE_EGRESS_FIREWALL AIDC_NO_NEW_PRIVILEGES AIDC_OPENCODE_WEB \
        AIDC_OPENCODE_WEB_PORT AIDC_APPLE_DROP_USER APPLE_SYS_DOWN \
        APPLE_BUILD_FAIL APPLE_RUN_FAIL APPLE_VOLCREATE_FAIL \
        AIDC_BASE_IMAGE AIDC_AGENTS 2>/dev/null || true
}
count() { grep -c -- "$1" "$2" 2>/dev/null || printf '0'; }

# Fresh engine env per section (export_compose_env sets these).
fresh_env() {
  resets
  aidc::export_compose_env "$WS" >/dev/null 2>&1
}

# ── 1. engine gate: no fallback, ever ───────────────────────────────────────
out="$(unset -f container; aidc_apple::require_engine 2>&1)" && rc=0 || rc=$?
if [[ "$rc" != "0" ]] && printf '%s' "$out" | grep -q "no fallback"; then
  ok "missing container CLI → die, message names 'no fallback'"
else
  fail "gate missing-CLI: rc=$rc out=$out"
fi
APPLE_SYS_DOWN=1
out="$(aidc_apple::require_engine 2>&1)" && rc=0 || rc=$?
if [[ "$rc" != "0" ]] && printf '%s' "$out" | grep -q "container system start"; then
  ok "services down → die with start hint"
else
  fail "gate services-down: rc=$rc out=$out"
fi
unset APPLE_SYS_DOWN
AIDC_ISOLATE_VM=1 out="$(aidc_apple::require_engine 2>&1 || true)"
if printf '%s' "$out" | grep -q "AIDC_ISOLATE_VM ignored"; then
  ok "isolate-vm ignored with a warning (VM-per-container already)"
else
  fail "isolate-vm warn: $out"
fi
unset AIDC_ISOLATE_VM AIDC_APPLE_VM_WARNED

# ── 2. naming + resource defaults ───────────────────────────────────────────
fresh_env
[[ "$(aidc_apple::cname)" == "aidc_demo-workspace" ]] \
  && [[ "$(aidc_apple::vol claude_home)" == "aidc_demo_claude_home" ]] \
  && [[ "$(aidc_apple::thin_image)" == "aidc_demo-workspace:latest" ]] \
  && ok "naming mirrors compose (project-scoped)" || fail "naming"
[[ "$(aidc_apple::memory)" == "4G" && "$(aidc_apple::cpus)" == "4" ]] \
  && ok "conservative defaults: 4G / 4 cpu" || fail "defaults: $(aidc_apple::memory)/$(aidc_apple::cpus)"
AIDC_MEM_LIMIT=8g; AIDC_CPU_LIMIT=1.5
[[ "$(aidc_apple::memory)" == "8G" && "$(aidc_apple::cpus)" == "1" ]] \
  && ok "stock knobs honored; units normalized; 1.5 cpu truncates to whole vCPU (Apple floors)" \
  || fail "knobs: $(aidc_apple::memory)/$(aidc_apple::cpus)"
AIDC_CPU_LIMIT=0.5
[[ "$(aidc_apple::cpus)" == "1" ]] \
  && ok "0.5 cpu floors to 1 vCPU, never a zero-cpu degenerate" \
  || fail "cpu floor: $(aidc_apple::cpus)"
resets

# ── 3. volumes ──────────────────────────────────────────────────────────────
fresh_env
aidc_apple::ensure_volumes
if [[ "$(wc -l <"$ST/volumes" | tr -d ' ')" == "10" ]] \
   && grep -q "aidc_demo_claude_home" "$ST/volumes" \
   && grep -q "^aidc_toolchains$" "$ST/volumes" \
   && grep -q "journal=ordered" "$ST/volcreates"; then
  ok "nine state volumes + toolchains store created with journal=ordered"
else
  fail "volumes: $(cat "$ST/volumes" | tr '\n' ' ')"
fi

# ── 3b. the 16 KiB Dockerfile cap (apple/container#735) ────────────────────
# Minifier semantics: heredoc-aware (bodies verbatim except whole-line
# comments; shebangs kept), outside heredocs comments/blanks/indentation go.
MN="$TMP_ROOT/min"; mkdir -p "$MN"
cat >"$MN/big.Dockerfile" <<'MDEOF'
# leading comment — stripped
FROM alpine:3.20

  # indented comment — stripped
RUN echo one \
    && echo two
COPY <<'EOF' /script
#!/bin/sh
# a shell comment inside the heredoc — stripped
echo payload
EOF
# trailing comment — stripped
MDEOF
aidc_apple::minify_dockerfile "$MN/big.Dockerfile" "$MN/min.out"
mn_out="$(cat "$MN/min.out")"
if printf '%s\n' "$mn_out" | grep -qx 'FROM alpine:3.20' \
   && printf '%s\n' "$mn_out" | grep -qx 'RUN echo one \\' \
   && printf '%s\n' "$mn_out" | grep -qx '&& echo two' \
   && printf '%s\n' "$mn_out" | grep -qx '#!/bin/sh' \
   && printf '%s\n' "$mn_out" | grep -qx 'echo payload' \
   && printf '%s\n' "$mn_out" | grep -qx 'EOF' \
   && ! printf '%s\n' "$mn_out" | grep -q 'a shell comment' \
   && ! printf '%s\n' "$mn_out" | grep -q 'leading comment'; then
  ok "minifier: comments/blanks/indent stripped outside heredocs; shebang kept, comments stripped inside"
else
  fail "minifier: $(printf '%s' "$mn_out" | tr '\n' ';')"
fi

# Size gate on the REAL template, measuring the RIGHT number (the minified
# form — what the builder actually receives). If the template grows past the
# cap, this fails CI with the reason instead of a mysterious build error.
aidc_apple::minify_dockerfile "$REPO_ROOT/templates/devcontainer/Dockerfile.base.tmpl" "$MN/base.min"
base_min_size="$(wc -c <"$MN/base.min" | tr -d ' ')"
if [[ "$base_min_size" -lt "${AIDC_APPLE_DOCKERFILE_MAX:-16384}" ]]; then
  ok "minified Dockerfile.base ($base_min_size bytes) fits the 16384-byte native cap"
else
  fail "minified Dockerfile.base is $base_min_size bytes — over the 16384 cap; trim the template"
fi

# prepare_dockerfile routing: small file passes through; big file gets the
# .apple-min sibling; an over-cap-even-minified file dies naming #735.
small="$MN/small.Dockerfile"; printf 'FROM alpine:3.20\n' >"$small"
[[ "$(aidc_apple::prepare_dockerfile "$small")" == "$small" ]] \
  && ok "prepare_dockerfile: small file used as-is" || fail "small passthrough"
big="$MN/over.Dockerfile"
{ printf 'FROM alpine:3.20\n'; for i in $(seq 1 600); do printf '# padding comment line %s to exceed the cap with non-comment content\n' "$i"; done; printf 'RUN true %s\n' "$(head -c 16200 /dev/zero | tr '\0' 'x')"; } >"$big"
[[ "$(aidc_apple::prepare_dockerfile "$big")" == "$big.apple-min" ]] \
  && ok "prepare_dockerfile: oversized file minified to .apple-min sibling" \
  || fail "big routing: got '$(aidc_apple::prepare_dockerfile "$big" 2>&1 | head -1)'"
huge="$MN/huge.Dockerfile"
{ printf 'FROM alpine:3.20\n'; for i in $(seq 1 300); do printf 'RUN printf %s > /dev/null && true\n' "$(head -c 60 /dev/zero | tr '\0' 'y')"; done; } >"$huge"
out="$(aidc_apple::prepare_dockerfile "$huge" 2>&1)" && rc=0 || rc=$?
if [[ "$rc" != "0" ]] && printf '%s' "$out" | grep -q 'apple/container#735'; then
  ok "prepare_dockerfile: unminifiable file dies naming apple/container#735"
else
  fail "over-cap die: rc=$rc out=$out"
fi

# ── 3c. chunked builds (FROM-local chaining under the header budget) ───────
CH="$TMP_ROOT/chunk"; mkdir -p "$CH"
{
  printf 'FROM alpine:3.20 AS base\n'          # 1
  printf 'ARG PIN_ONE=abc\n'                    # 2
  printf 'RUN echo one \\\n'                    # 3 (continuation)
  printf '  && echo two\n'                      # 4
  printf 'RUN echo three\n'                     # 5
  printf 'COPY --from=base /x /y\n'             # 6  last COPY --from consumer
  printf 'RUN echo four\n'                      # 7
  printf 'RUN echo five\n'                      # 8
  printf 'COPY <<'"'"'EOF'"'"' /f\n'            # 9  heredoc start
  printf 'hello body\n'                         # 10 heredoc body
  printf 'EOF\n'                                # 11 heredoc end
  printf 'RUN echo six\n'                       # 12
  printf 'RUN echo seven\n'                     # 13
  printf 'RUN echo eight\n'                     # 14
} >"$CH/min"
# Boundary properties with a mid-file budget.
split="$(aidc_apple::pick_split "$CH/min" 1000000)"
split_line="$(sed -n "${split}p" "$CH/min")"
if [[ "$split" -gt "6" && "$split" -lt "14" ]] \
   && [[ "$split_line" == RUN* ]] \
   && [[ "$(wc -c <"$(head -n $((split - 1)) "$CH/min")" | tr -d ' ')" -le "1000000" ]]; then
  ok "pick_split: after the last COPY --from, before EOF, at an instruction start"
else
  fail "pick_split: split=$split line='$split_line'"
fi
split2="$(aidc_apple::pick_split "$CH/min" 110)"  # bytes(1..6)=107 → earliest legal split
if [[ "$split2" == "7" ]]; then
  ok "pick_split: respects the byte budget (earliest boundary after COPY --from)"
else
  fail "pick_split budget: split2=$split2 (want 7)"
fi
# Continuation/heredoc safety: with the budget forcing near line 4-11, the
# split must land on instruction starts only (7/12/13 — never 4, 10, 11).
for b in 60 70 80 100 120; do
  s="$(aidc_apple::pick_split "$CH/min" "$b")"
  [[ "$s" == "7" || "$s" == "12" || "$s" == "13" || -z "$s" || "$s" == "0" ]] \
    || { fail "pick_split unsafe split=$s at budget=$b"; break; }
done
ok "pick_split: never inside continuations or heredoc bodies"

# Stage-def/consumer pairs pin ONLY their own span. A late COPY --from=base
# whose stage is defined at the TOP makes mid-file splits unsafe (the
# consumer's stage would not exist in chunk 2) → 0. The same file with the
# consumer referencing its OWN stage (defined next to it) splits fine.
{
  printf 'FROM alpine AS base\n'
  printf 'RUN echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
  printf 'RUN echo bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
  printf 'FROM base AS final\n'
  printf 'COPY --from=base /x /y\n'
} >"$CH/pairs"
s="$(aidc_apple::pick_split "$CH/pairs" 1000)"
[[ "$s" == "0" ]] \
  && ok "pick_split: refuses to strand a COPY --from=<early stage> (def→use span pinned)" \
  || fail "stage-pair rule: split=$s (want 0 — base's def must stay with its consumer)"
{
  printf 'FROM alpine AS base\n'
  printf 'RUN echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
  printf 'RUN echo bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
  printf 'FROM base AS final\n'
  printf 'COPY --from=final /x /y\n'
} >"$CH/pairs2"
s="$(aidc_apple::pick_split "$CH/pairs2" 1000)"
[[ "$s" == "4" ]] \
  && ok "pick_split: unrelated late pairs do not block mid-file splits" \
  || fail "stage-pair rule 2: split=$s (want 4)"

# emit_chunk_header: mid-stage continuation gets FROM + ARG redeclare.
aidc_apple::emit_chunk_header "$CH/min" "12" "prev-tag:1" >"$CH/hdr1"
hdr1="$(head -3 "$CH/hdr1" | tr '\n' ';')"
if [[ "$hdr1" == "FROM prev-tag:1;ARG PIN_ONE=abc;RUN echo six;" ]]; then
  ok "chunk header: mid-stage → FROM prev + ARG redeclare + continuation"
else
  fail "chunk header mid-stage: $hdr1"
fi
# Split landing ON a `FROM base AS agent-x`: rebased onto the previous chunk
# (base is an earlier stage here — defined at line 1).
{
  printf 'FROM alpine:3.20 AS base\n'
  printf 'RUN echo setup\n'
  printf 'FROM base AS agent-x\n'
  printf 'RUN true\n'
} >"$CH/stagefile"
aidc_apple::emit_chunk_header "$CH/stagefile" "3" "prev-tag:2" >"$CH/hdr2"
hdr2="$(head -1 "$CH/hdr2")"
[[ "$hdr2" == "FROM prev-tag:2 AS agent-x" ]] \
  && ok "chunk header: FROM <earlier-stage> AS x rebased onto the previous chunk" \
  || fail "chunk header FROM-AS: line1='$hdr2' out=$(cat "$CH/hdr2" | tr '\n' ';')"
# Bare FROM (no stage): replaced, not duplicated.
{
  printf 'FROM alpine:3.20 AS base\n'
  printf 'RUN echo setup\n'
  printf 'FROM base\n'
  printf 'RUN true\n'
} >"$CH/barefile"
aidc_apple::emit_chunk_header "$CH/barefile" "3" "prev-tag:3" >"$CH/hdr3"
if [[ "$(head -1 "$CH/hdr3")" == "FROM prev-tag:3" ]] \
   && [[ "$(grep -c '^FROM' "$CH/hdr3")" == "1" ]]; then
  ok "chunk header: bare FROM replaced (no double stage boundary)"
else
  fail "chunk header bare FROM: $(cat "$CH/hdr3" | tr '\n' ';')"
fi
# THE HARDWARE BUG: a DEEP `FROM base` (not at the split line) must also be
# rewritten — left alone it resolves as docker.io/library/base:latest (401).
{
  printf 'FROM alpine:3.20 AS base\n'
  printf 'RUN echo setup\n'
  printf 'RUN echo more\n'                 # split lands here (line 3)
  printf 'FROM base AS agent-claude-0\n'   # deep reference to chunk-1's stage
  printf 'RUN install-claude\n'
  printf 'FROM agent-claude-0 AS sel-claude\n'   # defined IN this chunk: untouched
  printf 'RUN select\n'
} >"$CH/deepfile"
aidc_apple::emit_chunk_header "$CH/deepfile" "3" "prev-tag:4" >"$CH/hdr4"
if grep -qx 'FROM prev-tag:4 AS agent-claude-0' "$CH/hdr4" \
   && grep -qx 'FROM agent-claude-0 AS sel-claude' "$CH/hdr4" \
   && ! grep -q '^FROM base' "$CH/hdr4"; then
  ok "chunk header: DEEP FROM <earlier-stage> rewritten; local stages untouched"
else
  fail "deep rewrite: $(cat "$CH/hdr4" | tr '\n' ';')"
fi
# Selector form referencing an earlier stem is rewritten too.
{
  printf 'FROM alpine:3.20 AS base\n'
  printf 'FROM base AS agent-opencode-0\n'
  printf 'FROM base AS agent-opencode-1\n'
  printf 'RUN echo split-point\n'                # split at line 4
  printf 'FROM agent-opencode-${WITH_OPENCODE} AS sel-opencode\n'
  printf 'RUN select\n'
} >"$CH/selfile"
aidc_apple::emit_chunk_header "$CH/selfile" "4" "prev-tag:5" >"$CH/hdr5"
if grep -qx 'FROM prev-tag:5 AS sel-opencode' "$CH/hdr5"; then
  ok "chunk header: selector FROM agent-x-\${ARG} rebased when the stem was split"
else
  fail "selector rewrite: $(cat "$CH/hdr5" | tr '\n' ';')"
fi

# End-to-end chunked build through the stub: small budget forces 2+ chunks.
fresh_env
{
  printf 'FROM alpine:3.20 AS base\n'
  printf 'ARG PIN=xyz\n'
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do printf 'RUN echo padding-step-%02d-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' "$i"; done
} >"$WS/.devcontainer/Dockerfile.base"
export AIDC_APPLE_DOCKERFILE_BUDGET=450
: >"$ST/build.args"
aidc::ensure_base_image "$WS" >/dev/null 2>&1
base_tag="$(aidc::base_image_tag "$WS")"
if grep -q -- "-t ${base_tag}-c1" "$ST/build.args" \
   && grep -q -- "-t ${base_tag} " "$ST/build.args" \
   && [[ "$(grep -c '^--- ' "$ST/build.args")" -ge "2" ]] \
   && grep -q "${base_tag}$" "$ST/images" \
   && [[ -f "$WS/.devcontainer/Dockerfile.base.c1" ]] \
   && [[ "$(head -1 "$WS/.devcontainer/Dockerfile.base.r1")" == "FROM ${base_tag}-c1" ]] \
   && grep -q '^ARG PIN=xyz' "$WS/.devcontainer/Dockerfile.base.r1"; then
  ok "native_build: oversized file chunked, chained via FROM <chunk-tag>, ARG redeclared"
else
  fail "chunked e2e: builds=$(grep -c '^--- ' "$ST/build.args") r1='$(head -2 "$WS/.devcontainer/Dockerfile.base.r1" 2>/dev/null | tr '\n' ';')'"
fi
unset AIDC_APPLE_DOCKERFILE_BUDGET
rm -f "$WS/.devcontainer/Dockerfile.base.c1" "$WS/.devcontainer/Dockerfile.base.r1"
: >"$WS/.devcontainer/Dockerfile.base"

# ensure_base_image builds from the minified file when the source is oversized.
fresh_env

cp "$REPO_ROOT/templates/devcontainer/Dockerfile.base.tmpl" "$WS/.devcontainer/Dockerfile.base"
: >"$ST/build.args"
aidc::ensure_base_image "$WS" >/dev/null 2>&1
if grep -q -- '-f .*Dockerfile.base.apple-min' "$ST/build.args"; then
  ok "base build routed through the minified Dockerfile (29KB source)"
else
  fail "base build file: $(grep -o -- '-f [^ ]*' "$ST/build.args" | head -1)"
fi
rm -f "$WS/.devcontainer/Dockerfile.base.apple-min"
# Restore the empty fixture: later cases (the up tests) must not inherit the
# real template's content hash — it would make the base image "already built".
: >"$WS/.devcontainer/Dockerfile.base"

# ── 4. run flags ────────────────────────────────────────────────────────────

fresh_env
aidc_apple::run_flags
# Render as a single argv line so flag/value pairs (separate array elements,
# exactly as the CLI receives them) can be asserted as substrings. NB: `has`
# takes the pattern as $1 directly — a `--` separator would BE $1.
flags_str="$(printf ' %s' "${AIDC_APPLE_RUN_FLAGS[@]}") "
has() { printf '%s' "$flags_str" | grep -q -- " $1 "; }
if has '--init' && has '-w /workspace' && has '--shm-size 1G' \
   && has '-m 4G' && has '-c 4' && has '-l aidc.project=demo' \
   && has '--user 0:0' \
   && printf '%s' "$flags_str" | grep -q 'source=.*/.devcontainer,target=/workspace/.devcontainer,readonly' \
   && printf '%s' "$flags_str" | grep -q 'gitconfig.d,target=/host-seed/gitconfig.d,readonly' \
   && ! printf '%s' "$flags_str" | grep -q 'gitconfig,target=/host-seed/gitconfig,readonly' \
   && printf '%s' "$flags_str" | grep -q 'target=/host-seed/claude,readonly' \
   && printf '%s' "$flags_str" | grep -q 'source=aidc_toolchains,target=/opt/toolchains,readonly' \
   && [[ "$(printf '%s' "$flags_str" | grep -o -- ' -v aidc_demo_[a-z_]*:' | wc -l | tr -d ' ')" == "9" ]] \
   && has '-e HOME=/home/aidc' \
   && has '-e CLAUDE_CONFIG_DIR=/home/aidc/.claude' \
   && ! printf '%s' "$flags_str" | grep -q ' -p '; then
  ok "run flags: init/root-init/workdir/shm/limits/label/ro-binds/9 volumes/env; no port by default"
else
  fail "run flags: $flags_str"
fi
AIDC_OPENCODE_WEB=1 AIDC_OPENCODE_WEB_PORT=4096
aidc_apple::run_flags
printf ' %s' "${AIDC_APPLE_RUN_FLAGS[@]}" | grep -q -- ' -p 127.0.0.1:4096:4096 ' \
  && ok "opencode-web publishes loopback-only" || fail "port publish"
AIDC_ENABLE_EGRESS_FIREWALL=1
aidc_apple::run_flags
flags_str="$(printf ' %s' "${AIDC_APPLE_RUN_FLAGS[@]}") "
if printf '%s' "$flags_str" | grep -q -- ' --cap-add NET_ADMIN ' \
   && printf '%s' "$flags_str" | grep -q -- ' --cap-add NET_RAW '; then
  ok "firewall grants NET_ADMIN+NET_RAW"
else
  fail "caps: $flags_str"
fi
unset AIDC_ENABLE_EGRESS_FIREWALL AIDC_APPLE_NNP_WARNED
AIDC_NO_NEW_PRIVILEGES=1
nnp_out="$(aidc_apple::run_flags 2>&1 || true)"
if printf '%s' "$nnp_out" | grep -q "no Apple container equivalent"; then
  ok "no-new-privileges warns once and is dropped (no native equivalent)"
else
  fail "nnp: $nnp_out"
fi
resets

# ── 5. entrypoint (volume ownership + user drop) ────────────────────────────
fresh_env
aidc_apple::entrypoint_args
ep="$(printf '%s ' "${AIDC_APPLE_ENTRY[@]}")"
if printf '%s' "$ep" | grep -q 'chown 1000:1000' && printf '%s' "$ep" | grep -q 'sudo -u aidc -E' \
   && printf '%s' "$ep" | grep -q 'bootstrap-state.sh init' && printf '%s' "$ep" | grep -q 'sleep infinity' \
   && printf '%s' "$ep" | grep -q 'ln -sfn /host-seed/gitconfig.d/gitconfig /host-seed/gitconfig' \
   && printf '%s' "$ep" | grep -q 'command -v sudo' \
   && printf '%s' "$ep" | grep -q 'overlay bind may be broken' \
   && ! printf '%s' "$ep" | grep -q runuser; then
  ok "entrypoint: gitconfig symlink + chown → sudo drop (image-guaranteed) + bootstrap existence check → bootstrap && sleep"
else
  fail "entrypoint: $ep"
fi
AIDC_APPLE_DROP_USER=0
aidc_apple::entrypoint_args
ep="$(printf '%s ' "${AIDC_APPLE_ENTRY[@]}")"
if ! printf '%s' "$ep" | grep -q 'sudo -u aidc' && ! printf '%s' "$ep" | grep -q runuser \
   && printf '%s' "$ep" | grep -q 'bootstrap-state.sh init'; then
  ok "AIDC_APPLE_DROP_USER=0 keeps the root escape hatch (no drop machinery)"
else
  fail "drop-user=0: $ep"
fi
resets

# ── 6. gateway: ps / config / exec ──────────────────────────────────────────
fresh_env
[[ "$(aidc::compose_capture "$WS" ps -q workspace)" == "" ]] \
  && ok "ps -q: empty when the container does not exist" || fail "ps absent"
printf '%s\n' "aidc_demo-workspace" >>"$ST/containers"
[[ "$(aidc::compose_capture "$WS" ps -q workspace)" == "" ]] \
  && ok "ps -q: STOPPED container is not 'running' (compose semantics — self-heal keeps working)" \
  || fail "ps stopped: got '$(aidc::compose_capture "$WS" ps -q workspace)'"
printf '%s\n' "aidc_demo-workspace" >>"$ST/running"
[[ "$(aidc::compose_capture "$WS" ps -q workspace)" == "aidc_demo-workspace" ]] \
  && ok "ps -q: prints the container name when running" || fail "ps running"
[[ "$(aidc::compose_capture "$WS" config --images)" == "aidc_demo-workspace:latest" ]] \
  && ok "config --images resolves the thin image" || fail "config"
: >"$ST/exec.args"
aidc::compose "$WS" exec -T workspace echo hi >/dev/null 2>&1 || true
last_exec="$(tail -1 "$ST/exec.args")"
if printf '%s' "$last_exec" | grep -q -- '-i --user 1000:1000 -w /workspace aidc_demo-workspace echo hi'; then
  ok "exec -T: scripted path — stdin open, no TTY, STILL uid 1000 (root execs would leave unreadable files)"
else
  fail "exec -T: $last_exec"
fi
: >"$ST/exec.args"
aidc::compose "$WS" exec -e OPENCODE_PASSWORD workspace zsh -l >/dev/null 2>&1 || true
last_exec="$(tail -1 "$ST/exec.args")"
if printf '%s' "$last_exec" | grep -q -- '--user 1000:1000' \
   && printf '%s' "$last_exec" | grep -q -- '-w /workspace' \
   && printf '%s' "$last_exec" | grep -q 'zsh -l'; then
  ok "interactive exec: uid drop + workdir"
else
  fail "exec interactive: $last_exec"
fi
# Bare `-e KEY` is docker syntax (inherit from caller). Apple documents exec
# -e as key=value only → the gateway expands bare keys host-side; unset keys
# are omitted (docker semantics).
: >"$ST/exec.args"
export APPLE_TEST_SECRET="tok-val"
aidc::compose "$WS" exec -T -e APPLE_TEST_SECRET -e APPLE_TEST_UNSET workspace true >/dev/null 2>&1 || true
last_exec="$(tail -1 "$ST/exec.args")"
if printf '%s' "$last_exec" | grep -q -- '-e APPLE_TEST_SECRET=tok-val' \
   && ! printf '%s' "$last_exec" | grep -q 'APPLE_TEST_UNSET'; then
  ok "exec -e: bare keys expand host-side; unset keys omitted"
else
  fail "exec -e expansion: $last_exec"
fi
unset APPLE_TEST_SECRET
out="$(aidc::compose "$WS" exec -T -e 2>&1)" && rc=0 || rc=$?
if [[ "$rc" != "0" ]] && printf '%s' "$out" | grep -q "needs a non-empty value"; then
  ok "exec -e as last arg / empty value → die (no unbound-variable crash)"
else
  fail "exec -e guard: rc=$rc out=$out"
fi

# ── 7. up: build + run + idempotence ────────────────────────────────────────
fresh_env
: >"$ST/run.args"; : >"$ST/build.args"
aidc::compose "$WS" up -d workspace >/dev/null 2>&1
run1="$(grep -c '^--- ' "$ST/run.args")"
builds="$(grep -c '^--- ' "$ST/build.args")"
last_run="$(tail -1 "$ST/run.args")"
if [[ "$builds" == "2" ]] \
   && grep -q -- '--build-arg AIDC_AGENTS=opencode' "$ST/build.args" \
   && grep -q -- "--build-arg AIDC_BASE_IMAGE=$(aidc::base_image_tag "$WS")" "$ST/build.args" \
   && printf '%s' "$last_run" | grep -q -- '--name aidc_demo-workspace' \
   && printf '%s' "$last_run" | grep -q -- '--init' \
   && [[ "$(cat "$WS/.ai-container/apple-image-base" 2>/dev/null)" == "$(aidc::base_image_tag "$WS")" ]] \
   && [[ -f "$WS/.ai-container/apple-run-state" ]] \
   && grep -qx 'aidc_demo-workspace' "$ST/running"; then
  ok "up: base + thin built natively, run with full flags, state recorded, running"
else
  fail "up: builds=$builds run=$(printf '%s' "$last_run" | cut -c1-120)"
fi
# Idempotent: same image + no port change → no recreate, no rebuild.
aidc::compose "$WS" up -d workspace >/dev/null 2>&1
if [[ "$(grep -c '^--- ' "$ST/run.args")" == "$run1" ]] \
   && [[ "$(grep -c '^--- ' "$ST/build.args")" == "$builds" ]]; then
  ok "up fast-path: identical state is a no-op (compose parity)"
else
  fail "up idempotence: runs=$(grep -c '^--- ' "$ST/run.args") builds=$(grep -c '^--- ' "$ST/build.args")"
fi
# --build forces a thin rebuild + recreate.
aidc::compose "$WS" up -d --build workspace >/dev/null 2>&1
if [[ "$(grep -c '^--- ' "$ST/run.args")" == "$((run1 + 1))" ]] \
   && [[ "$(grep -c '^--- ' "$ST/build.args")" == "$((builds + 1))" ]]; then
  ok "up --build: rebuilds and recreates"
else
  fail "up --build: runs/builds=$(grep -c '^--- ' "$ST/run.args")/$(grep -c '^--- ' "$ST/build.args")"
fi
# Stale base record → thin rebuild on plain up.
: >"$WS/.ai-container/apple-image-base"
aidc::compose "$WS" up -d workspace >/dev/null 2>&1
if [[ "$(grep -c '^--- ' "$ST/build.args")" == "$((builds + 2))" ]]; then
  ok "base-change detection rebuilds the thin image (recorded-tag fast path)"
else
  fail "base-current: builds=$(grep -c '^--- ' "$ST/build.args")"
fi

# ── 8. down / destroy ───────────────────────────────────────────────────────
vol_count_before="$(wc -l <"$ST/volumes" | tr -d ' ')"
img_before="$(wc -l <"$ST/images" | tr -d ' ')"
aidc::compose "$WS" down >/dev/null 2>&1
if ! grep -qx 'aidc_demo-workspace' "$ST/containers" \
   && [[ "$(wc -l <"$ST/volumes" | tr -d ' ')" == "$vol_count_before" ]] \
   && [[ "$(wc -l <"$ST/images" | tr -d ' ')" == "$img_before" ]]; then
  ok "down: stops + deletes the container; volumes and images kept"
else
  fail "down: vols/images changed"
fi
# Bring it back, then destroy.
aidc::compose "$WS" up -d workspace >/dev/null 2>&1
aidc::compose "$WS" down -v --rmi local --remove-orphans >/dev/null 2>&1
if ! grep -q 'aidc_demo_claude_home' "$ST/volumes" \
   && grep -qx 'aidc_toolchains' "$ST/volumes" \
   && ! grep -q 'aidc_demo-workspace:latest' "$ST/images" \
   && grep -q "aidc-base:" "$ST/images"; then
  ok "destroy: project volumes + thin image wiped; toolchains + base kept"
else
  fail "destroy: vols=$(cat "$ST/volumes" | tr '\n' ' ') imgs=$(cat "$ST/images" | tr '\n' ' ')"
fi

# ── 9. toolchains ───────────────────────────────────────────────────────────
rm -f "$ST/tc-ready"
fresh_env
aidc::ensure_toolchain_volume go >/dev/null 2>&1
if grep -q 'aidc-toolchain-store-go' "$ST/build.args" && [[ -f "$ST/tc-ready" ]]; then
  ok "tools install: store image built, volume populated once"
else
  fail "toolchain populate: $(grep 'toolchain-store' "$ST/build.args" | head -1)"
fi
pop_runs="$(grep 'aidc-toolchain-store-go' "$ST/run.args" | grep -cv -- '--entrypoint test' || true)"
aidc::ensure_toolchain_volume go >/dev/null 2>&1
if [[ "$(grep 'aidc-toolchain-store-go' "$ST/run.args" | grep -cv -- '--entrypoint test' || true)" == "$pop_runs" ]]; then
  ok "tools install idempotent: ready marker skips re-populate"
else
  fail "toolchain re-populate"
fi

# ── 10. clean / doctor / unknown verb / help ────────────────────────────────
fresh_env
clean_out="$(AIDC_DOCTOR_WARNS=0 AIDC_DOCTOR_FAILS=0 aidc::doctor_check_docker 2>&1 || true)"
if printf '%s' "$clean_out" | grep -q 'OK.*container' \
   && printf '%s' "$clean_out" | grep -q 'no shim' \
   && printf '%s' "$clean_out" | grep -q 'WARN.*memory'; then
  ok "doctor: native rows, 'no shim', memory default warn"
else
  fail "doctor: $clean_out"
fi
APPLE_SYS_DOWN=1
AIDC_DOCTOR_WARNS=0; AIDC_DOCTOR_FAILS=0
down_out="$(aidc::doctor_check_docker 2>&1 || true)"
printf '%s' "$down_out" | grep -q 'FAIL.*apple-system' \
  && ok "doctor: services-down FAIL row" || fail "doctor down: $down_out"
unset APPLE_SYS_DOWN

out="$(aidc::compose "$WS" frobnicate 2>&1)" && rc=0 || rc=$?
if [[ "$rc" != "0" ]] && printf '%s' "$out" | grep -q "not implemented natively"; then
  ok "unknown compose verb dies loudly (no silent fallback)"
else
  fail "unknown verb: rc=$rc out=$out"
fi

help_out="$(aidc::cmd_help 2>&1 || true)"
if printf '%s' "$help_out" | grep -q 'aidc-apple - AI devcontainer bootstrapper' \
   && printf '%s' "$help_out" | grep -q 'native runtime notes' \
   && printf '%s' "$help_out" | grep -q 'aidc-apple destroy'; then
  ok "help: stock command list under the aidc-apple name + native notes"
else
  fail "help: $(printf '%s' "$help_out" | head -3)"
fi

# ── 9d. store-index lag: own-tag docker.io 401 → wait + retry recovers ─────
fresh_env
{
  printf 'FROM alpine:3.20 AS base\n'
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do printf 'RUN echo padding-step-%02d-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' "$i"; done
} >"$WS/.devcontainer/Dockerfile.base"
export AIDC_APPLE_DOCKERFILE_BUDGET=450 APPLE_BUILD_401_ONCE=1
rm -f "$ST/401-consumed"
: >"$ST/build.args"
aidc::ensure_base_image "$WS" >/dev/null 2>&1
base_tag2="$(aidc::base_image_tag "$WS")"
first_line="$(head -1 "$ST/build.args")"
attempts1="$(grep -c -- "-t ${base_tag2}-c1" "$ST/build.args")"
if [[ "$attempts1" -ge "2" ]] \
   && grep -q "${base_tag2}$" "$ST/images" \
   && [[ "$first_line" == *"-t ${base_tag2}-c1"* ]]; then
  ok "lag-retry: own-tag docker.io 401 retried once, build recovered"
else
  fail "lag-retry: attempts=$attempts1 imgs=$(cat "$ST/images" | tr '\n' ' ')"
fi
unset AIDC_APPLE_DOCKERFILE_BUDGET APPLE_BUILD_401_ONCE
rm -f "$ST/401-consumed" "$WS/.devcontainer/Dockerfile.base.c1" "$WS/.devcontainer/Dockerfile.base.r1"
: >"$WS/.devcontainer/Dockerfile.base"

# ── 9b. the untagged-landing shim bug: build → tag_fresh recovery ──────────

fresh_env
export APPLE_BUILD_UNTAGGED=1
: >"$ST/imagetag.log"
aidc::compose "$WS" up -d workspace >/dev/null 2>&1
if grep -q 'aidc_demo-workspace:latest' "$ST/images" \
   && ! grep -q '^untagged@' "$ST/images" \
   && grep -q 'untagged@sha256:fake-aidc_demo-workspace.latest -> aidc_demo-workspace:latest' "$ST/imagetag.log"; then
  ok "untagged-landing bug: build recovers via tag-the-fresh-digest (no untagged leftovers)"
else
  fail "untagged recovery: imgs=$(cat "$ST/images" | tr '\n' ' ') tags=$(cat "$ST/imagetag.log" | tr '\n' ';')"
fi
unset APPLE_BUILD_UNTAGGED

# ── 9c. socktainer coexistence warn (shared engine; DNS_UPSTREAM panics) ───
unset AIDC_APPLE_SOCKTAINER_WARNED
mkdir -p "$HOME/.socktainer"
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$HOME/.socktainer/container.sock" 2>/dev/null || true
warn_out="$(aidc_apple::warn_socktainer 2>&1 || true)"
if printf '%s' "$warn_out" | grep -q "brew services stop socktainer"; then
  ok "socktainer socket detected → engine-shared DNS warning (on the create path, not per-exec)"
else
  fail "socktainer warn: $warn_out"
fi
# The engine gate itself must NOT warn (exec-path spam guard).
gate_out="$(aidc_apple::require_engine 2>&1 || true)"
if ! printf '%s' "$gate_out" | grep -q "socktainer"; then
  ok "require_engine stays quiet about socktainer (warn moved to container creation)"
else
  fail "engine-gate warn spam: $gate_out"
fi
rm -f "$HOME/.socktainer/container.sock"
unset AIDC_APPLE_SOCKTAINER_WARNED

# ── 9e. crash-at-startup: liveness check surfaces boot/stdio logs, no fake ready ──
fresh_env
export APPLE_RUN_DIES=1 AIDC_APPLE_LIVENESS_WAIT=2
: >"$ST/running"; : >"$ST/containers"   # prior sections left it running
printf 'vminit panic: DNS_UPSTREAM env var must be set\n' >"$ST/boot.log"
printf 'entrypoint: runuser failed\n' >"$ST/stdio.log"
out="$(aidc::compose "$WS" up -d workspace 2>&1)" && rc=0 || rc=$?
if [[ "$rc" != "0" ]] \
   && printf '%s' "$out" | grep -q 'died within' \
   && printf '%s' "$out" | grep -q 'DNS_UPSTREAM env var must be set' \
   && printf '%s' "$out" | grep -q 'runuser failed' \
   && ! printf '%s' "$out" | grep -q 'container is ready'; then
  ok "crash-at-startup: up dies loudly with boot+stdio log tails (no fake 'ready')"
else
  fail "crash startup: rc=$rc out=$(printf '%s' "$out" | tail -4 | tr '\n' ';')"
fi
unset APPLE_RUN_DIES AIDC_APPLE_LIVENESS_WAIT
rm -f "$ST/boot.log" "$ST/stdio.log"
# Leave a clean running container for later sections.
fresh_env
aidc::compose "$WS" up -d workspace >/dev/null 2>&1

# ── 10. overrides for stock docker-shaped helpers ───────────────────────────

# ensure_toolchain_volumes (PLURAL — the up/agent-entry path) must never touch
# docker and must create the shared store + per-language toolchains. Reset
# the stub's toolchain-store images first: earlier sections leave them built,
# which would legitimately skip the builds this case asserts on.
: >"$ST/log"
: >"$ST/build.args"
grep -v '^aidc-toolchain-store-' "$ST/images" >"$ST/images.t" 2>/dev/null || true
mv -f "$ST/images.t" "$ST/images"
AIDC_TOOLCHAINS="go,java"
aidc::ensure_toolchain_volumes "$WS" >/dev/null 2>&1
if grep -qx 'aidc_toolchains' "$ST/volumes" \
   && grep -q 'aidc-toolchain-store-go' "$ST/build.args" \
   && grep -q 'aidc-toolchain-store-java' "$ST/build.args"; then
  ok "ensure_toolchain_volumes: native store + per-language toolchains"
else
  fail "ensure_toolchain_volumes: $(tail -3 "$ST/log" | tr '\n' ';')"
fi
unset AIDC_TOOLCHAINS

# need_cmd: docker is not a requirement under the native runtime; others are.
if aidc::need_cmd docker git 2>/dev/null; then
  ok "need_cmd: docker requirement dropped, real ones kept"
else
  fail "need_cmd docker-skip"
fi
out="$(aidc::need_cmd definitely-not-a-command-xyz 2>&1)" && rc=0 || rc=$?
if [[ "$rc" != "0" ]] && printf '%s' "$out" | grep -q "definitely-not-a-command-xyz"; then
  ok "need_cmd: missing real command still dies"
else
  fail "need_cmd missing: rc=$rc"
fi

# vm_* are no-ops (VM-per-container makes them redundant; stock ones would
# build a Lima VM and hijack DOCKER_HOST).
if aidc::vm_ensure "/ws" && aidc::vm_stop "/ws" && aidc::vm_destroy "/ws" \
   && [[ "$DOCKER_CALLS" == "0" ]]; then
  ok "vm_ensure/stop/destroy neutralized (no Lima/Firecracker, no DOCKER_HOST)"
else
  fail "vm neutralization"
fi

# doctor_check_container: native rows, no docker info probe.
AIDC_DOCTOR_WARNS=0; AIDC_DOCTOR_FAILS=0
c_out="$(aidc::doctor_check_container "$WS" 2>&1 || true)"
printf '%s' "$c_out" | grep -q 'OK.*container' \
  && ok "doctor_check_container: native state row (no docker info)" \
  || fail "doctor container: $c_out"

# ── 10b. recreate on resource change (config identity) ─────────────────────
fresh_env
aidc::compose "$WS" up -d workspace >/dev/null 2>&1
runs_before="$(grep -c '^--- ' "$ST/run.args")"
AIDC_MEM_LIMIT=8g aidc::compose "$WS" up -d workspace >/dev/null 2>&1
last_run="$(tail -1 "$ST/run.args")"
if [[ "$(grep -c '^--- ' "$ST/run.args")" == "$((runs_before + 1))" ]] \
   && printf '%s' "$last_run" | grep -q -- ' -m 8G '; then
  ok "memory change recreates the container with the new size (VM resources are create-time)"
else
  fail "memory recreate: runs=$(grep -c '^--- ' "$ST/run.args") want $((runs_before + 1)) last='$(printf '%s' "$last_run" | grep -o -- '-m [^ ]*')'"
fi
resets

# ── 10c. clean: stale store reclamation ─────────────────────────────────────
# clean computes the current-base keeper from the CWD project (that's how
# `aidc-apple clean` runs in real life) — so run it from $WS. project.env's
# AIDC_AGENTS is part of the base tag's content hash: the keeper must reflect
# the PROJECT's selection (loaded from project.env), not the ambient default.
fresh_env
cp "$WS/.ai-container/project.env" "$TMP_ROOT/project.env.bak"
printf 'AIDC_AGENTS=opencode,claude\n' >>"$WS/.ai-container/project.env"
project_base="$(AIDC_AGENTS=opencode,claude aidc::base_image_tag "$WS")"
ambient_base="$(AIDC_AGENTS=opencode aidc::base_image_tag "$WS")"
printf '%s\n' "aidc-base:stalehash1" "aidc-toolchain-store-go:oldhash" \
  "$project_base" "$ambient_base" >>"$ST/images"
clean_out="$(cd "$WS" && AIDC_AGENTS=opencode aidc::cmd_clean --apply 2>&1 || true)"
if ! grep -q 'aidc-base:stalehash1' "$ST/images" \
   && ! grep -q 'aidc-toolchain-store-go:oldhash' "$ST/images" \
   && ! grep -q "$ambient_base" "$ST/images" \
   && grep -q "$project_base" "$ST/images" \
   && grep -q 'aidc_demo-workspace:latest' "$ST/images" \
   && grep -qx 'aidc_toolchains' "$ST/volumes"; then
  ok "clean --apply: stale stores removed; the project's OWN base (per project.env AIDC_AGENTS) kept"
else
  fail "clean: imgs=$(cat "$ST/images" | tr '\n' ' ')"
fi
cp "$TMP_ROOT/project.env.bak" "$WS/.ai-container/project.env"
rm -f "$TMP_ROOT/project.env.bak"

# ── 10d. status: native rows, docker-store rows masked, guard preserved ────
status_out="$(cd "$WS" && aidc::cmd_status 2>&1 || true)"
if printf '%s' "$status_out" | grep -q 'apple-native' \
   && printf '%s' "$status_out" | grep -q 'claude_home' \
   && [[ "$DOCKER_CALLS" == "0" ]] \
   && declare -f docker >/dev/null 2>&1; then
  ok "status: native rows; docker-store volume row masked; no-docker guard survives the mask"
else
  fail "status: $(printf '%s' "$status_out" | head -4)"
fi

# ── 10e. recreate on bind-layout change (clipboard) ────────────────────────
fresh_env
aidc::compose "$WS" up -d workspace >/dev/null 2>&1
runs_before="$(grep -c '^--- ' "$ST/run.args")"
AIDC_ENABLE_CLIPBOARD=1 aidc::compose "$WS" up -d workspace >/dev/null 2>&1
if [[ "$(grep -c '^--- ' "$ST/run.args")" == "$((runs_before + 1))" ]]; then
  ok "clipboard toggle recreates the container (bind layout is create-time)"
else
  fail "clipboard recreate: runs=$(grep -c '^--- ' "$ST/run.args")"
fi
resets

# ── 11. the invariant: docker was never invoked ─────────────────────────────
if [[ "$DOCKER_CALLS" == "0" ]]; then
  ok "no-docker invariant: aidc-apple never invoked docker across all flows"
else
  fail "docker was invoked $DOCKER_CALLS time(s)"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
