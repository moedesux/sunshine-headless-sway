#!/bin/bash
# Shuts down ALL Lutris processes system-wide, cleans up session files, then
# restarts Lutris on the main desktop (wayland-0).
#
# This is used as prep-cmd.undo for Lutris entries in apps.json.
#
# CRITICAL: The script path contains "lutris" so pgrep -f "lutris" matches
# the script itself. We exclude our own PID and parent PID to prevent
# self-termination before restart completes.

LOG="$HOME/.config/sway-sunshine/stop-lutris-game.log"
touch "$LOG" 2>/dev/null
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

log "=== stop-lutris-game.sh started ==="

# Helper: get Lutris PIDs excluding our own process tree
# pgrep -f "lutris" matches this script's own path, so we exclude $$ and $PPID
get_lutris_pids() {
    _my_pid=$$
    pgrep -f "lutris" 2>/dev/null | grep -v "^${PPID}$" | grep -v "^${_my_pid}$" || true
}

# --- Shut down ALL Lutris processes (including children) ---
log "Shutting down all Lutris processes..."
LUTRIS_PIDS=$(get_lutris_pids)

if [ -n "$LUTRIS_PIDS" ]; then
    for PID in $LUTRIS_PIDS; do
        kill -TERM "$PID" 2>/dev/null
    done
else
    log "No Lutris processes found."
fi

# Wait for all Lutris-related processes to exit
log "Waiting for Lutris processes to exit..."
for i in $(seq 1 30); do
    LUTRIS_PIDS=$(get_lutris_pids)
    if [ -z "$LUTRIS_PIDS" ]; then
        break
    fi
    sleep 1
done

# Force kill any remaining Lutris processes
LUTRIS_PIDS=$(get_lutris_pids)
if [ -n "$LUTRIS_PIDS" ]; then
    log "Some Lutris processes still running, force killing..."
    for PID in $LUTRIS_PIDS; do
        kill -KILL "$PID" 2>/dev/null
    done
    sleep 2
fi

# Double-check everything is gone
LUTRIS_PIDS=$(get_lutris_pids)
if [ -n "$LUTRIS_PIDS" ]; then
    log "WARNING: Lutris processes still running after SIGKILL: $LUTRIS_PIDS"
else
    log "All Lutris processes terminated."
fi

# --- Clean up session tracking files ---
log "Cleaning up Lutris session files..."
rm -f /tmp/lutris-* 2>/dev/null

# --- Restart Lutris on the main desktop ---
log "Restarting Lutris on main desktop (wayland-0)..."
if command -v systemd-run >/dev/null 2>&1; then
    log "Using systemd-run to launch Lutris..."
    systemd-run --user --scope --unit=lutris-restore-wayland-0 lutris --open &
    log "Lutris launch command sent via systemd-run."
else
    log "ERROR: systemd-run not found. Cannot restart Lutris."
fi

log "=== stop-lutris-game.sh finished ==="
