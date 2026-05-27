#!/bin/bash
LOG="$HOME/.config/sway-sunshine/stop-steam-game.log"
touch "$LOG" 2>/dev/null
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}
log "=== stop-steam-game.sh started ==="

MY_PID=$$

# Function: collect all descendants of a PID recursively
collect_descendants() {
    local parent=$1
    local children
    children=$(pgrep -P "$parent" 2>/dev/null)
    for child in $children; do
        [[ "$child" == "$MY_PID" ]] && continue
        [[ "$child" == "$$" ]] && continue
        echo "$child"
        collect_descendants "$child"  # recurse into grandchildren
    done
}

# Function: collect all processes matching a pattern, excluding self
collect_matching() {
    local pattern="$1"
    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        [[ "$pid" == "$MY_PID" ]] && continue
        [[ "$pid" == "$$" ]] && continue
        echo "$pid"
    done < <(pgrep -f "$pattern" 2>/dev/null)
}

# Step 1: Kill main steam binary
log "Shutting down all Steam processes..."
pkill -TERM -x steam 2>/dev/null

# Step 2: Find all Steam parent PIDs
steam_pids=""
while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    [[ "$pid" == "$MY_PID" ]] && continue
    [[ "$pid" == "$$" ]] && continue
    steam_pids="$steam_pids $pid"
done < <(pgrep -f '[s]team' 2>/dev/null)

# Also catch Steam-wrapped processes (steamui, steamwebhelper, steamcmd, steam_startup, SteamThreadService, SteamGpuThread, steamrt, etc.)
while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    [[ "$pid" == "$MY_PID" ]] && continue
    [[ "$pid" == "$$" ]] && continue
    steam_pids="$steam_pids $pid"
done < <(pgrep -f 'steam[ui]?|steamwebhelper|steamcmd|steam_startup|SteamThreadService|SteamGpuThread|steamrt|SteamAcl|SteamUpdate' 2>/dev/null)

# Deduplicate steam_pids
if [[ -n "$steam_pids" ]]; then
    steam_pids=$(echo "$steam_pids" | tr ' ' '\n' | sort -un | tr '\n' ' ')
fi

# Step 3: Collect all descendants recursively
all_descendants=""
for spid in $steam_pids; do
    while IFS= read -r depid; do
        [[ -z "$depid" ]] && continue
        [[ "$depid" == "$MY_PID" ]] && continue
        [[ "$depid" == "$$" ]] && continue
        all_descendants="$all_descendants $depid"
    done < <(collect_descendants "$spid")
done

# Step 4: Kill all descendants first (so parent dies last)
kill_all() {
    local sig="$1"
    shift
    for pid in "$@"; do
        kill -"$sig" "$pid" 2>/dev/null
    done
}

# Get unique descendants
if [[ -n "$all_descendants" ]]; then
    all_descendants=$(echo "$all_descendants" | tr ' ' '\n' | sort -un | tr '\n' ' ')
    log "Found $(echo "$all_descendants" | wc -w) descendants to kill"
    kill_all TERM $all_descendants
fi

# Then kill Steam parents
if [[ -n "$steam_pids" ]]; then
    log "Found $(echo "$steam_pids" | wc -w) Steam parent PID(s)"
    kill_all TERM $steam_pids
fi

# Step 5: Wait for graceful exit
log "Waiting for processes to exit..."
sleep 2  # Initial wait

for i in $(seq 1 28); do
    # Check if any Steam parents or descendants still exist
    any_still=0
    for pid in $steam_pids $all_descendants; do
        if kill -0 "$pid" 2>/dev/null; then
            any_still=1
            break
        fi
    done
    if [[ "$any_still" -eq 0 ]]; then
        break
    fi
    sleep 1
done

# Step 6: Force kill any remaining
if kill -0 $steam_pids $all_descendants 2>/dev/null || pgrep -f '[s]team' > /dev/null 2>&1; then
    log "Force killing remaining processes..."

    # Collect any remaining PIDs via tree traversal of any surviving Steam parent
    remaining_pids="$all_descendants $steam_pids"
    for spid in $steam_pids; do
        if kill -0 "$spid" 2>/dev/null; then
            while IFS= read -r depid; do
                [[ -z "$depid" ]] && continue
                remaining_pids="$remaining_pids $depid"
            done < <(collect_descendants "$spid")
        fi
    done

    remaining_pids=$(echo "$remaining_pids" | tr ' ' '\n' | sort -un | tr '\n' ' ')
    kill_all KILL $remaining_pids

    # Also kill wineserver (Wine/Proton environment)
    log "Killing wineserver processes..."
    pkill -KILL -x wineserver 2>/dev/null
fi

sleep 1

# Step 7: Final check
if pgrep -f '[s]team' > /dev/null 2>&1 || pgrep -x wineserver > /dev/null 2>&1; then
    log "WARNING: Some processes still running"
else
    log "All Steam processes terminated."
fi

# Step 8: Clean up IPC
log "Cleaning up IPC files..."
rm -f ~/.steam/steam.pid 2>/dev/null
rm -f /tmp/steam_singleton_* 2>/dev/null

# Step 9: Restart Steam on main desktop
log "Restarting Steam on main desktop (wayland-0)..."
if command -v systemd-run >/dev/null 2>&1; then
    log "Using systemd-run to launch Steam..."
    systemd-run --user --scope --unit=steam-restore-wayland-0 steam &
    log "Steam launch command sent via systemd-run."
else
    log "ERROR: systemd-run not found. Cannot restart Steam."
fi

log "=== stop-steam-game.sh finished ==="
