#!/bin/bash
# Launches a Lutris game in the headless Sway session
# Usage: start-lutris-game.sh <lutris_game_id|lutris>
#   <lutris_game_id> — launches the game via lutris:rungameid/<id>
#   lutris            — opens the Lutris launcher UI
# Migrates Lutris from the main desktop if it's running there

GAME_ID="$1"
WAYLAND_DISPLAY="wayland-1"

# Sway IPC socket for the headless session
SWAYSOCK="/run/user/$(id -u)/sway-sunshine.sock"

export WAYLAND_DISPLAY
export SWAYSOCK


LOG_FILE="$HOME/.config/sway-sunshine/start-lutris-game.log"
echo "[$(date)] Environment: WAYLAND_DISPLAY=$WAYLAND_DISPLAY, SWAYSOCK=$SWAYSOCK" >> "$LOG_FILE"


echo "Unlocking session" >> "$LOG_FILE"
loginctl unlock-session

if [ -z "$GAME_ID" ]; then
    echo "Usage: $0 <lutris_game_id|lutris>"
    exit 1
fi

echo "[$(date)] Launching Lutris game $GAME_ID" >> "$LOG_FILE"

# Helper: get Lutris PIDs excluding our own process tree
# pgrep -f "lutris" matches the script's own path, so we exclude $$ and $PPID
# (Using a variable for $$ because "$$$\$" expands incorrectly in double-quoted strings)
get_lutris_pids() {
    _my_pid=$$
    pgrep -f "lutris" 2>/dev/null | grep -v "^${PPID}$" | grep -v "^${_my_pid}$" || true
}

# Shut down any running Lutris instance
LUTRIS_PIDS=$(get_lutris_pids)
if [ -n "$LUTRIS_PIDS" ]; then
    echo "[$(date)] Existing Lutris processes detected, shutting down..." >> "$LOG_FILE"

    # Send SIGTERM to all Lutris processes (excluding self)
    for PID in $LUTRIS_PIDS; do
        kill -TERM "$PID" 2>/dev/null
    done

    # Wait for graceful shutdown (up to 15s)
    for i in $(seq 1 15); do
        LUTRIS_PIDS=$(get_lutris_pids)
        [ -z "$LUTRIS_PIDS" ] && break
        sleep 1
    done

    # Force kill only if still running
    if [ -n "$LUTRIS_PIDS" ]; then
        echo "[$(date)] Lutris still running after SIGTERM, sending SIGKILL..." >> "$LOG_FILE"
        for PID in $LUTRIS_PIDS; do
            kill -KILL "$PID" 2>/dev/null
        done
        sleep 2
    fi

    echo "[$(date)] Lutris shutdown complete." >> "$LOG_FILE"
fi

# Clean up Lutris session tracking to prevent DBus single-instance detection
rm -f /tmp/lutris-* 2>/dev/null

# Test swaymsg connection
SWAYMSG_OUTPUT=$(SWAYSOCK="$SWAYSOCK" swaymsg -t get_outputs 2>&1)
if [ $? -ne 0 ]; then
    echo "[$(date)] ERROR: swaymsg failed to connect: $SWAYMSG_OUTPUT" >> "$LOG_FILE"
    exit 1
fi

# Launch Lutris in the headless Sway session
if [ "$GAME_ID" = "lutris" ]; then
    EXEC_OUTPUT=$(SWAYSOCK="$SWAYSOCK" swaymsg exec "lutris --open" 2>&1)
    EXEC_CODE=$?
else
    EXEC_OUTPUT=$(SWAYSOCK="$SWAYSOCK" swaymsg exec "lutris lutris:rungameid/$GAME_ID" 2>&1)
    EXEC_CODE=$?
fi

echo "[$(date)] swaymsg exec exit code: $EXEC_CODE, output: $EXEC_OUTPUT" >> "$LOG_FILE"
