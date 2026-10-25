#!/bin/zsh
set -euo pipefail

case "${1:-}" in
  --restart)
    echo "Quitting Apogee Control 2..."
    osascript -e 'tell application "Apogee Control 2" to quit' 2>/dev/null || true

    echo "Restarting Apogee launch daemons. This may ask for your password."
    sudo launchctl kickstart -k system/com.apogeedigital.apogeeglue
    sudo launchctl kickstart -k system/com.apogeedigital.apogeemessenger

    echo "Reopening Apogee Control 2..."
    open -a "Apogee Control 2"
    ;;
  *)
    printf "%-8s %-7s %-12s %s\n" "PID" "%CPU" "ELAPSED" "COMMAND"
    ps -axo pid=,pcpu=,etime=,command= \
      | awk '/[A]pogeeGlue|[A]pogeeMessenger|[A]pogee Control 2|[A]pogeeTalkbackHelper/ {
          printf "%-8s %-7s %-12s %s\n", $1, $2, $3, substr($0, index($0,$4))
        }'
    echo
    echo "Run with --restart only when you are not in an active audio session."
    ;;
esac
