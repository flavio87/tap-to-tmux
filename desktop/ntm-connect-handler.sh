#!/bin/bash
# NTM Connect Handler — activated by ntm-connect:// URL scheme on macOS
# Finds the WezTerm tab/pane for a given tmux session and activates it.
#
# URL format: ntm-connect://SESSION_NAME
# Example:    ntm-connect://carltalent
#
# Install: copy to ~/bin/ntm-connect-handler.sh && chmod +x

set -eu

LOG="$HOME/.local/share/ntm-connect/handler.log"
mkdir -p "$(dirname "$LOG")"

log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG"; }

URL="${1:-}"
if [[ -z "$URL" ]]; then
    log "ERROR: no URL provided"
    exit 1
fi

log "Received URL: $URL"

# Parse: ntm-connect://SESSION_NAME
SESSION="${URL#ntm-connect://}"
SESSION="${SESSION%%/*}"      # strip any trailing path
SESSION="${SESSION%%\?*}"     # strip any query params
SESSION="${SESSION%%#*}"      # strip any fragment

if [[ -z "$SESSION" ]]; then
    log "ERROR: could not parse session from URL: $URL"
    exit 1
fi

log "Looking for WezTerm pane with session: $SESSION"

# Fix stale WezTerm CLI socket symlink.
# When WezTerm crashes or gets force-killed, the default-* symlink can point to
# a dead gui-sock-* file, breaking all wezterm cli commands.
WEZTERM_DIR="$HOME/.local/share/wezterm"
WEZTERM_SYMLINK="$WEZTERM_DIR/default-org.wezfurlong.wezterm"
if [[ -L "$WEZTERM_SYMLINK" && ! -e "$WEZTERM_SYMLINK" ]]; then
    # Symlink exists but target is gone — find the newest live gui-sock-*
    # shellcheck disable=SC2012
    LIVE_SOCK=$(ls -t "$WEZTERM_DIR"/gui-sock-* 2>/dev/null | head -1)
    if [[ -n "$LIVE_SOCK" && -S "$LIVE_SOCK" ]]; then
        ln -sf "$(basename "$LIVE_SOCK")" "$WEZTERM_SYMLINK"
        log "Fixed stale WezTerm socket symlink -> $(basename "$LIVE_SOCK")"
    fi
fi

# Use Aerospace to find and focus the correct WezTerm window.
# Aerospace manages workspaces — focusing via aerospace automatically switches
# to the right workspace, which wezterm cli activate-tab cannot do.
AEROSPACE=$(command -v aerospace 2>/dev/null || true)

if [[ -n "$AEROSPACE" ]]; then
    # Aerospace CLI hangs when called directly from AppleScript's do shell script
    # context. Using 'launchctl asuser' runs it in the user's GUI session where
    # Aerospace IPC works reliably.
    UID_NUM=$(id -u)
    AERO_WIN_ID=$(launchctl asuser "$UID_NUM" "$AEROSPACE" list-windows --all --format '%{window-id} | %{app-name} | %{window-title}' 2>/dev/null \
        | grep -i 'wezterm-gui' \
        | grep -i "$SESSION" \
        | head -1 \
        | awk -F' \\| ' '{print $1}' \
        | tr -d ' ') || true

    if [[ -n "$AERO_WIN_ID" ]]; then
        log "Aerospace: focusing window $AERO_WIN_ID for session $SESSION"
        launchctl asuser "$UID_NUM" "$AEROSPACE" focus --window-id "$AERO_WIN_ID" 2>>"$LOG" || log "aerospace focus failed"
        log "Done"
        exit 0
    else
        log "Aerospace: no WezTerm window found for session $SESSION, falling back to wezterm cli"
    fi
fi

# Fallback: use wezterm cli directly (no Aerospace, or no matching window found)
osascript -e 'tell application "WezTerm" to activate' 2>/dev/null || true
sleep 0.3

PANE_LIST=$(wezterm cli list --format json 2>/dev/null || echo "[]")

if [[ "$PANE_LIST" == "[]" ]]; then
    log "WARNING: wezterm cli list returned empty, WezTerm may not be running"
    exit 1
fi

MATCH=$(echo "$PANE_LIST" | python3 -c "
import sys, json
data = json.load(sys.stdin)
session = '$SESSION'
for pane in data:
    title = pane.get('title', '')
    if session in title:
        print(json.dumps({'pane_id': pane['pane_id'], 'tab_id': pane['tab_id'], 'match': 'title', 'title': title}))
        sys.exit(0)
for pane in data:
    cwd = pane.get('cwd', '')
    if '/projects/' + session in cwd or cwd.endswith('/' + session):
        print(json.dumps({'pane_id': pane['pane_id'], 'tab_id': pane['tab_id'], 'match': 'cwd', 'cwd': cwd}))
        sys.exit(0)
for pane in data:
    ws = pane.get('workspace', '')
    if session in ws:
        print(json.dumps({'pane_id': pane['pane_id'], 'tab_id': pane['tab_id'], 'match': 'workspace', 'ws': ws}))
        sys.exit(0)
print('{}')
" 2>/dev/null)

if [[ -z "$MATCH" || "$MATCH" == "{}" ]]; then
    log "No matching pane found for session: $SESSION"
    log "Available panes: $(echo "$PANE_LIST" | python3 -c "import sys,json; [print(p.get('title','?'), p.get('cwd','?')) for p in json.load(sys.stdin)]" 2>/dev/null)"
    exit 0
fi

log "Match found: $MATCH"

PANE_ID=$(echo "$MATCH" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pane_id',''))" 2>/dev/null)
TAB_ID=$(echo "$MATCH" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tab_id',''))" 2>/dev/null)

if [[ -n "$TAB_ID" ]]; then
    log "Activating tab $TAB_ID"
    wezterm cli activate-tab --tab-id "$TAB_ID" 2>>"$LOG" || log "activate-tab failed"
fi

if [[ -n "$PANE_ID" ]]; then
    log "Activating pane $PANE_ID"
    wezterm cli activate-pane --pane-id "$PANE_ID" 2>>"$LOG" || log "activate-pane failed"
fi

log "Done"
