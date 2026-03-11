# cc-notify

Phone notifications when Claude Code (or other AI agents) need your attention on a remote server.

You're running Claude Code in tmux on a VPS. You walk away. Claude finishes, or needs permission, or hits an error. **cc-notify sends a push notification to your phone** so you know exactly when to come back — with context about what happened and a tap-to-connect deep link.

## How it works

cc-notify has two notification layers:

1. **Claude Code hook** (`tmux-notify.sh`) — Fires on CC lifecycle events (`Notification`, `Stop`). Extracts context from the session transcript (what task was running, what Claude's last response was). Sends rich notifications with project name, machine name, and context.

2. **NTM agent monitor** (`ntm-notify-monitor.sh`) — Polls [NTM](https://github.com/cyanheads/ntm) health for non-CC agents (Codex, Gemini CLI, etc.) and sends notifications when they go idle or error. Optional — only needed if you run multiple agent types.

Both layers deliver via [ntfy](https://ntfy.sh) (push notifications) and optionally Slack (incoming webhook).

### Notification types

| Event | Title | Priority |
|-------|-------|----------|
| Permission needed | `machine/project [cc]: Permission Needed` | High |
| Waiting for input | `machine/project [cc]: Waiting for Input` | Default |
| Session finished | `machine/project [cc]: Done` | Default |
| NTM agent idle | `machine/project [agent] p0: Idle` | Default |

### Smart deduplication

You get **one notification per project** when something needs attention, then silence until the cooldown expires (24h default). The cooldown resets when you interact with the session — so you'll get notified again next time it's idle.

## Prerequisites

- **Required:** `jq`, `curl`, `tmux`, `python3`
- **Required:** [ntfy](https://ntfy.sh) app on your phone (iOS/Android)
- **Optional:** [NTM](https://github.com/cyanheads/ntm) — needed for the multi-agent monitor
- **Optional:** [Blink Shell](https://blink.sh) — iOS SSH client for tap-to-connect deep links

## Installation

```bash
git clone https://github.com/flavio87/cc-notify.git
cd cc-notify
./install.sh
```

The installer:
1. Copies `config.env` template to `~/.config/cc-notify/config.env`
2. Installs scripts to `~/.local/bin/`
3. Installs Claude Code hooks to `~/.claude/hooks/`
4. Installs systemd user units (optional auto-start daemons)

Then edit your config:

```bash
nano ~/.config/cc-notify/config.env
```

## Configuration

All settings live in `~/.config/cc-notify/config.env`:

| Variable | Required | Description |
|----------|----------|-------------|
| `NTFY_TOPIC` | Yes | Unique topic name for your notification channel. Generate one: `python3 -c "import secrets; print(f'cc-notify-{secrets.token_hex(8)}')"` |
| `MACHINE` | No | Display name in notification titles. Defaults to hostname. |
| `SSH_USER` | No | Username for deep link SSH commands. Defaults to current user. |
| `SSH_HOST` | No | Hostname/IP for deep link SSH commands. Defaults to hostname. |
| `NTFY_SERVER` | No | ntfy server URL. Defaults to `https://ntfy.sh` (public). Set to your self-hosted URL if desired. |
| `BLINK_KEY` | No | Blink Shell x-callback-url key for tap-to-connect on iOS. Leave empty to disable deep links. |
| `SLACK_WEBHOOK_URL` | No | Slack incoming webhook URL for dual delivery. Leave empty to disable. |
| `PROJECTS_DIR` | No | Directory containing your project repos. Defaults to `$HOME/projects`. Used by the NTM monitor for session matching. |

## Claude Code hooks setup

Add to your Claude Code settings (`~/.claude/settings.json`):

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "",
        "hooks": ["~/.claude/hooks/tmux-notify.sh"]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": ["~/.claude/hooks/tmux-notify.sh"]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": ["~/.claude/hooks/ntfy-cooldown-clear.sh"]
      }
    ]
  }
}
```

The `Notification` hook fires on permission prompts and idle events. The `Stop` hook fires when a session finishes. The `UserPromptSubmit` hook clears the cooldown so you'll get notified again next time.

## Starting the services

```bash
# NTM agent monitor (optional — only if you use NTM)
systemctl --user enable --now ntm-notify-monitor

# NTM serve daemon (optional — powers the dashboard)
systemctl --user enable --now ntm-serve

# Status dashboard (optional — web UI at port 7338)
systemctl --user enable --now ntm-dashboard
```

## Health check

Run the built-in health check to verify your setup:

```bash
ntfy-health-check.sh              # check config + tools
ntfy-health-check.sh --send-test  # also send a test notification
```

## Troubleshooting

**No notifications received:**
1. Run `ntfy-health-check.sh --send-test` — does the test notification arrive?
2. Check `NTFY_TOPIC` in your config matches the topic you subscribed to in the ntfy app
3. Check logs: `cat /tmp/cc-notify-logs/tmux-notify.log`

**Duplicate notifications:**
- The cooldown system should prevent these. Check: `ls -la /tmp/cc-notify-cooldown/`
- Default cooldown is 24h. Override with `NTFY_COOLDOWN_SECONDS` in config.

**Deep links not working:**
- Blink Shell deep links require `BLINK_KEY` to be set. Find it in Blink Settings > x-callback-url.
- Other SSH clients: set `SSH_USER` and `SSH_HOST`, then use the notification body to manually SSH in.

**NTM monitor not detecting agents:**
- Verify NTM is installed: `ntm --version`
- Check if sessions are visible: `ntm health --json`
- Logs: `cat /tmp/cc-notify-logs/ntm-notify-monitor.log`

## Project structure

```
hooks/                  # Claude Code lifecycle hooks
  tmux-notify.sh          # Main notification hook (Notification + Stop events)
  ntfy-cooldown-clear.sh  # Cooldown reset on user interaction
scripts/                # Core scripts
  ntfy-notify-common.sh   # Shared library (config, logging, deep links, sending)
  ntm-notify-monitor.sh   # NTM agent polling monitor
  ntm-dashboard-server.py # Status dashboard HTTP server
  ntfy-health-check.sh    # Pipeline health check
  ntfy-broadcast-status.sh # Broadcast status to all subscribers
  tmux-mobile-attach.sh   # SSH helper for mobile deep links
dashboard/              # Web dashboard
  status.html             # Mobile-first status page
systemd/                # Linux systemd user units
  ntm-notify-monitor.service
  ntm-dashboard.service
  ntm-serve.service
  ft-watch.service        # Optional FrankenTerm integration
launchd/                # macOS launchd agents
desktop/                # macOS desktop integration (AppleScript, handlers)
server/                 # Self-hosted ntfy server config (Docker)
config.env              # Configuration template
install.sh              # Installer
```

## Self-hosted ntfy server

If you prefer not to use the public ntfy.sh server, the `server/` directory includes a Docker Compose setup:

```bash
cd server
docker compose up -d
```

Edit `server/server.yml` with your domain, then set `NTFY_SERVER` in your config.

## Optional integrations

- **Blink Shell** (iOS): Tap-to-connect deep links that SSH into the right tmux session and pane. Set `BLINK_KEY` in config.
- **Slack**: Dual delivery via incoming webhook. Set `SLACK_WEBHOOK_URL` in config.
- **FrankenTerm**: File watcher integration via the `ft-watch` systemd unit. See `systemd/ft-watch.service`.
- **NTM**: Multi-agent session management. The monitor script polls NTM health for state transitions. Not required for basic CC notifications.

## License

MIT — see [LICENSE](LICENSE).
