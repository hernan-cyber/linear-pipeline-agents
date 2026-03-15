#!/bin/bash
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
