# Security policy

## Scope

`aidc` provisions and runs container images that hold API tokens (Anthropic, Z.ai, OpenRouter, self-hosted Anthropic-compatible servers) and execute AI coding agents with workspace and network access. Relevant attack surfaces:

- the host-side launcher (`bin/aidc`, `lib/aidc.sh`, `install.sh`) and the templates it writes into a user's repo (`templates/`)
- the host clipboard bridge (`bin/aidc-clipboard-server`) and its Unix-socket protocol
- container hardening defaults (egress firewall, supply-chain shims, scanner pre-installs)
- the Claude-profile alias generation in `~/.local/bin`

Bugs in `claude`, `codex`, `opencode`, `cursor-agent`, `pmg`, `vet`, `rtk`, or the upstream devcontainer base image are out of scope — report those to their respective projects.

## Supported versions

`aidc` is pre-1.0 and rolling-release. Only `main` is supported; fixes land there. Tagged releases are best-effort.

## Reporting a vulnerability

**Do not open a public issue for security bugs.**

Preferred: open a private GitHub Security Advisory at <https://github.com/cyfinoid/aidc/security/advisories/new>.

Alternative: email <security@cyfinoid.com> with `[aidc]` in the subject. Include:

- a description of the issue and impact
- reproduction steps or a proof-of-concept
- the commit hash you tested against
- any suggested mitigation

You should get an acknowledgement within 5 business days. Coordinated disclosure timeline is negotiable; default is 90 days from acknowledgement.

## Out of scope

- Findings that require an attacker to already have root on the host or full write access to the user's home directory.
- Token leakage caused by the user committing `.env` files into their own repo (the scaffold ignores them; user override is user-owned risk).
- Denial of service against the local Docker daemon.
- Issues only reproducible against unsupported architectures or non-macOS hosts.
