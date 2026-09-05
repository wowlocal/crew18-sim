#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"

if [[ ! -f local.env ]]; then
  printf 'Run scripts/install-review-host.sh DEVICE_UDID first.\n' >&2
  exit 1
fi
source ./local.env
: "${TAPFLOW_NODE:?Missing Node path in local.env}"
: "${TAPFLOW_DEVICE:?Missing simulator UDID in local.env}"
export PATH="$(dirname -- "$TAPFLOW_NODE"):/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export TAPFLOW_AUDIO=off
export TAPFLOW_IOS_MAX_SIZE=1200

"$TAPFLOW_NODE" prepare-local-binding.mjs
exec "$TAPFLOW_NODE" node_modules/tapflow/bin/tapflow.js start \
  --platform ios --device "$TAPFLOW_DEVICE"
