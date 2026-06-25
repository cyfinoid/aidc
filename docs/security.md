# Security tooling

For aidc's own vulnerability-disclosure policy, see [`/SECURITY.md`](../SECURITY.md). This page documents the scanners and guardrails baked into every aidc container.

## Always-on scanners

Every aidc image ships with:

- [`semgrep`](https://semgrep.dev) — SAST. Run: `semgrep scan --config auto <paths>`.
- [`gitleaks`](https://github.com/gitleaks/gitleaks) — secret detection. Run: `gitleaks detect --no-banner`.
- [`trufflehog`](https://github.com/trufflesecurity/trufflehog) — secret detection with optional verification.

If the egress firewall is enabled, `semgrep.dev` is in the default allowlist so `--config auto` works.

## Per-toolchain linters (auto-installed)

When aidc detects a language toolchain it also installs the standard security linter for that language:

| Detected toolchain | Linter | Invocation |
|---|---|---|
| Go (`go.mod`) | `gosec` | `gosec ./...` |
| Python (`pyproject.toml`, etc.) | `bandit` | `bandit -r <src>` |
| Rust (`Cargo.toml`) | `cargo-audit` | `cargo audit` |
| Ruby (`Gemfile`) | `bundler-audit` | `bundle-audit check --update` |

Node uses the built-in `npm audit` (or `pnpm audit` / `yarn npm audit`); Java and PHP rely on semgrep for SAST.

## Opt-in heavier tools

Add to `.ai-container/project.env` and `aidc rebuild`:

```bash
AIDC_SECURITY_TOOLS=grype,syft,checkov,bandit
```

Supported: `grype` (vuln scan), `syft` (SBOM), `checkov` (IaC), `bandit` (Python SAST — already auto-installed when Python is detected; explicit listing is a no-op).

## Agent-enforced guardrails

The scaffold writes a "Security guardrails (non-negotiable)" block into `CLAUDE.md` and `AGENTS.md` inside the aidc-managed marker. It instructs agents to run the relevant scanners on every code change and fix findings above LOW before declaring work complete. User-edited content outside the markers is preserved on scaffold refresh.

## Supply-chain guardrails (always on)

The container ships with SafeDep's [`pmg`](https://github.com/safedep/pmg) and [`vet`](https://github.com/safedep/vet) baked in. `pmg setup install` runs at image build **before any user-level package install**, and interception rides on the `~/.pmg/bin` PATH shims — which are first on the image `ENV PATH` for both build and runtime. It is deliberately **not** dependent on the shell aliases pmg also writes to `~/.zshrc`/`~/.bashrc`: Docker build `RUN` steps and exec'd agent subprocesses never source rc files, so only the PATH shims reliably gate package managers. The shims intercept `npm`, `pnpm`, `yarn`, `bun`, `npx`, `pnpx`, `pip`, `pip3`, `uv`, and `poetry` — including subprocess calls from agents (Claude, Codex, OpenCode, Grok, Cursor Agent). Malicious packages are blocked before install.

The coding agents themselves are installed as **native prebuilt binaries** (via each vendor's `curl | sh` installer), not `npm install -g`, so there is no agent-install step for pmg to vet and no Node runtime dependency for the agents. The `NPM_CONFIG_*` hardening in the image still governs any npm the agents or project toolchains invoke at runtime, which the pmg shims gate.

Run scans by hand with `aidc exec -- vet scan -D /workspace`. Re-run `pmg setup doctor` inside the container to verify wiring (`aidc exec -- pmg setup doctor`). To confirm interception is alias-independent, check that the shim wins without sourcing rc files: `aidc exec -- bash -c 'command -v npm'` should resolve under `~/.pmg/bin`.

If the egress firewall is enabled, the allowlist already includes `api.safedep.io`, `vetpkg.dev`, `osv.dev`, and `semgrep.dev`.

## Sharing credentials with the agents

aidc never mounts your whole host home into the container. Instead each agent's
config/auth is shared two ways, both scoped to that agent:

**1. Read-only seed mounts (the default path).** On first startup
`bootstrap-state.sh init` copies selected files from host config dirs (mounted
read-only at `/host-seed/<tool>`) into the agent's per-repo volume:

| Agent | Host source | Container volume | Seeded by |
|---|---|---|---|
| Claude | `~/.claude` | `~/.claude` | `settings.json`, `CLAUDE.md` |
| Codex | `~/.codex` | `~/.codex` | `auth.json`, `config.toml`, `AGENTS.md`, `rules/`, `skills/` |
| OpenCode | `~/.config/opencode` | `~/.config/opencode` | `opencode.json`, `plugins/` |
| Grok | `~/.grok` | `~/.grok` | `config.toml` / `user-settings.json` / `auth.json` (whichever exists) |

Re-sync after changing host config with `aidc sync-config <claude|codex|opencode|grok|all>`.
Because the seed is read-only and only specific files are copied, the agents
reuse your existing logins without the container being able to write back to the
host. After interactive login *inside* the container, credentials persist in the
named volume across restarts (and are wiped by `aidc destroy`).

**2. Environment-variable passthrough.** For headless/API-key auth, `aidc`
forwards a fixed set of host env vars into the agent process when present:
`ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `OPENAI_API_KEY`,
`CURSOR_API_KEY`, `OPENROUTER_API_KEY`, `OPENAI_BASE_URL`. OpenCode and Grok can
both speak to multiple providers, so these shared keys let all the agents reuse
the same host credentials. For xAI specifically, either log in interactively
(persisted in `~/.grok`) or export the xAI key on the host and add it to the
passthrough list in `AIDC_PASSTHROUGH_ENV_KEYS` (`lib/aidc.sh`) before launching.

## Agent guardrails: rtk

The image ships [`rtk`](https://github.com/rtk-ai/rtk) (Rust Token Killer — a token-saving CLI proxy that rewrites commands like `git status` → `rtk git status` via the Claude Code `PreToolUse`/`Bash` hook, typically cutting 60–90% of the tokens dev operations cost).

rtk is auto-initialised the first time a fresh `claude_home` volume is created: `bootstrap-state.sh init` runs `rtk init --global --auto-patch --hook-only` (non-interactive; installs just the hook, no `RTK.md`/`CLAUDE.md` rewrite since both are seeded from the host), then drops a marker at `~/.claude/.aidc-agent-hooks-installed` so it isn't rerun on every container restart. `aidc destroy -f` wipes the volume and the marker, so the next `aidc up` re-applies the hook cleanly.

The host's own agent hooks — SafeDep's `gryph` audit layer, and `cot` (whose command is a macOS-only binary path) — are host-side concerns: in-container transcripts auto-sync back to the host on container start and exit, so observability happens there rather than in the VM. `bootstrap-state.sh` strips those host-only hook entries from the seeded `settings.json` on every sync (preserving rtk and any user hooks), so the VM never carries hooks that can't run inside it.

Verify:

```bash
aidc exec -- rtk --version
aidc exec -- rtk gain                                                     # token savings so far
aidc exec -- cat /home/vscode/.claude/settings.json | jq '.hooks // {}'   # just the rtk PreToolUse/Bash hook
```

## Optional: egress firewall

Default-deny outbound with an allowlist (Anthropic, OpenAI, Z.ai, OpenRouter, GitHub, npm, PyPI, SafeDep, OSV, semgrep.dev). All ports are open to the Tailscale CGNAT range (`100.64.0.0/10`) so tailnet peers stay reachable.

```bash
echo 'AIDC_ENABLE_EGRESS_FIREWALL=1' >> .ai-container/project.env
aidc rebuild
```

Extend the allowlist via `.ai-container/firewall-allowlist.txt` (one hostname per line). Hostnames resolve at container start; restart to refresh.
