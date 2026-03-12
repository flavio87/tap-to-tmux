#!/bin/bash
# Attach to a tmux session from mobile with independent viewport and pane zoom
# Usage: tmux-mobile-attach.sh SESSION [PANE_INDEX]

# Blink Shell may set TMUX in the calling environment (local tmux),
# which blocks tmux new-session/attach with "should be nested with care".
# We always need to create/attach to the server's tmux, so unset it.
unset TMUX

SESSION="${1:?Usage: tmux-mobile-attach.sh SESSION [PANE_INDEX]}"
PANE="${2:-}"
LOG="/tmp/tmux-mobile-attach.log"

# Safety net: if a stale deep link targets a mob-* session, resolve to its parent
if [[ "$SESSION" == mob-* ]]; then
    _parent=$(tmux display-message -t "$SESSION" -p '#{session_group}' 2>/dev/null)
    if [[ -n "$_parent" && "$_parent" != "$SESSION" ]]; then
        echo "[$(date '+%H:%M:%S')] Redirecting mob- target $SESSION -> $_parent" >> "$LOG"
        SESSION="$_parent"
    else
        echo "[$(date '+%H:%M:%S')] WARNING: target $SESSION is a mob- session with no resolvable parent, trying anyway" >> "$LOG"
    fi
fi

log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG"; echo "$*"; }

log "=== Mobile attach: SESSION=$SESSION PANE=$PANE PID=$$ ==="

# Clean up any stale mob- sessions (unattached, from previous dropped connections)
for s in $(tmux list-sessions -F '#{session_name} #{session_attached}' 2>/dev/null \
    | awk '/^mob-/ && $2 == "0" {print $1}'); do
    log "Cleaning stale session: $s"
    tmux kill-session -t "$s" 2>/dev/null
done

# Validate that the target session actually exists before creating a grouped session
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    log "ERROR: Session '$SESSION' does not exist"
    tmux list-sessions -F '  #{session_name}' 2>/dev/null >> "$LOG"
    echo "Session '$SESSION' no longer exists. Available sessions:"
    tmux list-sessions -F '  #{session_name}' 2>/dev/null
    exit 1
fi

S="mob-$$"
cleanup() {
    log "Cleanup: killing $S"

    # Unzoom before killing — zoom state is window-level (shared across grouped sessions).
    # Without this, the desktop is left with a zoomed pane at mobile dimensions.
    local zoomed
    zoomed=$(tmux display-message -t "$S" -p '#{window_zoomed_flag}' 2>/dev/null || echo "0")
    if [[ "$zoomed" == "1" ]]; then
        log "Unzooming shared pane before cleanup"
        tmux resize-pane -Z -t "$S" 2>/dev/null || true
    fi

    tmux kill-session -t "$S" 2>/dev/null

    # Nudge desktop clients to recalculate window size now that the mobile
    # client (window-size latest) is gone. Without this the window can stay
    # at phone dimensions until the desktop client resizes itself.
    tmux list-clients -t "$SESSION" -F '#{client_name}' 2>/dev/null \
        | while read -r _client; do
            tmux refresh-client -t "$_client" 2>/dev/null || true
          done
}
trap cleanup EXIT

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
log "Grouped session created OK"

log "Setting window-size latest"
tmux set -t "$S" window-size latest 2>>"$LOG" && log "window-size OK" || log "window-size FAILED"

log "Setting status off"
tmux set -t "$S" status off 2>>"$LOG" && log "status OK" || log "status FAILED"

if [[ -n "$PANE" ]]; then
    log "Selecting pane $PANE"
    tmux select-pane -t "$S:.$PANE" 2>>"$LOG" && log "select-pane OK" || log "select-pane FAILED"

    # Zoom via client-attached hook rather than before attach.
    # Pre-attach zoom gets cancelled when the mobile client connects and
    # triggers a layout recalculation (window-size latest + different terminal size).
    log "Setting client-attached hook to zoom pane $PANE"
    tmux set-hook -t "$S" client-attached \
        "select-pane -t .$PANE ; resize-pane -Z -t .$PANE" 2>>"$LOG" \
        && log "zoom hook OK" || log "zoom hook FAILED"
fi

log "Attaching to $S"
tmux attach -t "$S"
