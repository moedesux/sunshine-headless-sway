#!/bin/bash
# Launches a Steam game in the headless Sway session
# Usage: start-steam-game.sh <appid|bigpicture|0>
# Migrates Steam from the main desktop if it's running there

APPID="$1"
# Resolve the headless session's Wayland display at runtime (the main desktop
# may occupy wayland-0, wayland-1, or higher depending on DE/uwsm/SDDM).
WAYLAND_DISPLAY=$(sed -n 's/^WAYLAND_DISPLAY=//p' /run/user/$(id -u)/sway-sunshine-display 2>/dev/null)
WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-1}"
LOG_FILE="$HOME/.config/sway-sunshine/start-steam-game.log"

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

# Sway IPC socket for the headless session
SWAYSOCK="/run/user/$(id -u)/sway-sunshine.sock"

export WAYLAND_DISPLAY
export SWAYSOCK
echo "[$(date)] Environment: WAYLAND_DISPLAY=$WAYLAND_DISPLAY, SWAYSOCK=$SWAYSOCK" >> "$LOG_FILE"
echo "[$(date)] Launching Steam game $APPID" >> "$LOG_FILE"

echo "Unlocking session" >> "$LOG_FILE"
loginctl unlock-session


if [ -z "$APPID" ]; then
    echo "Usage: $0 <steam_appid|bigpicture|0>"
    exit 1
fi

# Disable the omarchy screensaver for the duration of this game stream. The
# GPU-heavy TTE screensaver effect runs on the main Hyprland desktop while the
# game runs in the headless Sway session and competes for GPU resources, which
# drops in-game FPS. `omarchy-toggle screensaver-off on` creates the flag file
# that gates omarchy-launch-screensaver; the stop script removes it at stream
# end to restore the default (enabled) state.
if command -v omarchy-toggle >/dev/null 2>&1; then
    omarchy-toggle screensaver-off on 2>/dev/null \
        && echo "[$(date)] Screensaver disabled (omarchy-toggle screensaver-off on)" >> "$LOG_FILE" \
        || echo "[$(date)] WARNING: failed to disable omarchy screensaver" >> "$LOG_FILE"
else
    echo "[$(date)] NOTE: omarchy-toggle not found, skipping screensaver disable" >> "$LOG_FILE"
fi

# Shut down any running Steam instance
if pgrep -x steam > /dev/null 2>&1; then
    steam -shutdown 2>/dev/null
    # Wait for graceful shutdown
    for i in $(seq 1 15); do
        pgrep -x steam > /dev/null 2>&1 || break
        sleep 1
    done
    # Force kill only if still running
    if pgrep -x steam > /dev/null 2>&1; then
        pkill -x steam 2>/dev/null
        sleep 2
    fi
fi

# Clean up Steam IPC to prevent instance detection
rm -f ~/.steam/steam.pid 2>/dev/null
rm -f /tmp/steam_singleton_* 2>/dev/null

# Test swaymsg connection
SWAYMSG_OUTPUT=$(SWAYSOCK="$SWAYSOCK" swaymsg -t get_outputs 2>&1)
if [ $? -ne 0 ]; then
    echo "[$(date)] ERROR: swaymsg failed to connect: $SWAYMSG_OUTPUT" >> "$LOG_FILE"
    exit 1
fi

# Launch Steam in the headless Sway session
if [ "$APPID" = "bigpicture" ]; then
    EXEC_OUTPUT=$(SWAYSOCK="$SWAYSOCK" swaymsg exec "steam steam://open/bigpicture" 2>&1)
    EXEC_CODE=$?
elif [ "$APPID" = "0" ]; then
    EXEC_OUTPUT=$(SWAYSOCK="$SWAYSOCK" swaymsg exec steam 2>&1)
    EXEC_CODE=$?
else
    EXEC_OUTPUT=$(SWAYSOCK="$SWAYSOCK" swaymsg exec "steam -applaunch $APPID" 2>&1)
    EXEC_CODE=$?
fi

echo "[$(date)] swaymsg exec exit code: $EXEC_CODE, output: $EXEC_OUTPUT" >> "$LOG_FILE"
