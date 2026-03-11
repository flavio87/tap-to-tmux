#!/bin/bash
# Claude Code notification hook - rich phone notifications via ntfy
# Sources shared config from ntfy-notify-common.sh
# Includes: machine name, project, task context, tap-to-SSH via Blink
# Deduplication: one notification per event type per session, then cooldown

# Load shared config and functions
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../scripts/ntfy-notify-common.sh" 2>/dev/null \
    || source "$HOME/.local/bin/ntfy-notify-common.sh" 2>/dev/null \
    || { echo "ERROR: ntfy-notify-common.sh not found" >&2; exit 1; }

check_required_tools jq || exit 1

# Cooldown: suppress repeat notifications of the same type for this many seconds
COOLDOWN_SECONDS="${NTFY_COOLDOWN_SECONDS:-86400}"  # 24 hours default

# Read hook payload from stdin
INPUT=$(cat)
NOTIFICATION_TYPE=$(echo "$INPUT" | jq -r '.notification_type // .hook_event_name // "unknown"')
MESSAGE=$(echo "$INPUT" | jq -r '.message // ""')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // ""')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')

# Extract project name from cwd
PROJECT=""
if [[ -n "$CWD" ]]; then
    PROJECT=$(basename "$CWD")
fi

ntfy_log INFO "Hook fired: type=${NOTIFICATION_TYPE} project=${PROJECT} session_id=${SESSION_ID}"

# --- Directory exclusions ---
# If CWD starts with any path in NOTIFY_EXCLUDE_DIRS (colon-separated), skip silently.
# Set in config.env: NOTIFY_EXCLUDE_DIRS="/data/notes:/home/user/personal"
if [[ -n "${NOTIFY_EXCLUDE_DIRS:-}" && -n "$CWD" ]]; then
    IFS=: read -ra _exclude_list <<< "$NOTIFY_EXCLUDE_DIRS"
    for _excl in "${_exclude_list[@]}"; do
        [[ -z "$_excl" ]] && continue
        if [[ "$CWD" == "$_excl"* ]]; then
            ntfy_log INFO "CWD '$CWD' matches exclusion '$_excl', skipping notification"
            exit 0
        fi
    done
fi

# --- Deduplication ---
# All "needs attention" events (idle, permission, stop) share ONE cooldown per project.
# You get one notification when a session needs you, then silence until the cooldown expires.
# The cooldown is cleared when you interact (UserPromptSubmit hook or new CC turn).
COOLDOWN_DIR="/tmp/cc-notify-cooldown"
mkdir -p "$COOLDOWN_DIR"
COOLDOWN_FILE="${COOLDOWN_DIR}/${PROJECT:-unknown}"

if [[ -f "$COOLDOWN_FILE" ]]; then
    last_sent=$(cat "$COOLDOWN_FILE")
    now=$(date +%s)
    elapsed=$(( now - last_sent ))
    if [[ "$elapsed" -lt "$COOLDOWN_SECONDS" ]]; then
        ntfy_log INFO "Cooldown active for ${PROJECT}: ${elapsed}s < ${COOLDOWN_SECONDS}s, suppressing ${NOTIFICATION_TYPE}"
        exit 0
    fi
    ntfy_log INFO "Cooldown expired for ${PROJECT}: ${elapsed}s >= ${COOLDOWN_SECONDS}s, will notify"
fi

# Record this notification time (before sending, so even if send fails we don't spam)
date +%s > "$COOLDOWN_FILE"

# Find the tmux session and pane by walking up the process tree.
# This is more reliable than matching by CWD, which breaks when multiple
# panes share the same directory or when a pane was moved between sessions.
TMUX_SESSION=""
TMUX_PANE_INDEX=""
_pid=$$
while [[ "$_pid" -gt 1 ]]; do
    # Skip mob-* grouped sessions — they're ephemeral mobile viewports,
    # not the real session. Deep links must target the actual session.
    _match=$(tmux list-panes -a -F '#{pane_pid} #{session_name} #{pane_index}' 2>/dev/null \
        | awk -v pid="$_pid" '$1 == pid && $2 !~ /^mob-/ {print $2, $3}')
    if [[ -n "$_match" ]]; then
        TMUX_SESSION=$(echo "$_match" | awk '{print $1}')
        TMUX_PANE_INDEX=$(echo "$_match" | awk '{print $2}')
        ntfy_log INFO "Tmux lookup: SESSION=${TMUX_SESSION} PANE=${TMUX_PANE_INDEX}"
        break
    fi
    _pid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')
done
# Fallback: use project name as session guess
if [[ -z "$TMUX_SESSION" ]]; then
    TMUX_SESSION="$PROJECT"
    ntfy_log WARN "Tmux lookup failed, falling back to project name: ${PROJECT}"
fi

# Extract context from transcript (CC-specific: richer than pane capture)
# Transcript format: JSONL with multiple entry types:
#   queue-operation (operation=enqueue) → human-typed messages
#   assistant → agent responses (content at .message.content[].text)
#   user → tool results (NOT human input, despite the name)
LAST_TASK=""
LAST_RESPONSE=""
if [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]]; then
    # Get last human-typed message — two transcript formats exist:
    #   1. queue-operation (operation=enqueue) with .content string
    #   2. user entry where .message.content is a string (not array)
    # Scan from end with tac to find most recent
    LAST_TASK=$(tac "$TRANSCRIPT" 2>/dev/null \
        | jq -r '
            if .type == "queue-operation" and .operation == "enqueue" then .content
            elif .type == "user" and (.message.content | type) == "string" then .message.content
            else empty end' 2>/dev/null \
        | grep -v '<local-command' | grep -v '<command-name>' | grep -v '<command-message>' | grep -v '<command-args>' \
        | grep -v '<system-reminder>' | grep -v '^$' \
        | head -1 \
        | head -c 200 2>/dev/null)

    # Get last assistant text (what was done / last response)
    LAST_RESPONSE=$(tac "$TRANSCRIPT" 2>/dev/null \
        | jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' 2>/dev/null \
        | grep -v '<system-reminder>' | grep -v '^$' \
        | head -1 2>/dev/null)
    # Trim to last ~200 chars (most relevant part)
    if [[ ${#LAST_RESPONSE} -gt 200 ]]; then
        LAST_RESPONSE="...${LAST_RESPONSE: -200}"
    fi
    LAST_RESPONSE="${LAST_RESPONSE:0:200}"
fi

# Fallback: extract context from tmux pane if transcript extraction failed
if [[ -z "$LAST_TASK" && -z "$LAST_RESPONSE" && -n "$TMUX_SESSION" ]]; then
    pane_id=$(tmux list-panes -t "$TMUX_SESSION" -F '#{pane_id}' 2>/dev/null | head -1)
    if [[ -n "$pane_id" ]]; then
        extract_pane_context "$pane_id"
        LAST_TASK="$task_line"
        LAST_RESPONSE="$response_lines"
        [[ -n "$LAST_TASK" ]] && ntfy_log INFO "Context from pane fallback"
    fi
fi

if [[ -n "$LAST_TASK" || -n "$LAST_RESPONSE" ]]; then
    ntfy_log INFO "Context: task='${LAST_TASK:0:80}' response='${LAST_RESPONSE:0:80}'"
fi

# Build deep link
BLINK_LINK=$(build_blink_url "$TMUX_SESSION" "$TMUX_PANE_INDEX")

# Build notification content based on event type
case "$NOTIFICATION_TYPE" in
    permission_prompt)
        TITLE="${MACHINE}/${PROJECT} [cc]: Permission Needed"
        PRIORITY="high"
        TAGS="warning,claude,${MACHINE}"
        BODY="$MESSAGE"
        [[ -n "$LAST_TASK" ]] && BODY="${BODY}

Task: ${LAST_TASK:0:120}"
        [[ -n "$LAST_RESPONSE" ]] && BODY="${BODY}

Claude: ${LAST_RESPONSE:0:150}"
        ;;
    idle_prompt)
        TITLE="${MACHINE}/${PROJECT} [cc]: Waiting for Input"
        PRIORITY="default"
        TAGS="hourglass,claude,${MACHINE}"
        BODY="$MESSAGE"
        [[ -n "$LAST_TASK" ]] && BODY="${BODY}

Task: ${LAST_TASK:0:120}"
        [[ -n "$LAST_RESPONSE" ]] && BODY="${BODY}

Claude: ${LAST_RESPONSE:0:150}"
        ;;
    Stop|stop)
        TITLE="${MACHINE}/${PROJECT} [cc]: Done"
        PRIORITY="default"
        TAGS="white_check_mark,claude,${MACHINE}"
        BODY=""
        [[ -n "$LAST_TASK" ]] && BODY="Task: ${LAST_TASK:0:120}"
        if [[ -n "$LAST_RESPONSE" ]]; then
            BODY="${BODY}

Summary: ${LAST_RESPONSE:0:200}"
        fi
        [[ -z "$BODY" ]] && BODY="Session finished"
        ;;
    *)
        TITLE="${MACHINE}/${PROJECT} [cc]: Needs Attention"
        PRIORITY="default"
        TAGS="bell,claude,${MACHINE}"
        BODY="${MESSAGE:-Claude needs attention}"
        [[ -n "$LAST_TASK" ]] && BODY="${BODY}

Task: ${LAST_TASK:0:120}"
        [[ -n "$LAST_RESPONSE" ]] && BODY="${BODY}

Claude: ${LAST_RESPONSE:0:150}"
        ;;
esac

# Send via shared function (runs in background for non-blocking hook)
ntfy_log INFO "Sending: '${TITLE}' priority=${PRIORITY}"
send_ntfy_notification "$TITLE" "$PRIORITY" "$TAGS" "$BODY" "$BLINK_LINK" &

exit 0
