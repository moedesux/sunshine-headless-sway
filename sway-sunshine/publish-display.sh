#!/bin/bash
# publish-display.sh
#
# Invoked from the headless Sway config via:
#     exec $HOME/.config/sway-sunshine/publish-display.sh
#
# Sway loads its config AFTER wlroots has bound the real wayland display and
# (crucially) updated WAYLAND_DISPLAY in its own environment to the socket it
# actually got. The wrapper's pre-exec write of the display file can be STALE
# after a contested bind where wlroots renumbers (e.g. a same-second restart
# race) — the file then names a socket Sway never opened. This child process
# re-publishes the authoritative value so consumers read the real socket.
#
# Primary source: Sway's (our parent's) /proc/<PPID>/environ. A direct child can
# read its parent's environ even under Yama ptrace_scope=1 (verified on this box).
# Fallback: the WAYLAND_DISPLAY we inherited from Sway at fork() time (same value).
DISPLAY_FILE="/run/user/$(id -u)/sway-sunshine-display"

real=$(tr '\0' '\n' < "/proc/$PPID/environ" 2>/dev/null | grep '^WAYLAND_DISPLAY=' | head -n1)
real="${real:-WAYLAND_DISPLAY=$WAYLAND_DISPLAY}"

# Guard: only publish a well-formed value; otherwise leave the file untouched
# rather than clobbering a good value with garbage (fail-safe, never fail loud
# here — this runs during compositor startup and must not abort it).
case "$real" in
    WAYLAND_DISPLAY=wayland-*) ;;
    *) exit 0 ;;
esac

printf '%s\n' "$real" > "$DISPLAY_FILE"
