#!/bin/bash
# NTM Agent Monitor — sends ntfy notifications when any non-CC agent goes idle/errors
# Polls `ntm health --json` every N seconds for state transitions.
# Uses `ntm health` (process-based) instead of `ntm activity` (velocity-based)
# because activity can't detect Codex state changes reliably.
# Uses `ntm --robot-tail` for structured pane output capture (falls back to tmux capture-pane).
# Claude Code agents are handled by the CC hook (tmux-notify.sh) with richer transcript context.
#
# Note: ntm --robot-monitor only emits proactive warnings (stuck, resource), NOT idle
# transitions. The polling loop remains the correct approach for state transition detection.
# For single-session scripting, use `ntm wait --until=idle` instead.

POLL_SECONDS="${1:-5}"

# Load shared config and functions
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/ntfy-notify-common.sh" 2>/dev/null \
    || source "$HOME/.local/bin/ntfy-notify-common.sh" 2>/dev/null \
    || { echo "ERROR: ntfy-notify-common.sh not found"; exit 1; }

check_required_tools jq ntm tmux || exit 1

# Heartbeat interval: log a heartbeat every N poll cycles (~5 minutes at 5s poll)
HEARTBEAT_INTERVAL=$(( 300 / POLL_SECONDS ))
_poll_count=0

send_agent_notification() {
    local session="$1" pane_index="$2" agent_type="$3" state="$4"

    local blink_url
    blink_url=$(build_blink_url "$session" "$pane_index")

    # Extract context: tries ntm --robot-tail first, falls back to tmux capture-pane
    extract_pane_context_robot "$session" "$pane_index"

    local title priority tags body
    case "$state" in
        WAITING)
            title="${MACHINE}/${session} [${agent_type}] p${pane_index}: Idle"
            priority="default"
            tags="${agent_type},${MACHINE},hourglass"
            body=""
            [[ -n "$task_line" ]] && body="Task: ${task_line:0:150}"
            if [[ -n "$response_lines" ]]; then
                [[ -n "$body" ]] && body="${body}

"
                body="${body}${response_lines}"
            fi
            [[ -z "$body" ]] && body="Agent finished and waiting for input."
            ;;
        ERROR)
            title="${MACHINE}/${session} [${agent_type}] p${pane_index}: Error"
            priority="high"
            tags="${agent_type},${MACHINE},warning"
            body=""
            [[ -n "$task_line" ]] && body="Task: ${task_line:0:150}"
            if [[ -n "$response_lines" ]]; then
                [[ -n "$body" ]] && body="${body}

"
                body="${body}${response_lines}"
            fi
            [[ -z "$body" ]] && body="Agent hit an error."
            ;;
        *)
            return 0
            ;;
    esac

    ntfy_log INFO "NOTIFY: ${title}"
    send_ntfy_notification "$title" "$priority" "$tags" "$body" "$blink_url"
}

# Normalize ntm health agent_type (cc/cod/gmi) to display names
normalize_agent_type() {
    case "$1" in
        cc) echo "claude" ;;
        cod) echo "codex" ;;
        gmi) echo "gemini" ;;
        *) echo "$1" ;;
    esac
}

check_and_notify() {
    local session="$1"
    local json
    json=$(ntm health "$session" --json 2>/dev/null)
    if [[ -z "$json" || "$json" == "null" ]]; then
        ntfy_log DEBUG "ntm health returned empty/null for ${session}"
        return
    fi

    echo "$json" | jq -c '.agents[]' 2>/dev/null | while read -r agent; do
        local pane activity status stage raw_type agent_type
        pane=$(echo "$agent" | jq -r '.pane')
        activity=$(echo "$agent" | jq -r '.activity')
        status=$(echo "$agent" | jq -r '.status')
        stage=$(echo "$agent" | jq -r '.progress.stage // "unknown"')
        raw_type=$(echo "$agent" | jq -r '.agent_type')
        agent_type=$(normalize_agent_type "$raw_type")

        # Map health fields to our state model:
        #   activity=active → agent process is running → ACTIVE (regardless of stage)
        #   activity=idle → agent waiting for input → WAITING
        #   status=error/unhealthy → ERROR
        # Note: stage=stuck with activity=active means ntm thinks the agent MIGHT
        # need help, but the process is still running. We treat this as ACTIVE to
        # avoid notification spam from working→stuck oscillation.
        local effective_state
        if [[ "$status" == "error" || "$status" == "unhealthy" ]]; then
            effective_state="ERROR"
        elif [[ "$activity" == "idle" ]]; then
            effective_state="WAITING"
        else
            effective_state="ACTIVE"
        fi

        ntfy_log DEBUG "STATE: ${session}/p${pane} [${agent_type}]: ${effective_state} (activity=${activity} stage=${stage} status=${status})"

        local state_file="${STATE_DIR}/${session}_${pane}"

        if [[ "$effective_state" == "ACTIVE" ]]; then
            # Agent is working — clear state so next idle triggers notification
            rm -f "$state_file"
        elif [[ "$effective_state" == "WAITING" || "$effective_state" == "ERROR" ]]; then
            # Agent is idle/error — check if this is a new transition
            local old_state=""
            [[ -f "$state_file" ]] && old_state=$(cat "$state_file")
            if [[ "$effective_state" != "$old_state" ]]; then
                echo "$effective_state" > "$state_file"
                # Only notify if not initial run
                if [[ "${INITIAL_CAPTURE:-0}" != "1" ]]; then
                    # Skip claude agents — CC hook handles those with richer context
                    if [[ "$agent_type" == "claude" ]]; then
                        ntfy_log INFO "SKIP: ${session}/p${pane} [${agent_type}]: ${effective_state} (CC hook handles)"
                    else
                        ntfy_log INFO "TRANSITION: ${session}/p${pane} [${agent_type}]: ${old_state:-NEW} -> ${effective_state}"
                        send_agent_notification "$session" "$pane" "$agent_type" "$effective_state"
                    fi
                else
                    ntfy_log INFO "INITIAL: ${session}/p${pane} [${agent_type}]: ${effective_state} (captured, no notification)"
                fi
            fi
        fi
    done
}

ntfy_log INFO "Starting NTM notify monitor (poll: ${POLL_SECONDS}s)"
ntfy_log INFO "Config: MACHINE=${MACHINE}, NTFY_URL=${NTFY_URL}"

# Capture initial states without notifying
INITIAL_CAPTURE=1
for session in $(tmux list-sessions -F '#{session_name}' 2>/dev/null); do
    [[ -d "${PROJECTS_DIR}/${session}" ]] || continue
    check_and_notify "$session"
done
INITIAL_CAPTURE=0
_state_count=$(find "$STATE_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l)
ntfy_log INFO "Initial states captured (${_state_count} state files), monitoring for changes..."

# Main polling loop
while true; do
    sleep "$POLL_SECONDS"
    _poll_count=$(( _poll_count + 1 ))

    for session in $(tmux list-sessions -F '#{session_name}' 2>/dev/null); do
        [[ -d "${PROJECTS_DIR}/${session}" ]] || continue
        check_and_notify "$session"
    done

    # Heartbeat every ~5 minutes
    if (( _poll_count >= HEARTBEAT_INTERVAL )); then
        _poll_count=0
        _sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | wc -l)
        _state_files=$(find "$STATE_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l)
        ntfy_log INFO "HEARTBEAT: ${_sessions} tmux sessions, ${_state_files} state files"
    fi
done
