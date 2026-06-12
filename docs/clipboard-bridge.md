# Image paste (clipboard bridge)

Claude Code in the container reads the host's macOS clipboard via a small Unix-socket bridge. PNG bytes from `pbpaste` are proxied; `pbpaste`, `xclip`, and `wl-paste` inside the container all hit the same shim.

> **Off by default.** The bridge is opt-in. Unless you enable it, aidc mounts an empty directory at `/host-clipboard`, so no host clipboard socket is reachable from any container. Enabling it is a two-part action: run the host-side server (below) **and** create the container with the mount turned on.

## Enable the mount

The clipboard socket is wired into the container at (re)create time, so the toggle lives on `aidc up` / `aidc rebuild`:

```bash
aidc up --clipboard        # fresh container with the bridge mounted
aidc rebuild --clipboard   # re-create an existing container with it mounted
```

To make it stick for a repo without passing the flag each time, persist it in `.ai-container/project.env`:

```bash
echo 'AIDC_ENABLE_CLIPBOARD=1' >> .ai-container/project.env
aidc rebuild
```

Because the mount is fixed for a container's lifetime, enabling (or disabling) it on an already-running container requires `aidc rebuild` — a plain `aidc claude` will not change it. The `--clipboard` flag passed to `aidc up`/`rebuild` overrides whatever `project.env` says for that invocation.

## One-time setup

The server lives at `<aidc-repo>/bin/aidc-clipboard-server`. Pick how you want to run it.

**Foreground in a terminal tab** (simplest, restart it after reboot):

```bash
~/path/to/aidc-repo/bin/aidc-clipboard-server
```

Leave that tab open while you work.

**LaunchAgent (auto-starts on login, recommended):**

```bash
AIDC_REPO="$(cd ~/path/to/aidc-repo && pwd -P)"
mkdir -p ~/Library/LaunchAgents
cat > ~/Library/LaunchAgents/io.aidc.clipboard.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>io.aidc.clipboard</string>
  <key>ProgramArguments</key>
  <array>
    <string>$AIDC_REPO/bin/aidc-clipboard-server</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$HOME/.config/aidc/clipboard/server.log</string>
  <key>StandardOutPath</key><string>$HOME/.config/aidc/clipboard/server.log</string>
</dict>
</plist>
EOF
launchctl unload ~/Library/LaunchAgents/io.aidc.clipboard.plist 2>/dev/null
launchctl load ~/Library/LaunchAgents/io.aidc.clipboard.plist
```

Disable with `launchctl unload ~/Library/LaunchAgents/io.aidc.clipboard.plist`.

## Verify

```bash
# host
ls -la ~/.config/aidc/clipboard/clipboard.sock   # should be a socket (srwx------)

# screenshot something, then inside the container
aidc exec -- pbpaste | file -        # should say "PNG image data"
```

In Claude Code: `Cmd+Shift+4` to screenshot to file *or* `Cmd+Shift+Ctrl+4` to copy to clipboard, then in Claude Code press `Ctrl+V` (terminal paste) — it pulls the PNG via the shim.

## Trust boundary

When the bridge is enabled for a container, any process inside *that* container can read your host clipboard at any moment while the server runs. The mount is per-container and opt-in (see [Enable the mount](#enable-the-mount)), so containers created without `--clipboard` / `AIDC_ENABLE_CLIPBOARD=1` have no access at all. Only PNG-preferred bytes are exposed (so text/passwords in the clipboard aren't returned in plain text — `pbpaste -Prefer png` returns the text only if no image is present). If that's still too much, kill the LaunchAgent and only run the server when actively pasting.
