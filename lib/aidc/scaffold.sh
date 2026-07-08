#!/usr/bin/env bash
# aidc module: Project scaffolding: init, template copy/merge, upgrade, CORE_LOGICS worktrees.
# Sourced by lib/aidc.sh — never directly. Functions moved verbatim from
# the former monolith; behavior changes ride their own commits.

# ─── upgrade ───
# Bring an existing project's aidc-owned scaffold files up to the running
# aidc's templates, with a visible diff and backups. User-owned files
# (project-setup.sh, license-matrix.tsv, CHANGELOG/DETAILED_CHANGELOG, logs/,
# project.env settings) are never touched; CLAUDE.md/AGENTS.md only have
# their managed block re-merged.

aidc::update_project_env_stamp() {
  local workspace="$1"
  local env_file="$workspace/.ai-container/project.env"
  local tmp
  tmp="$(mktemp "$workspace/.ai-container/.aidc-stamp.XXXXXX")" \
    || aidc::die "mktemp failed for $env_file"
  if awk -v v="$AIDC_VERSION" \
       '/^AIDC_VERSION=/ { print "AIDC_VERSION=" v; next } { print }' \
       "$env_file" >"$tmp"; then
    mv "$tmp" "$env_file"
  else
    rm -f "$tmp"
    aidc::die "failed to update the version stamp in $env_file"
  fi
}

aidc::cmd_upgrade() {
  local dry_run=0 assume_yes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run|--diff) dry_run=1 ;;
      -y|--yes) assume_yes=1 ;;
      *) aidc::die "unknown upgrade flag: $1 (valid: --dry-run/--diff, -y)" ;;
    esac
    shift
  done

  local workspace
  workspace="$(aidc::default_workspace)"
  [[ -f "$workspace/.ai-container/project.env" ]] \
    || aidc::die "no aidc project in $workspace (run 'aidc init' first)"
  aidc::load_project_env "$workspace"

  local stamp
  stamp="$(aidc::scaffold_stamp "$workspace")"

  local -a to_create=() to_update=()
  local entry tmpl rest target
  for entry in "${AIDC_OVERWRITE_TEMPLATE_MAP[@]}"; do
    tmpl="${entry%%:*}"
    rest="${entry#*:}"
    target="${rest%%:*}"
    if [[ ! -f "$workspace/$target" ]]; then
      to_create+=("$target")
    elif ! cmp -s "$AIDC_ROOT/$tmpl" "$workspace/$target"; then
      to_update+=("$entry")
    fi
  done

  if [[ ${#to_create[@]} -eq 0 && ${#to_update[@]} -eq 0 && "$stamp" == "$AIDC_VERSION" ]]; then
    aidc::log "scaffold already current (aidc $AIDC_VERSION)"
    return 0
  fi

  printf 'aidc upgrade — scaffold stamped %s, current %s\n\n' "${stamp:-unknown}" "$AIDC_VERSION"
  local t
  for t in ${to_create[@]+"${to_create[@]}"}; do
    printf 'create: %s\n' "$t"
  done
  for entry in ${to_update[@]+"${to_update[@]}"}; do
    tmpl="${entry%%:*}"
    rest="${entry#*:}"
    target="${rest%%:*}"
    printf 'update: %s\n' "$target"
    diff -u -L "current/$target" -L "aidc-$AIDC_VERSION/$target" \
      "$workspace/$target" "$AIDC_ROOT/$tmpl" || true
    printf '\n'
  done
  printf 'untouched: user-owned files (.devcontainer/project-setup.sh,\n'
  printf '  scripts/ci/license-matrix.tsv, CHANGELOG.md, DETAILED_CHANGELOG.md,\n'
  printf '  logs/, your project.env settings). CLAUDE.md/AGENTS.md only have\n'
  printf '  their aidc-managed block re-merged.\n\n'

  if [[ "$dry_run" -eq 1 ]]; then
    aidc::log "dry run — nothing applied"
    return 0
  fi

  if [[ "$assume_yes" -ne 1 ]]; then
    if [[ ! -t 0 ]]; then
      aidc::die "refusing to apply without confirmation on non-interactive stdin — pass -y"
    fi
    printf '[aidc] apply these updates? [y/N] '
    local reply
    read -r reply
    case "$reply" in
      y|Y|yes|YES) ;;
      *) aidc::log "upgrade aborted"; return ;;
    esac
  fi

  if [[ ${#to_update[@]} -gt 0 ]]; then
    local backup_dir
    backup_dir="$workspace/.ai-container/backup/$(date +%Y%m%d-%H%M%S)"
    for entry in "${to_update[@]}"; do
      rest="${entry#*:}"
      target="${rest%%:*}"
      mkdir -p "$backup_dir/$(dirname "$target")"
      cp "$workspace/$target" "$backup_dir/$target"
    done
    aidc::log "backed up ${#to_update[@]} file(s) to $backup_dir"
  fi

  aidc::refresh_scaffold "$workspace" "$AIDC_REPO_SLUG" "$AIDC_CORE_ROOT" "$AIDC_CORE_BRANCH" "$AIDC_CORE_WORKTREE"
  aidc::update_project_env_stamp "$workspace"
  aidc::log "scaffold upgraded to aidc $AIDC_VERSION — run 'aidc rebuild' to apply image changes"
}

aidc::cmd_init() {
  local force=0
  local workspace_arg=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--force) force=1; shift ;;
      --) shift; [[ $# -gt 0 ]] && workspace_arg="$1"; break ;;
      -*) aidc::die "unknown init flag: $1 (valid: -f/--force)" ;;
      *) workspace_arg="$1"; shift ;;
    esac
  done

  local workspace
  workspace="$(aidc::resolve_workspace_arg "$workspace_arg")"

  aidc::need_cmd docker git
  aidc::ensure_host_config_dirs
  aidc::ensure_claude_profile_examples
  aidc::sync_claude_aliases
  # --force adopts a directory that already has files at aidc-managed paths,
  # overwriting them (scaffold mode is "overwrite" during init). Without it,
  # a pre-existing managed file is a hard stop so we never clobber silently.
  if [[ "$force" -eq 1 ]]; then
    aidc::warn "--force: overwriting any existing aidc-managed files in $workspace"
  else
    aidc::check_init_conflicts "$workspace"
  fi

  local repo_slug
  repo_slug="$(aidc::repo_slug "$workspace")"

  aidc::ensure_core_repo
  local core_root
  core_root="$(aidc::core_root)"
  local core_branch
  core_branch="project/$repo_slug"
  local core_worktree
  core_worktree="$(aidc::ensure_core_worktree "$repo_slug" "$core_branch")"

  aidc::refresh_scaffold "$workspace" "$repo_slug" "$core_root" "$core_branch" "$core_worktree"
  aidc::ensure_local_git_excludes "$workspace"

  aidc::log "initialized $workspace"
  aidc::log "repo slug: $repo_slug"
  aidc::log "CORE_LOGICS branch: $core_branch"
  aidc::log "next: run 'aidc up' or 'aidc claude'"
}

aidc::refresh_scaffold() {
  local workspace="$1"
  local repo_slug="$2"
  local core_root="$3"
  local core_branch="$4"
  local core_worktree="$5"

  mkdir -p \
    "$workspace/.devcontainer/scripts" \
    "$workspace/.ai-container" \
    "$workspace/.cursor/rules"

  # aidc-owned template-tracking files (one map shared with 'aidc upgrade').
  local entry tmpl rest target mode
  for entry in "${AIDC_OVERWRITE_TEMPLATE_MAP[@]}"; do
    tmpl="${entry%%:*}"
    rest="${entry#*:}"
    target="${rest%%:*}"
    mode="${rest#*:}"
    aidc::copy_template "$tmpl" "$workspace/$target" "$mode"
  done
  # User-owned. Created once, never refreshed; edits drive per-project image layers.
  aidc::copy_template_once "templates/devcontainer/project-setup.sh.tmpl" "$workspace/.devcontainer/project-setup.sh" "0755"
  # Project documentation seeds. Created once and never overwritten so the
  # project's own history is never clobbered. Intentionally NOT git-excluded —
  # these belong to the repo and should be committed.
  aidc::copy_template_once "templates/CHANGELOG.md.tmpl" "$workspace/CHANGELOG.md" "0644"
  aidc::copy_template_once "templates/DETAILED_CHANGELOG.md.tmpl" "$workspace/DETAILED_CHANGELOG.md" "0644"
  aidc::copy_template_once "templates/logs/README.md.tmpl" "$workspace/logs/README.md" "0644"
  aidc::merge_template "templates/CLAUDE.md.tmpl" "$workspace/CLAUDE.md"
  aidc::merge_template "templates/AGENTS.md.tmpl" "$workspace/AGENTS.md"

  # scripts/ci compatibility matrix is user-owned policy (copied once, never
  # clobbered); the managed scripts/ci/*.sh come from the map above.
  aidc::copy_template_once "templates/ci/license-matrix.tsv.tmpl" "$workspace/scripts/ci/license-matrix.tsv" "0644"
  # Reference CI caller. User-owned (copied once) since CI configs get tailored.
  aidc::copy_template_once "templates/ci/github-sbom.yml.tmpl" "$workspace/.github/workflows/sbom.yml" "0644"

  # project.env is preserved if it already exists, so user-added settings
  # (e.g. AIDC_ENABLE_EGRESS_FIREWALL=1) survive scaffold refreshes.
  if [[ ! -f "$workspace/.ai-container/project.env" ]]; then
    aidc::write_project_env "$workspace/.ai-container/project.env" "$workspace" "$repo_slug" "$core_root" "$core_branch" "$core_worktree"
  fi
}

aidc::destroy_core_worktree() {
  local repo_slug="$1"
  local branch="$2"
  local core_root
  core_root="$(aidc::core_root)"
  local worktree="$AIDC_CORE_WORKTREE_ROOT/$repo_slug"

  if [[ -e "$worktree" ]]; then
    git -C "$core_root" worktree remove --force "$worktree" 2>/dev/null || rm -rf "$worktree"
    aidc::log "removed worktree $worktree"
  fi
  if git -C "$core_root" rev-parse --verify "$branch" >/dev/null 2>&1; then
    git -C "$core_root" branch -D "$branch" >/dev/null
    aidc::log "deleted branch $branch in $core_root"
  fi
}

aidc::destroy_scaffold() {
  local workspace="$1"
  local path
  for path in "${AIDC_MANAGED_PATHS[@]}"; do
    rm -rf "${workspace:?}/${path:?}"
  done
  for path in "${AIDC_MERGE_PATHS[@]}"; do
    aidc::strip_merge_block "$workspace/$path"
  done
  rmdir "$workspace/.devcontainer/scripts" 2>/dev/null || true
  rmdir "$workspace/.devcontainer" 2>/dev/null || true
  rmdir "$workspace/.ai-container" 2>/dev/null || true
  rmdir "$workspace/.cursor/rules" 2>/dev/null || true
  rmdir "$workspace/.cursor" 2>/dev/null || true

  if git -C "$workspace" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local exclude_file
    exclude_file="$(git -C "$workspace" rev-parse --git-path info/exclude)"
    if [[ "$exclude_file" != /* ]]; then
      exclude_file="$workspace/$exclude_file"
    fi
    if [[ -f "$exclude_file" ]]; then
      local tmp
      tmp="$(mktemp)"
      grep -Fvx -e ".devcontainer/" -e ".ai-container/" -e ".cursor/rules/00-core-logics.mdc" -e "CLAUDE.md" -e "AGENTS.md" "$exclude_file" >"$tmp" || true
      mv "$tmp" "$exclude_file"
    fi
  fi
  aidc::log "removed scaffold files from $workspace"
}

aidc::copy_template() {
  local source_rel="$1"
  local target="$2"
  local mode="$3"
  local source="$AIDC_ROOT/$source_rel"

  [[ -f "$source" ]] || aidc::die "missing template: $source"
  if [[ "${AIDC_SCAFFOLD_MODE:-overwrite}" == "create" && -e "$target" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "$target")"
  cp "$source" "$target"
  chmod "$mode" "$target"
}

aidc::copy_template_once() {
  local source_rel="$1"
  local target="$2"
  local mode="$3"
  [[ -e "$target" ]] && return 0
  aidc::copy_template "$source_rel" "$target" "$mode"
}

aidc::_strip_block_to() {
  # Write the contents of $1 to $2, removing any aidc merge block and
  # trimming trailing blank lines.
  local src="$1"
  local dst="$2"
  awk -v start="$AIDC_MERGE_MARKER_START" -v end="$AIDC_MERGE_MARKER_END" '
    $0 == start { skip = 1; next }
    $0 == end   { skip = 0; next }
    skip { next }
    NF { while (blank-- > 0) print ""; blank = 0; print; next }
    { blank++ }
  ' "$src" >"$dst"
}

aidc::merge_template() {
  local source_rel="$1"
  local target="$2"
  local source="$AIDC_ROOT/$source_rel"

  [[ -f "$source" ]] || aidc::die "missing template: $source"
  mkdir -p "$(dirname "$target")"

  if [[ ! -f "$target" ]]; then
    cp "$source" "$target"
    chmod 0644 "$target"
    return
  fi

  # In create mode (implicit scaffold paths) an existing managed block is
  # left exactly as-is; only a file missing the block gets it appended.
  if [[ "${AIDC_SCAFFOLD_MODE:-overwrite}" == "create" ]] \
     && grep -Fq "$AIDC_MERGE_MARKER_START" "$target"; then
    return 0
  fi

  # Temp file lives next to the target (same-fs atomic mv, no /tmp lingering)
  # and is removed on any failure path.
  local tmp
  tmp="$(mktemp "$(dirname "$target")/.aidc-merge.XXXXXX")" \
    || aidc::die "mktemp failed for $target"
  if ! { aidc::_strip_block_to "$target" "$tmp" \
         && { [[ ! -s "$tmp" ]] || printf '\n' >>"$tmp"; } \
         && cat "$source" >>"$tmp"; }; then
    rm -f "$tmp"
    aidc::die "template merge failed for $target"
  fi
  mv "$tmp" "$target"
  chmod 0644 "$target"
}

aidc::strip_merge_block() {
  local target="$1"
  [[ -f "$target" ]] || return 0
  grep -Fq "$AIDC_MERGE_MARKER_START" "$target" || return 0

  local tmp
  tmp="$(mktemp "$(dirname "$target")/.aidc-strip.XXXXXX")" \
    || aidc::die "mktemp failed for $target"
  if ! aidc::_strip_block_to "$target" "$tmp"; then
    rm -f "$tmp"
    aidc::die "merge-block strip failed for $target"
  fi

  if ! grep -q '[^[:space:]]' "$tmp"; then
    rm -f "$target" "$tmp"
  else
    mv "$tmp" "$target"
  fi
}

aidc::write_project_env() {
  local target="$1"
  local workspace="$2"
  local repo_slug="$3"
  local core_root="$4"
  local core_branch="$5"
  local core_worktree="$6"

  cat >"$target" <<EOF
# aidc-managed
AIDC_VERSION=$AIDC_VERSION
AIDC_WORKSPACE=$(aidc::shell_escape "$workspace")
AIDC_REPO_SLUG=$repo_slug
AIDC_CORE_ROOT=$(aidc::shell_escape "$core_root")
AIDC_CORE_BRANCH=$core_branch
AIDC_CORE_WORKTREE=$(aidc::shell_escape "$core_worktree")

# Auto-pull in-container agent transcripts to the host on container start, agent
# exit, 'down', and 'destroy'. Set to 0 to disable and sync manually with
# 'aidc sync-sessions'. Overrides the host-wide default in
# ~/.config/aidc/config.env for this project only.
# AIDC_AUTO_SYNC_SESSIONS=1
EOF
}

aidc::check_init_conflicts() {
  local workspace="$1"
  local project_env="$workspace/.ai-container/project.env"
  if [[ -f "$project_env" ]]; then
    return
  fi

  local path
  for path in "${AIDC_MANAGED_PATHS[@]}"; do
    if [[ -e "$workspace/$path" ]]; then
      aidc::die "refusing to overwrite existing file: $workspace/$path"
    fi
  done
}

aidc::ensure_local_git_excludes() {
  local workspace="$1"
  if ! git -C "$workspace" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    aidc::log "skipping git exclude update because $workspace is not a git repo"
    return
  fi

  local exclude_file
  exclude_file="$(git -C "$workspace" rev-parse --git-path info/exclude)"
  if [[ "$exclude_file" != /* ]]; then
    exclude_file="$workspace/$exclude_file"
  fi
  mkdir -p "$(dirname "$exclude_file")"
  touch "$exclude_file"

  local pattern
  for pattern in ".devcontainer/" ".ai-container/" ".cursor/rules/00-core-logics.mdc" "CLAUDE.md" "AGENTS.md"; do
    if ! grep -Fxq "$pattern" "$exclude_file"; then
      printf '%s\n' "$pattern" >>"$exclude_file"
    fi
  done
}

aidc::ensure_workspace_ready() {
  local workspace="$1"
  if [[ ! -f "$workspace/.ai-container/project.env" ]]; then
    aidc::cmd_init "$workspace"
    return
  fi

  aidc::ensure_host_config_dirs
  aidc::ensure_claude_profile_examples
  aidc::load_project_env "$workspace"
  aidc::ensure_core_repo
  aidc::ensure_core_worktree "$AIDC_REPO_SLUG" "$AIDC_CORE_BRANCH" >/dev/null
  # Conservative on implicit paths (up / agent commands): only create missing
  # scaffold files, never rewrite existing ones behind the user's back.
  # Explicit refreshes go through 'aidc upgrade' (diff + backup) or
  # 'aidc init'. Staleness is surfaced as a one-line notice, not applied.
  AIDC_SCAFFOLD_MODE="create"
  aidc::refresh_scaffold "$workspace" "$AIDC_REPO_SLUG" "$AIDC_CORE_ROOT" "$AIDC_CORE_BRANCH" "$AIDC_CORE_WORKTREE"
  AIDC_SCAFFOLD_MODE="overwrite"
  if aidc::scaffold_is_stale "$workspace"; then
    aidc::log "scaffold is out of date (stamped $(aidc::scaffold_stamp "$workspace" || true), current $AIDC_VERSION) — run 'aidc upgrade' to review and apply updates"
  fi
}

aidc::scaffold_stamp() {
  sed -n 's/^AIDC_VERSION=\(.*\)$/\1/p' "$1/.ai-container/project.env" 2>/dev/null | head -1
}

# Stale = version stamp differs from the running aidc, or any aidc-owned
# template-tracking file is missing or differs from its template.
aidc::scaffold_is_stale() {
  local workspace="$1"
  local stamp
  stamp="$(aidc::scaffold_stamp "$workspace")"
  [[ "$stamp" == "$AIDC_VERSION" ]] || return 0
  local entry tmpl rest target
  for entry in "${AIDC_OVERWRITE_TEMPLATE_MAP[@]}"; do
    tmpl="${entry%%:*}"
    rest="${entry#*:}"
    target="${rest%%:*}"
    [[ -f "$workspace/$target" ]] || return 0
    cmp -s "$AIDC_ROOT/$tmpl" "$workspace/$target" || return 0
  done
  return 1
}

aidc::core_root() {
  printf '%s\n' "$AIDC_CORE_ROOT_DEFAULT"
}

aidc::ensure_core_repo() {
  local core_root
  core_root="$(aidc::core_root)"
  mkdir -p "$core_root"

  if ! git -C "$core_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [[ -n "$(find "$core_root" -mindepth 1 -maxdepth 1 ! -name .git -print -quit 2>/dev/null)" ]]; then
      aidc::die "$core_root exists and is not an empty git repository"
    fi
    git -C "$core_root" init -b main >/dev/null
  fi

  local wrote=0
  if [[ ! -f "$core_root/README.md" ]]; then
    cat >"$core_root/README.md" <<'EOF'
# CORE_LOGICS

Shared reusable guidance discovered across isolated coding sessions.
EOF
    wrote=1
  fi

  if [[ ! -f "$core_root/patternlist.md" ]]; then
    cat >"$core_root/patternlist.md" <<'EOF'
# Pattern List

- Add durable, reusable guidance here when it is broadly applicable beyond one repo.
EOF
    wrote=1
  fi

  if ! git -C "$core_root" rev-parse HEAD >/dev/null 2>&1; then
    wrote=1
  fi

  if [[ "$wrote" -eq 1 ]]; then
    git -C "$core_root" add README.md patternlist.md
    GIT_AUTHOR_NAME="aidc" \
      GIT_AUTHOR_EMAIL="aidc@local" \
      GIT_COMMITTER_NAME="aidc" \
      GIT_COMMITTER_EMAIL="aidc@local" \
      git -C "$core_root" commit -m "Initialize CORE_LOGICS" >/dev/null
  fi
}

aidc::ensure_core_worktree() {
  local repo_slug="$1"
  local branch="$2"
  local core_root
  core_root="$(aidc::core_root)"
  local worktree="$AIDC_CORE_WORKTREE_ROOT/$repo_slug"

  if [[ -e "$worktree/.git" || -d "$worktree/.git" ]]; then
    printf '%s\n' "$worktree"
    return
  fi

  if [[ -e "$worktree" && ! -e "$worktree/.git" && ! -d "$worktree/.git" ]]; then
    aidc::die "worktree path exists but is not a git worktree: $worktree"
  fi

  mkdir -p "$AIDC_CORE_WORKTREE_ROOT"
  if ! git -C "$core_root" rev-parse --verify "$branch" >/dev/null 2>&1; then
    git -C "$core_root" branch "$branch" HEAD >/dev/null
  fi

  git -C "$core_root" worktree add "$worktree" "$branch" >/dev/null
  printf '%s\n' "$worktree"
}
