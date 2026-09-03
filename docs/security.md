# Security tooling

For aidc's own vulnerability-disclosure policy, see [`/SECURITY.md`](../SECURITY.md). This page documents the scanners and guardrails baked into every aidc container.

## `aidc scan` — one command, the right scanners

`aidc scan` (host) / `aidc-scan` (inside the container, on PATH) runs the
right scanners for what actually changed, so a one-line fix costs seconds and
a dependency bump gets the full treatment:

```bash
aidc scan                 # files changed vs HEAD + untracked (the default)
aidc scan --staged        # the git index
aidc scan --all           # whole repo
aidc scan src/thing.py    # exactly these paths
aidc scan --json          # machine-readable (used by tooling/hooks)
```

Selection rules: **semgrep** (WARNING+ERROR) and **gitleaks** always;
**shellcheck** when shell files are in scope; **bandit** (medium+) for Python
files; **gosec** when Go code changed; **cargo-audit** / **bundle-audit** /
**npm audit** when the matching dependency files changed; **vet** and the
**SBOM/license gate** only when manifests or the LICENSE changed. Missing
scanners are reported as skipped, never fatal. Exit 0 = clean, 1 = findings
above LOW, 2 = usage error.

The implementation is the scaffolded `.devcontainer/scripts/aidc-scan.sh`
(aidc-managed, updated by `aidc upgrade`); the container bootstrap symlinks
it to `~/.local/bin/aidc-scan`. The seeded agent guardrails
(CLAUDE.md/AGENTS.md) instruct agents to run it before declaring work done.
The per-scanner commands below remain valid for manual use.

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

- `scripts/ci/aidc-sbom-code.sh` — code-level SBOM in **both** CycloneDX (`code.cdx.json`) and SPDX (`code.spdx.json`), from one `syft` catalog so the two stay consistent.
- `scripts/ci/aidc-sbom-image.sh` — build-time SBOM (`image.cdx.json`, `image.spdx.json`) from `AIDC_IMAGE_REF`. No-op when unset (projects with no Docker setup).
- `scripts/ci/aidc-sbom-diff.sh` — diffs the code vs build SBOMs by component (added / removed / version-changed) into `diff.json`, so you can see exactly what the image build added over the source manifests.
- `scripts/ci/aidc-license-check.sh` — the license gate. Resolves the project's own license (SPDX id from the `LICENSE` file or a manifest), builds a dependency license inventory from the SPDX SBOM, and flags any dependency whose license conflicts with the project license per `license-matrix.tsv`. Deterministic and offline; optionally enriched by `vet` when `AIDC_LICENSE_USE_VET=1`.
- `scripts/ci/aidc-sbom-all.sh` — orchestrates all of the above; the single entry point any CI calls.

**From the aidc CLI:**

```bash
aidc sbom                       # full pipeline (code + image + diff + license check)
AIDC_IMAGE_REF=myapp:dev aidc sbom   # also scan a built image + diff against code
aidc licenses                   # license check only, warn mode (fast dev-loop check)
aidc licenses --fail            # exit non-zero on a conflict (as CI would)
```

**As early as possible.** The license check is meant to surface conflicts before they land. Three surfaces, all calling `aidc-license-check.sh`:

1. Dev loop — `aidc licenses` (warns; exit 0).
2. Agents — the "Security guardrails" block tells agents to run it when dependencies or the license change.
3. Pre-commit — opt-in; drop this into `.git/hooks/pre-commit` (not auto-installed):

   ```bash
   #!/usr/bin/env bash
   # Warn on license conflicts when a manifest or LICENSE changes.
   if git diff --cached --name-only | grep -Eq '(^|/)(package\.json|go\.mod|requirements\.txt|pyproject\.toml|Cargo\.toml|Gemfile|composer\.json|LICENSE)'; then
     ./scripts/ci/aidc-license-check.sh || true
   fi
   ```

4. CI — the scaffolded `.github/workflows/sbom.yml` (and the equivalent for any CI) runs `aidc-sbom-all.sh` with `AIDC_LICENSE_MODE=fail`.

**Tuning the policy.** `license-matrix.tsv` is TAB-separated `project-license <TAB> conflicting-dep-license` rows; `*` in the project column matches any project. The shipped default is conservative (permissive projects pulling in strong copyleft; AGPL flagged everywhere) and is **not legal advice** — edit it for your project. Note the check is deliberately conservative with dual-license expressions like `(MIT OR GPL-2.0-only)`: it flags the row if *any* branch conflicts, so review those by hand.

## Scan-hook enforcement (Claude Code)

The "run `aidc-scan` before declaring done" guardrail is enforced
**mechanically** for Claude Code: the container bootstrap seeds a Stop hook
(`.devcontainer/scripts/aidc-scan-hook.sh`) into the agent's
`settings.json`. When the agent tries to finish with findings above LOW in
the changed files, the stop is blocked and the findings are fed back to the
agent to fix.

Designed to be invisible when things are fine:

- **Fails open.** A missing scanner, a broken script, or any infrastructure
  error lets the agent finish — the hook must never make the agent unusable.
  Errors are logged, not enforced.
- **Debounced.** A tree already scanned clean is not re-scanned; no changes,
  no scan.
- **Loop-guarded.** A stop that is already continuing from a blocked stop is
  never blocked again (`stop_hook_active`).
- **Opt-out**: `AIDC_ENFORCE_SCAN_HOOK=0` (project.env or config.env) removes
  the hook on the next container start.

Outcomes log to `.ai-container/scan-hook.log`; `aidc insights` summarizes
them (clean passes / blocked / infra errors). Coverage matrix: Claude Code —
enforced via hook; codex/opencode/grok — prose guardrail in AGENTS.md only
(their runtimes lack an equivalent hook point today).

## MCP servers

Treat third-party MCP servers as supply chain: they run inside the container
with full workspace access. aidc pins `enableAllProjectMcpServers: false` in
the seeded Claude settings (when the key is absent), so servers declared in a
project's `.mcp.json` require explicit approval instead of auto-starting.
When using any external MCP server, consider enabling the egress firewall
and allowlisting only the hosts it needs.

## Agent-enforced guardrails

The scaffold writes a "Security guardrails (non-negotiable)" block into `CLAUDE.md` and `AGENTS.md` inside the aidc-managed marker. It instructs agents to run the relevant scanners on every code change and fix findings above LOW before declaring work complete. User-edited content outside the markers is preserved on scaffold refresh.

## Supply-chain guardrails (always on)

The container ships with SafeDep's [`pmg`](https://github.com/safedep/pmg) and [`vet`](https://github.com/safedep/vet) baked in. `pmg setup install` runs at image build **before any user-level package install**, and interception rides on the `~/.pmg/bin` PATH shims — which are first on the image `ENV PATH` for both build and runtime. It is deliberately **not** dependent on the shell aliases pmg also writes to `~/.zshrc`/`~/.bashrc`: Docker build `RUN` steps and exec'd agent subprocesses never source rc files, so only the PATH shims reliably gate package managers. The shims intercept `npm`, `pnpm`, `yarn`, `bun`, `npx`, `pnpx`, `pip`, `pip3`, `uv`, and `poetry` — including subprocess calls from agents (Claude, Codex, OpenCode, Grok, Cursor Agent). Malicious packages are blocked before install.

The coding agents themselves are installed as **native prebuilt binaries**, not `npm install -g`, so there is no agent-install step for pmg to vet and no Node runtime dependency for the agents. The `NPM_CONFIG_*` hardening in the image still governs any npm the agents or project toolchains invoke at runtime, which the pmg shims gate.

Run scans by hand with `aidc exec -- vet scan -D /workspace`. Re-run `pmg setup doctor` inside the container to verify wiring (`aidc exec -- pmg setup doctor`). To confirm interception is alias-independent, check that the shim wins without sourcing rc files: `aidc exec -- bash -c 'command -v npm'` should resolve under `~/.pmg/bin`.

If the egress firewall is enabled, the allowlist already includes `api.safedep.io`, `vetpkg.dev`, `osv.dev`, and `semgrep.dev`.

## Container hardening

The default container is deliberately **unrestricted for normal development**
— sudo works, ping works, no capability surprises. Hardening beyond that is
layered and conditional:

- **Capabilities**: the base compose file adds none (Docker's default set
  only). `NET_ADMIN`/`NET_RAW` — needed solely by the egress firewall's
  iptables/ipset init — are granted through `compose.firewall.yaml`, which
  aidc adds to the compose invocation only when
  `AIDC_ENABLE_EGRESS_FIREWALL=1`.
- **Fork-bomb guard**: `pids_limit` defaults to 4096 (invisible in normal
  use). Override with `AIDC_PIDS_LIMIT`.
- **Memory / CPU**: unlimited by default; cap per project or host-wide with
  `AIDC_MEM_LIMIT` (e.g. `8g`) and `AIDC_CPU_LIMIT` (e.g. `4`).
- **no-new-privileges** (opt-in, `AIDC_NO_NEW_PRIVILEGES=1`): blocks all
  privilege escalation inside the container via `compose.hardened.yaml`.
  Trade-off: setuid stops working, so interactive `sudo` inside the container
  is gone, and it cannot be combined with the egress firewall (whose init
  needs runtime sudo) — aidc warns and skips it when both are set.

All knobs live host-wide in `~/.config/aidc/config.env` or per project in
`.ai-container/project.env` (per-project wins). Note for VS Code users: the
`devcontainer.json` flow uses the base compose file only — the conditional
overrides apply on the `aidc` CLI path.

## Exposing the opencode web UI (`aidc opencode-web`)

`aidc opencode-web` runs opencode's browser UI (`opencode web`) inside the
container. This is the **only** aidc feature that publishes a container port to
the host, so its posture is deliberately conservative:

- **Loopback-only host publish.** The `compose.opencode-web.yaml` override (added
  only when `AIDC_OPENCODE_WEB=1`, which `aidc opencode-web` sets) publishes
  `127.0.0.1:<port>:<port>` — the host's own browser can reach it, but the LAN
  cannot. opencode itself binds `0.0.0.0` *inside* the container, which is
  required for the forwarded port to reach it; keeping the **host** publish on
  `127.0.0.1` is what keeps the agent off the network.
- **Auth on by default.** A random `OPENCODE_SERVER_PASSWORD` is generated,
  delivered to the container by env-key reference (never on any argv), and
  printed once for you to use. Export your own `OPENCODE_SERVER_PASSWORD`
  beforehand to pin it; `--username` overrides the default `opencode` user.
- **`--no-auth`** removes the password. It is safe *only* because the publish is
  loopback-only; do not pair it with any host-side reverse proxy or port
  re-forward that would widen the exposure.
- **Port default 4096** (`--port N` or `AIDC_OPENCODE_WEB_PORT`; validated to
  1024–65535). Opting in (re)creates the container to attach the port, and a
  later plain `aidc <tool>` recreates it back without the port — the same
  ephemeral-override behavior as the firewall/hardened files above.

## Image supply chain

Everything fetched during the image build is pinned; nothing installs from a
floating branch or unpinned `latest`:

- **Base images** are pinned by multi-arch digest (`FROM …@sha256:…`).
- **CLI tools** — `git-delta`, `pmg`, `vet`, `trufflehog`, `gitleaks`, `syft`,
  `grype`, `rtk` — are downloaded as **versioned release artifacts and verified
  against a SHA256 recorded in the Dockerfile** (per-arch `ARG *_SHA256_AMD64` /
  `*_SHA256_ARM64`). A checksum mismatch fails the build. The shared
  `aidc-fetch-verified` helper in the Dockerfile implements the
  download-and-verify step.
- **Coding agents** are version-pinned through each vendor's installer, which
  is fetched to a file and executed (never piped): `claude` (positional
  version; the installer verifies the binary against its manifest SHA256),
  `codex` (`--release`, artifacts from the vendor's GitHub releases),
  `opencode` (`VERSION` env, GitHub releases), `grok` (positional version).

**Documented exceptions** (no pinnable artifact offered by the vendor):

- `cursor-agent` — the `cursor.com/install` script offers no version pin; the
  installed version is logged during the build (`cursor-agent --version`).
- `grok` — version-pinned, but the vendor publishes no artifact checksums
  (TLS + version pin only).
- `rustup` (only when the Rust toolchain is auto-detected) — installed via the
  official `sh.rustup.rs` bootstrap, which self-verifies its downloads.
- Debian/NodeSource packages — verified by apt's GPG signature chain instead.

**Bumping pins:** run `scripts/update-pins.sh` (prints fresh `ARG` lines from
the vendors' latest releases and checksum files; `--write` applies them to
`templates/devcontainer/Dockerfile.tmpl`), rebuild, and commit. Ad-hoc
`latest` overrides (e.g. `VET_VERSION=latest` as a build arg) still work but
**skip checksum verification with a loud build-log warning** — never commit
one.

CI cross-checks the supply chain from both ends: the e2e workflow lints the
scaffolded Dockerfile (`docker build --check`), and the `image-scan` job in
`sbom.yml` builds the image, asserts each pinned tool reports its pinned
version, and scans the result with grype.

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

**How the token reaches the agent (file delivery).** The full path is:
Keychain → aidc's process (only for the duration of the run) → the exec's
**stdin** → a `0600` tmpfs file (`/dev/shm/aidc-oauth-token`) inside the
container → imported into the agent process's environment and the file
deleted at launch. The token therefore never appears on any command line, in
`docker inspect` exec metadata, or in the forwarded `-e` env args. A process
inside the container running as the same user *can* still read the agent
process's environment (`/proc/<pid>/environ`) — that is inherent to the agent
consuming an env var — but the exposure window and surface are much smaller
than env passthrough. Set `AIDC_TOKEN_DELIVERY=env` to restore the legacy
`-e` passthrough (aidc also falls back to it automatically, with a warning,
if file delivery fails).

**Claude profile files are required to be `0600`.** `aidc claude --profile X`
refuses to load a profile env file with looser permissions (these files carry
API keys); the error names the exact `chmod` to run. Profile-sourced
variables are scrubbed from aidc's own environment as soon as the agent
exits.

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

The firewall is **opt-in by design and stays that way** — the default aidc
container runs with an open network. `aidc status` shows the current posture
(`firewall: off (open network, default)` / `on (default-deny allowlist)`)
without nagging either way.

```bash
echo 'AIDC_ENABLE_EGRESS_FIREWALL=1' >> .ai-container/project.env
aidc rebuild
```

What "on" enforces:

- **IPv4**: only ports 443/80 to allowlisted hosts (plus the Tailscale range).
- **IPv6**: dropped entirely (loopback + established excepted). The allowlist
  is IPv4-only, so without this a v6-capable network would bypass it.
- **DNS**: port-53 egress is restricted to the resolvers in
  `/etc/resolv.conf` (Docker's embedded `127.0.0.11` rides the loopback
  accept). DNS-over-HTTPS to a non-allowlisted IP is blocked like any other
  443 traffic; DoH via an *allowlisted* host can hide which names you
  resolve, but cannot reach non-allowlisted addresses.
- **Capabilities**: `NET_ADMIN`/`NET_RAW` are granted to the container only
  when the firewall is enabled (see § Container hardening).

**Allowlist file** — `.ai-container/firewall-allowlist.txt`, one hostname per
line; `#` starts a comment, blank lines are ignored:

```text
# internal package mirror
artifacts.example.com
sentry.example.com   # error reporting
```

**DNS refresh**: allowlisted names are re-resolved every
`AIDC_FIREWALL_REFRESH_SECONDS` (default 300; `0` disables) and swapped in
atomically, so CDN/IP rotation doesn't strand allowed hosts. Refresh events
log to `/var/log/aidc-firewall.log` inside the container. A manual refresh:
`aidc exec -- sudo /workspace/.devcontainer/scripts/init-firewall.sh refresh`.
