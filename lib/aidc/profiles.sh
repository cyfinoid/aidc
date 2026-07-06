#!/usr/bin/env bash
# aidc module: Claude profiles, OAuth token resolution, and profile aliases.
# Sourced by lib/aidc.sh — never directly. Functions moved verbatim from
# the former monolith; behavior changes ride their own commits.

aidc::cmd_sync_claude_aliases() {
  aidc::ensure_host_config_dirs
  aidc::ensure_claude_profile_examples
  aidc::sync_claude_aliases
}

aidc::ensure_claude_profile_examples() {
  local zai="$AIDC_CLAUDE_PROFILE_ROOT/zai.env.example"
  local openrouterfree="$AIDC_CLAUDE_PROFILE_ROOT/openrouterfree.env.example"
  local localhost_example="$AIDC_CLAUDE_PROFILE_ROOT/localhost.env.example"
  local localnetwork="$AIDC_CLAUDE_PROFILE_ROOT/localnetwork.env.example"

  if [[ ! -f "$zai" ]]; then
    cat >"$zai" <<'EOF'
# aidc Claude profile example
# Copy to zai.env and replace the placeholder values on the host.
AIDC_CLAUDE_DESCRIPTION="Z.ai Anthropic-compatible profile"
ZAI_API_KEY="replace-me"
ANTHROPIC_AUTH_TOKEN="$ZAI_API_KEY"
ANTHROPIC_BASE_URL="https://api.z.ai/api/anthropic"
ANTHROPIC_MODEL="GLM-5.1"
EOF
  fi

  if [[ ! -f "$openrouterfree" ]]; then
    cat >"$openrouterfree" <<'EOF'
# aidc Claude profile example
# Copy to openrouterfree.env and fill in the provider-specific values on the host.
AIDC_CLAUDE_DESCRIPTION="OpenRouter free-tier profile"
OPENROUTER_API_KEY="replace-me"
ANTHROPIC_AUTH_TOKEN="$OPENROUTER_API_KEY"
# Set this to your Anthropic-compatible OpenRouter endpoint.
ANTHROPIC_BASE_URL="replace-me"
ANTHROPIC_MODEL="replace-me"
EOF
  fi

  if [[ ! -f "$localhost_example" ]]; then
    cat >"$localhost_example" <<'EOF'
# aidc Claude profile example
# Copy to localhost.env. Targets an Anthropic-compatible server running on
# this Mac (LM Studio, LiteLLM in Anthropic mode, etc.).
# host.docker.internal resolves to the host on Docker Desktop / OrbStack.
AIDC_CLAUDE_DESCRIPTION="Localhost Anthropic-compatible profile"
LOCAL_LLM_API_KEY="replace-me"
ANTHROPIC_AUTH_TOKEN="$LOCAL_LLM_API_KEY"
ANTHROPIC_BASE_URL="http://host.docker.internal:PORT"
ANTHROPIC_MODEL="replace-me"
EOF
  fi

  if [[ ! -f "$localnetwork" ]]; then
    cat >"$localnetwork" <<'EOF'
# aidc Claude profile example
# Copy to localnetwork.env (or localnetwork-<engine>.env for multiple peers;
# any *.env in this dir is discovered as a profile).
# Use the Tailscale MagicDNS name or 100.x.y.z address of the peer.
AIDC_CLAUDE_DESCRIPTION="Local-network Anthropic-compatible profile"
LOCAL_LLM_API_KEY="replace-me"
ANTHROPIC_AUTH_TOKEN="$LOCAL_LLM_API_KEY"
ANTHROPIC_BASE_URL="http://hostname.your-tailnet.ts.net:PORT"
ANTHROPIC_MODEL="replace-me"
EOF
  fi

  # Copies of these become real credential files; seed them (and any
  # pre-existing examples) with strict permissions so the copies start strict.
  chmod 600 "$zai" "$openrouterfree" "$localhost_example" "$localnetwork" 2>/dev/null || true
}

aidc::append_passthrough_env_args() {
  local key
  for key in "${AIDC_PASSTHROUGH_ENV_KEYS[@]}"; do
    if [[ -n "${AIDC_PASSTHROUGH_SKIP_KEY:-}" && "$key" == "$AIDC_PASSTHROUGH_SKIP_KEY" ]]; then
      continue
    fi
    if [[ -n "${!key:-}" ]]; then
      AIDC_EXEC_ENV_ARGS+=("-e" "$key")
    fi
  done
}

# Populate CLAUDE_CODE_OAUTH_TOKEN from the macOS Keychain so the token only
# lives in this process for the duration of the exec, instead of being exported
# into every shell via ~/.zshrc. No-op when the token is already set, when the
# key has been dropped from the passthrough list (per-project opt-out via
# AIDC_PASSTHROUGH_ENV_KEYS), when the Keychain lookup is disabled, or when the
# `security` tool is unavailable (e.g. non-macOS hosts). Never logs the token.
aidc::resolve_claude_oauth_token() {
  [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] && return 0
  [[ -n "${AIDC_CLAUDE_OAUTH_KEYCHAIN_SERVICE:-}" ]] || return 0

  local key forwarded=0
  for key in "${AIDC_PASSTHROUGH_ENV_KEYS[@]}"; do
    if [[ "$key" == "CLAUDE_CODE_OAUTH_TOKEN" ]]; then
      forwarded=1
      break
    fi
  done
  [[ "$forwarded" -eq 1 ]] || return 0

  command -v security >/dev/null 2>&1 || return 0

  local account token
  account="${USER:-$(id -un 2>/dev/null || true)}"
  token="$(security find-generic-password -a "$account" -s "$AIDC_CLAUDE_OAUTH_KEYCHAIN_SERVICE" -w 2>/dev/null || true)"
  if [[ -n "$token" ]]; then
    export CLAUDE_CODE_OAUTH_TOKEN="$token"
  fi
}

aidc::validate_claude_profile_name() {
  local profile="$1"
  [[ "$profile" =~ ^[a-z0-9][a-z0-9-]*$ ]] || aidc::die "invalid Claude profile name: $profile"
}

aidc::validate_claude_alias_name() {
  local alias_name="$1"
  [[ "$alias_name" =~ ^claude-[a-z0-9][a-z0-9-]*$ ]] || aidc::die "invalid Claude alias name: $alias_name"
}

aidc::claude_profile_env_file() {
  local profile="$1"
  aidc::validate_claude_profile_name "$profile"
  printf '%s/%s.env\n' "$AIDC_CLAUDE_PROFILE_ROOT" "$profile"
}

aidc::claude_profile_metadata() {
  local profile="$1"
  local env_file
  env_file="$(aidc::claude_profile_env_file "$profile")"
  [[ -f "$env_file" ]] || aidc::die "missing Claude profile: $env_file"
  aidc::warn_if_loose_permissions "$env_file"

  local metadata
  metadata="$(
    unset AIDC_CLAUDE_ALIAS AIDC_CLAUDE_DESCRIPTION
    set -a
    # shellcheck disable=SC1090
    . "$env_file"
    set +a
    printf '%s\t%s\n' "${AIDC_CLAUDE_ALIAS:-claude-$profile}" "${AIDC_CLAUDE_DESCRIPTION:-}"
  )"

  local alias_name="${metadata%%$'\t'*}"
  aidc::validate_claude_alias_name "$alias_name"
  printf '%s\n' "$metadata"
}

aidc::find_claude_profiles() {
  [[ -d "$AIDC_CLAUDE_PROFILE_ROOT" ]] || return 0

  local env_file profile
  while IFS= read -r env_file; do
    [[ -n "$env_file" ]] || continue
    profile="$(basename "$env_file" .env)"
    if [[ ! "$profile" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
      aidc::warn "ignoring invalid Claude profile filename: $(basename "$env_file")"
      continue
    fi
    printf '%s\n' "$profile"
  done < <(find "$AIDC_CLAUDE_PROFILE_ROOT" -maxdepth 1 -type f -name '*.env' -print | sort)
}

aidc::list_claude_profiles() {
  aidc::ensure_host_config_dirs
  aidc::ensure_claude_profile_examples

  local found=0
  local profile metadata alias_name description
  while IFS= read -r profile; do
    [[ -n "$profile" ]] || continue
    found=1
    metadata="$(aidc::claude_profile_metadata "$profile")"
    alias_name="${metadata%%$'\t'*}"
    description="${metadata#*$'\t'}"
    if [[ "$description" == "$metadata" ]]; then
      description=""
    fi

    if [[ -n "$description" ]]; then
      printf '%-20s %-24s %s\n' "$profile" "$alias_name" "$description"
    else
      printf '%-20s %-24s\n' "$profile" "$alias_name"
    fi
  done < <(aidc::find_claude_profiles)

  if [[ "$found" -eq 0 ]]; then
    aidc::log "no Claude profiles found in $AIDC_CLAUDE_PROFILE_ROOT"
  fi
}

aidc::claude_alias_is_managed() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  grep -Fq "$AIDC_MANAGED_CLAUDE_ALIAS_MARKER" "$path"
}

aidc::write_claude_alias_wrapper() {
  local target="$1"
  local profile="$2"

  cat >"$target" <<EOF
#!/usr/bin/env bash
$AIDC_MANAGED_CLAUDE_ALIAS_MARKER
exec aidc claude --profile $profile "\$@"
EOF
  chmod 0755 "$target"
}

aidc::remove_stale_claude_aliases() {
  local desired_aliases=("$@")
  [[ -d "$AIDC_BIN_DIR" ]] || return 0

  local path alias_name
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if ! aidc::claude_alias_is_managed "$path"; then
      continue
    fi

    alias_name="$(basename "$path")"
    if ! aidc::array_contains "$alias_name" ${desired_aliases[@]+"${desired_aliases[@]}"}; then
      rm -f "$path"
      aidc::log "removed stale Claude alias $alias_name"
    fi
  done < <(find "$AIDC_BIN_DIR" -maxdepth 1 \( -type f -o -type l \) -name 'claude-*' -print 2>/dev/null | sort)
}

aidc::sync_claude_aliases() {
  mkdir -p "$AIDC_BIN_DIR"

  local desired_aliases=()
  local profile metadata alias_name target
  while IFS= read -r profile; do
    [[ -n "$profile" ]] || continue
    metadata="$(aidc::claude_profile_metadata "$profile")"
    alias_name="${metadata%%$'\t'*}"
    desired_aliases+=("$alias_name")
    target="$AIDC_BIN_DIR/$alias_name"

    if [[ -e "$target" ]] && ! aidc::claude_alias_is_managed "$target"; then
      aidc::warn "skipping Claude alias $alias_name because $target already exists and is not aidc-managed"
      continue
    fi

    aidc::write_claude_alias_wrapper "$target" "$profile"
    aidc::log "synced Claude alias $alias_name"
  done < <(aidc::find_claude_profiles)

  aidc::remove_stale_claude_aliases ${desired_aliases[@]+"${desired_aliases[@]}"}
}

aidc::load_claude_profile_env() {
  local profile="$1"
  local env_file
  env_file="$(aidc::claude_profile_env_file "$profile")"
  [[ -f "$env_file" ]] || aidc::die "missing Claude profile: $env_file"
  # Hard requirement at the moment of use: this file's values are about to be
  # exported and forwarded into the container. (Read-only paths like
  # --list-profiles only warn.)
  aidc::require_strict_permissions "$env_file"

  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  set +a

  local metadata alias_name
  metadata="$(aidc::claude_profile_metadata "$profile")"
  alias_name="${metadata%%$'\t'*}"
  aidc::validate_claude_alias_name "$alias_name"

  local key
  AIDC_PROFILE_LOADED_KEYS=()
  while IFS= read -r key; do
    if [[ "$key" == "AIDC_CLAUDE_ALIAS" || "$key" == "AIDC_CLAUDE_DESCRIPTION" ]]; then
      continue
    fi
    if aidc::var_is_set "$key"; then
      AIDC_EXEC_ENV_ARGS+=("-e" "$key")
      AIDC_PROFILE_LOADED_KEYS+=("$key")
    fi
  done < <(aidc::env_file_keys "$env_file")
}
