#!/usr/bin/env bash
# aidc clean — reclaim disk from stale aidc images (dry-run by default).
#
# aidc's image model is content-hash-tagged (aidc-base:<hash>, aidc-toolchain-
# store-<lang>:<hash>): every pin bump, template edit, or AIDC_AGENTS change
# builds a NEW tag while the old ~3GB images stay on disk forever, and compose
# rebuilds leave dangling per-project images behind. Nothing pruned them —
# this command does:
#
#   1. stale aidc-base:<hash12> images — every content-hashed base that no
#      local image's `aidc.base` label references (i.e. no thin image was
#      built from it). Refs that don't match the hash pattern (custom bases
#      like aidc-base:mine or :latest) are never touched.
#   2. stale aidc-toolchain-store-<lang>:<hash12> images — hashes that don't
#      match the current toolchain template. The shared toolchain VOLUME keeps
#      its contents; only the one-shot store images are garbage-collected.
#   3. dangling images — unnamed leftovers of compose rebuilds. Never removes
#      an image a container (running or stopped) still uses.
#
# Usage: aidc clean [--apply] [--cache] [-f|--force] [-h|--help]
#   (default)     dry-run: list what would be removed and the approximate
#                 reclaim (shared OS layers are deduplicated by Docker, so
#                 per-image sizes overstate the true reclaim).
#   --apply       actually remove. Prompts unless -f/--force is given.
#   --cache       also prune the docker build cache (`docker builder prune`).
#                 Off by default: the cache is what keeps rebuilds fast.
#
# Removing a stale base is always safe to redo: the next 'aidc up'/'aidc
# rebuild' for a project that needs it simply rebuilds it (at build-time cost,
# not correctness cost).

# Indirection so tests can stub docker without touching PATH.
aidc::clean_docker() {
  docker "$@"
}

# "<n>MB" / "<n>GB" / "<n>kB" / "<n>B" -> bytes (0 on anything unparseable).
aidc::clean_size_bytes() {
  awk -v s="$1" 'BEGIN {
    v = s + 0
    if (s ~ /GB$/) printf "%.0f", v * 1024 * 1024 * 1024
    else if (s ~ /MB$/) printf "%.0f", v * 1024 * 1024
    else if (s ~ /kB$/) printf "%.0f", v * 1024
    else printf "%.0f", v
  }'
}

aidc::clean_human_size() { # bytes -> human
  awk -v b="$1" 'BEGIN {
    if (b >= 1073741824) printf "%.1fGB", b / 1073741824
    else if (b >= 1048576) printf "%.0fMB", b / 1048576
    else if (b >= 1024) printf "%.0fkB", b / 1024
    else printf "%dB", b
  }'
}

# "Images|<count>|<size>|<reclaimable>" row of `docker system df`.
aidc::clean_df_images() {
  aidc::clean_docker system df --format '{{.Type}}|{{.Count}}|{{.Size}}|{{.Reclaimable}}' 2>/dev/null \
    | awk -F'|' '$1 == "Images" {print}'
}

aidc::cmd_clean() {
  local apply=0 force=0 prune_cache=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apply) apply=1 ;;
      -f|--force) force=1 ;;
      --cache) prune_cache=1 ;;
      -h|--help)
        sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        return 0
        ;;
      *)
        aidc::die "unknown clean flag: $1 (valid: --apply, --cache, -f/--force, -h/--help)"
        ;;
    esac
    shift
  done

  command -v docker >/dev/null 2>&1 \
    || aidc::die "docker not found — 'aidc clean' manages docker images"

  local rows
  rows="$(aidc::clean_docker image ls --format '{{.Repository}}:{{.Tag}}|{{.ID}}|{{.Size}}' 2>/dev/null)"
  if [[ -z "$rows" ]]; then
    aidc::log "no docker images found — nothing to clean"
    return 0
  fi

  # Bases referenced by any local image's aidc.base label (thin images record
  # the base they were built on). One inspect over all image IDs.
  local ids="" ref base_ref
  while IFS='|' read -r ref id _sz; do
    [[ -z "$id" ]] && continue
    ids+=" $id"
  done <<<"$rows"
  local referenced=" "
  if [[ -n "${ids// /}" ]]; then
    # shellcheck disable=SC2086  # ids are 12-hex image IDs; word-split intended
    while IFS='|' read -r _id base_ref; do
      [[ -n "$base_ref" && "$base_ref" != "<no value>" ]] && referenced+="$base_ref "
    done <<<"$(aidc::clean_docker image inspect --format '{{.Id}}|{{index .Config.Labels "aidc.base"}}' $ids 2>/dev/null)"
  fi

  # Current toolchain store tags (one per language) are the keepers.
  local tc_current=" "
  local lang
  for lang in go rust java; do
    tc_current+="$(aidc::toolchain_image_tag "$lang") "
  done

  local stale_refs=() stale_sizes=() total=0 count=0
  local dangling_ids
  dangling_ids="$(aidc::clean_docker image ls -f dangling=true -q 2>/dev/null | sed '/^$/d' | tr '\n' ' ')"
  while IFS='|' read -r ref id size; do
    [[ -z "$ref" ]] && continue
    case "$ref" in
      aidc-base:*)
        # only content-hashed tags are aidc-owned; custom tags are never touched
        [[ "$ref" =~ ^aidc-base:[0-9a-f]{12}$ ]] || continue
        [[ "$referenced" == *" $ref "* ]] && continue
        ;;
      aidc-toolchain-store-*)
        [[ "$ref" =~ ^aidc-toolchain-store-[^:]+:[0-9a-f]{12}$ ]] || continue
        [[ "$tc_current" == *" $ref "* ]] && continue
        ;;
      *) continue ;;
    esac
    stale_refs+=("$ref")
    stale_sizes+=("$size")
    total=$((total + "$(aidc::clean_size_bytes "$size")"))
    count=$((count + 1))
  done <<<"$rows"

  if [[ "$count" -eq 0 && -z "$dangling_ids" && "$prune_cache" -ne 1 ]]; then
    aidc::log "nothing to clean — all aidc-base/toolchain-store images are in use"
    return 0
  fi

  local i
  if [[ "$count" -gt 0 ]]; then
    echo "stale aidc images (unreferenced):"
    for i in "${!stale_refs[@]}"; do
      printf '  %-46s %s\n' "${stale_refs[$i]}" "${stale_sizes[$i]}"
    done
    printf '  approx reclaim: %s (shared base layers are deduplicated; real reclaim is smaller)\n' \
      "$(aidc::clean_human_size "$total")"
  fi
  if [[ -n "$dangling_ids" ]]; then
    printf 'dangling images (compose rebuild leftovers): %s\n' \
      "$(printf '%s' "$dangling_ids" | wc -w | tr -d ' ')"
  fi
  if [[ "$count" -eq 0 && -z "$dangling_ids" ]]; then
    aidc::log "no stale or dangling images; only --cache pruning was requested"
  fi

  if [[ "$apply" -ne 1 ]]; then
    local hint="--apply"
    [[ "$prune_cache" -eq 1 ]] && hint="--apply --cache"
    aidc::log "dry run — re-run with $hint to remove"
    return 0
  fi

  if [[ "$force" -ne 1 ]]; then
    printf '[aidc] remove the images listed above? [y/N] '
    local reply
    read -r reply
    case "$reply" in
      y|Y|yes|YES) ;;
      *) aidc::log "clean aborted"; return 0 ;;
    esac
  fi

  local df_before
  df_before="$(aidc::clean_df_images)"

  local removed=0 failed=0
  if [[ "$count" -gt 0 ]]; then
    for i in "${!stale_refs[@]}"; do
      if aidc::clean_docker rmi -f "${stale_refs[$i]}" >/dev/null 2>&1; then
        removed=$((removed + 1))
      else
        failed=$((failed + 1))
        aidc::warn "could not remove ${stale_refs[$i]} (in use by a container?)"
      fi
    done
  fi

  if [[ -n "$dangling_ids" ]]; then
    aidc::clean_docker image prune -f >/dev/null 2>&1 || aidc::warn "dangling-image prune failed"
  fi
  if [[ "$prune_cache" -eq 1 ]]; then
    aidc::clean_docker builder prune -f >/dev/null 2>&1 || aidc::warn "build-cache prune failed"
  fi

  local df_after
  df_after="$(aidc::clean_df_images)"

  aidc::log "cleaned: $removed image tag(s) removed${failed:+, $failed failed}"
  if [[ -n "$df_before" && -n "$df_after" ]]; then
    printf 'images on disk: %s -> %s\n' \
      "$(printf '%s' "$df_before" | cut -d'|' -f3)" \
      "$(printf '%s' "$df_after" | cut -d'|' -f3)"
  fi
  return 0
}
