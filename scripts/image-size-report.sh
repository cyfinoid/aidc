#!/usr/bin/env bash
#
# image-size-report — per-layer and per-component disk breakdown of an aidc image.
#
# The CI image-size workflow reports one total against a soft budget; this tool
# explains WHERE the bytes are, so slimming work (Dockerfile.base experiments,
# AIDC_AGENTS selection) is measurable instead of guesswork.
#
# Usage (from an aidc-scaffolded repo root, or the aidc repo itself):
#   scripts/image-size-report.sh [--image REF] [--build] [--top N] [--json]
#
#   --image REF   image ref to inspect. Default: the content-hashed
#                 aidc-base:<hash> that aidc would build here (hash of
#                 .devcontainer/Dockerfile.base + the AIDC_AGENTS selection).
#   --build       build the default image first if it doesn't exist (refused
#                 together with --image; pinned/custom refs are never built).
#   --top N       how many rows per section (default 15).
#   --json        machine-readable output instead of the human table.
#
# Requires: docker, awk. Read-only — the image is only run to `du` it, never
# modified.
set -uo pipefail

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

IMAGE=""
IMAGE_EXPLICIT=0
BUILD=0
TOP=15
JSON=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMAGE="${2:-}"; IMAGE_EXPLICIT=1; shift 2 ;;
    --build) BUILD=1; shift ;;
    --top)
      [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "image-size-report: --top needs a number" >&2; exit 2; }
      TOP="$2"; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "image-size-report: unknown flag $1" >&2; usage 2 ;;
  esac
done

[[ -f .devcontainer/Dockerfile.base ]] || {
  echo "image-size-report: no .devcontainer/Dockerfile.base here — run from an aidc-scaffolded repo" >&2
  exit 2
}

# Default image = the tag aidc::base_image_tag would use, so the report always
# describes the image aidc actually starts.
if [[ "$IMAGE_EXPLICIT" -eq 0 ]]; then
  if command -v sha256sum >/dev/null 2>&1; then cmd="sha256sum"; else cmd="shasum -a 256"; fi
  input="$(cat .devcontainer/Dockerfile.base)"
  input+="|AIDC_AGENTS=${AIDC_AGENTS:-opencode}"
  hash="$(printf '%s' "$input" | $cmd | awk '{print $1}' | cut -c1-12)"
  IMAGE="aidc-base:${hash:-latest}"
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  if [[ "$BUILD" -eq 1 && "$IMAGE_EXPLICIT" -eq 0 ]]; then
    echo "image-size-report: building $IMAGE (one-time)..." >&2
    # Mirror of aidc::agents_build_flags (lib/aidc/runtime.sh): per-agent
    # WITH_* flags drive Dockerfile.base's conditional agent stages.
    flags=""
    sel="${AIDC_AGENTS:-opencode}"
    [[ "$sel" == "all" ]] && sel="claude,codex,opencode,cursor-agent,grok,omp"
    [[ "$sel" == "none" ]] && sel=""
    for a in claude codex opencode cursor-agent grok omp; do
      case ",$sel," in *",$a,"*) flags+=" --build-arg WITH_$(printf '%s' "$a" | tr 'a-z' 'A-Z' | tr '-' '_')=1" ;; esac
    done
    # shellcheck disable=SC2086  # flag tokens are generated above
    docker build -f .devcontainer/Dockerfile.base \
      --build-arg AIDC_AGENTS="${AIDC_AGENTS:-opencode}" $flags \
      -t "$IMAGE" .devcontainer >&2 || exit 1
  else
    echo "image-size-report: image $IMAGE not found locally (build it with 'aidc up', or retry with --build)" >&2
    exit 1
  fi
fi

total_bytes="$(docker image inspect "$IMAGE" --format '{{.Size}}' 2>/dev/null)" || total_bytes=0
[[ "$total_bytes" =~ ^[0-9]+$ ]] || total_bytes=0

# ── layers: docker history (biggest first) ────────────────────────────────────
# Sizes are human ("500MB"); normalize to bytes for sorting. CreatedBy is
# trimmed: the interesting part is which RUN/COPY produced the layer.
layer_rows="$(docker history --no-trunc --format '{{.Size}}|{{.CreatedBy}}' "$IMAGE" 2>/dev/null \
  | awk -F'|' '
      function bytes(s) {
        v = s + 0
        if (s ~ /GB$/) return v * 1024 * 1024 * 1024
        if (s ~ /MB$/) return v * 1024 * 1024
        if (s ~ /kB$/) return v * 1024
        return v
      }
      {
        # heredoc COPY layers span real newlines in --no-trunc output; the
        # continuation lines have no size field and are skipped here.
        if ($1 !~ /^[0-9]+(\.[0-9]+)?(GB|MB|kB|B)$/) next
        cmd = $2
        sub(/^\/bin\/sh -c /, "", cmd)
        sub(/^[|0-9]+ /, "", cmd)
        gsub(/\\n.*/, " …", cmd)
        if (length(cmd) > 90) cmd = substr(cmd, 1, 90) " …"
        printf "%020.0f|%s|%s\n", bytes($1), $1, cmd
      }' | sort -r)"

# ── components: one throwaway container, one sh -c with tagged du sections ───
# The image's default user (vscode) only reads; @@section markers delimit the
# du groups so the parser stays dumb.
du_out="$(docker run --rm --entrypoint /bin/sh "$IMAGE" -c '
  echo "@@top-level"
  du -sk /usr /opt /home/vscode /var /etc /root /commandhistory 2>/dev/null
  echo "@@home-children"
  du -sk /home/vscode/* /home/vscode/.[!.]* 2>/dev/null
  echo "@@opt-children"
  du -sk /opt/* /opt/uv/* 2>/dev/null
  echo "@@tools-children"
  du -sk /opt/uv/tools/* 2>/dev/null
  echo "@@python"
  du -sk /opt/uv/python/* 2>/dev/null
  echo "@@localbin"
  du -sk /usr/local/bin/* 2>/dev/null
' 2>/dev/null)"

component_rows() { # <section> — raw "kb<TAB>path" rows of one @@section
  local section="$1" in_sec=0 line
  while IFS= read -r line; do
    if [[ "$line" == "@@"* ]]; then
      if [[ "$line" == "@@$section" ]]; then
        in_sec=1
      elif [[ "$in_sec" -eq 1 ]]; then
        break
      fi
      continue
    fi
    [[ "$in_sec" -eq 1 && -n "$line" ]] && printf '%s\n' "$line"
  done <<<"$du_out"
}

human() { # bytes -> human
  awk -v b="$1" 'BEGIN {
    if (b >= 1073741824) printf "%.1fGB", b / 1073741824
    else if (b >= 1048576) printf "%.0fMB", b / 1048576
    else if (b >= 1024) printf "%.0fkB", b / 1024
    else printf "%dB", b
  }'
}

if [[ "$JSON" -eq 1 ]]; then
  printf '{"image":"%s","total_bytes":%s,"layers":[' "$IMAGE" "$total_bytes"
  first=1
  while IFS='|' read -r b sz cmd; do
    [[ -z "$b" ]] && continue
    [[ "$first" -eq 1 ]] || printf ','
    first=0
    esc="$(printf '%s' "$cmd" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    printf '{"size":"%s","bytes":%d,"created_by":"%s"}' "$sz" "$((10#$b))" "$esc"
  done <<<"$layer_rows"
  printf '],"top_level":['
  first=1
  while IFS=$'\t' read -r kb path; do
    [[ -z "$kb" ]] && continue
    [[ "$first" -eq 1 ]] || printf ','
    first=0
    printf '{"path":"%s","bytes":%d}' "$path" "$((kb * 1024))"
  done < <(component_rows top-level)
  printf ']}\n'
  exit 0
fi

# ── human report ──────────────────────────────────────────────────────────────
printf 'image-size-report: %s\n' "$IMAGE"
printf 'total: %s\n\n' "$(human "$total_bytes")"

printf '── largest layers (%s total) ──────────────────────────────────\n' \
  "$(printf '%s\n' "$layer_rows" | grep -c .)"
printf '%10s  %s\n' 'SIZE' 'LAYER'
printf '%s\n' "$layer_rows" | awk -F'|' -v n="$TOP" 'NR <= n { printf "%10s  %s\n", $2, $3 }'
printf '\n'

emit_table() { # <title> <section> <n>
  printf '── %s ──\n' "$1"
  printf '%10s  %s\n' 'SIZE' 'PATH'
  component_rows "$2" | sort -rn | head -n "$3" | while IFS=$'\t' read -r kb path; do
    printf '%10s  %s\n' "$(human "$((kb * 1024))")" "$path"
  done
  printf '\n'
}

emit_table "top-level dirs" top-level "$TOP"
emit_table "/home/vscode (agents, config)" home-children "$TOP"
emit_table "/opt (uv, python, tools)" opt-children "$TOP"
emit_table "/opt/uv/tools (uv-installed tools)" tools-children "$TOP"
emit_table "/opt/uv/python (uv-managed runtimes)" python "$TOP"
emit_table "/usr/local/bin (scanners, helpers)" localbin 25
