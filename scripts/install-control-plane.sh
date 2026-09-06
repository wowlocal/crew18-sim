#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python="$project_dir/infra/control-plane/.venv/bin/python"
service="gui/$(id -u)/io.podlodka.control"
plist="$HOME/Library/LaunchAgents/io.podlodka.control.plist"
if [[ ! -x "$python" ]]; then
  printf 'Run uv sync --project infra/control-plane --locked first.\n' >&2
  exit 1
fi
umask 077
mkdir -p "$project_dir/var/control/logs" "$HOME/Library/LaunchAgents"
"$python" - "$project_dir" "$plist" <<'PY'
from pathlib import Path
import plistlib, sys
root, destination = map(Path, sys.argv[1:])
settings = {
    'Label': 'io.podlodka.control',
    'ProgramArguments': [str(root/'infra/control-plane/.venv/bin/python'), '-m', 'crew_control.cli',
                         '--data-dir', str(root/'var/control'), 'serve', '--host', '127.0.0.1', '--port', '4100'],
    'WorkingDirectory': str(root), 'RunAtLoad': True, 'KeepAlive': True,
    'ThrottleInterval': 10, 'ProcessType': 'Background',
    'StandardOutPath': str(root/'var/control/logs/service.log'),
    'StandardErrorPath': str(root/'var/control/logs/service.error.log')
}
with destination.open('wb') as output:
    plistlib.dump(settings, output)
destination.chmod(0o600)
PY
plutil -lint "$plist"
if launchctl print "$service" >/dev/null 2>&1; then
  launchctl bootout "$service"
fi
launchctl bootstrap "gui/$(id -u)" "$plist"
printf 'Local API configured at http://localhost:4100/docs\n'
