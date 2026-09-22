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

# Shell completions: link into the user bash-completion dir when it is in
# use; zsh users get a one-line hint (no rc-file edits behind their back).
bash_comp_dir="${BASH_COMPLETION_USER_DIR:-$HOME/.local/share/bash-completion}/completions"
if [ -d "$(dirname "$bash_comp_dir")" ]; then
  mkdir -p "$bash_comp_dir"
  ln -sf "$repo_root/completions/aidc.bash" "$bash_comp_dir/aidc"
  printf 'Linked bash completion into %s\n' "$bash_comp_dir"
else
  printf 'bash completion: add to your rc ->  source %s/completions/aidc.bash\n' "$repo_root"
fi
printf 'zsh completion:  add to your rc ->  source %s/completions/aidc.zsh\n' "$repo_root"
