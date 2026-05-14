#!/bin/bash
# Launches a Heroic game in the headless Sway session
# Usage: start-heroic-game.sh <runner> <game_id>
#   <runner> — one of: legendary, gog, nile, sideload
#   <game_id> — the game identifier for the runner

RUNNER="$1"
GAME_ID="$2"
WAYLAND_DISPLAY="wayland-1"

SWAYSOCK="/run/user/$(id -u)/sway-sunshine.sock"

export WAYLAND_DISPLAY
export SWAYSOCK

LOG_FILE="$HOME/.config/sway-sunshine/start-heroic-game.log"
echo "[$(date)] Environment: WAYLAND_DISPLAY=$WAYLAND_DISPLAY, SWAYSOCK=$SWAYSOCK" >> "$LOG_FILE"

echo "Unlocking session" >> "$LOG_FILE"
loginctl unlock-session

# Validate both arguments are provided
if [ -z "$RUNNER" ]; then
    echo "Usage: $0 <runner> <game_id>"
    echo "  runner: legendary, gog, nile, sideload"
    exit 1
fi

if [ -z "$GAME_ID" ]; then
    echo "Usage: $0 <runner> <game_id>"
    echo "  runner: legendary, gog, nile, sideload"
    exit 1
fi

echo "[$(date)] Launching Heroic game: runner=$RUNNER, game_id=$GAME_ID" >> "$LOG_FILE"

# Test swaymsg connection
SWAYMSG_OUTPUT=$(SWAYSOCK="$SWAYSOCK" swaymsg -t get_outputs 2>&1)
if [ $? -ne 0 ]; then
    echo "[$(date)] ERROR: swaymsg failed to connect: $SWAYMSG_OUTPUT" >> "$LOG_FILE"
    exit 1
fi

# Launch Heroic game in the headless Sway session
EXEC_OUTPUT=$(SWAYSOCK="$SWAYSOCK" swaymsg exec "heroic heroic://launch/$RUNNER/$GAME_ID --no-gui --no-sandbox" 2>&1)
EXEC_CODE=$?

echo "[$(date)] swaymsg exec exit code: $EXEC_CODE, output: $EXEC_OUTPUT" >> "$LOG_FILE"
