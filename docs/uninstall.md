# Uninstall

## Remove aidc from one project

```bash
cd /path/to/repo
aidc destroy -f --purge-worktree --purge-scaffold
```

Removes the container, its named volumes, the image, the project's
CORE_LOGICS worktree/branch, and every scaffolded file (the seeded
`CHANGELOG.md`, `DETAILED_CHANGELOG.md`, and `logs/` stay — they belong to
your repo). `.git/info/exclude` entries are cleaned up.

## Remove aidc from the host

1. **Per-project cleanup first** (above) for every project — easiest to find
   them via `aidc status --global`, which lists all aidc containers.
2. **CLI + aliases + completions:**

   ```bash
   rm -f ~/.local/bin/aidc
   # Claude profile alias wrappers are aidc-managed and marked as such:
   grep -l 'aidc claude --profile' ~/.local/bin/claude-* 2>/dev/null | xargs rm -f
   rm -f ~/.local/share/bash-completion/completions/aidc
   # remove any `source …/completions/aidc.zsh` line from your ~/.zshrc
   ```

3. **Config & state:**

   ```bash
   rm -rf ~/.config/aidc            # global config + Claude profiles (API keys!)
   rm -rf ~/.local/share/aidc       # CORE_LOGICS worktrees
   ```

4. **Clipboard bridge** (only if you enabled it): unload and remove the
   LaunchAgent as described in `docs/clipboard-bridge.md`.
5. **Keychain** (optional): delete the stored Claude token:

   ```bash
   security delete-generic-password -a "$USER" -s claude-code-oauth-token
   ```

6. **The checkout itself:** delete the cloned `aidc` directory.
7. **Leftover Docker state** (belt and braces):

   ```bash
   docker ps -a --format '{{.Names}}' | grep '^aidc_' | xargs -r docker rm -f
   docker volume ls -q | grep '^aidc_' | xargs -r docker volume rm
   docker image prune
   ```

`~/CORE_LOGICS` (the shared notes repo) is yours — aidc created it but the
content is your accumulated guidance; delete it only if you're sure.
