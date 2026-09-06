#!/bin/bash
# Launches a Heroic game in the headless Sway session
# Usage: start-heroic-game.sh <runner> <game_id>
#   <runner> — one of: legendary, gog, nile, sideload
#   <game_id> — the game identifier for the runner

RUNNER="$1"
GAME_ID="$2"
# Resolve the headless session's Wayland display at runtime (the main desktop
# may occupy wayland-0, wayland-1, or higher depending on DE/uwsm/SDDM).
WAYLAND_DISPLAY=$(sed -n 's/^WAYLAND_DISPLAY=//p' /run/user/$(id -u)/sway-sunshine-display 2>/dev/null)
WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-1}"
LOG_FILE="$HOME/.config/sway-sunshine/start-heroic-game.log"

# Verify the published display is actually live; fall back to scanning live sockets
if command -v wayland-info >/dev/null 2>&1 && ! WAYLAND_DISPLAY="$WAYLAND_DISPLAY" wayland-info >/dev/null 2>&1; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') WARNING: published display $WAYLAND_DISPLAY not live, scanning /run/user/$(id -u)" | tee -a "$LOG_FILE"
    for cand in $(ls /run/user/$(id -u)/ 2>/dev/null | grep -E '^wayland-[0-9]+$'); do
        if WAYLAND_DISPLAY="$cand" wayland-info >/dev/null 2>&1; then
            WAYLAND_DISPLAY="$cand"
            echo "$(date '+%Y-%m-%d %H:%M:%S') using live display $WAYLAND_DISPLAY" | tee -a "$LOG_FILE"
            break
        fi
    done
fi

SWAYSOCK="/run/user/$(id -u)/sway-sunshine.sock"

export WAYLAND_DISPLAY
export SWAYSOCK
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
