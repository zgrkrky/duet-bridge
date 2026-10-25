#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BIN="$HOME/Applications/Duet Bridge.app/Contents/MacOS/duet-bridge"
LABEL="com.local.duet-bridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

case "${1:-status}" in
  install)
    "$ROOT/Scripts/install.sh"
    ;;
  start)
    launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || launchctl kickstart -k "$DOMAIN/$LABEL"
    ;;
  stop)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    ;;
  restart)
    launchctl kickstart -k "$DOMAIN/$LABEL"
    ;;
  status)
    launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -E '^\s+(state|pid) =' || echo "not loaded"
    "$BIN" --status || true
    echo "--- log ---"
    tail -10 "$HOME/Library/Logs/DuetBridge.log" 2>/dev/null || true
    ;;
  *)
    echo "Usage: $0 {install|start|stop|restart|status}" >&2
    exit 2
    ;;
esac
