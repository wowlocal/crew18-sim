#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
host_dir="$project_dir/.tapflow-host"
service="gui/$(id -u)/io.podlodka.tapflow"
plist="$HOME/Library/LaunchAgents/io.podlodka.tapflow.plist"
device="${1:-}"
node_binary="${NODE_BINARY:-$(command -v node || true)}"

if [[ -z "$device" || $# -ne 1 ]]; then
  printf 'Usage: %s DEVICE_UDID\nFind a simulator with: xcrun simctl list devices available\n' "$0" >&2
  exit 2
fi
if [[ -z "$node_binary" ]]; then
  printf 'Install Node.js 22 or newer, then install the host npm dependencies.\n' >&2
  exit 1
fi
node_binary="$("$node_binary" -p 'process.execPath')"
"$node_binary" -e 'if (Number(process.versions.node.split(".")[0]) < 22) { console.error("Node.js 22 or newer is required."); process.exit(1); }'
if [[ ! -f "$host_dir/node_modules/tapflow/bin/tapflow.js" ]]; then
  printf 'Install dependencies in .tapflow-host first; see docs/remote-review.md.\n' >&2
  exit 1
fi
xcrun simctl list devices available --json | "$node_binary" -e '
  let data = "";
  process.stdin.on("data", part => data += part);
  process.stdin.on("end", () => {
    const devices = Object.values(JSON.parse(data).devices).flat();
    if (!devices.some(device => device.udid === process.argv[1])) {
      console.error("Simulator UDID is unavailable:", process.argv[1]);
      process.exit(1);
    }
  });
' "$device"
"$node_binary" "$host_dir/prepare-local-binding.mjs"

umask 077
mkdir -p "$host_dir/logs" "$HOME/Library/LaunchAgents"
chmod 700 "$host_dir"
printf 'TAPFLOW_NODE=%q\nTAPFLOW_DEVICE=%q\n' "$node_binary" "$device" > "$host_dir/local.env"
"$node_binary" --input-type=module - "$host_dir" "$plist" <<'JS'
import { writeFileSync } from 'node:fs';
const [host, plist] = process.argv.slice(2);
const escape = value => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
writeFileSync(plist, `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>io.podlodka.tapflow</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/caffeinate</string><string>-i</string>
    <string>/bin/bash</string><string>${escape(host)}/start.sh</string>
  </array>
  <key>WorkingDirectory</key><string>${escape(host)}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>${escape(host)}/logs/service.log</string>
  <key>StandardErrorPath</key><string>${escape(host)}/logs/service.error.log</string>
</dict></plist>
`, { mode: 0o600 });
JS
plutil -lint "$plist"
if launchctl print "$service" >/dev/null 2>&1; then
  launchctl bootout "$service"
fi
launchctl bootstrap "gui/$(id -u)" "$plist"
printf 'Tapflow installed for simulator %s. Open http://localhost:4000\n' "$device"
