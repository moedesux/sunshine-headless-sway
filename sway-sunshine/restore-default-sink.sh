#!/bin/bash
# Compatibility hook for existing apps.json entries. Isolation is enforced by
# WirePlumber before default selection, not by a delayed default-sink flip.
# Preserve the user's current physical-output choice throughout the stream.
set -eu
systemctl --user stop sunshine-sink-restore.service 2>/dev/null || true
if ! systemctl --user is-active --quiet wireplumber.service; then
    echo "Audio isolation requires WirePlumber to be running" >&2
    exit 1
fi
