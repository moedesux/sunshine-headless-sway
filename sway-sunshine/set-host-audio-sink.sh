#!/bin/bash
#
# set-host-audio-sink.sh — change the preferred host audio sink without
# re-running ./install.sh.
#
# The preferred sink is recorded in ~/.config/sway-sunshine/host-audio-sink
# (a single pulse sink name) and is what restore-default-sink.sh's watchdog
# restores the system default to after a stream. This script updates that
# file AND applies the choice live via `pactl set-default-sink` (which also
# persists it in WirePlumber's default-nodes state).
#
# Usage:
#   set-host-audio-sink.sh              interactive: lists the non-sunshine
#                                       sinks and picks one by number
#   set-host-audio-sink.sh <sink-name>  apply a specific sink (exact name
#                                       from `pactl list sinks short`)
#   set-host-audio-sink.sh --show       print the recorded preference and the
#                                       current default; change nothing
#
# Safe to run during an active stream: it only touches the preference file
# and the system default sink. In-stream game audio is pinned to
# sink-sunshine-stereo via PULSE_SINK and is unaffected. A watchdog already
# running for the current stream re-reads the preference file on every check,
# so a mid-stream change is picked up without restarting anything.

set -u

PREF_FILE="${HOME}/.config/sway-sunshine/host-audio-sink"

die() { echo "Error: $*" >&2; exit 1; }

command -v pactl >/dev/null 2>&1 || die "pactl not found (pipewire-pulse required)"

current_default_sink() {
    pactl info 2>/dev/null | awk -F': ' '/^Default Sink:/{print $2; exit}'
}

# Names of all currently existing sinks, and of the non-sunshine ones
all_sink_names() {
    pactl list sinks short 2>/dev/null | awk '{print $2}'
}
real_sink_names() {
    pactl list sinks short 2>/dev/null | awk '{ s = tolower($2); if (s !~ /sunshine/) print $2 }'
}
real_sink_lines() {
    pactl list sinks short 2>/dev/null | awk '{ s = tolower($2); if (s !~ /sunshine/) print }'
}

# The currently recorded preference (first line of the preference file)
saved_preference() {
    sed -n '1p' "$PREF_FILE" 2>/dev/null || true
}

if [ $# -gt 1 ]; then
    die "unexpected extra arguments (usage: $0 [--show | <sink-name>])"
fi

# ── --show ─────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--show" ]; then
    pref="$(saved_preference)"
    cur="$(current_default_sink)"
    [ -n "$pref" ] || pref="<none — watchdog falls back to first non-sunshine sink>"
    [ -n "$cur" ] || cur="<none>"
    echo "Recorded preference:  $pref"
    echo "Current default sink: $cur"
    exit 0
fi

# ── resolve the target sink ────────────────────────────────────────────────
TARGET=""
ARG="${1:-}"
if [ -n "$ARG" ]; then
    if grep -qxF "$ARG" <<<"$(all_sink_names)"; then
        if grep -qxF "$ARG" <<<"$(real_sink_names)"; then
            TARGET="$ARG"
        else
            die "'$ARG' is one of Sunshine's own sinks — pick a non-sunshine host output"
        fi
    else
        die "no such sink: '$ARG' (run without arguments to list available outputs)"
    fi
fi

if [ -z "$TARGET" ]; then
    REAL_SINKS="$(real_sink_lines)"
    [ -n "$REAL_SINKS" ] || die "no non-sunshine audio outputs found — nothing to select"

    pref="$(saved_preference)"
    cur="$(current_default_sink)"
    [ -n "$pref" ] || pref="<none — watchdog falls back to first non-sunshine sink>"
    echo "Recorded preference:  $pref"
    echo "Current default sink: ${cur:-<none>}"
    echo ""
    echo "Available host audio outputs:"
    CHOICE_COUNT=0
    DEFAULT_CHOICE=1
    while read -r _idx name _rest; do
        CHOICE_COUNT=$((CHOICE_COUNT + 1))
        if [ -n "$cur" ] && [ "$name" = "$cur" ]; then
            mark=" (current default)"
            DEFAULT_CHOICE=$CHOICE_COUNT
        else
            mark=""
        fi
        printf "   %d) %s%s\n" "$CHOICE_COUNT" "$name" "$mark"
    done <<< "$REAL_SINKS"
    read -rp "Select the main desktop audio sink [1-$CHOICE_COUNT] (default: $DEFAULT_CHOICE): " ANSWER || ANSWER=""
    ANSWER="${ANSWER:-$DEFAULT_CHOICE}"
    [[ "$ANSWER" =~ ^[0-9]+$ ]] && [ "$ANSWER" -ge 1 ] && [ "$ANSWER" -le "$CHOICE_COUNT" ] \
        || die "invalid selection: '$ANSWER'"
    TARGET="$(printf '%s\n' "$REAL_SINKS" | awk -v n="$ANSWER" 'NR==n{print $2}')"
fi

# ── apply ──────────────────────────────────────────────────────────────────
OLD_PREF="$(saved_preference)"
mkdir -p "$(dirname "$PREF_FILE")"
printf '%s\n' "$TARGET" > "$PREF_FILE"
echo "Recorded host audio sink: $TARGET"
if [ -n "$OLD_PREF" ] && [ "$OLD_PREF" != "$TARGET" ]; then
    echo "  (previous preference was: $OLD_PREF)"
fi

if pactl set-default-sink "$TARGET" 2>/dev/null; then
    echo "Set default audio sink:   $TARGET"
    echo "Done — the post-stream watchdog will now restore this sink."
else
    die "failed to set default sink to '$TARGET' (the preference file was already updated)"
fi
