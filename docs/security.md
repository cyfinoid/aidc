# Security tooling

For aidc's own vulnerability-disclosure policy, see [`/SECURITY.md`](../SECURITY.md). This page documents the scanners and guardrails baked into every aidc container.

## Always-on scanners

Every aidc image ships with:

- [`semgrep`](https://semgrep.dev) — SAST. Run: `semgrep scan --config auto <paths>`.
- [`gitleaks`](https://github.com/gitleaks/gitleaks) — secret detection. Run: `gitleaks detect --no-banner`.
- [`trufflehog`](https://github.com/trufflesecurity/trufflehog) — secret detection with optional verification.
- [`syft`](https://github.com/anchore/syft) — SBOM generation (CycloneDX + SPDX). Backs `aidc sbom` / `scripts/ci/`.
- [`grype`](https://github.com/anchore/grype) — vulnerability scanning of SBOMs and images.

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
AIDC_SECURITY_TOOLS=checkov
```

Supported: `checkov` (IaC). `syft` and `grype` are now always-on (see above) and `bandit` is auto-installed when Python is detected — listing any of these three is a harmless no-op, kept for back-compat with existing `project.env` files.

## SBOM & license compliance

aidc ships a set of **CI-agnostic** scripts under `scripts/ci/` that generate SBOMs and gate license conflicts. They are plain bash, configured entirely by environment variables, and emit meaningful exit codes — so the *same* scripts run in the dev loop, a pre-commit hook, GitHub Actions, Jenkins, GitLab CI, or anything else. The CI config is just a thin caller; all logic lives in the scripts. `aidc init` scaffolds them into every project (the reusable scripts refresh on scaffold; `license-matrix.tsv` is yours to edit and is never overwritten).

**The contract (env in / exit code out):**

| Env var | Default | Meaning |
|---|---|---|
| `AIDC_SBOM_DIR` | `./sbom` | Output directory for all artifacts |
| `AIDC_SBOM_SRC` | `.` | Source tree to catalog for the code-level SBOM |
| `AIDC_IMAGE_REF` | *(unset)* | Built image to scan for the build-time SBOM; unset ⇒ skip |
| `AIDC_LICENSE_MODE` | `warn` | `warn` (report, exit 0) or `fail` (exit 1 on conflict) |
| `AIDC_LICENSE_MATRIX` | `scripts/ci/license-matrix.tsv` | License compatibility policy |
| `AIDC_PROJECT_LICENSE` | *(auto)* | Override the detected project license (SPDX id) |
| `AIDC_LICENSE_USE_VET` | `0` | `1` also runs `vet` license enrichment (needs network) |

Exit codes: `0` ok, `1` policy violation in `fail` mode, `2` tool missing / usage error.

**The scripts:**

- `scripts/ci/sbom-code.sh` — code-level SBOM in **both** CycloneDX (`code.cdx.json`) and SPDX (`code.spdx.json`), from one `syft` catalog so the two stay consistent.
- `scripts/ci/sbom-image.sh` — build-time SBOM (`image.cdx.json`, `image.spdx.json`) from `AIDC_IMAGE_REF`. No-op when unset (projects with no Docker setup).
- `scripts/ci/sbom-diff.sh` — diffs the code vs build SBOMs by component (added / removed / version-changed) into `diff.json`, so you can see exactly what the image build added over the source manifests.
- `scripts/ci/license-check.sh` — the license gate. Resolves the project's own license (SPDX id from the `LICENSE` file or a manifest), builds a dependency license inventory from the SPDX SBOM, and flags any dependency whose license conflicts with the project license per `license-matrix.tsv`. Deterministic and offline; optionally enriched by `vet` when `AIDC_LICENSE_USE_VET=1`.
- `scripts/ci/sbom-all.sh` — orchestrates all of the above; the single entry point any CI calls.

**From the aidc CLI:**

```bash
aidc sbom                       # full pipeline (code + image + diff + license check)
AIDC_IMAGE_REF=myapp:dev aidc sbom   # also scan a built image + diff against code
aidc licenses                   # license check only, warn mode (fast dev-loop check)
aidc licenses --fail            # exit non-zero on a conflict (as CI would)
```

**As early as possible.** The license check is meant to surface conflicts before they land. Three surfaces, all calling `license-check.sh`:

1. Dev loop — `aidc licenses` (warns; exit 0).
2. Agents — the "Security guardrails" block tells agents to run it when dependencies or the license change.
3. Pre-commit — opt-in; drop this into `.git/hooks/pre-commit` (not auto-installed):

   ```bash
   #!/usr/bin/env bash
   # Warn on license conflicts when a manifest or LICENSE changes.
   if git diff --cached --name-only | grep -Eq '(^|/)(package\.json|go\.mod|requirements\.txt|pyproject\.toml|Cargo\.toml|Gemfile|composer\.json|LICENSE)'; then
     ./scripts/ci/license-check.sh || true
   fi
   ```

4. CI — the scaffolded `.github/workflows/sbom.yml` (and the equivalent for any CI) runs `sbom-all.sh` with `AIDC_LICENSE_MODE=fail`.

**Tuning the policy.** `license-matrix.tsv` is TAB-separated `project-license <TAB> conflicting-dep-license` rows; `*` in the project column matches any project. The shipped default is conservative (permissive projects pulling in strong copyleft; AGPL flagged everywhere) and is **not legal advice** — edit it for your project. Note the check is deliberately conservative with dual-license expressions like `(MIT OR GPL-2.0-only)`: it flags the row if *any* branch conflicts, so review those by hand.

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

Only env vars actually set in `aidc`'s own process are forwarded — the value is
read at exec time and lives only for the duration of that `docker compose exec`,
never written into the container image or compose file.

**Narrowing the passthrough per container.** `AIDC_PASSTHROUGH_ENV_KEYS` is a
plain shell array sourced *before* it is consumed, so a host-wide
`~/.config/aidc/config.env` or a single repo's `.ai-container/project.env` can
reassign it to forward fewer keys (or none) into that container:

```bash
# .ai-container/project.env — forward nothing into THIS container
AIDC_PASSTHROUGH_ENV_KEYS=()

# …or a narrowed subset (drop the Claude OAuth token here)
AIDC_PASSTHROUGH_ENV_KEYS=("OPENAI_API_KEY")
```

This also gates the Keychain lookup below — dropping `CLAUDE_CODE_OAUTH_TOKEN`
from the array disables resolving it for that container. The one exception is the
`aidc claude` one-time-login bootstrap (`aidc-bootstrap-claude`), which reads
`CLAUDE_CODE_OAUTH_TOKEN` directly when it is already present.

**On-demand Claude OAuth token (macOS Keychain).** For `aidc claude`, if
`CLAUDE_CODE_OAUTH_TOKEN` is not already in the environment, `aidc` reads it from
the macOS Keychain on demand (service `claude-code-oauth-token`, your `$USER`
account) so the token never has to be exported into every shell via `~/.zshrc`.
Override the service name or disable the lookup with
`AIDC_CLAUDE_OAUTH_KEYCHAIN_SERVICE` (set it empty to disable). The lookup is a
no-op on hosts without the `security` tool. See `docs/claude-profiles.md` for
setup.

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
