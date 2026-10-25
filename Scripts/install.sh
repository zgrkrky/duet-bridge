#!/bin/zsh
# Builds Duet Bridge, installs it to ~/Applications and starts it at login.
# The app is only re-signed when the binary actually changes, so the
# Accessibility permission granted in System Settings survives re-installs.
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$HOME/Applications/Duet Bridge.app"
BIN="$APP/Contents/MacOS/duet-bridge"
LABEL="com.local.duet-bridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

cd "$ROOT"
swift build -c release

mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>Duet Bridge</string>
  <key>CFBundleExecutable</key><string>duet-bridge</string>
  <key>CFBundleIdentifier</key><string>com.local.DuetBridge</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Duet Bridge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

if ! cmp -s .build/release/duet-bridge "$BIN"; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  pkill -x duet-bridge 2>/dev/null || true
  cp .build/release/duet-bridge "$BIN"
  codesign --force --sign - --identifier com.local.DuetBridge "$APP"
  echo "Installed a new binary. macOS will ask for Accessibility permission on first launch."
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
EOF

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "Duet Bridge is running: $APP"
