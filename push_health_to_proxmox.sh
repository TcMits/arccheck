#!/bin/bash
#
# push_health_to_proxmox.sh
# Runs disk_health_check.sh in markdown mode and pushes the result into
# this node's "Notes" field, which Proxmox displays right on the node's
# Summary page in the web UI.
#
# Usage: ./push_health_to_proxmox.sh
# Run as root. Intended to be called on a schedule (cron/systemd timer).
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEALTH_SCRIPT="${SCRIPT_DIR}/disk_health_check.sh"
NODE="$(hostname)"

if [ ! -x "$HEALTH_SCRIPT" ]; then
  echo "disk_health_check.sh not found or not executable at: $HEALTH_SCRIPT" >&2
  exit 1
fi

REPORT="$("$HEALTH_SCRIPT" --markdown)"

if [ -z "$REPORT" ]; then
  echo "Health check produced no output - aborting, leaving existing notes untouched." >&2
  exit 1
fi

# pvesh reads the description from stdin via --description, passed as an
# argument here; bash preserves newlines inside the quoted variable.
pvesh set /nodes/"${NODE}"/config --description "$REPORT"

echo "Pushed disk health report to Node Notes for '${NODE}'."
