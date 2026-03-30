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
    blink_url=$(build_deep_link_url "$session" "$pane_index")

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

# Detect pane content changes for stale agents.
# Called when activity=stale and effective_state=WAITING and no state transition occurred.
# Uses a settle timer: pane hash must be stable for STALE_SETTLE_SECS before notifying.
# State is tracked in two extra files per pane:
#   STATE_DIR/{session}_{pane}.hash    — hash at time of last notification (or startup)
#   STATE_DIR/{session}_{pane}.pending — "<hash>\n<timestamp>" of pending (changing) content
#
# Note: ntm health reports agent_type=user for both CC (bun→claude) and codex (node→codex)
# when stale. We resolve the real type via /proc to skip CC panes (handled by CC hook).
_pane_is_cc() {
    local session="$1" pane="$2"
    local pane_cmd pane_pid child_pid cmdline
    # display-message targets a specific pane; list-panes would list all panes in the window
    pane_cmd=$(tmux display-message -t "${session}:1.${pane}" -p '#{pane_current_command}' 2>/dev/null)
    [[ "$pane_cmd" != "bun" && "$pane_cmd" != "node" ]] && return 1
    pane_pid=$(tmux display-message -t "${session}:1.${pane}" -p '#{pane_pid}' 2>/dev/null)
    [[ -z "$pane_pid" ]] && return 1
    child_pid=$(pgrep -P "$pane_pid" 2>/dev/null | head -1)
    [[ -z "$child_pid" ]] && return 1
    cmdline=$(tr '\0' ' ' < "/proc/${child_pid}/cmdline" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    [[ "$cmdline" == *claude* ]]
}

check_stale_content_change() {
    local session="$1" pane="$2" agent_type="$3"

    # Skip CC panes — tmux-notify.sh hook handles Claude Code with richer transcript context
    if _pane_is_cc "$session" "$pane"; then
        ntfy_log DEBUG "STALE_SKIP_CC: ${session}/p${pane} is a Claude Code pane"
        return
    fi
    local hash_file="${STATE_DIR}/${session}_${pane}.hash"
    local pending_file="${STATE_DIR}/${session}_${pane}.pending"
    local settle_secs="${STALE_SETTLE_SECS:-10}"

    local current_hash
    current_hash=$(tmux capture-pane -t "${session}:1.${pane}" -p -S -100 2>/dev/null \
        | md5sum | awk '{print $1}')
    [[ -z "$current_hash" ]] && return

    # Initialize on first call: store current hash, no notification
    if [[ ! -f "$hash_file" ]]; then
        echo "$current_hash" > "$hash_file"
        ntfy_log DEBUG "STALE_INIT: ${session}/p${pane} hash initialized"
        return
    fi

    local notified_hash
    notified_hash=$(cat "$hash_file")

    # Content unchanged since last notification — nothing to do
    if [[ "$current_hash" == "$notified_hash" ]]; then
        rm -f "$pending_file"
        return
    fi

    # Content differs from last notification — track stability
    local pending_hash="" pending_since=0
    if [[ -f "$pending_file" ]]; then
        pending_hash=$(sed -n '1p' "$pending_file")
        pending_since=$(sed -n '2p' "$pending_file")
    fi

    if [[ "$current_hash" != "$pending_hash" ]]; then
        # Hash changed (or first time seeing new content) — reset settle timer
        printf '%s\n%s\n' "$current_hash" "$(date +%s)" > "$pending_file"
        ntfy_log DEBUG "STALE_PENDING: ${session}/p${pane} new hash, settling timer reset"
        return
    fi

    # Same pending hash — check if settled long enough
    local now elapsed
    now=$(date +%s)
    elapsed=$(( now - ${pending_since:-$now} ))
    if [[ "$elapsed" -ge "$settle_secs" ]]; then
        # Settled: update notified hash and fire notification
        echo "$current_hash" > "$hash_file"
        rm -f "$pending_file"
        ntfy_log INFO "STALE_COMPLETE: ${session}/p${pane} [${agent_type}]: content settled after ${elapsed}s → notifying"
        send_agent_notification "$session" "$pane" "$agent_type" "WAITING"
    else
        ntfy_log DEBUG "STALE_SETTLING: ${session}/p${pane} settling ${elapsed}/${settle_secs}s"
    fi
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
        #   activity=stale → ntm lost track of agent activity → treat as WAITING
        #     (stale means ntm never observed CPU activity since tracking started,
        #      i.e. idle_seconds is epoch-relative nonsense. Codex agents often go
        #      stale when ntm spawns after the agent is already running.)
        #   status=error/unhealthy → ERROR
        # Note: stage=stuck with activity=active means ntm thinks the agent MIGHT
        # need help, but the process is still running. We treat this as ACTIVE to
        # avoid notification spam from working→stuck oscillation.
        local effective_state
        if [[ "$status" == "error" || "$status" == "unhealthy" ]]; then
            effective_state="ERROR"
        elif [[ "$activity" == "idle" || "$activity" == "stale" ]]; then
            effective_state="WAITING"
        else
            effective_state="ACTIVE"
        fi

        ntfy_log DEBUG "STATE: ${session}/p${pane} [${agent_type}]: ${effective_state} (activity=${activity} stage=${stage} status=${status})"

        local state_file="${STATE_DIR}/${session}_${pane}"

        ntfy_log DEBUG "BRANCH_CHECK: ${session}/p${pane} effective_state=${effective_state}"
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
                    # Skip stale agents — STALE_COMPLETE handles with settled context (avoids double-notify)
                    if [[ "$agent_type" == "claude" ]]; then
                        ntfy_log INFO "SKIP: ${session}/p${pane} [${agent_type}]: ${effective_state} (CC hook handles)"
                    elif [[ "$activity" == "stale" ]]; then
                        ntfy_log INFO "SKIP_STALE: ${session}/p${pane} [${agent_type}]: ${effective_state} (stale content mechanism handles)"
                    else
                        ntfy_log INFO "TRANSITION: ${session}/p${pane} [${agent_type}]: ${old_state:-NEW} -> ${effective_state}"
                        send_agent_notification "$session" "$pane" "$agent_type" "$effective_state"
                    fi
                else
                    ntfy_log INFO "INITIAL: ${session}/p${pane} [${agent_type}]: ${effective_state} (captured, no notification)"
                fi
            fi

            # For stale agents: state machine can't detect activity (ntm never reports
            # active). Use pane content hashing with a settle timer to detect completions.
            ntfy_log DEBUG "STALE_CHECK: ${session}/p${pane} activity=${activity} IC=${INITIAL_CAPTURE:-0}"
            if [[ "$activity" == "stale" && "${INITIAL_CAPTURE:-0}" != "1" ]]; then
                check_stale_content_change "$session" "$pane" "$agent_type"
            fi
        fi
    done
}

# Check if a session name matches any NOTIFY_EXCLUDE_SESSIONS pattern (colon-separated globs)
session_is_excluded() {
    local session="$1"
    [[ -z "${NOTIFY_EXCLUDE_SESSIONS:-}" ]] && return 1
    local _pat
    IFS=: read -ra _excl_patterns <<< "$NOTIFY_EXCLUDE_SESSIONS"
    for _pat in "${_excl_patterns[@]}"; do
        [[ -z "$_pat" ]] && continue
        # shellcheck disable=SC2254
        case "$session" in $_pat) return 0 ;; esac
    done
    return 1
}

ntfy_log INFO "Starting NTM notify monitor (poll: ${POLL_SECONDS}s)"
ntfy_log INFO "Config: MACHINE=${MACHINE}, NTFY_URL=${NTFY_URL}"
[[ -n "${NOTIFY_EXCLUDE_SESSIONS:-}" ]] && ntfy_log INFO "Excluding sessions: ${NOTIFY_EXCLUDE_SESSIONS}"

# Capture initial states without notifying
INITIAL_CAPTURE=1
for session in $(tmux list-sessions -F '#{session_name}' 2>/dev/null); do
    [[ -d "${PROJECTS_DIR}/${session}" ]] || continue
    if session_is_excluded "$session"; then
        ntfy_log DEBUG "SKIP session '${session}': matches NOTIFY_EXCLUDE_SESSIONS"
        continue
    fi
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
        if session_is_excluded "$session"; then
            ntfy_log DEBUG "SKIP session '${session}': matches NOTIFY_EXCLUDE_SESSIONS"
            continue
        fi
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
