#!/bin/bash
# Install cc-notify: phone + desktop notifications for NTM agent sessions
# Run: ./install.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== cc-notify installer ==="

# 1. Install config
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cc-notify"
mkdir -p "$CONFIG_DIR"
if [[ ! -f "$CONFIG_DIR/config.env" ]]; then
    cp "$SCRIPT_DIR/config.env" "$CONFIG_DIR/config.env"
    echo "Created $CONFIG_DIR/config.env — EDIT THIS with your settings"
else
    echo "Config already exists at $CONFIG_DIR/config.env (skipped)"
fi

# 2. Install scripts to ~/.local/bin
mkdir -p "$HOME/.local/bin"
cp "$SCRIPT_DIR/scripts/ntfy-notify-common.sh" "$HOME/.local/bin/"
cp "$SCRIPT_DIR/scripts/ntm-notify-monitor.sh" "$HOME/.local/bin/"
cp "$SCRIPT_DIR/scripts/tmux-mobile-attach.sh" "$HOME/.local/bin/"
cp "$SCRIPT_DIR/scripts/ntfy-broadcast-status.sh" "$HOME/.local/bin/"
cp "$SCRIPT_DIR/scripts/ntfy-health-check.sh" "$HOME/.local/bin/"
cp "$SCRIPT_DIR/scripts/ntm-dashboard-server.py" "$HOME/.local/bin/"
chmod +x "$HOME/.local/bin/ntfy-notify-common.sh"
chmod +x "$HOME/.local/bin/ntm-notify-monitor.sh"
chmod +x "$HOME/.local/bin/tmux-mobile-attach.sh"
chmod +x "$HOME/.local/bin/ntfy-broadcast-status.sh"
chmod +x "$HOME/.local/bin/ntfy-health-check.sh"
chmod +x "$HOME/.local/bin/ntm-dashboard-server.py"
echo "Installed scripts to ~/.local/bin/"

# 2b. Install dashboard HTML
mkdir -p "$HOME/.local/share/ntm-dashboard"
cp "$SCRIPT_DIR/dashboard/status.html" "$HOME/.local/share/ntm-dashboard/"
echo "Installed dashboard to ~/.local/share/ntm-dashboard/"

# 3. Clean up old silence handler if present
if [[ -f "$HOME/.local/bin/ntm-silence-handler.sh" ]]; then
    rm -f "$HOME/.local/bin/ntm-silence-handler.sh"
    echo "Removed deprecated ntm-silence-handler.sh"
fi

# 4. Install Claude Code hooks
HOOKS_DIR="$HOME/.claude/hooks"
mkdir -p "$HOOKS_DIR"
cp "$SCRIPT_DIR/hooks/tmux-notify.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/hooks/ntfy-cooldown-clear.sh" "$HOOKS_DIR/"
chmod +x "$HOOKS_DIR/tmux-notify.sh"
chmod +x "$HOOKS_DIR/ntfy-cooldown-clear.sh"
echo "Installed CC hooks to $HOOKS_DIR/"

# 5. Set up Claude Code hooks config if not already present
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
if [[ -f "$CLAUDE_SETTINGS" ]]; then
    if grep -q "tmux-notify.sh" "$CLAUDE_SETTINGS" 2>/dev/null; then
        echo "Claude Code hooks already configured (skipped)"
    else
        echo ""
        echo "NOTE: Add this to your Claude Code settings ($CLAUDE_SETTINGS):"
        echo '  "hooks": {'
        echo '    "Notification": ['
        echo '      {'
        echo '        "matcher": "",'
        echo "        \"hooks\": [\"$HOOKS_DIR/tmux-notify.sh\"]"
        echo '      }'
        echo '    ]'
        echo '  }'
    fi
else
    echo "No Claude Code settings found — configure hooks manually"
fi

# 6. Install systemd user units (optional auto-start)
SYSTEMD_DIR="$HOME/.config/systemd/user"
mkdir -p "$SYSTEMD_DIR"
cp "$SCRIPT_DIR/systemd/ntm-notify-monitor.service" "$SYSTEMD_DIR/"
cp "$SCRIPT_DIR/systemd/ntm-serve.service" "$SYSTEMD_DIR/"
cp "$SCRIPT_DIR/systemd/ntm-dashboard.service" "$SYSTEMD_DIR/"
if [[ -f "$SCRIPT_DIR/systemd/ft-watch.service" ]]; then
    cp "$SCRIPT_DIR/systemd/ft-watch.service" "$SYSTEMD_DIR/"
fi
systemctl --user daemon-reload 2>/dev/null || true
echo "Installed systemd units to $SYSTEMD_DIR/"

echo ""
echo "=== Next steps ==="
echo "1. Edit $CONFIG_DIR/config.env with your machine settings"
echo "2. Start services:"
echo "   systemctl --user enable --now ntm-notify-monitor"
echo "   systemctl --user enable --now ntm-serve"
echo "   systemctl --user enable --now ntm-dashboard"
echo "   systemctl --user enable --now ft-watch  # if ft is installed"
echo "3. Subscribe in ntfy app to your topic on your server"
echo "4. Run health check: ntfy-health-check.sh --send-test"
echo "5. Dashboard: http://<hostname>:7338/"
echo ""
echo "Done!"
