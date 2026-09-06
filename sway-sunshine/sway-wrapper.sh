#!/bin/bash
# Wrapper for sway-sunshine that tracks the session PID for graceful shutdown
# Written by systemd as ExecStart, replaces /usr/bin/sway directly

RUNTIME_DIR="/run/user/$(id -u)"
PID_FILE="$RUNTIME_DIR/sway-sunshine.pid"
DISPLAY_FILE="$RUNTIME_DIR/sway-sunshine-display"

# Detect the next available Wayland display number. The main desktop may occupy
# wayland-0, wayland-1, or higher depending on DE/uwsm/SDDM (e.g. omarchy 4.0
# puts Hyprland on wayland-1). Always take the next free number so Sunshine
# never captures the main desktop by accident.
NEXT=0
for sock in "$RUNTIME_DIR"/wayland-*; do
    [ -e "$sock" ] || continue
    case "$sock" in
        *lock*) continue ;;
    esac
    num="${sock##*wayland-}"
    case "$num" in
        ''|*[!0-9]*) continue ;;
    esac
    [ "$num" -gt "$NEXT" ] && NEXT=$num
done
WAYLAND_DISPLAY="wayland-$((NEXT + 1))"
export WAYLAND_DISPLAY

# Record the display number so sunshine-headless.service (via EnvironmentFile)
# and the game launcher scripts can target this session regardless of the main
# desktop's numbering. Format is KEY=VALUE for systemd EnvironmentFile.
echo "WAYLAND_DISPLAY=$WAYLAND_DISPLAY" > "$DISPLAY_FILE"

# Write PID file so install.sh can detect/stop a running session
echo $$ > "$PID_FILE"
trap 'rm -f "$PID_FILE"' EXIT

exec /usr/bin/sway --config "$HOME/.config/sway-sunshine/config"
