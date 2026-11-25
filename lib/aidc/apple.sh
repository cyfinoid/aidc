#!/usr/bin/env bash
# aidc module: Apple `container` NATIVE runtime (aidc-apple).
#
# Sourced by bin/aidc-apple AFTER lib/aidc.sh with AIDC_RUNTIME=apple, this
# module redefines aidc's engine chokepoints so the ENTIRE command surface
# (init/up/down/agents/sync/status/…) runs on Apple's `container` CLI
# directly — no socktainer, no Docker API, no fallback. Everything
# engine-agnostic (scaffold, config, auth seeding, session sync, hooks,
# scan/ci/sbom plumbing) is reused verbatim from the other modules; only the
# functions below touch an engine.
#
# Why overrides instead of a parallel module: aidc funnels every container
# operation through aidc::compose / aidc::compose_capture plus a handful of
# image/volume helpers (ensure_base_image, image_exists, toolchain volume).
# Redefining those here gives the native runtime the whole command surface
# for free — and keeps a single source of truth for everything else.
#
# Mapping (docs/apple-container.md has the full table):
#   compose up -d [--build]   -> volume create + container build + container run -d
#   compose down [−v --rmi]   -> container stop/delete (+ volume/image delete)
#   compose exec [-T]         -> container exec [--tty] [--interactive]
#   docker build              -> container build (BuildKit; builder sized via env)
#   docker volume             -> container volume (ext4, journal=ordered)
#
# Native gaps (documented, never silent):
#   - security_opt no-new-privileges has no Apple equivalent → warned + dropped
#     (per-container VM isolation is the boundary Apple provides).
#   - pids_limit has no Apple equivalent (no cgroup pids.max in a VM).
#   - Named volumes are fresh ext4: the image's uid-1000 pre-created dirs do
#     NOT seed them (Docker does) → the init runs as root, chowns the volume
#     roots, then drops to the aidc user via runuser (AIDC_APPLE_DROP_USER=0
#     keeps everything root as an escape hatch).
#
# Bash-3.2-safe; never sourced directly (see bin/aidc-apple).

# ─── engine gate ────────────────────────────────────────────────────────────
# No fallback, no alternatives: die loudly when the native engine isn't there.
aidc_apple::require_engine() {
  if ! command -v container >/dev/null 2>&1; then
    aidc::die "aidc-apple drives Apple's native 'container' CLI, which was not found — install github.com/apple/container (macOS 26 + Apple Silicon); there is no fallback engine"
  fi
  if ! container system status >/dev/null 2>&1; then
    aidc::die "Apple container services are not running — start them with: container system start"
  fi
  if [[ "${AIDC_ISOLATE_VM:-0}" == "1" && -z "${AIDC_APPLE_VM_WARNED:-}" ]]; then
    aidc::warn "AIDC_ISOLATE_VM ignored: Apple container already isolates each container in its own VM"
    export AIDC_APPLE_VM_WARNED=1
  fi
}

# Socktainer-coexistence warning — deliberately NOT in require_engine (that
# runs on every exec and would spam; this only matters when (re)creating
# containers). Both stacks share ONE apple/container engine; a running
# socktainer reconfigures init/DNS (its DNS server listens on :2054), and
# native runs can panic with "DNS_UPSTREAM env var must be set" (seen on
# hardware).
aidc_apple::warn_socktainer() {
  [[ -z "${AIDC_APPLE_SOCKTAINER_WARNED:-}" ]] || return 0
  local s
  for s in /opt/homebrew/var/run/socktainer/.socktainer/container.sock \
           "$HOME/.socktainer/container.sock"; do
    if [[ -S "$s" ]]; then
      aidc::warn "socktainer's socket exists ($s) — both stacks share the container engine; if native runs panic with 'DNS_UPSTREAM', stop the socktainer service (brew services stop socktainer)"
      export AIDC_APPLE_SOCKTAINER_WARNED=1
      return 0
    fi
  done
}

# ─── naming (mirrors compose's, so status/destroy semantics stay familiar) ──
aidc_apple::cname() { printf '%s-workspace' "$COMPOSE_PROJECT_NAME"; }
aidc_apple::vol()   { printf '%s_%s' "$COMPOSE_PROJECT_NAME" "$1"; }
aidc_apple::thin_image() { printf '%s-workspace:latest' "$COMPOSE_PROJECT_NAME"; }
# Records which base the thin image was built on (compose uses an image label
# for this; a state file avoids JSON parsing on the host).
aidc_apple::base_state_file() { printf '%s/.ai-container/apple-image-base' "$AIDC_WORKSPACE"; }

# ─── resource defaults (conservative; VM-per-container has no "unlimited") ──
# Apple maps an unset memory to ~1 GiB, which would OOM aidc builds — so the
# native runtime always applies an explicit size. AIDC_MEM_LIMIT/AIDC_CPU_LIMIT
# (the stock aidc knobs) win when set; AIDC_APPLE_* tune the native defaults.
aidc_apple::memory() {
  local m="${AIDC_MEM_LIMIT:-0}"
  [[ -z "$m" || "$m" == "0" ]] && m="${AIDC_APPLE_MEMORY:-4G}"
  # Apple documents K/M/G/T/P suffixes; normalize case so docker-style `8g`
  # cannot depend on undocumented lowercase acceptance (tr, not ${var^^} —
  # bash 3.2 has no case-modifier expansion).
  printf '%s' "$m" | tr 'kmgtp' 'KMGTP'
}
aidc_apple::cpus() {
  local c="${AIDC_CPU_LIMIT:-0}"
  [[ -z "$c" || "$c" == "0" ]] && c="${AIDC_APPLE_CPUS:-4}"
  # Apple allocates whole vCPUs and floors fractional values — truncate, don't
  # round, so 1.5 means 1 vCPU both here and in the runtime — and never below
  # 1 (0.5 must not degenerate into a zero-vCPU allocation).
  c="${c%%.*}"
  c="${c:-1}"
  [[ "$c" == "0" ]] && c=1
  printf '%s' "$c"
}

# ─── volumes ────────────────────────────────────────────────────────────────
# The nine state volumes from compose.yaml.tmpl (project-scoped names) plus
# the shared read-only toolchain store. ext4 with ordered journaling: agent
# state (sessions, auth dbs) survives host crashes without full-journal write
# amplification.
aidc_apple::state_volumes() {
  cat <<'EOF'
command_history:/commandhistory
claude_home:/home/aidc/.claude
codex_home:/home/aidc/.codex
opencode_home:/home/aidc/.config/opencode
opencode_data_home:/home/aidc/.local/share/opencode
cursor_agent_home:/home/aidc/.cursor
grok_home:/home/aidc/.grok
omp_home:/home/aidc/.omp
rtk_data:/home/aidc/.local/share/rtk
EOF
}

aidc_apple::ensure_volumes() {
  local name
  while IFS=: read -r name _target; do
    [[ -z "$name" ]] && continue
    if ! container volume inspect "$(aidc_apple::vol "$name")" >/dev/null 2>&1; then
      container volume create --opt "journal=${AIDC_APPLE_JOURNAL:-ordered}" \
        "$(aidc_apple::vol "$name")" >/dev/null 2>&1 \
        || container volume create "$(aidc_apple::vol "$name")" >/dev/null \
        || aidc::die "failed to create volume $(aidc_apple::vol "$name")"
    fi
  done < <(aidc_apple::state_volumes)
  # Shared toolchain store (external in compose terms): must exist before run.
  if ! container volume inspect "$AIDC_TOOLCHAIN_VOLUME" >/dev/null 2>&1; then
    container volume create "$AIDC_TOOLCHAIN_VOLUME" >/dev/null 2>&1 \
      || aidc::die "failed to create $AIDC_TOOLCHAIN_VOLUME"
  fi
}

# ─── the 16 KiB Dockerfile cap (apple/container#735) ────────────────────────
# Apple's builder sends the Dockerfile in a gRPC header capped at 16 KiB, so
# `container build` rejects larger files outright (fix still open upstream).
# aidc's base Dockerfile is ~29 KiB with comments — minified it fits. The
# minifier is heredoc-aware: bodies pass through EXCEPT whole-line shell/py/zsh
# comments (shebangs kept — they are load-bearing); outside heredocs, comment
# lines, blanks, and indentation go. This template's heredocs carry scripts
# and rc files only — no config formats where '#'-lines are data.
aidc_apple::minify_dockerfile() { # <src> <dst>
  local src="$1" dst="$2"
  awk '
    {
      if (inheredoc) {
        if ($0 == delim) { inheredoc = 0; print; next }
        if ($0 ~ /^[ \t]*#/ && $0 !~ /^#!/) next
        print; next
      }
      line = $0
      if (match(line, /<<-?['\''"]?[A-Za-z_][A-Za-z0-9_]*['\''"]?/)) {
        tok = substr(line, RSTART, RLENGTH)
        sub(/^<<-?['\''"]/, "", tok)
        sub(/['\''"]$/, "", tok)
        delim = tok
        sub(/^[ \t]+/, "", line)
        print line
        inheredoc = 1
        next
      }
      sub(/^[ \t]+/, "", line)
      sub(/[ \t]+$/, "", line)
      if (line == "") next
      if (line ~ /^#/) next
      print line
    }
  ' "$src" >"$dst"
}

# Pick the Dockerfile to hand `container build`: the original when it already
# fits the cap, a minified sibling (<name>.apple-min) when it does not. Dies
# with the upstream reference when even the minified form exceeds the cap.
aidc_apple::prepare_dockerfile() { # <src>  → prints the path to build from
  local src="$1"
  local max="${AIDC_APPLE_DOCKERFILE_MAX:-16384}"
  local size
  size="$(wc -c <"$src" 2>/dev/null | tr -d ' ')"
  [[ -n "$size" && "$size" -lt "$max" ]] && { printf '%s' "$src"; return 0; }
  local min="${src}.apple-min"
  aidc_apple::minify_dockerfile "$src" "$min" \
    || aidc::die "failed to minify $src for the native builder"
  local msize
  msize="$(wc -c <"$min" | tr -d ' ')"
  if [[ -z "$msize" || "$msize" -ge "$max" ]]; then
    aidc::die "even minified, $min is ${msize:-?} bytes — over the native builder's ${max}-byte Dockerfile cap (apple/container#735; trim the template or wait for the upstream fix)"
  fi
  # The CLI's check compares RAW bytes, but the Dockerfile travels base64-
  # encoded in a gRPC header, so files well under the raw cap can still die
  # with "Stream unexpectedly closed" (same #735). Warn near the empirical
  # danger zone; scripts/probe-apple-builder.sh measures the real ceiling.
  if [[ "$msize" -gt "${AIDC_APPLE_DOCKERFILE_WARN:-12000}" ]]; then
    aidc::warn "minified Dockerfile is ${msize} bytes — within the raw ${max}-byte check but possibly over the base64/gRPC header budget (build may fail with 'Stream unexpectedly closed'); run scripts/probe-apple-builder.sh to find the real ceiling"
  fi
  printf '%s' "$min"
}

# The builder-shim tag bug (confirmed on hardware 2026-10-23): `container
# build -t X` exits 0 but lands the image UNTAGGED (listed as
# untagged@sha256:…; `container image tag <full-ref> <tag>` works). Snapshot
# the untagged digests before a build; afterwards, tag the single fresh
# digest. Serial builds only (aidc builds are serial); multiple new digests
# are refused rather than guessed.
aidc_apple::untagged_snapshot() {
  # `|| true`: with no untagged images grep exits 1 and the pipeline's
  # failure would abort the caller's assignment under set -e -o pipefail.
  container image list --quiet 2>/dev/null | grep '^untagged@' | sort || true
}

aidc_apple::tag_fresh_image() { # tag_fresh_image <pre-build-snapshot> <tag>
  local before="$1" tag="$2"
  if aidc_apple::image_present "$tag"; then
    return 0   # the build DID tag properly (newer shim?) — nothing to do
  fi
  local after new
  after="$(aidc_apple::untagged_snapshot)"
  new="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep -v '^$' || true)"
  if [[ "$(printf '%s\n' "$new" | grep -c .)" == "0" ]]; then
    aidc::die "build of $tag finished but no new image appeared in the store (builder shim bug? see 'container image list')"
  fi
  if [[ "$(printf '%s\n' "$new" | grep -c .)" != "1" ]]; then
    aidc::die "build of $tag produced multiple new untagged images — cannot tell which to tag; tag manually with 'container image tag untagged@sha256:… $tag'"
  fi
  container image tag "$new" "$tag" >/dev/null 2>&1 \
    || aidc::die "failed to tag $new as $tag (the builder left the image untagged; tag manually)"
  aidc::warn "builder left the image untagged (shim bug) — tagged $new as $tag"
  aidc_apple::image_present "$tag"
}

# ─── chunked builds: FROM-local works, the header budget is ~13.5K ──────────
# Measured on hardware (2026-10-23, container 1.6.0): FROM <local tag> IS
# resolvable by the native builder, and the practical Dockerfile ceiling is
# between 13,976 (ok) and 15,956 (fails) raw bytes — below the CLI's own
# 16,384 check. So an oversized (even minified) Dockerfile is split at SAFE
# instruction boundaries into ≤-budget chunks, each built and tagged, the
# next chunk rebased on the previous chunk's tag (`FROM <tag> [AS stage]`).
#
# Safety rules baked into boundary selection:
#   - never inside a RUN continuation (line ending in `\`)
#   - never inside a heredoc body
#   - never before the last `COPY --from=<stage>` consumer (the referenced
#     stage must stay in the same file as its consumer)
#   - ARGs declared earlier but used later are re-declared (with defaults)
#     at each continuation chunk's top — an undeclared build-arg silently
#     expands EMPTY in RUN, which would corrupt pin checks.
aidc_apple::chunk_budget() { printf '%s' "${AIDC_APPLE_DOCKERFILE_BUDGET:-13500}"; }

# Pick the split line for <file> at ≤ <budget> bytes: the largest safe
# instruction boundary strictly before EOF; 0 = no split needed/possible.
# Safety: a boundary is UNSAFE only when it separates a stage definition
# (`FROM … AS name`) from a later `COPY --from=name` consumer — those must
# stay in the same chunk. Splits between unrelated stages are fine (this is
# what makes the real template splittable: its late final-stage COPYs pin
# only their own sel-* stages, not the whole tail). Never split inside a
# RUN continuation or heredoc body.
aidc_apple::pick_split() { # pick_split <file> <budget>
  awk -v budget="$2" '
    { lines[NR] = $0 }
    END {
      # pass A: classify instruction starts; collect stage defs and
      # COPY --from consumers.
      inh = 0; delim = ""; cont = 0
      for (i = 1; i <= NR; i++) {
        l = lines[i]
        if (inh) { if (l == delim) inh = 0; continue }
        if (cont) { cont = (l ~ /\\$/); continue }
        isinstr[i] = 1
        if (match(l, /^FROM[ \t]+[^ \t]+[ \t]+AS[ \t]+[A-Za-z_][A-Za-z0-9_-]*/)) {
          rest = substr(l, RSTART + 5)
          sub(/^[ \t]+/, "", rest)
          split(rest, w, /[ \t]+/)
          defs[w[3]] = i
        }
        if (match(l, /^COPY[ \t]+--from=[^ \t]+/)) {
          ref = substr(l, RSTART, RLENGTH)
          sub(/^COPY[ \t]+--from=/, "", ref)
          nu++; uline[nu] = i; uname[nu] = ref
        }
        if (match(l, /<<-?['\''"]?[A-Za-z_][A-Za-z0-9_]*['\''"]?/)) {
          tok = substr(l, RSTART, RLENGTH)
          sub(/^<<-?['\''"]/, "", tok); sub(/['\''"]$/, "", tok)
          delim = tok; inh = 1
        }
        cont = (l ~ /\\$/)
      }
      # Mark blocked boundaries: any i with def(S) < i <= use(S).
      for (u = 1; u <= nu; u++) {
        d = defs[uname[u]]
        if (d != "" && d < uline[u])
          for (i = d + 1; i <= uline[u]; i++) blocked[i] = 1
      }
      # pass B: largest fitting unblocked instruction boundary.
      bytes = 0; best = 0
      inh = 0; delim = ""; cont = 0
      for (i = 1; i <= NR; i++) {
        l = lines[i]
        if (inh) { if (l == delim) inh = 0; bytes += length(l) + 1; continue }
        if (cont) { cont = (l ~ /\\$/); bytes += length(l) + 1; continue }
        if (i > 1 && i < NR && isinstr[i] && !blocked[i] && bytes > 0 && bytes <= budget)
          best = i
        if (match(l, /<<-?['\''"]?[A-Za-z_][A-Za-z0-9_]*['\''"]?/)) {
          tok = substr(l, RSTART, RLENGTH)
          sub(/^<<-?['\''"]/, "", tok); sub(/['\''"]$/, "", tok)
          delim = tok; inh = 1
        }
        cont = (l ~ /\\$/)
        bytes += length(l) + 1
      }
      print best
    }
  ' "$1"
}

# Continuation-chunk generator: `FROM <prev-tag>` header when the chunk
# starts mid-stage (the stage continues under its own name) — and, for EVERY
# FROM in the continuation, the reference is rewritten to <prev-tag> when it
# names a stage defined in the EARLIER portion (`FROM base AS agent-x` deep
# in the file would otherwise resolve as docker.io/library/base:latest — the
# exact 401 seen on hardware). Stage names defined INSIDE the continuation
# are left untouched, and selector forms (`FROM agent-x-${WITH_X} AS sel-x`)
# referencing earlier stems are rewritten too. ARGs from earlier lines are
# re-declared after the header (undeclared build-args silently expand empty).
aidc_apple::emit_chunk_header() { # emit_chunk_header <minified> <first-line-no> <prev-tag> > <out>
  awk -v start="$2" -v prev="$3" '
    function reset_stem(name) {                   # "agent-x-0" → "agent-x"
      sub(/-[01]$/, "", name)
      return name
    }
    # Collect earlier stage names + stems (lines before start).
    NR < start {
      if ($0 ~ /^ARG[ \t]/) args[++nargs] = $0
      if (match($0, /^FROM[ \t]+[^ \t]+[ \t]+AS[ \t]+[A-Za-z_][A-Za-z0-9_-]*/)) {
        rest = substr($0, RSTART + 5)
        sub(/^[ \t]+/, "", rest)
        split(rest, w, /[ \t]+/)
        earlier[w[3]] = 1
        stems[reset_stem(w[3])] = 1
      }
      next
    }
    {
      line = $0
      if (match(line, /^FROM[ \t]+[^ \t]+([ \t]+AS[ \t]+[A-Za-z_][A-Za-z0-9_-]*)?/)) {
        ref = substr(line, RSTART + 5)
        sub(/^[ \t]+/, "", ref)
        split(ref, rw, /[ \t]+/)
        base_ref = rw[1]
        rewrite = 0
        if (base_ref in earlier) rewrite = 1
        # Selector form: FROM agent-x-${WITH_X} — the stem was split earlier.
        if (!rewrite) {
          sel = base_ref
          sub(/-\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$/, "", sel)
          if (sel != base_ref && sel in stems) rewrite = 1
        }
        if (rewrite) {
          sub(/^FROM[ \t]+[^ \t]+/, "FROM " prev, line)
        }
      }
      if (NR == start && line !~ /^FROM[ \t]/) {
        print "FROM " prev
        for (a = 1; a <= nargs; a++) print args[a]
      } else if (NR == start) {
        for (a = 1; a <= nargs; a++) print args[a]
      }
      print line
      next
    }
  ' "$1"
}

# Build runner with lag-retry: streams output (tee) and retries ONCE when the
# failure is the confirmed transient — a just-tagged LOCAL image momentarily
# unresolvable by the builder (the resolver index lags the store; seen on
# hardware as our own tag → docker.io 401 seconds after the tag landed).
# Anything else fails through untouched.
aidc_apple::build_with_retry() { # build_with_retry <expected-local-tag> <log> <cmd...>
  local want="$1" log="$2"; shift 2
  local want_name="${want%%:*}" rc=0
  if "$@" 2>&1 | tee "$log"; then
    return "${PIPESTATUS[0]}"
  fi
  rc="${PIPESTATUS[0]}"
  if [[ "$rc" != "0" ]] \
     && grep -q "registry-1.docker.io/v2/library/${want_name}" "$log" 2>/dev/null \
     && grep -q "401" "$log" 2>/dev/null; then
    aidc::warn "local tag ${want} not resolvable by the builder yet (store-index lag) — retrying in 3s"
    sleep 3
    "$@" 2>&1 | tee -a "$log"
    return "${PIPESTATUS[0]}"
  fi
  return "$rc"
}

# The chunked build driver. AIDC_APPLE_BUILD_ARGS carries the caller's
# --build-arg flags (they must apply to EVERY chunk). Every chunk build goes
# through tag_fresh_image (the shim's untagged-landing bug applies per chunk).
# Returns 0 with <final-tag> present in the store.
aidc_apple::native_build() { # native_build <dockerfile> <ctx-dir> <final-tag>
  local df="$1" ctx="$2" final="$3"
  local min
  min="$(aidc_apple::prepare_dockerfile "$df")"
  # Stale chunk artifacts from an earlier (failed) run would confuse the
  # builder and litter the tree; start clean.
  rm -f "$min".c[0-9]* "$min".r[0-9]* "$min".blog 2>/dev/null || true
  local budget; budget="$(aidc_apple::chunk_budget)"
  local size; size="$(wc -c <"$min" | tr -d ' ')"
  local n=0 chunk pre prev_tag rest blog
  local cur="$min"
  while [[ "$size" -gt "$budget" ]]; do
    n=$((n + 1))
    local split
    split="$(aidc_apple::pick_split "$cur" "$budget")"
    if [[ -z "$split" || "$split" == "0" ]]; then
      aidc::die "cannot split $(basename "$min") below ${budget} bytes (no safe boundary — a single RUN/heredoc block or a late COPY --from exceeds the budget; raise AIDC_APPLE_DOCKERFILE_BUDGET or trim the template)"
    fi
    chunk="${min}.c${n}"
    rest="${min}.r${n}"
    blog="${min}.b${n}.log"
    head -n $((split - 1)) "$cur" >"$chunk"
    prev_tag="${final}-c${n}"
    aidc::log "chunk ${n}: lines 1..$((split-1)) of $(basename "$min") as ${prev_tag} (file exceeds the ~${budget}-byte header budget; FROM-local chaining)"
    pre="$(aidc_apple::untagged_snapshot)"
    ( cd "$ctx" && aidc_apple::build_with_retry "$prev_tag" "$blog" \
        container build -f "$chunk" \
        ${AIDC_APPLE_BUILD_ARGS[@]+"${AIDC_APPLE_BUILD_ARGS[@]}"} -t "$prev_tag" "$ctx" ) \
      || aidc::die "chunk ${n} build failed ($chunk)"
    aidc_apple::tag_fresh_image "$pre" "$prev_tag" \
      || aidc::die "chunk ${n} image ${prev_tag} could not be tagged (untagged-landing bug)"
    aidc_apple::emit_chunk_header "$cur" "$split" "$prev_tag" >"$rest"
    cur="$rest"
    size="$(wc -c <"$cur" | tr -d ' ')"
  done
  pre="$(aidc_apple::untagged_snapshot)"
  ( cd "$ctx" && aidc_apple::build_with_retry "$final" "${min}.bf.log" \
      container build -f "$cur" \
      ${AIDC_APPLE_BUILD_ARGS[@]+"${AIDC_APPLE_BUILD_ARGS[@]}"} -t "$final" "$ctx" ) \
    || aidc::die "final build failed ($cur)"
  aidc_apple::tag_fresh_image "$pre" "$final"
}

# ─── builds ─────────────────────────────────────────────────────────────────
# Size the BuildKit builder before the first build (its default 2 CPU/2GB is
# too small for aidc's base image). Idempotent: builder start on a running
# builder is a cheap status call.
aidc_apple::ensure_builder() {
  container builder start \
    --cpus "${AIDC_APPLE_BUILDER_CPUS:-4}" \
    --memory "${AIDC_APPLE_BUILDER_MEMORY:-4G}" >/dev/null 2>&1 \
    || aidc::warn "could not size the BuildKit builder (using its defaults) — builds may be slow or OOM; see 'container builder start --help'"
}

# True when the image is in Apple's local store. The listing format for
# locally built images has NOT been confirmed on hardware (name vs name:tag
# vs name:latest) — normalize a trailing :latest on BOTH sides so a format
# difference can't false-negative (which would rebuild on every command).
aidc_apple::image_present() {
  local want="$1"
  want="${want%:latest}"
  local listed
  while IFS= read -r listed; do
    [[ "${listed%:latest}" == "$want" ]] && return 0
  done < <(container image list --quiet 2>/dev/null)
  return 1
}

# Overrides aidc::ensure_base_image: same tag/content-hash scheme, native build.
aidc::ensure_base_image() {
  local workspace="$1"
  aidc::export_compose_env "$workspace"
  local tag
  if [[ -n "${AIDC_BASE_IMAGE:-}" ]]; then
    tag="$AIDC_BASE_IMAGE"
  else
    tag="$(aidc::base_image_tag "$workspace")"
    export AIDC_BASE_IMAGE="$tag"
  fi
  if ! aidc_apple::image_present "$tag"; then
    aidc_apple::require_engine
    aidc_apple::ensure_builder
    aidc::log "building shared base image $tag (one-time; shared across projects, native BuildKit)"
    # WITH_* per-agent flags (aidc::agents_build_flags) drive the conditional
    # agent stages — word-split into the build args (mapfile is bash-4+).
    # shellcheck disable=SC2207,SC2206,SC2046
    AIDC_APPLE_BUILD_ARGS=(
      --build-arg "AIDC_AGENTS=${AIDC_AGENTS:-opencode}"
      $(aidc::agents_build_flags "${AIDC_AGENTS:-opencode}")
    )
    aidc_apple::native_build "$workspace/.devcontainer/Dockerfile.base" \
      "$workspace/.devcontainer" "$tag" \
      || aidc::die "failed to build base image $tag (native BuildKit; check 'container builder status')"
    aidc::log "base image $tag ready"
  fi
}

# Thin (per-project) image: compose builds it from Dockerfile with the
# AIDC_* build args; native does the same and records the base it was built
# on (compose uses an image label; we use a state file — see base_state_file).
# Every successful thin build bumps a generation counter: `up` compares it so
# a rebuilt image (via --build or a base change) always recreates a running
# container instead of no-op'ing on the unchanged :latest tag.
aidc_apple::gen_state_file() { printf '%s/.ai-container/apple-image-gen' "$AIDC_WORKSPACE"; }
aidc_apple::ensure_thin_image() {
  local workspace="$1" force="${2:-0}"
  local tag; tag="$(aidc_apple::thin_image)"
  local state_file; state_file="$(aidc_apple::base_state_file)"
  local gen_file; gen_file="$(aidc_apple::gen_state_file)"
  local gen; gen="$(cat "$gen_file" 2>/dev/null || printf '0')"
  if [[ "$force" == "1" ]] || ! aidc_apple::image_present "$tag" \
     || [[ "$(cat "$state_file" 2>/dev/null || true)" != "$AIDC_BASE_IMAGE" ]]; then
    aidc_apple::require_engine
    aidc_apple::ensure_builder
    aidc::log "building project image $tag (native BuildKit)"
    AIDC_APPLE_BUILD_ARGS=(
      --build-arg AIDC_BASE_IMAGE="$AIDC_BASE_IMAGE"
      --build-arg AIDC_TOOLCHAINS="${AIDC_TOOLCHAINS:-}"
      --build-arg AIDC_SECURITY_TOOLS="${AIDC_SECURITY_TOOLS:-}"
      --build-arg AIDC_AGENTS="${AIDC_AGENTS:-opencode}"
    )
    aidc_apple::native_build "$workspace/.devcontainer/Dockerfile" \
      "$workspace/.devcontainer" "$tag" \
      || aidc::die "failed to build project image $tag (if the failure is 'FROM $AIDC_BASE_IMAGE' not resolvable, the builder cannot see local images — see the known-gaps section of docs/aidc-apple.md)"
    printf '%s\n' "$AIDC_BASE_IMAGE" >"$state_file" 2>/dev/null \
      || aidc::warn "cannot write $state_file — base-change detection may rebuild unnecessarily"
    printf '%s\n' "$((gen + 1))" >"$gen_file" 2>/dev/null \
      || aidc::warn "cannot write $gen_file — 'up' may not deploy rebuilt images (recreates instead)"
  fi
}

# Overrides aidc::image_exists.
aidc::image_exists() {
  [[ -n "${COMPOSE_PROJECT_NAME:-}" ]] || return 1
  aidc_apple::image_present "$(aidc_apple::thin_image)"
}

# Overrides aidc::image_base_is_current (recorded-tag fast path).
aidc::image_base_is_current() {
  [[ -n "${AIDC_BASE_IMAGE:-}" ]] || return 1
  [[ "$(cat "$(aidc_apple::base_state_file)" 2>/dev/null || true)" == "$AIDC_BASE_IMAGE" ]]
}

# ─── the run flag set (mirrors templates/devcontainer/compose.yaml.tmpl) ────
aidc_apple::run_flags() {
  local -a flags=(
    --name "$(aidc_apple::cname)"
    -d
    --init
    # Pin the init process to root EXPLICITLY: the base image ends with
    # `USER aidc`, and the entrypoint must run as root to chown the (fresh,
    # root-owned) volume roots before dropping to uid 1000. Without this the
    # runtime would honor the image USER and the drop would fail.
    --user 0:0
    -w /workspace
    --shm-size "${AIDC_APPLE_SHM:-1G}"
    -m "$(aidc_apple::memory)"
    -c "$(aidc_apple::cpus)"
    -l "aidc.project=${AIDC_REPO_SLUG}"
  )
  # Egress firewall needs NET_ADMIN/NET_RAW at runtime (compose.firewall.yaml).
  if [[ "${AIDC_ENABLE_EGRESS_FIREWALL:-0}" == "1" ]]; then
    flags+=(--cap-add NET_ADMIN --cap-add NET_RAW)
  fi
  # no-new-privileges has no Apple equivalent — warn once, never silent.
  if [[ "${AIDC_NO_NEW_PRIVILEGES:-0}" == "1" && -z "${AIDC_APPLE_NNP_WARNED:-}" ]]; then
    aidc::warn "AIDC_NO_NEW_PRIVILEGES=1 has no Apple container equivalent — ignored (per-container VM isolation applies)"
    export AIDC_APPLE_NNP_WARNED=1
  fi
  # opencode-web: loopback-only publish (compose.opencode-web.yaml).
  if [[ "${AIDC_OPENCODE_WEB:-0}" == "1" ]]; then
    flags+=(-p "127.0.0.1:${AIDC_OPENCODE_WEB_PORT:-4096}:${AIDC_OPENCODE_WEB_PORT:-4096}")
  fi
  # Single-file binds are NOT supported by Apple's runtime ("path ... is not
  # a directory" — confirmed on hardware 2026-10-23). The gitconfig seed is
  # the only file bind; stage it into a per-project directory and bind THAT,
  # pointing GIT_CONFIG_GLOBAL inside it. Snapshotted at up-time (the docker
  # path binds the live file) — a gitconfig edit needs a re-up; documented.
  local gc_stage="${AIDC_HOST_CONFIG_ROOT:-$HOME/.config/aidc}/seeds/${AIDC_REPO_SLUG}/gitconfig.d"
  mkdir -p "$gc_stage" 2>/dev/null || true
  if [[ -f "$AIDC_GITCONFIG_SOURCE" ]]; then
    cat "$AIDC_GITCONFIG_SOURCE" >"$gc_stage/gitconfig" 2>/dev/null || : >"$gc_stage/gitconfig"
  else
    : >"$gc_stage/gitconfig"
  fi
  flags+=(--mount "type=bind,source=${gc_stage},target=/host-seed/gitconfig.d,readonly")
  # Bind mounts: workspace rw, the rest read-only seeds/overlays.
  flags+=(
    --mount "type=bind,source=${AIDC_WORKSPACE},target=/workspace"
    --mount "type=bind,source=${AIDC_DEVCONTAINER_DIR},target=/workspace/.devcontainer,readonly"
    --mount "type=bind,source=${AIDC_CORE_LOGICS_WORKTREE},target=/opt/CORE_LOGICS"
    --mount "type=bind,source=${AIDC_HOST_SEED_CLAUDE},target=/host-seed/claude,readonly"
    --mount "type=bind,source=${AIDC_HOST_SEED_CODEX},target=/host-seed/codex,readonly"
    --mount "type=bind,source=${AIDC_HOST_SEED_OPENCODE},target=/host-seed/opencode,readonly"
    --mount "type=bind,source=${AIDC_HOST_SEED_OPENCODE_DATA},target=/host-seed/opencode-data,readonly"
    --mount "type=bind,source=${AIDC_HOST_SEED_GROK},target=/host-seed/grok,readonly"
    --mount "type=bind,source=${AIDC_HOST_SEED_OMP},target=/host-seed/omp,readonly"
    --mount "type=bind,source=${AIDC_HOST_SEED_CURSOR},target=/host-seed/cursor,readonly"
    --mount "type=bind,source=${AIDC_CLIPBOARD_DIR_SOURCE},target=/host-clipboard,readonly"
  )
  # State volumes + the shared read-only toolchain store.
  local name target
  while IFS=: read -r name target; do
    [[ -z "$name" ]] && continue
    flags+=(-v "$(aidc_apple::vol "$name"):${target}")
  done < <(aidc_apple::state_volumes)
  flags+=(--mount "type=volume,source=${AIDC_TOOLCHAIN_VOLUME},target=/opt/toolchains,readonly")
  # Environment (compose environment: block, verbatim).
  flags+=(
    -e HOME=/home/aidc
    -e HISTFILE=/commandhistory/.zsh_history
    -e GIT_CONFIG_GLOBAL=/home/aidc/.gitconfig.local
    -e AIDC_CONTAINER_HOME=/home/aidc
    -e AIDC_CORE_LOGICS_DIR=/opt/CORE_LOGICS
    -e AIDC_WORKSPACE_DIR=/workspace
    -e CLAUDE_CONFIG_DIR=/home/aidc/.claude
    -e "AIDC_OPENCODE_SYNC_AUTH=${AIDC_OPENCODE_SYNC_AUTH:-1}"
  )
  AIDC_APPLE_RUN_FLAGS=("${flags[@]}")
}

# Container init: fresh ext4 volumes are root-owned (the image's uid-1000
# pre-created dirs do NOT seed them, unlike Docker), so init runs as root,
# chowns the state volume roots, then drops to the aidc user — after which
# everything matches the docker path (bootstrap init && sleep infinity).
# Sets AIDC_APPLE_ENTRY as an argv array: the bootstrap command must survive
# as ONE argument, so callers expand the array — never word-split a string.
#
# Robustness (each born from a hardware 127-crash): the uid drop uses sudo —
# the ONE privilege-drop binary guaranteed by the image (explicitly in the
# apt install list; runuser is util-linux and NOT guaranteed in slimmed
# images) — and the bootstrap path is existence-checked with a diagnostic
# dump (a failed .devcontainer overlay bind makes the path vanish → bare 127
# otherwise). Failures exit 126 with a named reason, not a mystery code.
aidc_apple::entrypoint_args() {
  if [[ "${AIDC_APPLE_DROP_USER:-1}" == "0" ]]; then
    AIDC_APPLE_ENTRY=(/bin/bash -lc '/workspace/.devcontainer/scripts/bootstrap-state.sh init && exec sleep infinity')
  else
    AIDC_APPLE_ENTRY=(/bin/bash -lc 'mkdir -p /host-seed && ln -sfn /host-seed/gitconfig.d/gitconfig /host-seed/gitconfig; chown 1000:1000 /commandhistory /home/aidc/.claude /home/aidc/.codex /home/aidc/.config/opencode /home/aidc/.local/share/opencode /home/aidc/.cursor /home/aidc/.grok /home/aidc/.omp /home/aidc/.local/share/rtk 2>/dev/null || true; command -v sudo >/dev/null 2>&1 || { echo "aidc: sudo not found in image — cannot drop to uid 1000 (AIDC_APPLE_DROP_USER=0 to run as root)" >&2; exit 126; }; if [[ ! -f /workspace/.devcontainer/scripts/bootstrap-state.sh ]]; then echo "aidc: bootstrap script missing — the /workspace/.devcontainer overlay bind may be broken" >&2; ls -la /workspace/ >&2; ls -la /workspace/.devcontainer 2>&1 | head -20 >&2; exit 126; fi; exec sudo -u aidc -E /bin/bash -lc "/workspace/.devcontainer/scripts/bootstrap-state.sh init && exec sleep infinity"')
  fi
}

# ─── lifecycle ──────────────────────────────────────────────────────────────
aidc_apple::exists() {
  container list --all --quiet 2>/dev/null | grep -qx "$(aidc_apple::cname)"
}
aidc_apple::running() {
  aidc_apple::exists || return 1
  container exec "$(aidc_apple::cname)" true >/dev/null 2>&1
}

aidc_apple::up() {
  local workspace="$1" force_build="${2:-0}"
  aidc_apple::require_engine
  aidc_apple::ensure_volumes
  aidc::ensure_base_image "$workspace"
  aidc_apple::ensure_thin_image "$workspace" "$force_build"
  aidc_apple::run_flags
  # Config identity of the running container: image generation + the knobs
  # `container run` cannot change in place (memory/cpus are VM-allocated at
  # creation; caps and the port layout are create-time flags). A mismatch
  # recreates — approximating compose's recreate-on-config-diff for the
  # settings that matter here.
  local gen; gen="$(cat "$(aidc_apple::gen_state_file)" 2>/dev/null || printf '0')"
  # Config identity of the running container: image generation + the knobs
  # `container run` cannot change in place — VM resources are allocated at
  # creation, and the bind layout (clipboard) / user-drop are create-time
  # flags, matching compose's recreate-on-config-diff for everything that
  # cannot be edited live.
  local want_state
  want_state="${gen}|${AIDC_APPLE_SHM:-1G}|$(aidc_apple::memory)|$(aidc_apple::cpus)|${AIDC_ENABLE_EGRESS_FIREWALL:-0}|${AIDC_OPENCODE_WEB:-0}|${AIDC_OPENCODE_WEB_PORT:-}|clip=${AIDC_ENABLE_CLIPBOARD:-0}|drop=${AIDC_APPLE_DROP_USER:-1}"
  local state_file="$workspace/.ai-container/apple-run-state"
  if aidc_apple::running \
     && [[ "$(cat "$state_file" 2>/dev/null || true)" == "$want_state" ]]; then
    return 0  # same image generation + config already running
  fi
  if aidc_apple::exists; then
    container stop -t 10 "$(aidc_apple::cname)" >/dev/null 2>&1 || true
    container delete --force "$(aidc_apple::cname)" >/dev/null 2>&1 || true
  fi
  aidc_apple::entrypoint_args
  aidc_apple::warn_socktainer
  container run "${AIDC_APPLE_RUN_FLAGS[@]}" "$(aidc_apple::thin_image)" \
    ${AIDC_APPLE_ENTRY[@]+"${AIDC_APPLE_ENTRY[@]}"} \
    || aidc::die "failed to start the container (native run; see 'container list --all')"
  # `container run -d` returning 0 does NOT mean the container stays up: the
  # entrypoint or the VM init can die a beat later (seen on hardware — a
  # crash loop surfaced only minutes after "ready"). Verify liveness for a
  # short window; on death, surface both log streams so the cause is in the
  # user's face instead of a mystery.
  local waited=0
  while [[ "$waited" -lt "${AIDC_APPLE_LIVENESS_WAIT:-8}" ]]; do
    aidc_apple::running && break
    sleep 1
    waited=$((waited + 1))
  done
  if ! aidc_apple::running; then
    aidc::warn "container died within ${waited}s of starting — boot log tail:"
    container logs --boot "$(aidc_apple::cname)" 2>/dev/null | tail -15 | sed 's/^/        /' || true
    aidc::warn "entrypoint stdio tail:"
    container logs "$(aidc_apple::cname)" 2>/dev/null | tail -15 | sed 's/^/        /' || true
    aidc::die "container is not running (crashed at startup — see the logs above; 'container logs --boot $(aidc_apple::cname)' has the full boot log)"
  fi
  printf '%s\n' "$want_state" >"$state_file" 2>/dev/null \
    || aidc::warn "cannot write $state_file — 'up' may recreate the container unnecessarily"
  # compose up -d returns before bootstrap finishes; mirror that (agents sync
  # sessions on the down→up transition; links are ensured per-command).
}

aidc_apple::down() {
  local wipe_volumes="${1:-0}"
  if aidc_apple::exists; then
    container stop -t 10 "$(aidc_apple::cname)" >/dev/null 2>&1 || true
    container delete --force "$(aidc_apple::cname)" >/dev/null 2>&1 || true
  fi
  if [[ "$wipe_volumes" == "1" ]]; then
    # Project state volumes only — NEVER the shared aidc_toolchains store.
    local name
    while IFS=: read -r name _target; do
      [[ -z "$name" ]] && continue
      container volume delete "$(aidc_apple::vol "$name")" >/dev/null 2>&1 || true
    done < <(aidc_apple::state_volumes)
    container image delete "$(aidc_apple::thin_image)" >/dev/null 2>&1 || true
  fi
}

# ─── the compose gateway override ───────────────────────────────────────────
# aidc::compose <workspace> <verb...> — translate the exact verb set aidc
# issues (see callers in runtime.sh/sync.sh). Unknown verbs die loudly rather
# than half-work: this gateway is the contract.
aidc::compose() {
  local workspace="$1"; shift
  aidc::export_compose_env "$workspace"
  aidc_apple::require_engine
  local verb="$1"; shift
  case "$verb" in
    up)
      local force_build=0
      local a
      for a in "$@"; do
        [[ "$a" == "--build" ]] && force_build=1
      done
      aidc_apple::up "$workspace" "$force_build"
      ;;
    down)
      if [[ "$*" == *-v* ]]; then
        aidc_apple::down 1   # destroy: wipe project volumes + thin image
      else
        aidc_apple::down 0
      fi
      ;;
    exec)
      local -a xflags=()
      local tty_seen=0
      while [[ $# -gt 0 ]]; do
        case "$1" in
          -T) tty_seen=1; shift ;;               # no TTY: scripted execs
          -e)
            # aidc issues docker-style bare `-e KEY` (inherit from the
            # caller's env). Apple documents exec's -e as key=value only, so
            # expand bare keys HOST-SIDE; unset keys are omitted (docker
            # semantics), explicit KEY=VALUE passes through verbatim.
            [[ $# -ge 2 && -n "$2" ]] || aidc::die "aidc-apple: exec -e needs a non-empty value"
            if [[ "$2" == *=* ]]; then
              xflags+=(-e "$2")
            elif [[ -n "${!2:-}" ]]; then
              xflags+=(-e "$2=${!2}")
            fi
            shift 2
            ;;
          workspace) shift ;;                    # the compose service name
          *) break ;;
        esac
      done
      if [[ "$tty_seen" == "1" ]]; then
        # Scripted execs (token delivery, sync tars, tool links): no TTY,
        # stdin kept open, but STILL uid 1000 — a root `-T` exec would leave
        # root-owned files (e.g. the /dev/shm OAuth token at 0600) that the
        # aidc-user agent session then cannot read.
        container exec -i --user 1000:1000 -w /workspace \
          ${xflags[@]+"${xflags[@]}"} "$(aidc_apple::cname)" "$@"
      else
        # Interactive (agents, shell): TTY when our own stdin has one, so
        # piped-but-not--T callers still work.
        if [[ -t 0 ]]; then
          container exec -t -i --user 1000:1000 -w /workspace \
            ${xflags[@]+"${xflags[@]}"} "$(aidc_apple::cname)" "$@"
        else
          container exec -i --user 1000:1000 -w /workspace \
            ${xflags[@]+"${xflags[@]}"} "$(aidc_apple::cname)" "$@"
        fi
      fi
      ;;
    ps)
      # `ps -q workspace` = RUNNING-only in compose. Reporting a stopped
      # container here would defeat ensure_container_running's self-heal (it
      # would skip bring-up and every later exec would fail on a dead VM).
      aidc_apple::running && printf '%s\n' "$(aidc_apple::cname)"
      return 0
      ;;
    config)
      # `config --images`: the thin image reference.
      if [[ "$1" == "--images" ]]; then
        printf '%s\n' "$(aidc_apple::thin_image)"
      fi
      return 0
      ;;
    *)
      aidc::die "aidc-apple: compose verb '$verb' is not implemented natively — this is a bug (no fallback engine by design)"
      ;;
  esac
}

aidc::compose_capture() { aidc::compose "$@"; }

# ─── toolchains (docker run/volume → container run/volume) ──────────────────
aidc::ensure_toolchain_image() {
  local lang="$1"
  local tag; tag="$(aidc::toolchain_image_tag "$lang")"
  if ! aidc_apple::image_present "$tag"; then
    aidc_apple::require_engine
    aidc_apple::ensure_builder
    aidc::log "building toolchain store image $tag (one-time, native BuildKit)"
    # Build from a COPY of the template: chunk/minify artifacts must not land
    # inside the git-tracked templates/ tree (context stays $AIDC_ROOT).
    local tcdf
    tcdf="$(mktemp "${TMPDIR:-/tmp}/aidc-tcdf.XXXXXX")"
    cat "$AIDC_ROOT/templates/devcontainer/Dockerfile.toolchain.tmpl" >"$tcdf"
    AIDC_APPLE_BUILD_ARGS=(--build-arg AIDC_TOOLCHAIN="$lang")
    aidc_apple::native_build "$tcdf" "$AIDC_ROOT" "$tag" \
      || { rm -f "$tcdf"; aidc::die "failed to build toolchain store image for $lang"; }
    rm -f "$tcdf" "$tcdf.apple-min" "$tcdf.apple-min".[cr][0-9]* 2>/dev/null || true
    aidc::log "toolchain store image $tag ready"
  fi
}

aidc::ensure_toolchain_volume() {
  local lang="$1"
  local tag; tag="$(aidc::toolchain_image_tag "$lang")"
  container volume inspect "$AIDC_TOOLCHAIN_VOLUME" >/dev/null 2>&1 \
    || container volume create "$AIDC_TOOLCHAIN_VOLUME" >/dev/null
  aidc::ensure_toolchain_image "$lang"
  if ! container run --rm -v "$AIDC_TOOLCHAIN_VOLUME:/opt/toolchains" \
         --entrypoint test "$tag" -f "/opt/toolchains/$lang/.aidc-ready" >/dev/null 2>&1; then
    aidc::log "populating shared $lang toolchain in $AIDC_TOOLCHAIN_VOLUME (one-time)"
    container run --rm -v "$AIDC_TOOLCHAIN_VOLUME:/opt/toolchains" "$tag" \
      || aidc::die "failed to populate $lang toolchain volume"
    aidc::log "shared $lang toolchain ready"
  fi
}

aidc::tools_status() {
  printf 'shared toolchain volume: %s\n' "$AIDC_TOOLCHAIN_VOLUME"
  if ! container volume inspect "$AIDC_TOOLCHAIN_VOLUME" >/dev/null 2>&1; then
    # shellcheck disable=SC2016  # backticks are literal guidance, not a subshell
    printf '  (not created yet — run `aidc-apple tools install all`)\n'
    return 0
  fi
  local lang tag
  for lang in go rust java; do
    tag="$(aidc::toolchain_image_tag "$lang")"
    if aidc_apple::image_present "$tag" \
        && container run --rm -v "$AIDC_TOOLCHAIN_VOLUME:/opt/toolchains" \
             --entrypoint test "$tag" -f "/opt/toolchains/$lang/.aidc-ready" >/dev/null 2>&1; then
      printf '  %-5s installed\n' "$lang"
    else
      printf '  %-5s not installed\n' "$lang"
    fi
  done
}

# Ensure every volume-backed toolchain the workspace needs (go/rust/java) is
# present before the container starts (native mirror of the compose-path
# helper — the stock one shells out to docker and must never run here).
aidc::ensure_toolchain_volumes() {
  local workspace="$1"
  aidc::export_compose_env "$workspace"
  container volume inspect "$AIDC_TOOLCHAIN_VOLUME" >/dev/null 2>&1 \
    || container volume create "$AIDC_TOOLCHAIN_VOLUME" >/dev/null 2>&1 \
    || aidc::die "failed to create $AIDC_TOOLCHAIN_VOLUME"
  local tc
  IFS=',' read -ra _aidc_tcs <<<"${AIDC_TOOLCHAINS:-}"
  for tc in ${_aidc_tcs[@]+"${_aidc_tcs[@]}"}; do
    case "$tc" in
      go|rust|java) aidc::ensure_toolchain_volume "$tc" ;;
      *) : ;;
    esac
  done
}

# ─── engine-agnostic helpers whose stock versions assume docker ─────────────

# `aidc init` (and the auto-init path) requires `docker git` — wrong engine
# here. Re-require everything EXCEPT docker; the native engine gate (require_
# engine) owns that check with the right remedy.
aidc::need_cmd() {
  local cmd
  for cmd in "$@"; do
    [[ "$cmd" == "docker" ]] && continue
    command -v "$cmd" >/dev/null 2>&1 || aidc::die "required command not found: $cmd"
  done
}

# AIDC_ISOLATE_VM is redundant under Apple container (VM-per-container; the
# warning fires in require_engine). The stock vm_* helpers would build a
# Lima/Firecracker VM — and point DOCKER_HOST at it — so they are no-ops here.
aidc::vm_ensure()   { :; }
aidc::vm_stop()     { :; }
aidc::vm_destroy()  { :; }

# Native container-state rows for `aidc-apple doctor` (the stock check probes
# `docker info`; ours never touches a Docker API).
aidc::doctor_check_container() {
  local workspace="$1"
  aidc::export_compose_env "$workspace" >/dev/null 2>&1 || true
  if aidc_apple::running; then
    aidc::doctor_report ok container "running (native Apple container)"
  elif aidc_apple::exists; then
    aidc::doctor_report ok container "stopped — starts on the next aidc-apple command"
  else
    aidc::doctor_report ok container "not created yet — 'aidc-apple up' builds it"
  fi
}

# ─── status (native rows + the shared engine-agnostic config block) ─────────
aidc::cmd_status() {
  local global=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --global|-g) global=1 ;;
      *) aidc::die "unknown status flag: $1 (valid: --global)" ;;
    esac
    shift
  done
  if [[ "$global" == "1" ]]; then
    aidc_apple::require_engine
    printf 'aidc-apple containers (native Apple container runtime):\n'
    container list --all --quiet 2>/dev/null | grep '^aidc_' || printf '  (none)\n'
    return 0
  fi

  local workspace
  workspace="$(aidc::default_workspace)"
  if [[ ! -f "$workspace/.ai-container/project.env" ]]; then
    printf 'no aidc project in %s (run '\''aidc-apple init'\'' first)\n' "$workspace"
    return 0
  fi
  aidc::load_project_env "$workspace"
  aidc::export_compose_env "$workspace"
  aidc_apple::require_engine

  local C_LBL=$'\033[2m' C_OK=$'\033[1;32m' C_DIM=$'\033[2m' C_RST=$'\033[0m'
  if [[ ! -t 1 ]]; then C_LBL=''; C_OK=''; C_DIM=''; C_RST=''; fi
  # The stock config block's trailing volumes row reads the DOCKER store
  # (label-filtered volume ls) — wrong store here. Mask `docker` to a failing
  # no-op for exactly this call so the row is skipped on docker-equipped
  # hosts too. The mask is saved/restored (not blindly unset) so a
  # pre-existing docker function — e.g. a test's no-docker guard — survives.
  local saved_docker_fn
  saved_docker_fn="$(declare -f docker 2>/dev/null || true)"
  docker() { return 1; }
  aidc::status_config "$workspace" "$C_LBL" "$C_DIM" "$C_RST" || true
  if [[ -n "$saved_docker_fn" ]]; then
    eval "$saved_docker_fn"
  else
    unset -f docker
  fi
  printf '  %sruntime%s     apple-native (per-container VM; no shim)\n' "$C_LBL" "$C_RST"
  if aidc_apple::running; then
    printf '  %sstate%s       %s● running%s\n' "$C_LBL" "$C_RST" "$C_OK" "$C_RST"
  elif aidc_apple::exists; then
    printf '  %sstate%s       %s○ stopped%s\n' "$C_LBL" "$C_RST" "$C_DIM" "$C_RST"
  else
    printf '  %sstate%s       %s○ not created%s\n' "$C_LBL" "$C_RST" "$C_DIM" "$C_RST"
  fi
  printf '  %simage%s       %s\n' "$C_LBL" "$C_RST" "$(aidc_apple::thin_image)"
  printf '  %sresources%s   %s memory, %s cpu (VM-sized; see AIDC_APPLE_MEMORY/CPUS)\n' \
    "$C_LBL" "$C_RST" "$(aidc_apple::memory)" "$(aidc_apple::cpus)"
  local vols name
  vols=""
  while IFS=: read -r name _target; do
    [[ -z "$name" ]] && continue
    container volume inspect "$(aidc_apple::vol "$name")" >/dev/null 2>&1 && vols+="$name "
  done < <(aidc_apple::state_volumes)
  [[ -n "$vols" ]] && printf '\n  %svolumes%s   %s\n' "$C_LBL" "$C_RST" "$vols"
}

# ─── clean (native prune; volumes are NEVER pruned — agent state) ───────────
# Beyond dangling images, stock aidc reclaims stale content-hashed stores:
# every AIDC_AGENTS change / template pin-bump orphans multi-GB TAGGED
# aid-base:/aidc-toolchain-store: images that `container image prune`
# (dangling-only) never touches. Keepers: the current base tag, the current
# toolchain store tags, and every project image (aidc_<slug>-workspace:).
aidc::cmd_clean() {
  local apply=0 prune_cache=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apply) apply=1 ;;
      -f|--force) : ;;
      --cache) prune_cache=1 ;;
      *)
        aidc::die "unknown clean flag: $1 (valid: --apply, --cache, -f/--force)"
        ;;
    esac
    shift
  done
  aidc_apple::require_engine
  aidc::log "apple-native clean: stale store images${prune_cache:+ + builder cache}${apply:+ (apply)}; state volumes are never pruned (use destroy)"

  # Keeper base must reflect the CWD PROJECT's actual selection: load its
  # project.env first (AIDC_AGENTS is part of the base tag's content hash, and
  # AIDC_BASE_IMAGE pins a custom base outright). Without this, `clean
  # --apply` in any multi-agent project would compute the wrong keeper and
  # delete the in-use base.
  local keep=" "
  local cwd_ws
  cwd_ws="$(aidc::default_workspace)"
  if [[ -f "$cwd_ws/.ai-container/project.env" ]]; then
    aidc::load_project_env "$cwd_ws"
  fi
  if [[ -n "${AIDC_BASE_IMAGE:-}" ]]; then
    keep+="$AIDC_BASE_IMAGE "
  elif [[ -f "$cwd_ws/.devcontainer/Dockerfile.base" ]]; then
    keep+="$(aidc::base_image_tag "$cwd_ws") "
  fi
  local lang
  for lang in go rust java; do
    keep+="$(aidc::toolchain_image_tag "$lang") "
  done
  local stale="" tag
  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    case "$tag" in
      aidc-base:*|aidc-toolchain-store-*)
        [[ "$keep" == *" $tag "* ]] && continue
        stale+="$tag "
        ;;
    esac
  done < <(container image list --quiet 2>/dev/null)

  if [[ -n "$stale" ]]; then
    aidc::log "stale store images (kept: current base + current toolchains + project images):"
    for tag in $stale; do aidc::log "  $tag"; done
    if [[ "$apply" == "1" ]]; then
      # shellcheck disable=SC2086  # tags are word-split by design
      container image delete $stale >/dev/null 2>&1 \
        && aidc::log "removed stale store images" \
        || aidc::warn "some stale images could not be removed (in use?)"
    fi
  else
    aidc::log "no stale store images"
  fi
  if [[ "$prune_cache" == "1" ]]; then
    if [[ "$apply" == "1" ]]; then
      container builder delete --force >/dev/null 2>&1 || true
      aidc::log "BuildKit builder removed (recreated on the next build)"
    else
      aidc::log "builder cache would be removed with --apply"
    fi
  fi
  if [[ "$apply" != "1" ]]; then
    aidc::log "dry-run: pass --apply to remove"
  fi
}

# ─── help (stock command list under the aidc-apple name) ────────────────────
aidc::cmd_help() {
  aidc_apple::stock_help \
    | sed -e 's/^aidc - AI devcontainer bootstrapper$/aidc-apple - AI devcontainer bootstrapper (Apple container native)/' \
          -e 's/^  aidc /  aidc-apple /'
  cat <<'EOF'

native runtime notes:
  - Apple `container` only: no socktainer, no Docker, no fallback (macOS 26 +
    Apple Silicon; 'container system start' must be running).
  - Each container is its own lightweight VM. Memory/cpu are VM-sized and
    always explicit (defaults 4G/4; AIDC_MEM_LIMIT/AIDC_CPU_LIMIT or
    AIDC_APPLE_MEMORY/AIDC_APPLE_CPUS override). There is no "unlimited".
  - docs/aidc-apple.md — full mapping table, knobs, and known gaps.
EOF
}

# ─── doctor (native engine rows in place of the docker checks) ──────────────
aidc::doctor_check_docker() {
  if ! command -v container >/dev/null 2>&1; then
    aidc::doctor_report fail container "'container' CLI not found — install github.com/apple/container (macOS 26 + Apple Silicon)"
    return 0
  fi
  aidc::doctor_report ok container "$(container --version 2>/dev/null | head -1 || echo "'container' CLI present")"
  if container system status >/dev/null 2>&1; then
    aidc::doctor_report ok apple-system "container services running (native runtime, no shim)"
  else
    aidc::doctor_report fail apple-system "container services not running — start with: container system start"
  fi
  if container builder status >/dev/null 2>&1; then
    aidc::doctor_report ok apple-builder "BuildKit builder available"
  else
    aidc::doctor_report warn apple-builder "builder not started — first build will start it (AIDC_APPLE_BUILDER_CPUS/MEMORY size it)"
  fi
  if [[ -z "${AIDC_MEM_LIMIT:-}" || "${AIDC_MEM_LIMIT:-0}" == "0" ]] \
     && [[ -z "${AIDC_APPLE_MEMORY:-}" ]]; then
    aidc::doctor_report warn memory "no explicit memory set — the native default ${AIDC_APPLE_MEM_DEFAULT_DESC:-4G} applies (VM-sized, not host RAM; raise via AIDC_MEM_LIMIT or AIDC_APPLE_MEMORY)"
  fi
}
