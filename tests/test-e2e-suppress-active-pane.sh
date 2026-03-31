#!/bin/bash
# E2E tests for PR #3: suppress notifications when tmux pane is actively focused
#
# Runs the REAL tmux-notify.sh hook inside real tmux panes, with a mock curl
# to intercept notification sends. Verifies the complete pipeline from stdin
# JSON through process-tree walk, suppression check, and notification dispatch.
#
# Usage: bash tests/test-e2e-suppress-active-pane.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# If running inside tmux, extract the socket path
TMUX_SOCKET=""
if [[ -n "${TMUX:-}" ]]; then
    TMUX_SOCKET=$(echo "$TMUX" | cut -d, -f1)
fi
tmux_cmd() {
    if [[ -n "$TMUX_SOCKET" ]]; then
        /usr/bin/tmux -S "$TMUX_SOCKET" "$@"
    else
        /usr/bin/tmux "$@"
    fi
}

TEST_SESSION="__e2e_suppress_$$"
PANE_BASE=$(tmux_cmd show-options -gv pane-base-index 2>/dev/null || echo "0")
PASS=0
FAIL=0
ERRORS=()

# Temp dir for mock curl, config, and result files
WORK_DIR=$(mktemp -d)

cleanup_session() {
    tmux_cmd kill-session -t "$TEST_SESSION" 2>/dev/null || true
}
cleanup_all() {
    cleanup_session
    rm -rf "$WORK_DIR"
}
trap cleanup_all EXIT

ok() {
    PASS=$((PASS + 1))
    echo "  PASS: $1"
}

fail() {
    FAIL=$((FAIL + 1))
    ERRORS+=("$1")
    echo "  FAIL: $1"
}

# --- Setup mock environment ---

# Mock curl: records that it was called, captures args
MOCK_BIN_DIR="${WORK_DIR}/bin"
mkdir -p "$MOCK_BIN_DIR"
cat > "${MOCK_BIN_DIR}/curl" << 'MOCK'
#!/bin/bash
# Mock curl: write a marker file so the test can check if notification was sent
echo "CURL_CALLED" >> "${MOCK_RESULT_FILE:-/dev/null}"
echo "$@" >> "${MOCK_RESULT_FILE:-/dev/null}"
# Return success with HTTP 200 (mimics -w '%{http_code}')
echo -n "200"
MOCK
chmod +x "${MOCK_BIN_DIR}/curl"

# Create a test config
TEST_CONFIG_DIR="${WORK_DIR}/config"
mkdir -p "$TEST_CONFIG_DIR"

# JSON payload that the hook reads from stdin
HOOK_INPUT_FILE="${WORK_DIR}/hook_input.json"
echo '{"notification_type":"idle_prompt","message":"Claude is waiting","cwd":"/tmp/test-project","transcript_path":"","session_id":"test-123"}' > "$HOOK_INPUT_FILE"

# Counter for unique wrapper names
WRAPPER_COUNT=0

# Helper: run the hook inside a specific tmux pane and check the result.
# The hook runs in a subshell inside the pane via send-keys + wait.
run_hook_in_pane() {
    local session="$1" pane_idx="$2" suppress_config="$3" result_file="$4"

    WRAPPER_COUNT=$((WRAPPER_COUNT + 1))
    local wrapper="${WORK_DIR}/run_hook_${WRAPPER_COUNT}.sh"
    cat > "$wrapper" << WRAPPER
#!/bin/bash
# E2E wrapper: runs the real hook with mock curl and test config
export PATH="${MOCK_BIN_DIR}:\$PATH"
export MOCK_RESULT_FILE="${result_file}"
export XDG_CONFIG_HOME="${WORK_DIR}"
export NTFY_TOPIC="test-topic-e2e"
export NTFY_SERVER="https://fake.ntfy.test"
export MACHINE="testbox"
export SSH_USER="testuser"
export SSH_HOST="testhost"
export BLINK_KEY=""
export SUPPRESS_WHEN_ACTIVE="${suppress_config}"
export NTFY_COOLDOWN_SECONDS=0
export XDG_RUNTIME_DIR="${WORK_DIR}/runtime"
mkdir -p "\${XDG_RUNTIME_DIR}"

# Clear any prior cooldown
rm -rf "\${XDG_RUNTIME_DIR}/tap-to-tmux-cooldown" 2>/dev/null

cat "${HOOK_INPUT_FILE}" | bash "${PROJECT_DIR}/hooks/tmux-notify.sh"
echo "HOOK_EXIT=\$?" > "${result_file}.exit"
WRAPPER
    chmod +x "$wrapper"

    # Clear result file
    > "$result_file"
    > "${result_file}.exit"

    # Send the command to the pane and wait for completion
    # Use a sentinel file to know when the script is done
    local sentinel="${result_file}.done"
    rm -f "$sentinel"

    tmux_cmd send-keys -t "${session}:.${pane_idx}" \
        "bash ${wrapper} && touch ${sentinel}" Enter

    # Wait for completion (max 10 seconds)
    local waited=0
    while [[ ! -f "$sentinel" && "$waited" -lt 100 ]]; do
        sleep 0.1
        waited=$((waited + 1))
    done

    if [[ ! -f "$sentinel" ]]; then
        echo "TIMEOUT"
        return 1
    fi
    return 0
}

# Check if curl was called (i.e., notification was sent)
was_notification_sent() {
    local result_file="$1"
    if grep -q "CURL_CALLED" "$result_file" 2>/dev/null; then
        echo "sent"
    else
        echo "suppressed"
    fi
}

# --- Tests ---

echo "=== E2E Tests: PR #3 Suppress Active Pane ==="
echo "(pane-base-index=$PANE_BASE, work_dir=$WORK_DIR)"
echo ""

# Write the tap-to-tmux config dir structure expected by common.sh.
# IMPORTANT: Do NOT set SUPPRESS_WHEN_ACTIVE here — the wrapper's export must
# be authoritative. If set here, source config.env overwrites the export.
mkdir -p "${WORK_DIR}/tap-to-tmux"
cat > "${WORK_DIR}/tap-to-tmux/config.env" << 'CFG'
NTFY_TOPIC="test-topic-e2e"
NTFY_SERVER="https://fake.ntfy.test"
MACHINE="testbox"
SSH_USER="testuser"
SSH_HOST="testhost"
CFG

# ============================================================
# Test 1: SUPPRESS_WHEN_ACTIVE="" (disabled) — notification sent
# ============================================================
echo "Test 1: E2E — config disabled, pane focused => notification SENT"
tmux_cmd new-session -d -s "$TEST_SESSION" -x 120 -y 40
sleep 0.3
PANE_A=$(tmux_cmd list-panes -t "$TEST_SESSION" -F '#{pane_index}' | head -1)

RESULT_FILE="${WORK_DIR}/result_test1"
run_hook_in_pane "$TEST_SESSION" "$PANE_A" "" "$RESULT_FILE"
outcome=$(was_notification_sent "$RESULT_FILE")
if [[ "$outcome" == "sent" ]]; then
    ok "config disabled: notification sent"
else
    fail "config disabled: expected sent, got $outcome"
fi
cleanup_session
sleep 0.3

# ============================================================
# Test 2: SUPPRESS_WHEN_ACTIVE=pane, focused pane => suppressed
# ============================================================
echo ""
echo "Test 2: E2E — config=pane, pane focused => notification SUPPRESSED"
tmux_cmd new-session -d -s "$TEST_SESSION" -x 120 -y 40
tmux_cmd split-window -t "$TEST_SESSION" -h
sleep 0.3
PANE_A=$(tmux_cmd list-panes -t "$TEST_SESSION" -F '#{pane_index}' | head -1)
PANE_B=$(tmux_cmd list-panes -t "$TEST_SESSION" -F '#{pane_index}' | tail -1)

# Focus pane A — hook will run IN pane A, and A is the active pane
tmux_cmd select-pane -t "${TEST_SESSION}:.${PANE_A}"
sleep 0.1

RESULT_FILE="${WORK_DIR}/result_test2"
run_hook_in_pane "$TEST_SESSION" "$PANE_A" "pane" "$RESULT_FILE"
outcome=$(was_notification_sent "$RESULT_FILE")
if [[ "$outcome" == "suppressed" ]]; then
    ok "config=pane, focused pane: notification suppressed"
else
    fail "config=pane, focused pane: expected suppressed, got $outcome"
fi
cleanup_session
sleep 0.3

# ============================================================
# Test 3: SUPPRESS_WHEN_ACTIVE=pane, unfocused pane => sent
# ============================================================
echo ""
echo "Test 3: E2E — config=pane, pane NOT focused => notification SENT"
tmux_cmd new-session -d -s "$TEST_SESSION" -x 120 -y 40
tmux_cmd split-window -t "$TEST_SESSION" -h
sleep 0.3
PANE_A=$(tmux_cmd list-panes -t "$TEST_SESSION" -F '#{pane_index}' | head -1)
PANE_B=$(tmux_cmd list-panes -t "$TEST_SESSION" -F '#{pane_index}' | tail -1)

# Focus pane B, run hook in pane A (A is not focused)
tmux_cmd select-pane -t "${TEST_SESSION}:.${PANE_B}"
sleep 0.1

RESULT_FILE="${WORK_DIR}/result_test3"
run_hook_in_pane "$TEST_SESSION" "$PANE_A" "pane" "$RESULT_FILE"
outcome=$(was_notification_sent "$RESULT_FILE")
if [[ "$outcome" == "sent" ]]; then
    ok "config=pane, unfocused pane: notification sent"
else
    fail "config=pane, unfocused pane: expected sent, got $outcome"
fi
cleanup_session
sleep 0.3

# ============================================================
# Test 4: SUPPRESS_WHEN_ACTIVE=pane, pane in inactive window => sent
# ============================================================
echo ""
echo "Test 4: E2E — config=pane, pane in inactive window => notification SENT"
tmux_cmd new-session -d -s "$TEST_SESSION" -x 120 -y 40
tmux_cmd split-window -t "$TEST_SESSION" -h
sleep 0.3
PANE_A=$(tmux_cmd list-panes -t "$TEST_SESSION" -F '#{pane_index}' | head -1)

# Create second window and switch to it — window with pane A is now inactive
tmux_cmd new-window -t "$TEST_SESSION"
sleep 0.2

# Even though pane A is the "selected" pane in window 1, the window itself is inactive
RESULT_FILE="${WORK_DIR}/result_test4"
run_hook_in_pane "$TEST_SESSION" "$PANE_A" "pane" "$RESULT_FILE"
outcome=$(was_notification_sent "$RESULT_FILE")
if [[ "$outcome" == "sent" ]]; then
    ok "config=pane, inactive window: notification sent"
else
    fail "config=pane, inactive window: expected sent, got $outcome"
fi
cleanup_session
sleep 0.3

# ============================================================
# Test 5: SUPPRESS_WHEN_ACTIVE=none — explicit none, focused => sent
# ============================================================
echo ""
echo "Test 5: E2E — config=none explicitly, pane focused => notification SENT"
tmux_cmd new-session -d -s "$TEST_SESSION" -x 120 -y 40
sleep 0.3
PANE_A=$(tmux_cmd list-panes -t "$TEST_SESSION" -F '#{pane_index}' | head -1)

RESULT_FILE="${WORK_DIR}/result_test5"
run_hook_in_pane "$TEST_SESSION" "$PANE_A" "none" "$RESULT_FILE"
outcome=$(was_notification_sent "$RESULT_FILE")
if [[ "$outcome" == "sent" ]]; then
    ok "config=none: notification sent despite focus"
else
    fail "config=none: expected sent, got $outcome"
fi
cleanup_session
sleep 0.3

# --- Summary ---
echo ""
echo "======================================="
echo "E2E Results: ${PASS} passed, ${FAIL} failed"
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo ""
    echo "Failures:"
    for e in "${ERRORS[@]}"; do
        echo "  - $e"
    done
    exit 1
fi
echo "All E2E tests passed!"
