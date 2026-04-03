#!/bin/bash
# Tests for suppress notifications when tmux pane is actively focused
# Uses a real tmux session to test the suppression logic end-to-end.
#
# Usage: bash tests/test-suppress-active-pane.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# If running inside tmux, extract the socket path
TMUX_SOCKET=""
if [[ -n "${TMUX:-}" ]]; then
    TMUX_SOCKET=$(echo "$TMUX" | cut -d, -f1)
fi

# Wrapper that passes -S if we know the socket
tmux_cmd() {
    if [[ -n "$TMUX_SOCKET" ]]; then
        /usr/bin/tmux -S "$TMUX_SOCKET" "$@"
    else
        /usr/bin/tmux "$@"
    fi
}

# Test session name (unique to avoid collisions)
TEST_SESSION="__test_suppress_$$"
PASS=0
FAIL=0
ERRORS=()

# Discover pane-base-index (could be 0 or 1)
PANE_BASE=$(tmux_cmd show-options -gv pane-base-index 2>/dev/null || echo "0")

# --- Helpers ---

cleanup() {
    tmux_cmd kill-session -t "$TEST_SESSION" 2>/dev/null || true
}
trap cleanup EXIT

ok() {
    PASS=$((PASS + 1))
    echo "  PASS: $1"
}

fail() {
    FAIL=$((FAIL + 1))
    ERRORS+=("$1")
    echo "  FAIL: $1"
}

assert_eq() {
    local actual="$1" expected="$2" label="$3"
    if [[ "$actual" == "$expected" ]]; then
        ok "$label"
    else
        fail "$label (expected='$expected' got='$actual')"
    fi
}

# Create a 2-pane test session and set PANE_A / PANE_B / WINDOW_A to actual indices
setup_session() {
    tmux_cmd new-session -d -s "$TEST_SESSION" -x 120 -y 40
    tmux_cmd split-window -t "$TEST_SESSION" -h
    sleep 0.3
    # Discover the actual pane and window indices
    PANE_A=$(tmux_cmd list-panes -t "$TEST_SESSION" -F '#{pane_index}' | head -1)
    PANE_B=$(tmux_cmd list-panes -t "$TEST_SESSION" -F '#{pane_index}' | tail -1)
    WINDOW_A=$(tmux_cmd list-panes -t "$TEST_SESSION" -F '#{window_index}' | head -1)
}

# Simulate the suppression check from the hook (must match hooks/tmux-notify.sh logic)
# Args: suppress_config session window_idx pane_idx
should_suppress() {
    local suppress_config="$1" session="$2" window_idx="$3" pane_idx="$4"

    if [[ "${suppress_config:-none}" == "pane" && -n "$session" && -n "$pane_idx" ]]; then
        local _pane_state _pane_active _window_active
        _pane_state=$(tmux_cmd list-panes -t "${session}" -s \
            -F '#{window_index} #{pane_index} #{pane_active} #{window_active}' 2>/dev/null \
            | awk -v widx="$window_idx" -v pidx="$pane_idx" \
                '$1 == widx && $2 == pidx {print $3, $4}')
        _pane_active="${_pane_state%% *}"
        _window_active="${_pane_state##* }"
        if [[ "$_pane_active" == "1" && "$_window_active" == "1" ]]; then
            echo "suppress"
            return
        fi
    fi
    echo "notify"
}

# --- Tests ---

echo "=== PR #3: Suppress Active Pane Tests ==="
echo "(pane-base-index=$PANE_BASE)"
echo ""

# --- Test 1: Config disabled (default) — always notify ---
echo "Test 1: SUPPRESS_WHEN_ACTIVE=none (default) — never suppresses"
setup_session

result=$(should_suppress "none" "$TEST_SESSION" "$WINDOW_A" "$PANE_A")
assert_eq "$result" "notify" "none config, active pane => notify"

result=$(should_suppress "" "$TEST_SESSION" "$WINDOW_A" "$PANE_A")
assert_eq "$result" "notify" "empty config, active pane => notify"

result=$(should_suppress "none" "$TEST_SESSION" "$WINDOW_A" "$PANE_B")
assert_eq "$result" "notify" "none config, inactive pane => notify"

cleanup

# --- Test 2: Config=pane, focused pane => suppress ---
echo ""
echo "Test 2: SUPPRESS_WHEN_ACTIVE=pane — suppresses focused pane"
setup_session

# Select pane A (makes it active)
tmux_cmd select-pane -t "${TEST_SESSION}:.${PANE_A}"
sleep 0.1

result=$(should_suppress "pane" "$TEST_SESSION" "$WINDOW_A" "$PANE_A")
assert_eq "$result" "suppress" "pane config, focused pane A => suppress"

cleanup

# --- Test 3: Config=pane, non-focused pane => notify ---
echo ""
echo "Test 3: SUPPRESS_WHEN_ACTIVE=pane — notifies for non-focused pane"
setup_session

# Select pane A, so pane B is NOT active
tmux_cmd select-pane -t "${TEST_SESSION}:.${PANE_A}"
sleep 0.1

result=$(should_suppress "pane" "$TEST_SESSION" "$WINDOW_A" "$PANE_B")
assert_eq "$result" "notify" "pane config, unfocused pane B => notify"

cleanup

# --- Test 4: Config=pane, window not active => notify ---
echo ""
echo "Test 4: SUPPRESS_WHEN_ACTIVE=pane — notifies when window is not active"
setup_session

# Create a second window and switch to it, making the first window inactive
tmux_cmd new-window -t "$TEST_SESSION"
sleep 0.1

# Pane A in window WINDOW_A is the "selected pane" of that window,
# but the window itself is not active (we're on the new window now)
result=$(should_suppress "pane" "$TEST_SESSION" "$WINDOW_A" "$PANE_A")
assert_eq "$result" "notify" "pane config, inactive window => notify"

cleanup

# --- Test 5: Missing session/pane gracefully falls through to notify ---
echo ""
echo "Test 5: Missing session/pane — falls through to notify"

result=$(should_suppress "pane" "nonexistent_session_$$" "1" "0")
assert_eq "$result" "notify" "pane config, nonexistent session => notify"

result=$(should_suppress "pane" "some_session" "1" "")
assert_eq "$result" "notify" "pane config, empty pane index => notify"

result=$(should_suppress "pane" "" "1" "0")
assert_eq "$result" "notify" "pane config, empty session => notify"

# --- Test 6: Config=pane, switch focus between panes ---
echo ""
echo "Test 6: SUPPRESS_WHEN_ACTIVE=pane — focus switches correctly"
setup_session

# Focus pane A
tmux_cmd select-pane -t "${TEST_SESSION}:.${PANE_A}"
sleep 0.1
result_a=$(should_suppress "pane" "$TEST_SESSION" "$WINDOW_A" "$PANE_A")
result_b=$(should_suppress "pane" "$TEST_SESSION" "$WINDOW_A" "$PANE_B")
assert_eq "$result_a" "suppress" "focus on A: pane A => suppress"
assert_eq "$result_b" "notify" "focus on A: pane B => notify"

# Now switch focus to pane B
tmux_cmd select-pane -t "${TEST_SESSION}:.${PANE_B}"
sleep 0.1
result_a=$(should_suppress "pane" "$TEST_SESSION" "$WINDOW_A" "$PANE_A")
result_b=$(should_suppress "pane" "$TEST_SESSION" "$WINDOW_A" "$PANE_B")
assert_eq "$result_a" "notify" "focus on B: pane A => notify"
assert_eq "$result_b" "suppress" "focus on B: pane B => suppress"

cleanup

# --- Test 7: Verify the actual tmux-notify.sh integration ---
echo ""
echo "Test 7: Integration — config.env has SUPPRESS_WHEN_ACTIVE option"

if grep -q 'SUPPRESS_WHEN_ACTIVE' "$PROJECT_DIR/config.env"; then
    ok "config.env contains SUPPRESS_WHEN_ACTIVE"
else
    fail "config.env missing SUPPRESS_WHEN_ACTIVE"
fi

# Check the default is empty (backward compat)
default_val=$(grep '^SUPPRESS_WHEN_ACTIVE=' "$PROJECT_DIR/config.env" | head -1 | cut -d'"' -f2)
assert_eq "$default_val" "" "config.env default is empty (backward compat)"

# --- Test 8: Verify the hook script has the suppression block ---
echo ""
echo "Test 8: Integration — tmux-notify.sh contains suppression logic"

if grep -q 'SUPPRESS_WHEN_ACTIVE' "$PROJECT_DIR/hooks/tmux-notify.sh"; then
    ok "tmux-notify.sh references SUPPRESS_WHEN_ACTIVE"
else
    fail "tmux-notify.sh missing SUPPRESS_WHEN_ACTIVE reference"
fi

if grep -q 'pane_active.*window_active\|window_active.*pane_active' "$PROJECT_DIR/hooks/tmux-notify.sh"; then
    ok "tmux-notify.sh checks both pane_active AND window_active"
else
    fail "tmux-notify.sh doesn't check both pane_active and window_active"
fi

if grep -q 'list-panes.*-s' "$PROJECT_DIR/hooks/tmux-notify.sh"; then
    ok "tmux-notify.sh uses list-panes -s for accurate window_active"
else
    fail "tmux-notify.sh should use list-panes -s for pane state queries"
fi

# Verify suppression block comes BEFORE the notification sending
suppression_line=$(grep -n 'SUPPRESS_WHEN_ACTIVE' "$PROJECT_DIR/hooks/tmux-notify.sh" | head -1 | cut -d: -f1)
send_line=$(grep -n 'send_ntfy_notification' "$PROJECT_DIR/hooks/tmux-notify.sh" | head -1 | cut -d: -f1)
if [[ "$suppression_line" -lt "$send_line" ]]; then
    ok "suppression check comes before send_ntfy_notification"
else
    fail "suppression check should come before send_ntfy_notification"
fi

# --- Summary ---
echo ""
echo "======================================="
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo ""
    echo "Failures:"
    for e in "${ERRORS[@]}"; do
        echo "  - $e"
    done
    exit 1
fi
echo "All tests passed!"
