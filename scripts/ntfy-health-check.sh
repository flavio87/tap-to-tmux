#!/bin/bash
# cc-notify health check — validates the entire notification pipeline
# Usage: ntfy-health-check.sh [--send-test]

SEND_TEST=0
[[ "${1:-}" == "--send-test" ]] && SEND_TEST=1

# Load shared config and functions
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/ntfy-notify-common.sh" 2>/dev/null \
    || source "$HOME/.local/bin/ntfy-notify-common.sh" 2>/dev/null \
    || { echo "ERROR: ntfy-notify-common.sh not found"; exit 1; }

PASS=0
WARN=0
FAIL=0

ok()   { echo "  OK: $*"; PASS=$((PASS + 1)); }
warn() { echo "  WARN: $*"; WARN=$((WARN + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "=== Required Tools ==="
for tool in jq curl tmux ntm python3; do
    if command -v "$tool" &>/dev/null; then
        ok "$tool found"
    else
        fail "$tool not found"
    fi
done

echo ""
echo "=== Configuration ==="
echo "  NTFY_URL=${NTFY_URL}"
echo "  MACHINE=${MACHINE}"
if [[ -f "${CONFIG_DIR}/config.env" ]]; then
    ok "config.env found at ${CONFIG_DIR}/config.env"
else
    warn "config.env not found (using defaults)"
fi

echo ""
echo "=== ntfy Server ==="
http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${NTFY_URL}" 2>/dev/null)
if [[ "$http_code" == "200" || "$http_code" == "405" ]]; then
    ok "Server reachable (HTTP ${http_code})"
else
    fail "Server unreachable (HTTP ${http_code})"
fi

echo ""
echo "=== Claude Code Hook ==="
HOOK_PATH="$HOME/.claude/hooks/tmux-notify.sh"
if [[ -x "$HOOK_PATH" ]]; then
    ok "Hook installed at ${HOOK_PATH}"
else
    fail "Hook not found or not executable at ${HOOK_PATH}"
fi

CLAUDE_SETTINGS="$HOME/.claude/settings.json"
if [[ -f "$CLAUDE_SETTINGS" ]]; then
    if grep -q "tmux-notify.sh" "$CLAUDE_SETTINGS" 2>/dev/null; then
        ok "Hook configured in settings.json"
    else
        fail "Hook not configured in settings.json"
    fi
    if grep -q "ntfy-cooldown-clear.sh" "$CLAUDE_SETTINGS" 2>/dev/null; then
        ok "Cooldown-clear hook configured"
    else
        warn "Cooldown-clear hook not configured in settings.json"
    fi
else
    warn "No Claude Code settings.json found"
fi

echo ""
echo "=== NTM Monitor ==="
if systemctl --user is-active ntm-notify-monitor &>/dev/null; then
    ok "Monitor service is running"
else
    warn "Monitor service is not running"
fi
state_count=$(find "$STATE_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l)
echo "  State directory has ${state_count} entries"

echo ""
echo "=== NTM Ecosystem (ntm doctor) ==="
if command -v ntm &>/dev/null; then
    ntm_version=$(ntm version 2>&1 | head -1)
    echo "  NTM version: ${ntm_version}"
    doctor_json=$(ntm doctor --json 2>/dev/null)
    if [[ -n "$doctor_json" ]]; then
        overall=$(echo "$doctor_json" | jq -r '.overall // "unknown"' 2>/dev/null)
        if [[ "$overall" == "healthy" ]]; then
            ok "NTM ecosystem healthy"
        else
            warn "NTM ecosystem: ${overall}"
        fi
        # Check critical daemons
        daemon_count=$(echo "$doctor_json" | jq '[.daemons[]? | select(.status == "ok")] | length' 2>/dev/null)
        daemon_total=$(echo "$doctor_json" | jq '[.daemons[]?] | length' 2>/dev/null)
        if [[ -n "$daemon_count" && -n "$daemon_total" ]]; then
            echo "  Daemons: ${daemon_count}/${daemon_total} healthy"
        fi
        # Report failed required tools
        failed_tools=$(echo "$doctor_json" | jq -r '[.tools[]? | select(.status == "error" and .required == true)] | map(.name) | join(", ")' 2>/dev/null)
        if [[ -n "$failed_tools" && "$failed_tools" != "" ]]; then
            warn "Missing required NTM tools: ${failed_tools}"
        fi
    else
        warn "ntm doctor --json returned no output"
    fi
else
    warn "ntm not found (NTM ecosystem check skipped)"
fi

echo ""
echo "=== NTM Serve (REST API) ==="
if systemctl --user is-active ntm-serve &>/dev/null; then
    ok "ntm-serve service is running"
    _serve_health=$(curl -s --max-time 3 http://127.0.0.1:7337/health 2>/dev/null)
    if echo "$_serve_health" | jq -e '.status == "healthy"' &>/dev/null; then
        ok "ntm serve health endpoint OK"
    else
        warn "ntm serve health endpoint returned: ${_serve_health:-no response}"
    fi
else
    warn "ntm-serve service is not running"
fi

echo ""
echo "=== Status Dashboard ==="
if systemctl --user is-active ntm-dashboard &>/dev/null; then
    ok "ntm-dashboard service is running"
    _dash_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:7338/ 2>/dev/null)
    if [[ "$_dash_code" == "200" ]]; then
        ok "Dashboard HTML accessible (HTTP 200)"
    else
        warn "Dashboard HTML returned HTTP ${_dash_code}"
    fi
    _dash_api=$(curl -s --max-time 5 http://127.0.0.1:7338/api/status 2>/dev/null)
    if echo "$_dash_api" | jq -e '.session_count >= 0' &>/dev/null; then
        _dash_sessions=$(echo "$_dash_api" | jq '.session_count' 2>/dev/null)
        _dash_agents=$(echo "$_dash_api" | jq '.total_agents' 2>/dev/null)
        ok "Dashboard API: ${_dash_sessions} sessions, ${_dash_agents} agents"
    else
        warn "Dashboard API returned unexpected response"
    fi
else
    warn "ntm-dashboard service is not running"
fi

echo ""
echo "=== FrankenTerm ==="
if command -v ft &>/dev/null; then
    ft_version=$(ft --version 2>&1 | head -1)
    echo "  FrankenTerm version: ${ft_version}"
    if systemctl --user is-active ft-watch &>/dev/null; then
        ok "ft-watch service is running"
    else
        warn "ft-watch service is not running"
    fi
    # Check ft doctor
    ft_doctor=$(ft doctor 2>&1)
    if echo "$ft_doctor" | grep -q "healthy\|ok\|pass" 2>/dev/null; then
        ok "FrankenTerm environment OK"
    else
        warn "FrankenTerm doctor reported issues"
    fi
    # Check recent events
    ft_events=$(ft events --limit 5 --format json 2>/dev/null)
    if [[ -n "$ft_events" ]] && echo "$ft_events" | jq -e 'length > 0' &>/dev/null 2>&1; then
        _ev_count=$(echo "$ft_events" | jq 'length' 2>/dev/null)
        echo "  Recent events: ${_ev_count} detected"
    else
        echo "  No recent events detected (normal if agents just started)"
    fi
else
    warn "ft not found (FrankenTerm check skipped)"
fi

echo ""
echo "=== Cooldown State ==="
COOLDOWN_DIR="/tmp/cc-notify-cooldown"
if [[ -d "$COOLDOWN_DIR" ]]; then
    found_cooldowns=0
    for f in "$COOLDOWN_DIR"/*; do
        [[ -f "$f" ]] || continue
        found_cooldowns=1
        project=$(basename "$f")
        ts=$(cat "$f")
        now=$(date +%s)
        age=$(( now - ts ))
        hours=$(( age / 3600 ))
        echo "  ${project}: cooldown set ${age}s ago (${hours}h)"
    done
    if [[ "$found_cooldowns" == "0" ]]; then
        echo "  No active cooldowns"
    fi
else
    echo "  No cooldown directory"
fi

echo ""
echo "=== tmux Sessions ==="
total_sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | wc -l)
project_sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | while read -r s; do
    [[ -d "${PROJECTS_DIR}/${s}" ]] && echo "$s"
done | wc -l)
echo "  ${total_sessions} sessions, ${project_sessions} match ${PROJECTS_DIR}/"

echo ""
echo "=== Agent Errors (ntm --robot-errors) ==="
if command -v ntm &>/dev/null; then
    _found_errors=0
    for _session in $(tmux list-sessions -F '#{session_name}' 2>/dev/null); do
        [[ -d "${PROJECTS_DIR}/${_session}" ]] || continue
        _errors_json=$(ntm --robot-errors="$_session" --json 2>/dev/null)
        if [[ -n "$_errors_json" ]] && echo "$_errors_json" | jq -e '.success == true' &>/dev/null; then
            _error_count=$(echo "$_errors_json" | jq '[.errors[]?] | length' 2>/dev/null)
            if [[ "$_error_count" -gt 0 ]]; then
                _found_errors=1
                # Show first error per session as a sample
                _first_error=$(echo "$_errors_json" | jq -r '.errors[0] | "\(.pane_name // "pane"): \(.match_type // "error") - \(.content[:80])"' 2>/dev/null)
                warn "${_session}: ${_error_count} error(s) detected (e.g. ${_first_error})"
            fi
        fi
    done
    if [[ "$_found_errors" == "0" ]]; then
        ok "No agent errors in active sessions"
    fi
else
    echo "  ntm not found (agent error check skipped)"
fi

echo ""
echo "=== Log Files ==="
LOG_DIR="/tmp/cc-notify-logs"
if [[ -d "$LOG_DIR" ]]; then
    for f in "$LOG_DIR"/*.log; do
        [[ -f "$f" ]] || continue
        fname=$(basename "$f")
        size=$(stat -c%s "$f" 2>/dev/null || echo 0)
        now=$(date +%s)
        mtime=$(stat -c%Y "$f" 2>/dev/null || echo 0)
        age=$(( now - mtime ))
        echo "  ${fname}: ${size} bytes, last modified ${age}s ago"
    done
else
    echo "  No log directory yet"
fi

if [[ "$SEND_TEST" == "1" ]]; then
    echo ""
    echo "=== Send Test Notification ==="
    blink_url=$(build_blink_url "test-session")
    if send_ntfy_notification \
        "${MACHINE}: Health Check Test" \
        "low" \
        "white_check_mark,${MACHINE}" \
        "This is a test notification from ntfy-health-check.sh" \
        "$blink_url"; then
        ok "Test notification sent successfully"
    else
        fail "Test notification failed"
    fi
fi

echo ""
echo "RESULT: ${PASS} passed, ${WARN} warnings, ${FAIL} failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
elif [[ "$WARN" -gt 0 ]]; then
    exit 0
else
    exit 0
fi
