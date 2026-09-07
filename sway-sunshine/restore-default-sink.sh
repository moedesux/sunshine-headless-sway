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
# stream is truly over before restoring the preferred host sink. "Truly over"
# means ALL of:
#   1. sunshine.log shows a CLIENT DISCONNECTED event that was logged after
#      this watchdog started (i.e. after this stream's connect). This is the
#      critical gate: without it, the watchdog fires during the long
#      game-load window after connect — when there is no active playback yet
#      — and flips the default sink mid-stream, leaking game audio to the
#      host output.
#   2. the default sink is still a sunshine sink, AND
#   3. no application is actively (uncorked) playing audio into any sunshine
#      sink (covers the brief tail where the game keeps playing after the
#      client disconnects).
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
SUNSHINE_LOG="${HOME}/.config/sunshine/sunshine.log"
MAX_WAIT_SECONDS=1800
TICK_SECONDS=2

# ── helpers ────────────────────────────────────────────────────────────────

log() { echo "[restore-default-sink] $*"; }

# Prints "<epoch> <state>" for the newest CLIENT CONNECTED/DISCONNECTED event
# in the recent tail of sunshine.log; prints nothing if the log is missing or
# contains no such event. The 1 MB tail comfortably covers the current
# session (the log is small and Sunshine truncates/rotates it).
last_client_event() {
    local line ts state
    line="$(tail -c 1048576 "$SUNSHINE_LOG" 2>/dev/null | grep -aiE 'CLIENT (CON|DIS)CONNECTED' | tail -n1)"
    [ -n "$line" ] || return 0
    if printf '%s\n' "$line" | grep -aqi 'CLIENT DISCONNECTED'; then
        state=disconnected
    else
        state=connected
    fi
    ts="$(printf '%s\n' "$line" | sed -nE 's/^\[([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?)\].*/\1/p')"
    [ -n "$ts" ] || return 0
    printf '%s %s\n' "$(date -d "$ts" +%s 2>/dev/null || true)" "$state"
}

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
    local start_epoch ev last_epoch="" last_state="" logged_connect=""
    host_sink="$(resolve_host_sink)" || host_sink=""
    start_epoch="$(date +%s)"
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

        # Gate on Sunshine's own client state: only restore once this
        # session's client has actually disconnected. During the game-load
        # window after connect there is no playback yet, so the playback
        # check below would pass too early and flip the default mid-stream.
        ev="$(last_client_event)"
        if [ -n "$ev" ]; then
            last_epoch="${ev%% *}"
            last_state="${ev##* }"
        else
            last_epoch=""
            last_state=""
        fi
        case "$last_epoch" in
            ''|*[!0-9]*)
                # No parseable client event in the log tail yet — wait.
                continue
                ;;
        esac
        if [ "$last_state" != "disconnected" ] || [ "$last_epoch" -le "$start_epoch" ]; then
            if [ "$last_state" = "connected" ] && [ -z "$logged_connect" ]; then
                log "client connected (per sunshine.log); waiting for disconnect"
                logged_connect=1
            fi
            continue
        fi

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
