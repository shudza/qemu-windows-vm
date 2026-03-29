#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_DIR="${XDG_RUNTIME_DIR:-/run}/windows-vm"
PID_FILE="$RUN_DIR/qemu.pid"
MONITOR_SOCK="$RUN_DIR/monitor.sock"
VIRTIOFS_SOCK="$RUN_DIR/virtiofs.sock"
TIMEOUT=10

if [ ! -f "$PID_FILE" ]; then
    echo "No PID file found — VM is not running."
    exit 0
fi

PID=$(cat "$PID_FILE")

if ! kill -0 "$PID" 2>/dev/null; then
    echo "VM process ($PID) not running. Cleaning up stale PID file."
    rm -f "$PID_FILE"
    exit 0
fi

# Send ACPI shutdown via QEMU monitor
echo "Sending ACPI shutdown to VM (PID $PID)..."
if [ -S "$MONITOR_SOCK" ]; then
    echo "system_powerdown" | socat - UNIX-CONNECT:"$MONITOR_SOCK" 2>/dev/null || true
else
    echo "Monitor socket not found. Sending SIGTERM..."
    kill "$PID"
fi

# Wait for graceful shutdown
echo "Waiting up to ${TIMEOUT}s for VM to shut down..."
for i in $(seq "$TIMEOUT"); do
    if ! kill -0 "$PID" 2>/dev/null; then
        echo "VM shut down gracefully."
        rm -f "$PID_FILE"
        if pgrep -f virtiofsd > /dev/null 2>&1; then
            echo "Stopping virtiofsd..."
            sudo pkill -f virtiofsd 2>/dev/null || true
        fi
        rm -f "$VIRTIOFS_SOCK"
        exit 0
    fi
    sleep 1
done

# Force kill
echo "Timeout reached. Force-killing VM (PID $PID)..."
kill -9 "$PID" 2>/dev/null || true
rm -f "$PID_FILE"
echo "VM force-killed."

# Stop virtiofsd
if pgrep -f virtiofsd > /dev/null 2>&1; then
    echo "Stopping virtiofsd..."
    sudo pkill -f virtiofsd 2>/dev/null || true
fi
rm -f "$VIRTIOFS_SOCK"
