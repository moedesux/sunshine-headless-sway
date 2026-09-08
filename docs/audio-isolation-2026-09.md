# Audio isolation regression, September 2026

This records an audio-isolation incident in a headless Sunshine stream. The
goal was to keep game audio in Sunshine's stream sink while desktop audio
continued through the user's selected physical output.

## Confirmed causes

The live restore script was byte-for-byte identical to commit `91c7161`, not
the newer script in HEAD `6ea5110`. Updating or switching a branch did not
update installed configuration. The existing stash was left untouched.

The underlying isolation problem predates the latest watchdog change:

1. Sunshine changes the shared PulseAudio default to its virtual capture sink
   when Moonlight connects. Desktop playback then joins the captured audio.
2. `PULSE_SINK` selects an initial destination; it does not guarantee isolation.
   WirePlumber's `linking-utils.lua` `checkFollowDefault()` deliberately marks
   streams connected to the default as following that default. The policy also
   applies to recording streams targeting a sink monitor.
3. Restoring the physical output during a stream moved **both game playback and
   Sunshine's recording** onto that output. Thus the game leaked to host
   speakers and Sunshine captured desktop audio. The disconnect-gated watchdog
   delayed this switch but still left the desktop default pointing into the
   stream while connected.

The first symptom was therefore a routing race, not a missing or silent game
audio source. During the stream, the default sink could become
`sink-sunshine-stereo`; newly created desktop streams followed it. When the
watchdog or a manual restore changed the default back to a physical output,
WirePlumber's follow-default behavior could move the already-created game and
Sunshine streams together. That produced both forms of leakage: game audio on
the host and desktop audio in the Moonlight stream.

The test `python3 tests/check-audio-isolation.py` reproduced:

```text
<game application> -> <physical sink>
Sunshine captures <physical sink>.monitor
FAIL: game audio leaks to <physical sink>
FAIL: Sunshine captures host audio from <physical sink>.monitor
```

## Fix

`pipewire/sunshine-host-default.lua` filters capture sinks out of WirePlumber's
default candidates **before** default selection. When Sunshine requests one,
the current valid physical default is retained and its configured preference
is restored. This avoids a polling interval during which desktop audio leaks.
Normal selection between physical outputs and device availability policy still
work. The script is installed under the user's WirePlumber data directory;
the component configuration goes under `~/.config/wireplumber/`.

The Sway and Sunshine systemd audio drop-ins set `node.dont-move`,
`node.dont-fallback`, and `state.restore-target=false` on their audio clients.
Sway also explicitly targets the streaming sink for native PipeWire clients.
The existing persistent sink and `audio_sink` capture setting remain in use.
The old restore hook now only retires stale watchdogs.

The installer now deploys the policy to the correct WirePlumber 0.5 locations:
the Lua script under `${XDG_DATA_HOME:-~/.local/share}/wireplumber/scripts` and
the component configuration under `~/.config/wireplumber/wireplumber.conf.d`.
The `--audio-only` installer path makes it possible to update this policy
without changing Wayland display detection, GPU settings, or `apps.json`.

## Future recommendations

- Keep the WirePlumber policy and the service drop-ins in the repository, and
  deploy them through `install.sh`; do not edit the installed files by hand.
- Keep `audio_sink` pointed at the persistent Sunshine sink and retain explicit
  stream targets with `node.dont-move=true` and `node.dont-fallback=true`.
- Run the regression check after PipeWire, WirePlumber, Sunshine, or Moonlight
  upgrades. Cover physical-output selection, client reconnects, and a native
  PipeWire application as well as a game.
- Treat a change in Moonlight's negotiated channel count as a client-side
  compatibility change. If a client has video but no audio, try Stereo and
  reconnect before changing host routing.
- Avoid restoring or changing the desktop default sink from a stream hook.
  If Sunshine changes that default in a future release, preserve the current
  physical sink synchronously in the audio policy instead of polling after the
  stream starts.

## Operational checks

```bash
python3 tests/check-audio-isolation.py --game-name '<application name>'
pactl get-default-sink
pactl list sink-inputs short
journalctl --user -u sunshine-headless -n 30 --no-pager
```

The expected routing is desktop playback to the selected physical sink, game
playback to `sink-sunshine-stereo`, and Sunshine capture from
`sink-sunshine-stereo.monitor`. If a client is silent after routing passes,
check its audio channel configuration before changing host audio routing.

All live changes are deployed through `./install.sh --audio-only`. This mode
does not restart consumers automatically; after ending a stream, restart the
WirePlumber, headless Sway, and Sunshine user services. No system-wide sudo
operation, remote push, or change to the model server is needed.

## Validation

The live test checks a silent desktop probe, game playback, and the Sunshine
recording source. It passed across physical-output changes, after Sunshine
requested its capture sink as default, and after a Moonlight reconnect. Stream
routing properties were verified on the game and Sunshine recording clients. A
native PipeWire silent probe launched through Sway also used the streaming sink
with movement and fallback disabled.

Reference behavior: [Sunshine audio selection](https://github.com/LizardByte/Sunshine/blob/master/src/audio.cpp)
and [Linux PulseAudio capture](https://github.com/LizardByte/Sunshine/blob/master/src/platform/linux/audio.cpp).
The installed WirePlumber 0.5.17 scripts under `/usr/share/wireplumber/scripts/`
were used to verify hook order, default selection, and stream movement semantics.

Sunshine can still restore the physical device it saw at session start when a
session ends. If the desktop device changed during the stream, it may restore
the earlier physical choice; it does not move the pinned game or recording
stream onto it.
