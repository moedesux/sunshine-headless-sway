#!/bin/bash
set -euo pipefail

# Headless Sway + Sunshine Game Streaming Setup
# https://github.com/dabiggm0e/sunshine-headless-sway

SWAY_CONFIG_DIR="$HOME/.config/sway-sunshine"
SUNSHINE_CONFIG_DIR="$HOME/.config/sunshine"
SYSTEMD_DIR="$HOME/.config/systemd/user"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

install_audio_policy() {
    local wp_dir="$HOME/.config/wireplumber"
    local wp_scripts="${XDG_DATA_HOME:-$HOME/.local/share}/wireplumber/scripts"
    mkdir -p "$SWAY_CONFIG_DIR" "$wp_scripts" "$wp_dir/wireplumber.conf.d" \
        "$SYSTEMD_DIR/sway-sunshine.service.d" "$SYSTEMD_DIR/sunshine-headless.service.d"
    cp "$SCRIPT_DIR/pipewire/sunshine-host-default.lua" "$wp_scripts/"
    # Remove the obsolete config-directory copy from early audio-policy installs.
    rm -f "$wp_dir/scripts/sunshine-host-default.lua"
    cp "$SCRIPT_DIR/pipewire/sunshine-host-default.conf" "$wp_dir/wireplumber.conf.d/"
    cp "$SCRIPT_DIR/systemd/sway-audio-routing.conf" "$SYSTEMD_DIR/sway-sunshine.service.d/audio-routing.conf"
    cp "$SCRIPT_DIR/systemd/sunshine-audio-routing.conf" "$SYSTEMD_DIR/sunshine-headless.service.d/audio-routing.conf"
    cp "$SCRIPT_DIR/sway-sunshine/restore-default-sink.sh" "$SWAY_CONFIG_DIR/"
    cp "$SCRIPT_DIR/sway-sunshine/set-host-audio-sink.sh" "$SWAY_CONFIG_DIR/"
    chmod +x "$SWAY_CONFIG_DIR/restore-default-sink.sh"
    chmod +x "$SWAY_CONFIG_DIR/set-host-audio-sink.sh"
    systemctl --user stop sunshine-sink-restore.service 2>/dev/null || true
}

# Deploy audio changes without touching display sockets, GPU settings or apps.
# Restart consumers separately, after ending any stream.
if [ "${1:-}" = "--audio-only" ]; then
    install_audio_policy
    systemctl --user daemon-reload
    echo "Audio policy installed. Restart wireplumber, sway-sunshine and sunshine-headless after ending the stream."
    exit 0
fi

echo "=== Headless Sway + Sunshine Installer ==="
echo ""

# Detect package manager
install_pkg() {
    if command -v pacman &>/dev/null; then
        sudo pacman -S --needed --noconfirm "$@"
    elif command -v apt &>/dev/null; then
        sudo apt install -y "$@"
    else
        echo "Error: No supported package manager found (pacman or apt)"
        exit 1
    fi
}

is_pkg_installed() {
    if command -v pacman &>/dev/null; then
        pacman -Qi "$1" &>/dev/null
    elif command -v dpkg &>/dev/null; then
        dpkg -s "$1" &>/dev/null 2>&1
    else
        return 1
    fi
}

# Install dependencies
for cmd in sway swaybg; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Installing sway and swaybg..."
        install_pkg sway swaybg
        break
    fi
done

if ! is_pkg_installed xdg-desktop-portal-wlr; then
    echo "Installing xdg-desktop-portal-wlr..."
    install_pkg xdg-desktop-portal-wlr
fi

# Detect desktop environment
detect_de() {
    local de="${XDG_CURRENT_DESKTOP:-}"
    de="${de,,}"  # lowercase

    if [[ "$de" == *"hyprland"* ]] || [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
        echo "hyprland"
    elif [[ "$de" == *"gnome"* ]] || [[ "$de" == *"unity"* ]] || [[ "$de" == *"budgie"* ]]; then
        echo "gnome"
    elif command -v Hyprland &>/dev/null || command -v hyprctl &>/dev/null; then
        echo "hyprland"
    elif command -v mutter &>/dev/null; then
        echo "gnome"
    else
        echo "unknown"
    fi
}

DETECTED_DE=$(detect_de)

echo ""
if [ "$DETECTED_DE" = "hyprland" ]; then
    echo "Detected desktop environment: Hyprland"
    echo "  → No udev input-isolation rule needed — Sunshine virtual devices are"
    echo "    disabled on the host at runtime via hyprctl (device[...]:enabled)"
elif [ "$DETECTED_DE" = "gnome" ]; then
    echo "Detected desktop environment: GNOME"
    echo "  → Will use mutter-device-ignore for input isolation"
else
    echo "Could not auto-detect desktop environment."
    echo ""
    echo "Input isolation method depends on your desktop:"
    echo "  1) Hyprland — disables Sunshine devices at runtime via hyprctl (no udev rule)"
    echo "  2) GNOME    — uses mutter-device-ignore (targeted, GNOME-only)"
    echo ""
    read -rp "Select your desktop [1/2]: " DE_CHOICE
    case "$DE_CHOICE" in
        1) DETECTED_DE="hyprland" ;;
        2) DETECTED_DE="gnome" ;;
        *)
            echo "Invalid choice. Defaulting to Hyprland method (no udev changes)."
            DETECTED_DE="hyprland"
            ;;
    esac
fi

# Check for Sunshine
SUNSHINE_PATH=""
if command -v sunshine &>/dev/null; then
    SUNSHINE_PATH="$(command -v sunshine)"
elif [ -f "$HOME/Apps/sunshine.AppImage" ]; then
    SUNSHINE_PATH="$HOME/Apps/sunshine.AppImage"
else
    echo ""
    echo "Sunshine not found. Please install it from:"
    echo "  https://github.com/LizardByte/Sunshine/releases"
    echo ""
    read -rp "Enter the path to your Sunshine binary/AppImage: " SUNSHINE_PATH
    if [ ! -f "$SUNSHINE_PATH" ]; then
        echo "Error: $SUNSHINE_PATH not found"
        exit 1
    fi
fi

echo "Using Sunshine at: $SUNSHINE_PATH"

# Detect UID for socket paths
USER_ID=$(id -u)
SOCKET_PATH="/run/user/$USER_ID/sway-sunshine.sock"

# Check for stale sway-sunshine session and stop it gracefully
PID_FILE="/run/user/$USER_ID/sway-sunshine.pid"
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    WAYLAND_SOCKET=""

    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "Found running sway-sunshine session (PID $OLD_PID), stopping..."

        # Scan Wayland socket BEFORE killing — /proc/PID/fd disappears after
        WAYLAND_DIR="/run/user/$USER_ID"
        WAYLAND_SOCKET=$(ls -l /proc/$OLD_PID/fd 2>/dev/null | grep "$WAYLAND_DIR/wayland-" | head -1 | sed 's|.*-> \(.*\)|\1|' || true)

        kill -INT "$OLD_PID"
        for i in $(seq 1 10); do
            kill -0 "$OLD_PID" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "$OLD_PID" 2>/dev/null; then
            echo "Session did not stop gracefully, force killing..."
            kill -9 "$OLD_PID" 2>/dev/null
            sleep 1
        fi
    else
        echo "Found stale PID file (process $OLD_PID not running)"
    fi

    rm -f "$PID_FILE" "$SOCKET_PATH"

    # Remove Wayland socket — use /proc scan result, fall back to filesystem
    WAYLAND_DIR="/run/user/$USER_ID"
    if [ -n "$WAYLAND_SOCKET" ] && [ -e "$WAYLAND_SOCKET" ]; then
        rm -f "$WAYLAND_SOCKET"
        echo "Removed sway-sunshine wayland socket: $WAYLAND_SOCKET"
    else
        # Fallback: remove highest-numbered wayland socket if multiple exist
        WAYLAND_COUNT=$( (ls "$WAYLAND_DIR"/wayland-* 2>/dev/null || true) | grep -v lock | wc -l)
        if [ "$WAYLAND_COUNT" -ge 2 ]; then
            HIGH=$( (ls "$WAYLAND_DIR"/wayland-* 2>/dev/null || true) | grep -v lock | sort | tail -1)
            rm -f "$HIGH"
            echo "Removed stale wayland socket: $(basename "$HIGH")"
        fi
    fi

    echo "Previous session stopped."

    # Restart Sunshine to capture from the new Sway session
    echo "Restarting Sunshine for new Sway session..."
    systemctl --user restart sunshine-headless.service 2>/dev/null || true
    sleep 1
fi

# Detect Wayland display for the headless session
# Strategy: reuse a recorded display from a previous headless session only if
# its socket is currently free; otherwise auto-detect the next free number.
# NOTE: do NOT trust the value in the installed service file — after a DE
# upgrade the main desktop may take a different display number (e.g. omarchy
# 4.0 moved Hyprland from wayland-0 to wayland-1), which would make Sunshine
# capture the main desktop instead of the headless session.
HEADLESS_DISPLAY=""
RUNTIME_DIR="/run/user/$(id -u)"

# 1. Reuse recorded display from a previous session if its socket is free
DISPLAY_FILE="$RUNTIME_DIR/sway-sunshine-display"
if [ -f "$DISPLAY_FILE" ]; then
    CANDIDATE=$(sed -n 's/^WAYLAND_DISPLAY=//p' "$DISPLAY_FILE")
    if [ -n "$CANDIDATE" ] && [ ! -e "$RUNTIME_DIR/$CANDIDATE" ]; then
        HEADLESS_DISPLAY="$CANDIDATE"
        echo "Reusing recorded WAYLAND_DISPLAY=$HEADLESS_DISPLAY (socket is free)"
    fi
fi

# 2. Fall back to auto-detection: next free number after the highest socket
if [ -z "$HEADLESS_DISPLAY" ]; then
    MAIN_WAYLAND=$(ls "$RUNTIME_DIR"/wayland-* 2>/dev/null | grep -v lock | sort | tail -1 | xargs basename 2>/dev/null || true)
    if [ -z "$MAIN_WAYLAND" ]; then
        HEADLESS_DISPLAY="wayland-1"
    elif [ "$MAIN_WAYLAND" = "wayland-0" ]; then
        HEADLESS_DISPLAY="wayland-1"
    else
        HEADLESS_DISPLAY="wayland-$((${MAIN_WAYLAND##wayland-} + 1))"
    fi
    echo "Auto-detected main display: ${MAIN_WAYLAND:-none}, headless will be: $HEADLESS_DISPLAY"
fi

# ─── Host audio sink preference ─────────────────────────────────────────────
# Record the preferred physical desktop output for installer checks and manual
# changes. WirePlumber policy preserves the live default during streams.
# Re-run ./install.sh after changing monitors to re-record the choice.
echo ""
echo "Configuring host audio sink preference..."
mkdir -p "$SWAY_CONFIG_DIR"
HOST_SINK_PREFERENCE_FILE="$SWAY_CONFIG_DIR/host-audio-sink"
CURRENT_DEFAULT_SINK=$(pactl info 2>/dev/null | awk -F': ' '/^Default Sink:/{print $2; exit}' || true)
SAVED_HOST_SINK=$(sed -n '1p' "$HOST_SINK_PREFERENCE_FILE" 2>/dev/null || true)
REAL_SINKS=$(pactl list sinks short 2>/dev/null | awk '{ s = tolower($2); if (s !~ /sunshine/) print }' || true)
HOST_SINK_NAME=""

if [ -z "$REAL_SINKS" ]; then
    echo "  Warning: no non-sunshine audio outputs found — skipping preference."
elif [ -n "$SAVED_HOST_SINK" ] && echo "$REAL_SINKS" | awk '{print $2}' | grep -qxF "$SAVED_HOST_SINK"; then
    HOST_SINK_NAME="$SAVED_HOST_SINK"
    echo "  Using saved host audio sink: $HOST_SINK_NAME"
elif [ -t 0 ]; then
    echo "  Available audio outputs:"
    CHOICE_COUNT=0
    DEFAULT_CHOICE=1
    while read -r idx name _rest; do
        CHOICE_COUNT=$((CHOICE_COUNT + 1))
        if [ "$name" = "$CURRENT_DEFAULT_SINK" ]; then
            mark=" (current default)"
            DEFAULT_CHOICE=$CHOICE_COUNT
        else
            mark=""
        fi
        printf "   %d) %s%s\n" "$CHOICE_COUNT" "$name" "$mark"
    done <<< "$REAL_SINKS"
    read -rp "  Select your main desktop audio sink [1-$CHOICE_COUNT] (default: $DEFAULT_CHOICE): " HOST_SINK_CHOICE || true
    if [[ "${HOST_SINK_CHOICE:-}" =~ ^[0-9]+$ ]] && [ "${HOST_SINK_CHOICE:-0}" -ge 1 ] && [ "${HOST_SINK_CHOICE:-0}" -le "$CHOICE_COUNT" ]; then
        HOST_SINK_NAME=$(echo "$REAL_SINKS" | awk -v n="$HOST_SINK_CHOICE" 'NR==n{print $2}')
    else
        HOST_SINK_NAME=$(echo "$REAL_SINKS" | awk -v n="$DEFAULT_CHOICE" 'NR==n{print $2}')
        echo "  Using selection $DEFAULT_CHOICE: $HOST_SINK_NAME"
    fi
else
    if [ -n "$CURRENT_DEFAULT_SINK" ] && echo "$REAL_SINKS" | awk '{print $2}' | grep -qxF "$CURRENT_DEFAULT_SINK"; then
        HOST_SINK_NAME="$CURRENT_DEFAULT_SINK"
        echo "  Non-interactive: using current default: $HOST_SINK_NAME"
    else
        HOST_SINK_NAME=$(echo "$REAL_SINKS" | awk 'NR==1{print $2}')
        echo "  Non-interactive: using first available: $HOST_SINK_NAME (re-run ./install.sh interactively to change)"
    fi
fi
if [ -n "$HOST_SINK_NAME" ]; then
    printf '%s\n' "$HOST_SINK_NAME" > "$HOST_SINK_PREFERENCE_FILE"
fi

echo ""
echo "Installing config files..."

# Sway config
mkdir -p "$SWAY_CONFIG_DIR"
cp "$SCRIPT_DIR/sway-sunshine/config" "$SWAY_CONFIG_DIR/config"

# Display re-publish helper (invoked from the Sway config; re-publishes the real WAYLAND_DISPLAY after Sway binds its socket)
cp "$SCRIPT_DIR/sway-sunshine/publish-display.sh" "$SWAY_CONFIG_DIR/publish-display.sh"
chmod +x "$SWAY_CONFIG_DIR/publish-display.sh"

# Resolution scripts (template the user ID into them)
sed "s|/run/user/1000/|/run/user/$USER_ID/|g" \
    "$SCRIPT_DIR/sway-sunshine/set-resolution.sh" > "$SWAY_CONFIG_DIR/set-resolution.sh"
sed "s|/run/user/1000/|/run/user/$USER_ID/|g" \
    "$SCRIPT_DIR/sway-sunshine/reset-resolution.sh" > "$SWAY_CONFIG_DIR/reset-resolution.sh"
chmod +x "$SWAY_CONFIG_DIR/set-resolution.sh"
chmod +x "$SWAY_CONFIG_DIR/reset-resolution.sh"

# Steam scripts (WAYLAND_DISPLAY is resolved at runtime by the script itself)
cp "$SCRIPT_DIR/sway-sunshine/start-steam-game.sh" "$SWAY_CONFIG_DIR/start-steam-game.sh"
cp "$SCRIPT_DIR/sway-sunshine/stop-steam-game.sh" "$SWAY_CONFIG_DIR/stop-steam-game.sh"
chmod +x "$SWAY_CONFIG_DIR/start-steam-game.sh"
chmod +x "$SWAY_CONFIG_DIR/stop-steam-game.sh"

# Lutris scripts (WAYLAND_DISPLAY is resolved at runtime by the script itself)
cp "$SCRIPT_DIR/sway-sunshine/start-lutris-game.sh" "$SWAY_CONFIG_DIR/start-lutris-game.sh"
cp "$SCRIPT_DIR/sway-sunshine/stop-lutris-game.sh" "$SWAY_CONFIG_DIR/stop-lutris-game.sh"
chmod +x "$SWAY_CONFIG_DIR/start-lutris-game.sh"
chmod +x "$SWAY_CONFIG_DIR/stop-lutris-game.sh"

# Heroic scripts (WAYLAND_DISPLAY is resolved at runtime by the script itself)
cp "$SCRIPT_DIR/sway-sunshine/start-heroic-game.sh" "$SWAY_CONFIG_DIR/start-heroic-game.sh"
cp "$SCRIPT_DIR/sway-sunshine/stop-heroic-game.sh" "$SWAY_CONFIG_DIR/stop-heroic-game.sh"
chmod +x "$SWAY_CONFIG_DIR/start-heroic-game.sh"
chmod +x "$SWAY_CONFIG_DIR/stop-heroic-game.sh"

# Sway wrapper (tracks session PID for graceful shutdown)
cp "$SCRIPT_DIR/sway-sunshine/sway-wrapper.sh" "$SWAY_CONFIG_DIR/sway-wrapper.sh"
chmod +x "$SWAY_CONFIG_DIR/sway-wrapper.sh"

# Sunshine config (always copy from template)
mkdir -p "$SUNSHINE_CONFIG_DIR"
cp "$SCRIPT_DIR/sunshine/sunshine.conf" "$SUNSHINE_CONFIG_DIR/sunshine.conf"
echo "Installed sunshine.conf"

# Apps config (only if not already present)
if [ ! -f "$SUNSHINE_CONFIG_DIR/apps.json" ]; then
    sed "s|/home/YOUR_USER/|$HOME/|g" \
        "$SCRIPT_DIR/sunshine/apps.json" > "$SUNSHINE_CONFIG_DIR/apps.json"
    sed -i "s|/run/user/1000/|/run/user/$USER_ID/|g" "$SUNSHINE_CONFIG_DIR/apps.json"
    echo "Created apps.json"
else
    echo "apps.json already exists, running migration..."
    # Migrate old Steam entries from cmd-based to detached-based format
    python3 - "$SUNSHINE_CONFIG_DIR/apps.json" "$HOME" <<'PYEOF'
import json
import sys
import re
import base64

apps_json_path = sys.argv[1]
home_dir = sys.argv[2]
start_steam = f"{home_dir}/.config/sway-sunshine/start-steam-game.sh"
stop_steam = f"{home_dir}/.config/sway-sunshine/stop-steam-game.sh"
start_lutris = f"{home_dir}/.config/sway-sunshine/start-lutris-game.sh"
stop_lutris = f"{home_dir}/.config/sway-sunshine/stop-lutris-game.sh"
start_heroic = f"{home_dir}/.config/sway-sunshine/start-heroic-game.sh"
stop_heroic = f"{home_dir}/.config/sway-sunshine/stop-heroic-game.sh"

try:
    with open(apps_json_path, "r") as f:
        data = json.load(f)
except (json.JSONDecodeError, FileNotFoundError) as e:
    print(f"Warning: Could not parse {apps_json_path}: {e}")
    sys.exit(0)

apps = data.get("apps", [])
migrated = 0

def ensure_restore_default_sink(prep_cmds):
    """Add restore-default-sink.sh as first prep-cmd entry if missing."""
    has_restore = any(
        "restore-default-sink.sh" in entry.get("do", "")
        for entry in prep_cmds
    )
    if not has_restore:
        prep_cmds.insert(0, {"do": "$HOME/.config/sway-sunshine/restore-default-sink.sh", "undo": ""})
    return prep_cmds

def dedup_restore(prep_cmds):
    """Remove duplicate restore-default-sink entries, keeping only the first."""
    seen_restore = False
    cleaned = []
    for entry in prep_cmds:
        if "restore-default-sink.sh" in entry.get("do", ""):
            if seen_restore:
                continue
            seen_restore = True
        cleaned.append(entry)
    return cleaned

def migrate_prep_undo(prep_cmds, stop_script):
    """Update set-resolution undo from reset-resolution.sh to stop-<type>-game.sh."""
    for entry in prep_cmds:
        if "set-resolution.sh" in entry.get("do", "") and "reset-resolution.sh" in entry.get("undo", ""):
            entry["undo"] = stop_script
    return prep_cmds

# --- Steam migration ---
for app in apps:
    cmd = app.get("cmd", "")
    detached = app.get("detached", [])

    # Big Picture must stay attached to Sunshine until Steam exits.  Older
    # installations used detached, which made Sunshine run the undo hook as
    # soon as the launcher returned while Steam was still starting.
    if app.get("name") == "Steam Big Picture" and detached:
        app["cmd"] = f"{start_steam} bigpicture --wait"
        app["auto-detach"] = False
        app.pop("detached", None)
        prep_cmds = app.get("prep-cmd", [])
        migrate_prep_undo(prep_cmds, stop_steam)
        app["prep-cmd"] = dedup_restore(prep_cmds)
        migrated += 1
        continue

    # Only migrate entries that use steam://run/ format
    match = re.match(r'^steam\s+steam://run/(\d+)$', cmd.strip())
    if not match:
        continue

    appid = match.group(1)
    print(f"  Migrating: {app.get('name', 'unnamed')} (appid: {appid})")

    # Build the new detached command
    app["detached"] = [f"{start_steam} {appid}"]
    app["cmd"] = ""

    # Update prep-cmd
    prep_cmds = app.get("prep-cmd", [])
    migrate_prep_undo(prep_cmds, stop_steam)
    app["prep-cmd"] = dedup_restore(prep_cmds)

    # Ensure image-path exists for migrated entries
    if "image-path" not in app:
        app["image-path"] = "steam.png"

    migrated += 1

# --- Lutris migration ---
for app in apps:
    cmd = app.get("cmd", "")

    # Only migrate entries that use lutristosunshine-launch-app.sh
    if "lutristosunshine-launch-app.sh" not in cmd:
        continue

    # Extract base64 from the cmd:
    # lutristosunshine-launch-app.sh cmd <timeout> <base64>
    parts = cmd.strip().split()
    if len(parts) < 4:
        print(f"  Skipping: {app.get('name', 'unnamed')} (invalid lutris cmd format)")
        continue

    base64_cmd = parts[3]

    # Decode the base64 command
    try:
        decoded = base64.b64decode(base64_cmd).decode("utf-8")
    except Exception as e:
        print(f"  Skipping: {app.get('name', 'unnamed')} (base64 decode failed: {e})")
        continue

    # Extract game ID from lutris:rungameid/<id>
    id_match = re.search(r'lutris:rungameid/(\d+)', decoded)
    if not id_match:
        print(f"  Skipping: {app.get('name', 'unnamed')} (no game ID found in decoded command: {decoded})")
        continue

    game_id = id_match.group(1)
    print(f"  Migrating: {app.get('name', 'unnamed')} (game_id: {game_id})")

    # Build the new detached command
    app["detached"] = [f"{start_lutris} {game_id}"]
    app["cmd"] = ""

    # Update prep-cmd
    prep_cmds = app.get("prep-cmd", [])
    migrate_prep_undo(prep_cmds, stop_lutris)
    app["prep-cmd"] = ensure_restore_default_sink(prep_cmds)
    app["prep-cmd"] = dedup_restore(app["prep-cmd"])

    # Set image-path
    if "image-path" not in app:
        app["image-path"] = "lutris.png"

    migrated += 1

# --- Heroic migration ---
for app in apps:
    cmd = app.get("cmd", "")

    # Only migrate entries that use heroic://launch/ pattern
    if "heroic://launch/" not in cmd:
        continue

    # Extract runner and game_id from heroic://launch/<runner>/<game_id>
    hero_match = re.search(r'heroic://launch/([^/]+)/([^/\s]+)', cmd)
    if not hero_match:
        print(f"  Skipping: {app.get('name', 'unnamed')} (invalid heroic cmd format)")
        continue

    runner = hero_match.group(1)
    game_id = hero_match.group(2)
    print(f"  Migrating: {app.get('name', 'unnamed')} (runner: {runner}, game_id: {game_id})")

    # Build the new detached command
    app["detached"] = [f"{start_heroic} {runner} {game_id}"]
    app["cmd"] = ""

    # Update prep-cmd
    prep_cmds = app.get("prep-cmd", [])
    migrate_prep_undo(prep_cmds, stop_heroic)
    app["prep-cmd"] = ensure_restore_default_sink(prep_cmds)
    app["prep-cmd"] = dedup_restore(app["prep-cmd"])

    # Set image-path
    if "image-path" not in app:
        app["image-path"] = "heroic.png"

    migrated += 1

if migrated > 0:
    with open(apps_json_path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print(f"  Migrated {migrated} entry(ies) to detached format")
else:
    print("  No entries need migration")
PYEOF
fi

# Systemd services
mkdir -p "$SYSTEMD_DIR"

sed -e "s|/run/user/1000/|/run/user/$USER_ID/|g" \
    -e "s|WAYLAND_DISPLAY=wayland-1|WAYLAND_DISPLAY=$HEADLESS_DISPLAY|g" \
    "$SCRIPT_DIR/systemd/sway-sunshine.service" > "$SYSTEMD_DIR/sway-sunshine.service"

sed -e "s|/run/user/1000/|/run/user/$USER_ID/|g" \
    -e "s|WAYLAND_DISPLAY=wayland-1|WAYLAND_DISPLAY=$HEADLESS_DISPLAY|g" \
    -e "s|ExecStart=.*|ExecStart=$SUNSHINE_PATH|g" \
    "$SCRIPT_DIR/systemd/sunshine-headless.service" > "$SYSTEMD_DIR/sunshine-headless.service"

# PipeWire persistent null sink (survives Moonlight disconnect)
PIPEWIRE_DIR="$HOME/.config/pipewire/pipewire.conf.d"
mkdir -p "$PIPEWIRE_DIR"
cp "$SCRIPT_DIR/pipewire/sunshine-null-sink.conf" "$PIPEWIRE_DIR/sunshine-null-sink.conf"
echo "Installed PipeWire persistent audio sink"
install_audio_policy
systemctl --user restart wireplumber.service

# udev rule: install DE-appropriate input isolation rule
# NOTE: This requires sudo. Running it manually ensures you control the action.
# Hyprland needs no udev rule — Sunshine virtual devices are disabled on the
# host at runtime via hyprctl (see LutrisToSunshine input isolation helper).
if [ "$DETECTED_DE" = "gnome" ]; then
    UDEV_RULE="85-sunshine-input-isolation.rules"
    UDEV_SRC="$SCRIPT_DIR/udev/85-sunshine-input-isolation-gnome.rules"
    echo "Installed GNOME input isolation rule (mutter-device-ignore)"
    echo ""
    echo "To install the udev rule (requires sudo):"
    echo "  sudo cp \"$UDEV_SRC\" \"/etc/udev/rules.d/$UDEV_RULE\""
    echo "  sudo udevadm control --reload-rules"
    echo ""
else
    echo "Hyprland detected — skipping udev input isolation rule (not needed)."
fi

echo "Installed systemd services"

# Reload and enable
systemctl --user daemon-reload
systemctl --user enable sway-sunshine.service
systemctl --user enable sunshine-headless.service

echo ""

# Restart Sunshine to pick up new config and capture from current Sway session
echo "Restarting Sunshine..."
systemctl --user restart sunshine-headless.service 2>/dev/null || true
sleep 1

echo "=== Installation complete ==="
echo ""
echo "Desktop environment: $([ "$DETECTED_DE" = "gnome" ] && echo "GNOME" || echo "Hyprland")"
echo "Wayland display: $HEADLESS_DISPLAY"
echo "Host audio sink: ${HOST_SINK_NAME:-<not set>}"
echo ""
echo "To start streaming now:"
echo "  systemctl --user start sway-sunshine.service"
echo ""
echo "To check status:"
echo "  systemctl --user status sway-sunshine sunshine-headless"
echo ""
echo "To add Steam games to Moonlight, edit:"
echo "  $SUNSHINE_CONFIG_DIR/apps.json"
echo ""
echo "Pair with Moonlight at: https://$(hostname):47990"
echo ""

read -rp "Start the services now? [Y/n] " START
if [[ "${START:-Y}" =~ ^[Yy]?$ ]]; then
    systemctl --user start sway-sunshine.service
    echo "Services started. Open Moonlight to connect."
fi
