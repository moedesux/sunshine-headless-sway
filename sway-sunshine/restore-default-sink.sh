#!/bin/bash
# Proactively detects and restores the host's default audio sink after Sunshine
# changes it. Instead of capturing the current default at launch (which is broken
# when a previous session left the default pointing to a sunshine sink), this
# script scans all available sinks and identifies the host sink by filtering out
# any sink whose node.name or node.description contains "sunshine" (case-insensitive).
#
# The watchdog polls wpctl for up to 1200 seconds, detects when the default sink
# changes to a sunshine sink, and switches it back to the host sink.

set -euo pipefail

# ─── Helpers ───────────────────────────────────────────────────────────────────

# Check whether a sink is a sunshine sink by inspecting its node.name and
# node.description fields. Returns 0 (true) if the sink is a sunshine sink.
is_sunshine_sink() {
    local sink_id="$1"
    local inspect_output

    inspect_output=$(wpctl inspect "$sink_id" 2>/dev/null) || return 1

    # Case-insensitive substring match on both node.name and node.description
    if echo "$inspect_output" | grep -qiE '^\s*(node\.name|node\.description)\s*='; then
        local name desc
        name=$(echo "$inspect_output" | grep -iE '^\s*node\.name\s*=' | head -1 | cut -d= -f2- | xargs)
        desc=$(echo "$inspect_output" | grep -iE '^\s*node\.description\s*=' | head -1 | cut -d= -f2- | xargs)

        if [[ "$name" == *[sS][uU][nN][sS][hH][iI][nN][eE]* ]] || \
           [[ "$desc" == *[sS][uU][nN][sS][hH][iI][nN][eE]* ]]; then
            return 0
        fi
    fi
    return 1
}

# Collect all sink IDs from wpctl status output.
# Returns the first non-sunshine sink ID found, or empty if none.
find_host_sink() {
    local sink_ids
    sink_ids=$(wpctl status 2>/dev/null | sed -n '/Sinks:/,/^[^ ]/p' | grep -oE '[0-9]+( |$)' | grep -oE '^[0-9]+' | sort -un)

    if [ -z "$sink_ids" ]; then
        return 1
    fi

    local sink_id
    for sink_id in $sink_ids; do
        if ! is_sunshine_sink "$sink_id"; then
            echo "$sink_id"
            return 0
        fi
    done

    # No non-sunshine sink found — cannot restore
    return 1
}

# ─── Main ─────────────────────────────────────────────────────────────────────

# 1. Find the host sink (first non-sunshine sink)
HOST_SINK_ID=$(find_host_sink) || true
if [ -z "$HOST_SINK_ID" ]; then
    # No host sink available — nothing to restore, exit silently
    exit 0
fi

# 2. Clean up any previous watcher before starting a new one
systemctl --user stop sunshine-sink-restore 2>/dev/null || true
systemctl --user reset-failed sunshine-sink-restore 2>/dev/null || true

# 3. Launch a detached watcher via systemd-run that survives prep-cmd cleanup.
#    The watchdog polls wpctl for up to 1200 seconds (20 minutes), detecting when
#    the current default sink is a sunshine sink and restoring the host sink.
#    If the default is already a non-sunshine sink, we exit early (idempotent).
systemd-run --user --no-block --unit=sunshine-sink-restore \
    bash -c "
    host_sink=\"${HOST_SINK_ID}\"

    # Check current default sink on each iteration
    for i in \$(seq 1 1200); do
        # Get the current default sink ID (marked with *)
        cur_id=\$(wpctl status 2>/dev/null | sed -n '/Sinks:/,/^[^ ]/p' | grep '\*' | head -1 | grep -oE '[0-9]+' | head -1)

        if [ -z \"\$cur_id\" ]; then
            continue
        fi

        # If the current default is already the host sink, we're done (idempotent)
        if [ \"\$cur_id\" = \"\$host_sink\" ]; then
            exit 0
        fi

        # Inspect the current default sink to determine if it's a sunshine sink
        inspect_output=\$(wpctl inspect \"\$cur_id\" 2>/dev/null) || continue

        is_sunshine=false
        if echo \"\$inspect_output\" | grep -qiE '^\s*(node\.name|node\.description)\s*='; then
            cur_name=\$(echo \"\$inspect_output\" | grep -iE '^\s*node\.name\s*=' | head -1 | cut -d= -f2- | xargs)
            cur_desc=\$(echo \"\$inspect_output\" | grep -iE '^\s*node\.description\s*=' | head -1 | cut -d= -f2- | xargs)

            if [[ \"\$cur_name\" == *[sS][uU][nN][sS][hH][iI][nN][eE]* ]] || \
               [[ \"\$cur_desc\" == *[sS][uU][nN][sS][hH][iI][nN][eE]* ]]; then
                is_sunshine=true
            fi
        fi

        # If the current default is a sunshine sink, restore to the host sink
        if [ \"\$is_sunshine\" = true ]; then
            wpctl set-default \"\$host_sink\"
            exit 0
        fi

        sleep 1
    done
    "
