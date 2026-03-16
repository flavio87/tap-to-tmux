#!/bin/bash
# Attach to a tmux session from mobile with independent viewport and pane zoom
# Usage: tmux-mobile-attach.sh SESSION [PANE_INDEX]

# Blink Shell may set TMUX in the calling environment (local tmux),
# which blocks tmux new-session/attach with "should be nested with care".
# We always need to create/attach to the server's tmux, so unset it.
unset TMUX

# macOS SSH sessions don't inherit TMPDIR, so tmux can't find the socket.
# Locate the socket explicitly and wrap tmux to always use it.
_tmux_socket="/tmp/tmux-$(id -u)/default"
if [[ ! -S "$_tmux_socket" ]]; then
    _tmux_socket=$(find /tmp /private/tmp -name "default" -path "*/tmux-$(id -u)/*" 2>/dev/null | head -1)
fi
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
tmux() { command tmux -S "$_tmux_socket" "$@"; }

SESSION="${1:?Usage: tmux-mobile-attach.sh SESSION [PANE_INDEX]}"
PANE="${2:-}"
LOG="/tmp/tmux-mobile-attach.log"

ts() { date '+%H:%M:%S.%3N'; }
log() { echo "[$(ts)] $*" >> "$LOG"; echo "$*"; }
log_sessions() { tmux list-sessions -F '  #{session_name} group=#{session_group} attached=#{session_attached}' 2>/dev/null >> "$LOG"; }

# Safety net: if a stale deep link targets a mob-* session, resolve to its parent
if [[ "$SESSION" == mob-* ]]; then
    _parent=$(tmux display-message -t "$SESSION" -p '#{session_group}' 2>/dev/null)
    if [[ -n "$_parent" && "$_parent" != "$SESSION" ]]; then
        echo "[$(ts)] Redirecting mob- target $SESSION -> $_parent" >> "$LOG"
        SESSION="$_parent"
    else
        echo "[$(ts)] WARNING: target $SESSION is a mob- session with no resolvable parent, trying anyway" >> "$LOG"
    fi
fi

log "=== Mobile attach: SESSION=$SESSION PANE=$PANE PID=$$ ==="
log "Sessions at entry:"
log_sessions

# Validate that the target session actually exists before doing anything
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    log "ERROR: Session '$SESSION' does not exist"
    echo "Session '$SESSION' no longer exists. Available sessions:"
    tmux list-sessions -F '  #{session_name}' 2>/dev/null
    exit 1
fi

# Acquire lock BEFORE killing or creating any sessions.
# Blink opens two SSH connections per tap. The loser exits here immediately
# without touching sessions — this prevents the loser's kill loop from
# destroying the mob session the winner just created.
LOCK_FILE="/tmp/tap-to-tmux-mobile-${SESSION}.lock"
if [[ "$(uname)" == "Darwin" ]]; then
    # macOS: flock is not available. Use atomic mkdir instead.
    # Clean up any stale file-based lock left by old flock implementations.
    [[ -f "$LOCK_FILE" ]] && unlink "$LOCK_FILE"
    if ! mkdir "$LOCK_FILE" 2>/dev/null; then
        log "LOSER: lock held by another PID — exiting duplicate (no sessions touched)"
        exit 0
    fi
    trap 'rmdir "$LOCK_FILE" 2>/dev/null' EXIT
else
    # Linux: use flock — kernel-guaranteed, auto-releases if process crashes.
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        log "LOSER: flock held by another PID — exiting duplicate (no sessions touched)"
        exit 0
    fi
fi
log "WINNER: acquired lock at $(ts)"

# We won the lock. Now kill any existing mob sessions for this parent.
# Blink keeps SSH connections alive when backgrounded, so "attached" mob
# sessions accumulate. A new deep link tap means the user wants a fresh
# connection, so we replace the old one unconditionally.
_killed=0
for s in $(tmux list-sessions -F '#{session_name} #{session_group}' 2>/dev/null \
    | awk -v parent="$SESSION" '/^mob-/ && $2 == parent {print $1}'); do
    log "Killing old mob session: $s"
    tmux kill-session -t "$s" 2>/dev/null && log "  killed $s OK" || log "  kill $s FAILED"
    (( _killed++ ))
done
log "Killed $_killed old mob session(s) for $SESSION"

# Also clean up stale mob sessions for other parents (unattached only)
for s in $(tmux list-sessions -F '#{session_name} #{session_attached}' 2>/dev/null \
    | awk '/^mob-/ && $2 == "0" {print $1}'); do
    log "Cleaning stale unattached session: $s"
    tmux kill-session -t "$s" 2>/dev/null
done

log "Sessions after cleanup:"
log_sessions

S="mob-$$"
cleanup() {
    log "=== Cleanup: killing $S ==="

    # Unzoom before killing — zoom state is window-level (shared across grouped sessions).
    # Without this, the desktop is left with a zoomed pane at mobile dimensions.
    local zoomed
    zoomed=$(tmux display-message -t "$S" -p '#{window_zoomed_flag}' 2>/dev/null || echo "0")
    log "Cleanup: window_zoomed_flag=$zoomed"
    if [[ "$zoomed" == "1" ]]; then
        log "Unzooming shared pane before kill"
        tmux resize-pane -Z -t "$S" 2>/dev/null && log "unzoom OK" || log "unzoom FAILED/skipped"
    fi

    tmux kill-session -t "$S" 2>/dev/null && log "kill-session $S OK" || log "kill-session $S FAILED/already gone"

    # Nudge desktop clients to recalculate window size now that the mobile
    # client (window-size latest) is gone. Without this the window can stay
    # at phone dimensions until the desktop client resizes itself.
    local clients
    clients=$(tmux list-clients -t "$SESSION" -F '#{client_name}' 2>/dev/null)
    log "Desktop clients to refresh: ${clients:-none}"
    echo "$clients" | while read -r _client; do
        [[ -z "$_client" ]] && continue
        tmux refresh-client -t "$_client" 2>/dev/null && log "refresh-client $_client OK" || log "refresh-client $_client FAILED"
    done
    log "=== Cleanup done ==="
}
trap cleanup EXIT

log "Pinning $SESSION to window-size largest"
tmux set -t "$SESSION" window-size largest 2>>"$LOG" && log "window-size largest OK" || log "window-size largest FAILED"
_ws=$(tmux show-option -t "$SESSION" -v window-size 2>/dev/null)
log "  verified: window-size=$_ws"

log "Creating grouped session $S -> $SESSION"
if ! tmux new-session -d -t "$SESSION" -s "$S" 2>>"$LOG"; then
    log "FAILED to create grouped session, falling back to direct attach"
    trap - EXIT
    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
        log "ERROR: Session '$SESSION' died before attach"
        echo "Session '$SESSION' no longer exists."
        exit 1
    fi
    tmux attach -t "$SESSION"
    exit
fi
log "Grouped session $S created OK"

# Release the lock now — the establishment race is over.
# Holding it for the full session lifetime would block future taps while
# Blink keeps this SSH connection alive in the background.
if [[ "$(uname)" == "Darwin" ]]; then
    rmdir "$LOCK_FILE" 2>/dev/null
else
    flock -u 200
fi
log "Lock released (establishment complete)"

log "Sessions after new-session:"
log_sessions

log "Setting $S window-size latest"
tmux set -t "$S" window-size latest 2>>"$LOG" && log "window-size latest OK" || log "window-size latest FAILED"
_ws=$(tmux show-option -t "$S" -v window-size 2>/dev/null)
log "  verified: window-size=$_ws"

log "Setting $S status off"
tmux set -t "$S" status off 2>>"$LOG" && log "status off OK" || log "status off FAILED"

if [[ -n "$PANE" ]]; then
    log "Selecting pane $PANE on $S"
    tmux select-pane -t "$S:.$PANE" 2>>"$LOG" && log "select-pane OK" || log "select-pane FAILED"

    # Zoom in a background bash job after terminal resize settles.
    # client-attached hook + run-shell has quoting issues and fires before
    # the SSH terminal negotiates its size. A bg job is simpler and more
    # debuggable. The job runs while tmux attach blocks the main script.
    (
        log() { echo "[$(ts)] $*" >> "$LOG"; }  # file-only in bg job — no stdout bleed into tmux
        sleep 0.5
        # resize-pane -Z is a toggle. Check current state before deciding what to do.
        # On reconnect the zoom from the previous mob session persists on the shared
        # window — if we're already zoomed on the right pane, skip entirely (no resize,
        # no cursor offset). Only unzoom+select+zoom if the wrong pane is zoomed.
        _flag=$(tmux display-message -t "$S" -p '#{window_zoomed_flag}' 2>/dev/null || echo "0")
        _pane_active=$(tmux display-message -t "$S:.$PANE" -p '#{pane_active}' 2>/dev/null || echo "0")
        log "bg-zoom: flag=$_flag pane_active=$_pane_active"
        if [[ "$_flag" == "1" && "$_pane_active" == "1" ]]; then
            log "bg-zoom: already zoomed on correct pane — nothing to do"
        elif [[ "$_flag" == "1" ]]; then
            log "bg-zoom: zoomed on wrong pane — unzoom, select, zoom"
            tmux resize-pane -Z -t "$S" 2>/dev/null
            tmux select-pane -t "$S:.$PANE" 2>/dev/null
            tmux resize-pane -Z -t "$S:.$PANE" 2>/dev/null
            log "bg-zoom fired: flag=$(tmux display-message -t "$S" -p '#{window_zoomed_flag}' 2>/dev/null)"
        else
            log "bg-zoom: not zoomed — select and zoom"
            tmux select-pane -t "$S:.$PANE" 2>/dev/null
            if tmux resize-pane -Z -t "$S:.$PANE" 2>/dev/null; then
                _flag=$(tmux display-message -t "$S" -p '#{window_zoomed_flag}' 2>/dev/null || echo "dead")
                log "bg-zoom fired: flag=$_flag"
            else
                log "bg-zoom FAILED (session/pane gone?)"
            fi
        fi
        sleep 1
        _flag2=$(tmux display-message -t "$S" -p '#{window_zoomed_flag}' 2>/dev/null || echo "dead")
        log "bg-zoom check 1s later: flag=$_flag2"
    ) &
    log "bg-zoom job started (PID $!), fires in 0.5s"
fi

log "Attaching to $S — handoff to tmux"
tmux attach -t "$S"
log "tmux attach returned (session ended)"
