#!/bin/bash
# Live operations are opt-in; cloud preparation and audits stay inert.
if [[ "${LINEAR_PIPELINE_ENABLE_LIVE:-}" != "1" ]]; then
  printf '%s\n' 'Live pipeline disabled. Static audit: python3 tools/cloud_audit.py'
  exit 0
fi
# End live-operation gate.
# Start both pipeline driver and watcher
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "$SCRIPT_DIR/.env" ]; then
  echo "No .env file found. Run setup.sh first."
  exit 1
fi

echo "Starting pipeline driver in background..."
bash "$SCRIPT_DIR/scripts/pipeline-driver.sh" &
DRIVER_PID=$!
echo "Driver PID: $DRIVER_PID"

echo "Starting pipeline watcher (Ctrl+C to stop both)..."
trap "kill $DRIVER_PID 2>/dev/null; exit 0" INT TERM
bash "$SCRIPT_DIR/scripts/pipeline-watch.sh"
