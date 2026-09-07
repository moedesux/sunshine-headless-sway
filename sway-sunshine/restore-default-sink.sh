#!/bin/bash
#
# restore-default-sink.sh — restores the host's default audio sink after a
# Sunshine stream ends.
#
# While a Moonlight client is connected, Sunshine points the system default
# audio sink at its own null capture sink (sink-sunshine-stereo). On client
# disconnect it does NOT restore the previous default, so desktop audio can
# be left silent (routed into the null sink).
#
# This script runs as a Sunshine prep-cmd (do) at stream start. It starts a
# detached watchdog (the sunshine-sink-restore user unit) that waits until the
# stream is truly over — i.e. the default sink is still a sunshine sink AND
# no application is actively (uncorked) playing audio into any sunshine sink —
# then restores the preferred host sink.
#
# The preferred host sink is recorded in ~/.config/sway-sunshine/host-audio-sink
# (a single pulse sink name; written by install.sh, which asks the user which
# output is their main desktop audio). If that sink no longer exists, the
# watchdog falls back to the first available non-sunshine sink.
#
# The restore uses `pactl set-default-sink`, which also persists the choice in
# WirePlumber's default-nodes state, so the host sink survives restarts.
#
# Watchdog log: journalctl --user -u sunshine-sink-restore -n 20 --no-pager

set -u

PREF_FILE="${HOME}/.config/sway-sunshine/host-audio-sink"
MAX_WAIT_SECONDS=1800
TICK_SECONDS=2

# ── helpers ────────────────────────────────────────────────────────────────

log() { echo "[restore-default-sink] $*"; }

default_sink_name() {
    pactl info 2>/dev/null | awk -F': ' '/^Default Sink:/{print $2; exit}'
}

# Names of all currently existing non-sunshine sinks
real_sink_names() {
    pactl list sinks short 2>/dev/null | awk '{ s = tolower($2); if (s !~ /sunshine/) print $2 }'
}

# Pulse indices of all sunshine sinks (used to match sink inputs, since
# `pactl list sink-inputs` reports the sink index, not the sink name)
sunshine_sink_indices() {
    pactl list sinks short 2>/dev/null | awk '{ s = tolower($2); if (s ~ /sunshine/) print $1 }'
}

# True (0) if any sink input is actively (uncorked) playing into a sunshine sink
sunshine_has_active_playback() {
    local sun_idx
    sun_idx="$(sunshine_sink_indices)"
    [ -n "$sun_idx" ] || return 1
    pactl list sink-inputs 2>/dev/null | awk -v sunidx="$sun_idx" '
        BEGIN { n = split(sunidx, a, " "); for (i = 1; i <= n; i++) S[a[i]] = 1 }
        $1 == "Sink:"   { in_sun = ($2 in S) }
        $1 == "Corked:" { if (in_sun && $2 == "no") { found = 1; exit } }
        END { exit found ? 0 : 1 }
    '
}

# Prints the sink to restore: the recorded preference if it still exists,
# otherwise the first available non-sunshine sink. Fails if neither.
resolve_host_sink() {
    local pref real
    pref="$(sed -n '1p' "$PREF_FILE" 2>/dev/null || true)"
    real="$(real_sink_names)"
    if [ -n "$pref" ] && grep -qxF "$pref" <<<"$real"; then
        printf '%s\n' "$pref"
        return 0
    fi
    if [ -n "$real" ]; then
        printf '%s\n' "$real" | head -n1
        return 0
    fi
    return 1
}

# ── watchdog ────────────────────────────────────────────────────────────────

run_watchdog() {
    local host_sink cur waited=0 target
    host_sink="$(resolve_host_sink)" || host_sink=""
    if [ -n "$host_sink" ]; then
        log "watchdog started; will restore default to: $host_sink"
    else
        log "warning: no non-sunshine sink found yet; will keep looking"
    fi

    while [ "$waited" -lt "$MAX_WAIT_SECONDS" ]; do
        sleep "$TICK_SECONDS"
        waited=$((waited + TICK_SECONDS))
        cur="$(default_sink_name)"

        # Nothing to restore while the default is not a sunshine sink
        # (stream hasn't flipped it yet, or the user set it themselves).
        case "${cur,,}" in
            *sunshine*) ;;
            *) continue ;;
        esac

        # Wait until stream audio is truly over: the game's (or any app's)
        # sink input stays alive a moment after the client disconnects.
        if sunshine_has_active_playback; then
            continue
        fi

        # Re-resolve in case the recorded sink vanished mid-stream.
        target="$(resolve_host_sink)" || target=""
        if [ -z "$target" ]; then
            log "default is '$cur' but no host sink is available yet (waiting)"
            continue
        fi
        if [ "$cur" = "$target" ]; then
            continue
        fi

        if pactl set-default-sink "$target" 2>/dev/null; then
            log "restored default audio sink: $cur -> $target"
        else
            log "error: failed to set default sink to '$target'"
        fi
        exit 0
    done

    log "timeout after ${MAX_WAIT_SECONDS}s; giving up (current default: '$(default_sink_name)')"
    exit 0
}

# ── main ────────────────────────────────────────────────────────────────────

if [ "${1:-}" = "--watchdog" ]; then
    run_watchdog
    exit 0
fi

# Do mode: stop any stale watchdog from a previous stream, then start a fresh
# detached one that outlives this prep-cmd.
systemctl --user stop sunshine-sink-restore 2>/dev/null || true
systemctl --user reset-failed sunshine-sink-restore 2>/dev/null || true

if systemd-run --user --no-block --unit=sunshine-sink-restore "$0" --watchdog; then
    log "started watchdog (journalctl --user -u sunshine-sink-restore)"
else
    log "error: failed to start sunshine-sink-restore"
fi
