#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
service="gui/$(id -u)/io.podlodka.tapflow"
plist="$HOME/Library/LaunchAgents/io.podlodka.tapflow.plist"

case "${1:-status}" in
  start)
    if launchctl print "$service" >/dev/null 2>&1; then
      launchctl kickstart "$service"
    else
      launchctl bootstrap "gui/$(id -u)" "$plist"
    fi
    ;;
  stop)
    launchctl bootout "$service"
    ;;
  restart)
    launchctl kickstart -k "$service"
    ;;
  status)
    launchctl print "$service"
    ;;
  logs)
    tail -n 80 "$project_dir/.tapflow-host/logs/service.log" \
      "$project_dir/.tapflow-host/logs/service.error.log"
    ;;
  *)
    printf 'Usage: %s {start|stop|restart|status|logs}\n' "$0" >&2
    exit 2
    ;;
esac
