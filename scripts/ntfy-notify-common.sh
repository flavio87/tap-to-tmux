#!/bin/bash
# tap-to-tmux shared library — sourced by all notification scripts
# Provides: config loading, deep link building, notification sending, context extraction

# Load config (safe defaults, overridden by config.env)
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/tap-to-tmux"
[[ -f "$CONFIG_DIR/config.env" ]] && source "$CONFIG_DIR/config.env"

# Validate required config
if [[ -z "${NTFY_TOPIC:-}" ]]; then
    echo "ERROR: NTFY_TOPIC is not set." >&2
    echo "  Create $CONFIG_DIR/config.env with at least:" >&2
    echo '    NTFY_TOPIC="your-secret-topic-name"' >&2
    exit 1
fi

NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
NTFY_URL="${NTFY_URL:-${NTFY_SERVER}/${NTFY_TOPIC}}"
MACHINE="${MACHINE:-$(hostname -s)}"
SSH_USER="${SSH_USER:-$(whoami)}"
SSH_HOST="${SSH_HOST:-$(hostname)}"
BLINK_KEY="${BLINK_KEY:-}"
TERMUX_ENABLED="${TERMUX_ENABLED:-}"
PROJECTS_DIR="${PROJECTS_DIR:-$HOME/projects}"

# Use XDG_RUNTIME_DIR (per-user, mode 0700) when available, fall back to /tmp.
_RUNTIME_BASE="${XDG_RUNTIME_DIR:-/tmp}"
STATE_DIR="${STATE_DIR:-${_RUNTIME_BASE}/tap-to-tmux-state}"

# Restrict new files/dirs to owner-only (prevents information leaks on multi-user systems)
umask 0077

mkdir -p "$STATE_DIR"

# --- Logging infrastructure ---
LOG_DIR="${_RUNTIME_BASE}/tap-to-tmux-logs"
mkdir -p "$LOG_DIR"

# Auto-derive log file from calling script name
_caller_name=$(basename "${BASH_SOURCE[-1]}" .sh 2>/dev/null)
[[ -z "$_caller_name" || "$_caller_name" == "ntfy-notify-common" ]] && _caller_name="ntfy-notify"
LOG_FILE="${LOG_DIR}/${_caller_name}.log"

# Rotate log if it exceeds 1MB (runs once at source time)
_rotate_log() {
    local f="$1"
    if [[ -f "$f" ]]; then
        local size
        size=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)
        if (( size > 1048576 )); then
            mv -f "$f" "${f}.1"
        fi
    fi
}
_rotate_log "$LOG_FILE"

# ntfy_log LEVEL "message" — timestamped logging
# ERROR and WARN also go to stderr (captured by journalctl for systemd services)
ntfy_log() {
    local level="$1"; shift
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*"
    echo "$msg" >> "$LOG_FILE"
    if [[ "$level" == "ERROR" || "$level" == "WARN" ]]; then
        echo "$msg" >&2
    fi
}

# Validate that required commands exist
# Usage: check_required_tools jq curl tmux || exit 1
check_required_tools() {
    local missing=0
    for tool in "$@"; do
        if ! command -v "$tool" &>/dev/null; then
            ntfy_log ERROR "Required tool not found: $tool"
            missing=1
        fi
    done
    return "$missing"
}

# Build a Blink Shell deep link URL for a given tmux session and pane
# Usage: build_blink_url SESSION [PANE_INDEX]
build_blink_url() {
    local session="$1" pane_index="$2"

    # If no BLINK_KEY configured, skip deep link generation
    if [[ -z "$BLINK_KEY" ]]; then
        echo ""
        return
    fi

    local ssh_cmd
    if [[ -n "$pane_index" ]]; then
        ssh_cmd="ssh -t ${SSH_USER}@${SSH_HOST} ${SSH_REMOTE_HOME:-/home/${SSH_USER}}/.local/bin/tmux-mobile-attach.sh ${session} ${pane_index}"
    else
        ssh_cmd="ssh -t ${SSH_USER}@${SSH_HOST} ${SSH_REMOTE_HOME:-/home/${SSH_USER}}/.local/bin/tmux-mobile-attach.sh ${session}"
    fi
    local encoded_cmd
    encoded_cmd=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$ssh_cmd")
    echo "blinkshell://run?key=${BLINK_KEY}&cmd=${encoded_cmd}"
}

# Build a Termux deep link URL for a given tmux session and pane (Android)
# Requires allow-external-apps=true in ~/.termux/termux.properties on the phone.
# Usage: build_termux_url SESSION [PANE_INDEX]
build_termux_url() {
    local session="$1" pane_index="$2"

    if [[ "${TERMUX_ENABLED:-}" != "true" ]]; then
        echo ""
        return
    fi

    local ssh_cmd
    if [[ -n "$pane_index" ]]; then
        ssh_cmd="ssh -t ${SSH_USER}@${SSH_HOST} ${SSH_REMOTE_HOME:-/home/${SSH_USER}}/.local/bin/tmux-mobile-attach.sh ${session} ${pane_index}"
    else
        ssh_cmd="ssh -t ${SSH_USER}@${SSH_HOST} ${SSH_REMOTE_HOME:-/home/${SSH_USER}}/.local/bin/tmux-mobile-attach.sh ${session}"
    fi
    local encoded_cmd
    encoded_cmd=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$ssh_cmd")
    echo "termux://run?command=${encoded_cmd}"
}

# Build a deep link URL using whichever mobile terminal is configured.
# Tries Blink (iOS) first, then Termux (Android). Returns empty if neither is set.
# Usage: build_deep_link_url SESSION [PANE_INDEX]
build_deep_link_url() {
    local url
    url=$(build_blink_url "$@")
    if [[ -z "$url" ]]; then
        url=$(build_termux_url "$@")
    fi
    echo "$url"
}

# Extract task and context from tmux pane output
# Usage: extract_pane_context PANE_ID
# Sets: task_line, response_lines
extract_pane_context() {
    local pane_id="$1"
    task_line=""
    response_lines=""
    [[ -z "$pane_id" ]] && return

    local raw_capture
    raw_capture=$(tmux capture-pane -t "$pane_id" -p -S -60 2>/dev/null)
    [[ -z "$raw_capture" ]] && return

    local _ctx_json
    _ctx_json=$(echo "$raw_capture" | python3 -c "
import sys, json
lines = sys.stdin.read().split('\n')
noise = set('─│╭╰╮╯')
skip_kw = ['? for shortcuts','context left','background terminal','Tip:','model:','directory:']

prompt_idx = -1
for i, l in enumerate(lines):
    if l.startswith('›'):
        prompt_idx = i

task = ''
ctx_lines = []
if prompt_idx >= 0:
    task = lines[prompt_idx].lstrip('› ').strip()[:150]
    for i in range(prompt_idx - 1, max(0, prompt_idx - 30), -1):
        s = lines[i].strip()
        if not s: continue
        if any(c in s for c in noise): continue
        if any(k in s for k in skip_kw): continue
        ctx_lines.insert(0, s)
        if len(ctx_lines) >= 6: break

ctx = chr(10).join(ctx_lines)
print(json.dumps({'task': task, 'ctx': ctx}))
" 2>/dev/null)
    if [[ -n "$_ctx_json" ]]; then
        task_line=$(echo "$_ctx_json" | jq -r '.task')
        response_lines=$(echo "$_ctx_json" | jq -r '.ctx')
    fi
}

# Extract task and context using ntm --robot-tail (structured JSON output)
# Falls back to extract_pane_context() if ntm is unavailable or fails.
# Usage: extract_pane_context_robot SESSION PANE_INDEX
# Sets: task_line, response_lines
extract_pane_context_robot() {
    local session="$1" pane_index="$2"
    task_line=""
    response_lines=""
    [[ -z "$session" ]] && return

    # Try ntm --robot-tail for structured output
    local robot_json
    local robot_target="${session}"
    [[ -n "$pane_index" ]] && robot_target="${session}:${pane_index}"
    robot_json=$(ntm --robot-tail="$robot_target" --json 2>/dev/null)

    if [[ -n "$robot_json" ]] && echo "$robot_json" | jq -e '.success == true' &>/dev/null; then
        # Parse structured robot-tail output
        local _robot_ctx
        _robot_ctx=$(echo "$robot_json" | python3 -c "
import sys, json

data = json.load(sys.stdin)
panes = data.get('panes', {})
task = ''
ctx_lines = []

# Find the target pane (use first pane if only one, or match pane_index)
pane_data = None
for pid, pd in panes.items():
    pane_data = pd
    break  # use first pane

if pane_data:
    lines = pane_data.get('lines', [])
    noise = set('─│╭╰╮╯')
    skip_kw = ['? for shortcuts','context left','background terminal','Tip:','model:','directory:']

    # Find last prompt line
    prompt_idx = -1
    for i, l in enumerate(lines):
        if l.startswith('›'):
            prompt_idx = i

    if prompt_idx >= 0:
        task = lines[prompt_idx].lstrip('› ').strip()[:150]
        for i in range(prompt_idx - 1, max(0, prompt_idx - 30), -1):
            s = lines[i].strip()
            if not s: continue
            if any(c in s for c in noise): continue
            if any(k in s for k in skip_kw): continue
            ctx_lines.insert(0, s)
            if len(ctx_lines) >= 6: break
    elif lines:
        # No prompt marker found -- use last non-empty lines as context
        for l in reversed(lines):
            s = l.strip()
            if not s: continue
            if any(c in s for c in noise): continue
            if any(k in s for k in skip_kw): continue
            ctx_lines.insert(0, s)
            if len(ctx_lines) >= 6: break

ctx = chr(10).join(ctx_lines)
print(json.dumps({'task': task, 'ctx': ctx}))
" 2>/dev/null)
        if [[ -n "$_robot_ctx" ]]; then
            task_line=$(echo "$_robot_ctx" | jq -r '.task')
            response_lines=$(echo "$_robot_ctx" | jq -r '.ctx')
        fi
        [[ -n "$task_line" || -n "$response_lines" ]] && return
    fi

    # Fallback: resolve pane_id and use tmux capture-pane method
    local pane_id
    if [[ -n "$pane_index" ]]; then
        pane_id=$(tmux list-panes -t "${session}" -F '#{pane_index} #{pane_id}' 2>/dev/null \
            | awk -v idx="$pane_index" '$1 == idx {print $2}')
    else
        pane_id=$(tmux list-panes -t "${session}" -F '#{pane_id}' 2>/dev/null | head -1)
    fi
    extract_pane_context "$pane_id"
}

# Send a Slack notification via incoming webhook
# Usage: send_slack_notification TITLE PRIORITY BODY BLINK_URL
# Requires SLACK_WEBHOOK_URL to be set (skips silently if empty)
send_slack_notification() {
    [[ -z "${SLACK_WEBHOOK_URL:-}" ]] && return 0

    local title="$1" priority="$2" body="$3" blink_url="$4"

    # Priority emoji
    local emoji=":white_circle:"
    case "$priority" in
        urgent) emoji=":red_circle:" ;;
        high)   emoji=":orange_circle:" ;;
        default) emoji=":large_blue_circle:" ;;
        low)    emoji=":white_circle:" ;;
    esac

    # Build Slack payload with jq to get proper newlines
    local payload
    payload=$(jq -n \
        --arg emoji "$emoji" \
        --arg title "$title" \
        --arg body "${body:0:300}" \
        --arg blink_url "$blink_url" \
        '{
            text: (
                ($emoji + " *" + $title + "*")
                + if $body != "" then ("\n```" + $body + "```") else "" end
                + if $blink_url != "" then ("\n<" + $blink_url + "|Connect via Blink>") else "" end
            ),
            unfurl_links: false
        }')

    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        -H 'Content-Type: application/json' \
        -d "$payload" \
        "$SLACK_WEBHOOK_URL" 2>/dev/null)

    if [[ "$http_code" == "200" ]]; then
        ntfy_log INFO "Slack sent OK"
    else
        ntfy_log WARN "Slack FAILED HTTP ${http_code}"
    fi
}

# Send an ntfy notification (and optionally Slack)
# Usage: send_ntfy_notification TITLE PRIORITY TAGS BODY BLINK_URL
send_ntfy_notification() {
    local title="$1" priority="$2" tags="$3" body="$4" blink_url="$5"
    body="${body:0:500}"

    ntfy_log INFO "Sending: title='${title}' priority=${priority}"

    local -a curl_args=(
        -s -o /dev/null -w '%{http_code}' --max-time 10
        -H "Title: $title"
        -H "Priority: $priority"
        -H "Tags: $tags"
    )

    # Add auth header for self-hosted servers with access control
    if [[ -n "${NTFY_TOKEN:-}" ]]; then
        curl_args+=( -H "Authorization: Bearer ${NTFY_TOKEN}" )
    fi

    # Only add Click/Actions headers if blink_url is non-empty
    if [[ -n "$blink_url" ]]; then
        curl_args+=( -H "Click: $blink_url" )
        curl_args+=( -H "Actions: view, Connect, ${blink_url}" )
    fi

    curl_args+=( -d "$body" "$NTFY_URL" )

    local http_code
    http_code=$(curl "${curl_args[@]}" 2>/dev/null)

    if [[ "$http_code" == "200" ]]; then
        ntfy_log INFO "Sent OK (HTTP 200)"
    else
        ntfy_log ERROR "FAILED HTTP ${http_code} for: ${title}"
    fi

    # Also send to Slack (non-blocking, failures logged but don't affect return)
    send_slack_notification "$title" "$priority" "$body" "$blink_url"
}
