# Cursor with aidc

Cursor's GUI is a desktop app and stays on the host. aidc's job is to make the **execution side** — the terminal, the language servers, the agent's tool calls, anything that runs your code — happen inside the container instead of on your machine.

Two paths, which you can use together:

| Path | What runs where | Use when |
|---|---|---|
| **Reopen in Container** | Cursor GUI on the host, everything it executes in the aidc container | You want the full IDE, editing files with the container's toolchain behind them |
| **`aidc cursor-agent`** | Cursor's CLI agent, entirely in the container | You want the agent without the GUI, like `aidc claude` |

---

## Path 1 — Cursor GUI on the host, execution in the container

`aidc init` already scaffolds the Dev Containers wiring: `.devcontainer/devcontainer.json` points at aidc's `compose.yaml`, service `workspace`, folder `/workspace`, user `vscode`.

```bash
cd /path/to/your/repo
aidc init                 # once per project — writes .devcontainer/
aidc cursor               # opens the host Cursor app on this repo
```

Then in Cursor: **Command Palette → "Dev Containers: Reopen in Container"**.

`aidc cursor` is only a convenience wrapper around `cursor "$workspace"`; opening the folder yourself works identically.

### Why this needs `initializeCommand`

The Dev Containers extension runs `docker compose up` **itself**, without aidc's exported environment. aidc's `compose.yaml` resolves its bind sources from `AIDC_*` variables that have no defaults (`AIDC_WORKSPACE`, `AIDC_DEVCONTAINER_DIR`, `AIDC_GITCONFIG_SOURCE`, every `AIDC_HOST_SEED_*`, …), and the extension also won't build the shared base image or create the external toolchain volume. Left alone, the reopen fails.

So `devcontainer.json` carries:

```json
"initializeCommand": "bash -lc 'aidc up'"
```

It runs **on the host, before the container is created**, and does three things the extension can't: writes `.devcontainer/.env` (the resolved `AIDC_*` values plus `COMPOSE_PROJECT_NAME`), builds the shared base image, and creates the external toolchain volume.

`.devcontainer/.env` is aidc-managed — mode `0600`, regenerated on every `aidc up` / `rebuild` / `rescan`, and git-excluded. **Don't edit or commit it**; change `.ai-container/project.env` instead and re-run `aidc up`.

### If the reopen fails

- **`aidc: command not found` during initializeCommand.** A GUI-launched Cursor on macOS doesn't inherit your shell PATH. `bash -lc` sources your login profile, which normally fixes it; if it doesn't, edit `.devcontainer/devcontainer.json` and replace `aidc` with its absolute path (`which aidc` in a terminal — typically `~/.local/bin/aidc`).
- **Compose errors about empty bind sources.** `.devcontainer/.env` wasn't written. Run `aidc up` in a host terminal and reopen.
- **Cursor and aidc disagree about the container.** The extension can override `COMPOSE_PROJECT_NAME`; `aidc status` shows the name aidc uses.

### Extensions

`devcontainer.json` requests both `anysphere.remote-containers` (Cursor's own fork) and `ms-vscode-remote.remote-containers`, so the same scaffold reopens in Cursor or VS Code.

---

## Path 2 — `cursor-agent` in the container

```bash
aidc cursor-agent             # start Cursor's CLI agent in the container
aidc cursor-agent -- --help   # pass flags through to cursor-agent
```

aidc runs it as `cursor-agent --sandbox disabled -f`: the container is already the isolation boundary, so cursor-agent's own sandbox is redundant.

The binary is only in the image if `cursor-agent` is in the agent set. It is by default (`AIDC_AGENTS=all`), but if you've pinned the set, include it:

```bash
# .ai-container/project.env
AIDC_AGENTS=claude,cursor-agent
```

Then `aidc rebuild` — an existing image fast-starts without the new agent.

> Cursor publishes no version pin for the CLI installer, so it's a documented exception to aidc's pin policy (see `docs/security.md`).

---

## Authentication

**Your host Cursor login cannot be inherited.** The interactive-login token lives in the macOS Keychain, not in a file, so there is nothing for aidc to seed into a Linux container. Only *settings* are seeded: `~/.cursor/cli-config.json` is bind-mounted read-only at `/host-seed/cursor` and copied in at bootstrap.

For the container, use an API key:

```bash
# ~/.config/aidc/config.env  (all projects)  — or  .ai-container/project.env
export CURSOR_API_KEY=...
```

`CURSOR_API_KEY` is in `AIDC_PASSTHROUGH_ENV_KEYS`, so aidc forwards it into the container. See [`docs/security.md`](security.md) for the full token-handling model.

After changing host-side Cursor settings:

```bash
aidc sync-config cursor      # re-seed cli-config.json from the host
```

---

## State and sessions

`~/.cursor` inside the container is the named volume `cursor_agent_home` — **not** `~/.cursor-agent`, which is where the CLI does *not* keep its state. Logins and transcripts therefore survive `aidc down` / `aidc up`, and are removed by `aidc destroy`.

Token-savings tracking is wired: bootstrap writes `~/.cursor/hooks.json` so `rtk` records cursor-agent's savings into the same shared `history.db` as the other agents (`rtk gain`).

Host-side session sync is **not** wired for cursor-agent — its on-disk transcript path is undocumented upstream — so unlike Claude/opencode, cursor transcripts stay in the volume and aren't copied to the host.

---

## Verify it worked

```bash
aidc status                  # shows the /host-seed/cursor mount + container state
aidc shell                   # then, inside:
  cursor-agent --version     # binary present
  ls ~/.cursor/              # cli-config.json seeded, hooks.json wired
```

From a Cursor terminal after "Reopen in Container", `hostname` and `ls /workspace` should show the container, not your host.
