# Claude profiles

For alternate Claude API targets (Z.ai, OpenRouter, locally-hosted Anthropic-compatible servers, tailnet peers, ...). Bedrock and Vertex are not supported.

```bash
cp ~/.config/aidc/providers/claude/zai.env.example \
   ~/.config/aidc/providers/claude/zai.env
$EDITOR ~/.config/aidc/providers/claude/zai.env
chmod 600 ~/.config/aidc/providers/claude/zai.env

aidc sync-claude-aliases
aidc claude --profile zai      # or just:
claude-zai
```

Each `<name>.env` produces a `claude-<name>` shim in `~/.local/bin`.

Profile files are shell-sourced env fragments. `aidc` forwards every declared env var except the reserved metadata keys below into the containerized Claude run.

Reserved metadata keys:

- `AIDC_CLAUDE_ALIAS`
- `AIDC_CLAUDE_DESCRIPTION`

If `AIDC_CLAUDE_ALIAS` is omitted, the wrapper name defaults to `claude-<profile>`.

## Local-model profiles

Two extra example templates are seeded for self-hosted endpoints (must expose an Anthropic-compatible API — e.g. LiteLLM in Anthropic mode):

- `localhost.env.example` — points at `host.docker.internal:PORT` for a server running on this Mac.
- `localnetwork.env.example` — points at a Tailscale MagicDNS name or `100.x.y.z` address for a peer. Copy to `localnetwork-<engine>.env` (e.g. `localnetwork-vllm.env`, `localnetwork-ollama.env`) for multiple peers; any `*.env` in the dir is discovered as a profile.

Container egress to the Tailscale CGNAT range (`100.64.0.0/10`) is allowed at all ports when the firewall is enabled, so tailnet peers stay reachable.

## Security

- keep real tokens only in host-global profile files (`~/.config/aidc/providers/claude/<name>.env`)
- do not commit live secrets into the repo or generated scaffolding
- prefer `chmod 600 ~/.config/aidc/providers/claude/*.env`

## One-time Claude login (skip per-repo re-login)

Each repo has its own `claude_home` named volume, so by default you re-login on every fresh repo (and after `aidc destroy`). To log in **once** on the host and have every container inherit it:

1. On host, generate a long-lived OAuth token:
   ```bash
   claude setup-token
   ```
   Copy the `sk-ant-oat01-...` value it prints.

2. Store it. **Pick one** — do not pick "paste it into `.zshrc`".

   ### Option A — macOS Keychain (recommended)

   Plaintext token never touches a dotfile.

   ```bash
   # one-time
   security add-generic-password -U \
     -a "$USER" -s claude-code-oauth-token \
     -w 'sk-ant-oat01-...'

   # in ~/.zshrc — this line references the keychain, not the secret
   export CLAUDE_CODE_OAUTH_TOKEN="$(security find-generic-password -a "$USER" -s claude-code-oauth-token -w 2>/dev/null)"
   ```

   First time a shell starts, macOS asks whether to allow `security` to read the item — click "Always Allow".

   Rotate later: `security add-generic-password -U -a "$USER" -s claude-code-oauth-token -w 'NEW_TOKEN'`. Delete: `security delete-generic-password -a "$USER" -s claude-code-oauth-token`.

   ### Option B — sourced env file, mode 600

   Plaintext on disk but outside the dotfiles repo.

   ```bash
   mkdir -p ~/.config/aidc
   umask 077
   cat > ~/.config/aidc/secrets.env <<'EOF'
   export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...
   EOF
   chmod 600 ~/.config/aidc/secrets.env

   # in ~/.zshrc
   [ -f ~/.config/aidc/secrets.env ] && source ~/.config/aidc/secrets.env
   ```

3. Re-open your terminal (or `source ~/.zshrc`). `aidc claude` now forwards `CLAUDE_CODE_OAUTH_TOKEN` into the container, and Claude Code uses it directly — no per-repo login.

Verify:
```bash
[ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] && echo "set" || echo "MISSING"
aidc exec -- printenv CLAUDE_CODE_OAUTH_TOKEN | head -c 12 && echo "..."
```

## Pulling sessions back to host

The host's Claude Code `/insights` only reads `~/.claude/projects/` on the host. Container sessions live in a Docker volume. Run:

```bash
aidc sync-sessions claude     # or: codex, opencode, all
```
