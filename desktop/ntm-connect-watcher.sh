#!/bin/bash
# NTM Connect Watcher — polls for trigger file and focuses the matching WezTerm
# window via Aerospace. Runs as a background process in a terminal context where
# Aerospace IPC works (unlike AppleScript's do shell script environment).
#
# Start: nohup ~/bin/ntm-connect-watcher.sh &
# Or add to login items / launchd.

TRIGGER="/tmp/ntm-connect-trigger"
LOG="$HOME/.local/share/ntm-connect/handler.log"
mkdir -p "$(dirname "$LOG")"

log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG"; }

AEROSPACE=$(command -v aerospace 2>/dev/null || true)
if [[ -z "$AEROSPACE" ]]; then
    log "Watcher: aerospace not found, exiting"
    exit 1
fi

log "Watcher: started (PID $$)"

while true; do
    if [[ -f "$TRIGGER" ]]; then
        SESSION=$(cat "$TRIGGER")
        rm -f "$TRIGGER"

        if [[ -n "$SESSION" ]]; then
            log "Watcher: focusing session '$SESSION'"

            # Match exact session name in title pattern [HOST:SESSION] to avoid
            # partial matches (e.g. carlsystem vs carlsystem-improvement-engine)
            AERO_WIN_ID=$("$AEROSPACE" list-windows --all --format '%{window-id} | %{app-name} | %{window-title}' 2>/dev/null \
                | grep -i 'wezterm-gui' \
                | grep -E ":${SESSION}]" \
                | head -1 \
                | awk -F' \\| ' '{print $1}' \
                | tr -d ' ') || true
            # Fallback to loose match if exact didn't find anything
            if [[ -z "$AERO_WIN_ID" ]]; then
                AERO_WIN_ID=$("$AEROSPACE" list-windows --all --format '%{window-id} | %{app-name} | %{window-title}' 2>/dev/null \
                    | grep -i 'wezterm-gui' \
                    | grep -i "$SESSION" \
                    | head -1 \
                    | awk -F' \\| ' '{print $1}' \
                    | tr -d ' ') || true
            fi

            if [[ -n "$AERO_WIN_ID" ]]; then
                "$AEROSPACE" focus --window-id "$AERO_WIN_ID" 2>>"$LOG" || log "Watcher: aerospace focus failed"
                log "Watcher: focused window $AERO_WIN_ID"
            else
                log "Watcher: no WezTerm window found for '$SESSION'"
            fi
        fi
    fi
    sleep 0.2
done
