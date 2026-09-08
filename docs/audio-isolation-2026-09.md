# Audio isolation regression, September 2026

This records the original audio-isolation incident reported while streaming
Big Walk to a TV Moonlight client. The goal was to keep headless game audio in
Sunshine's stream sink while desktop audio continued through AOC HDMI-0 or
connected AirPods.

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
3. Restoring AOC during a stream moved **both Big Walk playback and Sunshine's
   recording** onto AOC. Thus the game leaked to the PC and Sunshine captured
   desktop audio. The disconnect-gated watchdog in `6ea5110` delays this switch
   but still leaves the desktop default pointing into the stream while connected.

The first symptom was therefore a routing race, not a missing or silent game
audio source. During the stream, the default sink could become
`sink-sunshine-stereo`; newly created desktop streams followed it. When the
watchdog or a manual restore changed the default back to AOC, WirePlumber's
follow-default behavior could move the already-created Big Walk and Sunshine
streams together. That produced both forms of leakage: game audio on the PC
and desktop audio in the TV stream.

The test `python3 tests/check-audio-isolation.py` reproduced:

```text
Big Walk.exe -> alsa_output.pci-0000_03_00.1.hdmi-stereo
Sunshine captures alsa_output.pci-0000_03_00.1.hdmi-stereo.monitor
FAIL: game audio leaks to alsa_output.pci-0000_03_00.1.hdmi-stereo
FAIL: Sunshine captures host audio from alsa_output.pci-0000_03_00.1.hdmi-stereo.monitor
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
  upgrades. It should cover AOC, AirPods, client reconnects, and a native
  PipeWire application in addition to Big Walk.
- Treat a change in Moonlight's negotiated channel count as a client-side
  compatibility change. The TV client requested 7.1 while Big Walk produced
  stereo; the host sent valid 7.1 packets in testing, but the TV path only
  became reliable after selecting Stereo in Moonlight. Keep TV Moonlight set
  to Stereo unless the TV/audio system is known to handle the requested
  surround layout.
- Avoid restoring or changing the desktop default sink from a stream hook.
  If Sunshine changes that default in a future release, preserve the current
  physical sink synchronously in the audio policy instead of polling after the
  stream starts.
- Keep audible endpoints such as the TV, AOC, AirPods, and local Moonlight at
  5% or less during quiet testing. Leave Big Walk and the virtual Sunshine sink
  at normal gain so the stream does not become effectively silent.

## Operational checks

```bash
python3 tests/check-audio-isolation.py --game-name 'Big Walk.exe'
pactl get-default-sink
pactl list sink-inputs short
journalctl --user -u sunshine-headless -n 30 --no-pager
```

The expected routing is desktop playback to the selected physical sink, Big
Walk playback to `sink-sunshine-stereo`, and Sunshine capture from
`sink-sunshine-stereo.monitor`. If the Sunshine log reports 8 channels and the
TV is silent, check the TV Moonlight audio setting before changing host audio
routing.

All live changes are deployed through `./install.sh --audio-only`. This mode
does not restart consumers automatically; after ending a stream, restart the
WirePlumber, headless Sway, and Sunshine user services. No system-wide sudo
operation, remote push, or change to the model server is needed.

## Validation

The live test checks a silent desktop probe, actual Big Walk playback, and the
actual Sunshine recording source. It passed with AOC selected, with AirPods
selected, after requesting Sunshine as the default, and after switching back
to AOC. Stream routing properties were verified on the actual Proton game and
Sunshine recording clients. The same test passed after ending the session and
relaunching Big Walk through Moonlight. A native PipeWire silent probe launched
through Sway also used the streaming sink with movement/fallback disabled.
Local Moonlight test windows use host workspace 5;
the game itself runs in headless Sway.

Reference behavior: [Sunshine audio selection](https://github.com/LizardByte/Sunshine/blob/master/src/audio.cpp)
and [Linux PulseAudio capture](https://github.com/LizardByte/Sunshine/blob/master/src/platform/linux/audio.cpp).
The installed WirePlumber 0.5.17 scripts under `/usr/share/wireplumber/scripts/`
were used to verify hook order, default selection, and stream movement semantics.

Sunshine still restores the physical device it saw at session start when a
session ends. If the desktop device was changed during the stream, this may
restore the earlier physical choice; it does not move the pinned game or
recording stream onto it. AOC was selected again after testing. Audible host
outputs remained low; Big Walk and the virtual stream sink were restored to
normal gain after the TV volume was lowered.
