#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
install_dir="${AIDC_INSTALL_DIR:-$HOME/.local/bin}"
mkdir -p "$install_dir"
ln -sf "$repo_root/bin/aidc" "$install_dir/aidc"
AIDC_BIN_DIR="$install_dir" "$repo_root/bin/aidc" sync-claude-aliases

printf 'Installed aidc to %s/aidc\n' "$install_dir"
printf 'Synced Claude profile aliases in %s\n' "$install_dir"
printf 'Add %s to PATH if needed.\n' "$install_dir"
