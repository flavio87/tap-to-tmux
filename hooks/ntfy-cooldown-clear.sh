#!/bin/bash
# Clear ntfy notification cooldown when user interacts with a CC session.
# Added to UserPromptSubmit hook so that after you respond, the next idle
# event will trigger a fresh notification.
INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)
PROJECT=""
if [[ -n "$CWD" ]]; then
    PROJECT=$(basename "$CWD")
fi

COOLDOWN_FILE="/tmp/cc-notify-cooldown/${PROJECT:-unknown}"
if [[ -f "$COOLDOWN_FILE" ]]; then
    rm -f "$COOLDOWN_FILE"
    mkdir -p /tmp/cc-notify-logs
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Cooldown cleared for ${PROJECT}" >> /tmp/cc-notify-logs/cooldown-clear.log
fi
exit 0
