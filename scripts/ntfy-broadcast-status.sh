#!/bin/bash
# One-time broadcast: send a notification for every session needing attention.
# Does NOT write cooldown files, so it won't suppress future real notifications.
# Usage: ntfy-broadcast-status.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/ntfy-notify-common.sh" 2>/dev/null \
    || source "$HOME/.local/bin/ntfy-notify-common.sh" 2>/dev/null \
    || { echo "ERROR: ntfy-notify-common.sh not found"; exit 1; }

ntfy_log INFO "Broadcast status scan starting"

sent=0
for session in $(tmux list-sessions -F '#{session_name}' 2>/dev/null); do
    test -d "${PROJECTS_DIR}/${session}" || continue
    result=$(ntm activity "$session" --json 2>/dev/null)
    test -z "$result" && continue
    test "$result" = "null" && continue

    body=""
    has_attention=0
    while read -r agent; do
        state=$(echo "$agent" | jq -r '.state')
        pane=$(echo "$agent" | jq -r '.pane')
        agent_type=$(echo "$agent" | jq -r '.agent_type')
        if [[ "$state" == "WAITING" || "$state" == "ERROR" ]]; then
            body="${body}p${pane} [${agent_type}]: ${state}
"
            has_attention=1
        fi
    done < <(echo "$result" | jq -c '.agents[]' 2>/dev/null)

    if [[ "$has_attention" == "1" ]]; then
        blink_url=$(build_deep_link_url "$session")
        title="${MACHINE}/${session}: Needs Attention"
        ntfy_log INFO "Broadcast: ${title}"
        echo "Sending: $title"
        send_ntfy_notification "$title" "default" "bell,${MACHINE}" "$body" "$blink_url"
        sent=$((sent + 1))
    fi
done

ntfy_log INFO "Broadcast complete: sent ${sent} notifications"
echo "Sent ${sent} notifications (no cooldowns written)"
