#!/bin/bash
# Install NTM Connect URL handler on macOS
# Run: bash install-macos.sh
#
# After install, clicking ntm-connect://SESSION links in the browser
# will activate the corresponding WezTerm tab.

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== NTM Connect macOS Handler Installer ==="

# 1. Install handler script
mkdir -p ~/bin
cp "$SCRIPT_DIR/ntm-connect-handler.sh" ~/bin/
chmod +x ~/bin/ntm-connect-handler.sh
echo "Installed handler script to ~/bin/ntm-connect-handler.sh"

# 2. Compile AppleScript app
APP_DIR="$HOME/Applications"
mkdir -p "$APP_DIR"
if [[ -d "$APP_DIR/NTMConnect.app" ]]; then
    echo "Removing old NTMConnect.app"
    rm -rf "$APP_DIR/NTMConnect.app"
fi
osacompile -o "$APP_DIR/NTMConnect.app" "$SCRIPT_DIR/NTMConnect.applescript"
echo "Compiled AppleScript app to $APP_DIR/NTMConnect.app"

# 3. Patch Info.plist to register URL scheme
PLIST="$APP_DIR/NTMConnect.app/Contents/Info.plist"
if ! grep -q "CFBundleURLTypes" "$PLIST" 2>/dev/null; then
    # Insert URL scheme before the closing </dict></plist>
    # Use python for reliable plist editing
    python3 -c "
import plistlib, sys

with open('$PLIST', 'rb') as f:
    plist = plistlib.load(f)

plist['CFBundleURLTypes'] = [{
    'CFBundleURLName': 'NTM Connect',
    'CFBundleURLSchemes': ['ntm-connect'],
}]

with open('$PLIST', 'wb') as f:
    plistlib.dump(plist, f)

print('Registered ntm-connect:// URL scheme')
"
else
    echo "URL scheme already registered in Info.plist"
fi

# 4. Reset Launch Services to pick up the new handler
echo "Resetting Launch Services database..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP_DIR/NTMConnect.app" 2>/dev/null || true

# 5. Open the app once to complete registration
echo "Opening NTMConnect.app to complete registration..."
open "$APP_DIR/NTMConnect.app"
sleep 1

echo ""
echo "=== Done ==="
echo "Test it: open ntm-connect://carltalent"
echo "Or click an ntm-connect:// link in the NTM dashboard."
echo ""
echo "Handler log: ~/.local/share/ntm-connect/handler.log"
