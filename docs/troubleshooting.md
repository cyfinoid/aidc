# Troubleshooting

Start with **`aidc doctor`** — it diagnoses most of what's on this page and
names the fix. Each entry below: symptom → cause → fix.

## Docker

**`docker: CLI not found` / `daemon not responding` (doctor FAIL)**
Docker isn't installed or isn't running. Start Docker Desktop / OrbStack /
Colima; `docker info` should succeed before any `aidc` command that touches
containers.

**`container name already in use` on `aidc up`**
A previous container wasn't cleaned up (e.g. after a crash).
`aidc down` then `aidc up`; if that fails, `docker rm -f <name>` (find it
with `aidc status`).

**Build fails at a checksum line (`aidc-fetch-verified: checksum mismatch`)**
A pinned artifact changed upstream (or a proxy corrupted the download).
Re-run once (transient network); if it persists, verify upstream with
`scripts/update-pins.sh` in the aidc checkout and update the pins — a real
mismatch without a new release is a supply-chain red flag, treat it as such.

## PATH & install

**`aidc: command not found`**
`~/.local/bin` isn't on `PATH`. Add
`export PATH="$HOME/.local/bin:$PATH"` to your shell rc. `aidc doctor`
warns about this.

**`aidc update` says `fast-forward pull failed`**
Your aidc checkout has local commits or diverged from `origin/main`.
`git -C <aidc-checkout> status`, stash/rebase as you prefer, re-run.

## Claude auth (macOS Keychain)

**`aidc claude` drops into interactive login every time**
No long-lived token available. Store one once:
`security add-generic-password -U -a "$USER" -s claude-code-oauth-token -w "$(claude setup-token | grep sk-ant | tr -d '[:space:]')"`
— see README "Claude authentication". `aidc doctor` shows whether the
Keychain item exists.

**macOS keeps prompting to allow `security`**
Click **Always Allow** on the Keychain prompt (it's the `security` CLI
reading the token item on aidc's behalf).

**`profile file has loose permissions`**
Profile env files carry API keys and must be `0600`. The error names the
exact `chmod` to run.

## Scaffold

**`scaffold is out of date … run 'aidc upgrade'`**
Informational: aidc was updated and this project's scaffold predates it.
`aidc upgrade` shows a diff before changing anything; your edits to managed
files are backed up under `.ai-container/backup/`.

**`corrupt project env`**
`.ai-container/project.env` no longer parses. Restore it from a backup
(`.ai-container/backup/`), or `aidc destroy -f --purge-scaffold` + `aidc init`
(re-add any per-project settings afterwards).

**I edited `.devcontainer/Dockerfile` and want to keep the change**
Managed files are aidc-owned and `aidc upgrade` will offer to rewrite them
(with a backup). Persistent per-project build customization belongs in
`.devcontainer/project-setup.sh` — user-owned, never rewritten.

## Firewall (opt-in)

**A host the project needs is blocked**
Add its hostname to `.ai-container/firewall-allowlist.txt` (one per line,
`#` comments) and restart the container — or run
`aidc exec -- sudo /workspace/.devcontainer/scripts/init-firewall.sh` to
re-apply without a restart. Names re-resolve every
`AIDC_FIREWALL_REFRESH_SECONDS` (default 300).

**`firewall init failed (sudo required)`**
The container is running with `AIDC_NO_NEW_PRIVILEGES=1`, which disables
sudo. The two features are mutually exclusive; aidc normally warns and skips
NNP when both are set — check `.ai-container/project.env`.

## Clipboard bridge (opt-in)

**`pbpaste` in the container prints `connection refused`**
The host clipboard server isn't running, or the container was created
without `--clipboard`. See `docs/clipboard-bridge.md`; recreate with
`aidc rebuild --clipboard`.

## Sessions & transcripts

**Host `/insights` doesn't show container sessions**
Sessions auto-sync on container start, agent exit, `down`, and `destroy`
(`AIDC_AUTO_SYNC_SESSIONS=0` disables). Manual catch-up:
`aidc sync-sessions` (defaults to all agents).

## Still stuck

`aidc doctor` output plus the failing command's output makes a good issue
report: <https://github.com/cyfinoid/aidc/issues> (see `SECURITY.md` for
vulnerabilities — do not open public issues for those).
