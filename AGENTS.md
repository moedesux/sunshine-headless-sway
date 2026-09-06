# AGENTS.md — Build Orchestrator Rules

## Deployment Discipline

**NEVER update live services and config files directly.**

All changes must be made to the source files in this repository first, then deployed to the live system using `install.sh`.

This means:
- Source files live in: `systemd/`, `sway-sunshine/`, `sunshine/`, `pipewire/`, `udev/`
- Live config paths are: `~/.config/systemd/user/`, `~/.config/sway-sunshine/`, `~/.config/sunshine/`, `~/.config/pipewire/`
- Always edit the repo files, then run `./install.sh` to copy them to the live system
- This ensures config changes are tracked in git and can be reproduced

## Sudo Discipline

**NEVER run sudo yourself.** If any operation requires sudo privileges, stop and ask the user to run it. Failed sudo attempts can lock the user's account.

This means:
- If you need to install a package with `sudo pacman -S` or `sudo apt install`, tell the user the exact command to run
- If you need to modify system files (e.g., `/etc/udev/rules.d/`, `/etc/systemd/system/`), provide the command and let the user execute it
- Never use `sudo`, `su`, or `pkexec` in any command you run directly

## Push Discipline

**NEVER push to remote origin without explicit user consent.**

This means:
- Do not run `git push` or `gh push` or any command that sends commits to a remote repository
- Do not run `git push --force`, `git push --force-with-lease`, or any force push
- Always ask the user before pushing, and let them run the push command themselves
- Local commits and merges are fine — only remote pushes require explicit approval

## Process Protection

**NEVER kill the llama-server process.** It is running the AI model that powers this conversation. Killing it will terminate the current session.

This process consumes significant VRAM (~28 GB) on the NVIDIA RTX 5090, which may compete with game streaming for GPU resources. If Portal 2 fails to launch due to insufficient VRAM, this is expected — the AI model takes priority.

## Project Overview

> **Branch note (`hyprland`):** This branch targets a Hyprland host. All KDE/KWin dependencies have been removed: install.sh detects Hyprland (no udev rule needed), the KWin env vars were dropped from `sunshine-headless.service`, and LutrisToSunshine's input isolation helper now disables Sunshine's virtual devices on the host via `hyprctl keyword "device[...]:enabled" false` instead of the KWin DBus `org.kde.KWin.InputDevice` interface. Sections below mentioning KDE/KWin/Plasma are historical context from the `master` (KDE) branch.

This repo manages a **headless Sway + Sunshine game streaming** setup. A separate headless Wayland session (Sway) runs dedicated to game streaming, fully isolated from the main desktop. Sunshine captures the headless session and streams via Moonlight.

Key services:
- `sway-sunshine.service` — headless Sway compositor (no physical display)
- `sunshine-headless.service` — Sunshine server pointed at the headless session

## Testing with Moonlight CLI

To test game streaming from the command line:

```bash
flatpak run com.moonlight_stream.Moonlight stream localhost "Portal 2"
```

Replace `"Portal 2"` with the exact app name from `~/.config/sunshine/apps.json`.

After testing, disconnect the stream. The prep-cmd undo hooks will run automatically (reset resolution, stop Steam, etc.).

### Vulkan Driver Selection for Sunshine Encoding

**Sunshine's Vulkan encoding uses auto-selection by default.** On this setup, both Sway and Sunshine use Vulkan auto-selection — Sway renders on the NVIDIA GPU (`WLR_DRM_DEVICES=/dev/dri/renderD129`) and Sunshine auto-selects the correct Vulkan ICD for encoding.

On multi-GPU systems, if Sunshine picks the wrong GPU for encoding, you can restrict it using `VK_ICD_FILENAMES` in `sunshine-headless.service`:
- **Force NVIDIA encoding (NVENC):** `Environment=VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json`
- **Force AMD encoding (VCN):** `Environment=VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json`

**Verify encoding backend:**
```bash
journalctl --user -u sunshine-headless.service -n 30 --no-pager | grep -iE "encoder|nvenc|vcn"
# AMD setup: Creating encoder [h264_vcn], [hevc_vcn], [av1_vcn]
# NVIDIA setup: Creating encoder [h264_nvenc], [hevc_nvenc], [av1_nvenc]
```

## Wayland Display Layout

**Standard display numbering:**
- `wayland-0` = main desktop (physical monitor)
- `wayland-1` = headless Sway session (Sunshine streaming target)

**On most setups, the headless session uses `wayland-1`.** However, on KDE/CachyOS or other setups where SDDM or other components create additional Wayland sockets, the headless session may get `wayland-2` or higher. Always verify:

```bash
ls /run/user/$(id -u)/wayland-*
```

**Important for install.sh:** Both service files (`sway-sunshine.service` and `sunshine-headless.service`) hardcode `WAYLAND_DISPLAY=wayland-1`. The `start-steam-game.sh` script also hardcodes `WAYLAND_DISPLAY="wayland-1"`. If your headless session uses a different display number, update these files accordingly.

**Verification:** After any install or restart, always confirm:
```bash
ls /run/user/$(id -u)/wayland-*
grep WAYLAND_DISPLAY ~/.config/systemd/user/sway-sunshine.service
grep WAYLAND_DISPLAY ~/.config/systemd/user/sunshine-headless.service
```

## Scripts in `sway-sunshine/`

### `set-resolution.sh`
Called by Sunshine as a **prep-cmd.do** when a client connects. Uses `swaymsg` to set the headless output to match the Moonlight client's resolution/fps via `SUNSHINE_CLIENT_WIDTH`, `SUNSHINE_CLIENT_HEIGHT`, `SUNSHINE_CLIENT_FPS` env vars. Includes a 1s sleep for display mode to settle.

### `reset-resolution.sh`
Called by Sunshine as a **prep-cmd.undo** when a client disconnects. Resets headless output to 1920x1080@60Hz.

### `restore-default-sink.sh`
Restores the host's default audio sink after Sunshine changes it (Sunshine sets `audio_sink` as system default on connect). Uses `systemd-run` to spawn a detached watcher that survives prep-cmd cleanup, polling wpctl for 30s to detect and restore the original default sink.

### `start-steam-game.sh`
Launches a Steam game in the headless Sway session. **Kills ALL Steam processes system-wide** (including any running on the main desktop) before launching in the headless session. Handles:
- Checks for Sway IPC socket existence (`sway-sunshine.sock`) before launching
- Graceful shutdown of any existing Steam instance (`steam -shutdown`, wait, force kill)
- Cleanup of Steam IPC files (`~/.steam/steam.pid`, `/tmp/steam_singleton_*`)
- Launch via `swaymsg exec` in the headless session
- Accepts: `<appid>`, `bigpicture`, or `0` (plain Steam)

### `stop-steam-game.sh`
Shuts down ALL Steam processes system-wide and cleans up IPC. Used as **prep-cmd.undo** for Steam entries. Note: does NOT restart Steam on the main desktop.

> **Note:** `start-steam-game.sh` and `stop-steam-game.sh` are automatically installed by `install.sh`.

### `sway-wrapper.sh`
Thin wrapper that writes the sway-sunshine process PID to `/run/user/$USER_ID/sway-sunshine.pid` before exec'ing sway. Uses an EXIT trap to clean up the PID file. This enables external tools (install.sh) to detect and gracefully stop a running sway-sunshine session. Used as the `ExecStart` target in `sway-sunshine.service` instead of calling sway directly.

### `start-lutris-game.sh`
Launches a Lutris game in the headless Sway session. **Kills ALL Lutris processes system-wide** (including any running on the main desktop) before launching in the headless session. Used via `detached` in apps.json entries. Handles:
- Checks for Sway IPC socket existence (`sway-sunshine.sock`) before launching
- Graceful shutdown of any existing Lutris instance (`SIGTERM`, wait up to 15s, fallback to `SIGKILL`)
- Cleanup of Lutris session tracking files (`/tmp/lutris-*`) to prevent DBus single-instance detection
- Uses `get_lutris_pids()` helper to exclude its own PID and parent PID from `pgrep -f "lutris"` results (prevents self-termination since the script path contains "lutris")
- Launches via `swaymsg exec` in the headless session
- Accepts: `<lutris_game_id>` (launches game), or `lutris` (opens Lutris UI)

### `stop-lutris-game.sh`
Shuts down ALL Lutris processes system-wide, cleans up session files, then **restarts Lutris on the main desktop** (`wayland-0`). Used as **prep-cmd.undo** for Lutris entries. Uses `get_lutris_pids()` to exclude its own PID from kill targets (prevents self-termination).

> **Note:** `start-lutris-game.sh` and `stop-lutris-game.sh` are automatically installed by `install.sh`.

### `start-heroic-game.sh`
Launches a Heroic game in the headless Sway session. Used via `detached` in apps.json entries. Handles:
- Accepts `<runner> <game_id>` where runner is one of: legendary/gog/nile/sideload
- Checks for Sway IPC socket existence before launching
- Sets `WAYLAND_DISPLAY` for the headless session
- Launches via `swaymsg exec "heroic heroic://launch/<runner>/<game_id> --no-gui --no-sandbox"`

### `stop-heroic-game.sh`
Kills ALL Heroic processes system-wide. Used as **prep-cmd.undo** for Heroic entries. Uses `pkill -f "heroic"` for broad process matching.

> **Note:** `start-heroic-game.sh` and `stop-heroic-game.sh` are automatically installed by `install.sh`.

## `apps.json` Format & Conventions

The live config at `~/.config/sunshine/apps.json` uses **Sunshine v2 format** (`"version": 2`).

### Prep-cmd pattern for all games

Every game should have prep-cmd hooks for resolution and audio sink management:

```json
"prep-cmd": [
  {
    "do": "~/.config/sway-sunshine/restore-default-sink.sh",
    "undo": ""
  },
  {
    "do": "~/.config/sway-sunshine/set-resolution.sh",
    "undo": "~/.config/sway-sunshine/reset-resolution.sh"
  }
]
```

- `restore-default-sink.sh`: undo is empty (no need to restore on disconnect)
- `set-resolution.sh`: undo is `reset-resolution.sh` (revert to 1080p)

### Steam entries

Use `start-steam-game.sh` via `detached` instead of raw `steam steam://run/...` commands:

```json
{
  "name": "Game Name",
  "detached": ["~/.config/sway-sunshine/start-steam-game.sh <appid>"],
  "prep-cmd": [
    {"do": "~/.config/sway-sunshine/restore-default-sink.sh", "undo": ""},
    {"do": "~/.config/sway-sunshine/set-resolution.sh", "undo": "~/.config/sway-sunshine/stop-steam-game.sh"}
  ]
}
```

Steam undo uses `stop-steam-game.sh` instead of `reset-resolution.sh` because stopping Steam is the critical cleanup action.

### Desktop entry

The Desktop entry needs prep-cmd hooks with the full resolution pair:

```json
{
  "name": "Desktop",
  "prep-cmd": [
    {"do": "~/.config/sway-sunshine/restore-default-sink.sh", "undo": ""},
    {"do": "~/.config/sway-sunshine/set-resolution.sh", "undo": "~/.config/sway-sunshine/reset-resolution.sh"}
  ]
}
```

### Lutris detached entries

Lutris games use the `detached` field with `start-lutris-game.sh`, similar to Steam entries:

```json
{
  "name": "Game Name (Lutris)",
  "detached": ["~/.config/sway-sunshine/start-lutris-game.sh <slug_or_id>"],
  "prep-cmd": [
    {"do": "~/.config/sway-sunshine/restore-default-sink.sh", "undo": ""},
    {"do": "~/.config/sway-sunshine/set-resolution.sh", "undo": "~/.config/sway-sunshine/stop-lutris-game.sh"}
  ]
}
```

Lutris undo uses `stop-lutris-game.sh` which kills ALL Lutris processes system-wide, cleans up session files, and restarts Lutris on the main desktop — matching the Steam migration pattern.

### Heroic detached entries

Heroic games use the `detached` field with `start-heroic-game.sh`, similar to Steam entries:

```json
{
  "name": "Game Name (Heroic/Legendary)",
  "detached": ["~/.config/sway-sunshine/start-heroic-game.sh legendary <game_id>"],
  "prep-cmd": [
    {"do": "~/.config/sway-sunshine/restore-default-sink.sh", "undo": ""},
    {"do": "~/.config/sway-sunshine/set-resolution.sh", "undo": "~/.config/sway-sunshine/stop-heroic-game.sh"}
  ]
}
```

Heroic undo uses `stop-heroic-game.sh` as the resolution undo hook, matching the pattern of using the game-stop script as cleanup.

Runner types:
- `legendary` - Epic Games Store games (installed via LegendaryXL)
- `gog` - GOG games
- `nile` - Amazon Prime Games (formerly Luna)
- `sideload` - Sideloaded games

## install.sh Behavior

The install script:
- Templates user ID into `set-resolution.sh` and `reset-resolution.sh` (replaces `/run/user/1000/`)
- Templates `WAYLAND_DISPLAY` into `start-steam-game.sh` based on detected display number
- Copies `start-steam-game.sh`, `stop-steam-game.sh`, and `sway-wrapper.sh` to `~/.config/sway-sunshine/`
- Checks for a stale sway-sunshine session via PID file (`/run/user/$USER_ID/sway-sunshine.pid`), sends SIGINT with 10s grace period, falls back to SIGKILL if needed
- Overwrites sunshine.conf from template on each run
- Preserves existing apps.json if it already exists, running auto-migration (prep-cmd updates, duplicate cleanup)
- Auto-detects DE for input isolation (Hyprland: no udev rule, uses hyprctl runtime disable; GNOME: mutter-device-ignore udev rule)
- Installs DE-appropriate udev rule to `/etc/udev/rules.d/85-sunshine-input-isolation.rules` (GNOME only; skipped entirely on Hyprland — input isolation is handled by the Sway config plus the hyprctl runtime helper in LutrisToSunshine)
- Auto-detects Wayland display number for the headless session (finds latest `wayland-*` socket and increments)
- Templates `WAYLAND_DISPLAY` into both `sway-sunshine.service` and `sunshine-headless.service`
- Replaces `ExecStart` in `sunshine-headless.service` with the detected Sunshine path (preserves `sg input -c` wrapper)

## KDE Plasma Wayland Compatibility (Updated 2026-04-25)

### Capture Method: wlr

**`capture = wlr` is the recommended method for KDE Plasma Wayland.** This is the correct and default capture method for this setup.

**How it works:** Sunshine connects to the **headless Sway session** (Wayland display number auto-detected by install.sh — typically `wayland-1` on standard setups, `wayland-2` on KDE where the main desktop uses `wayland-1`), NOT to KWin/KDE Plasma. Sway implements `zwlr-screencopy-unstable-v1` natively because it IS a wlroots compositor. The wlr capture path talks directly to Sway's Wayland socket — it never involves KWin at all.

**This is why the setup works on KDE Plasma:** KWin's lack of wlr-screencopy support is irrelevant because Sunshine captures from Sway, not from the KDE desktop session.

**Required setup:**
- `sunshine.conf` must have `capture = wlr` (this is the repo template default — kms works but has cross-GPU pitfalls on multi-GPU systems)
- Headless Sway must be running with `WLR_BACKENDS=headless` and `WLR_RENDERER=gles2` (or `vulkan` for AMD / modern wlroots + NVIDIA)
- `sway-sunshine.service` must set `WLR_DRM_DEVICES` to the correct render node (see Hardware Layout below)

**Wayland display numbering on KDE/CachyOS:** On some KDE setups (especially CachyOS), SDDM or other components may create additional Wayland sockets, causing the headless session to get `wayland-2` instead of `wayland-1`. To verify the correct display number:
```bash
ls /run/user/$(id -u)/wayland-*
```
If the headless Sway session uses a different display number (e.g., `wayland-2`), both service files are automatically templated by install.sh. Always verify after installation:
```bash
grep WAYLAND_DISPLAY ~/.config/systemd/user/sway-sunshine.service
grep WAYLAND_DISPLAY ~/.config/systemd/user/sunshine-headless.service
```

### Cross-GPU DMA-BUF Failure (KMS-specific)

**The cross-GPU DMA-BUF SEGV crash is specific to `capture = kms` mode, NOT `capture = wlr`.** With wlr capture, frames are shared via Wayland/DMA-BUF between Sway and Sunshine in the same session — but on multi-GPU systems, Sunshine still needs to know *which* render node to use for DMA-BUF imports (see "Multi-GPU wlr Capture: `adapter_name`" below).

If you ever use `capture = kms` (e.g., for direct DRM capture), you MUST avoid cross-GPU capture+encode:
- If KMS captures from one GPU but the Vulkan encoder runs on a different GPU, cross-device DMA-BUF import fails with SEGV crash → "No video received." This applies to any AMD + NVIDIA combination.
- **Fix for KMS mode:** Restrict Sunshine's Vulkan to only the capture GPU using `VK_ICD_FILENAMES`:
  - **AMD capture GPU:** `Environment=VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json`
  - **NVIDIA capture GPU:** `Environment=VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json`
This tells Vulkan to only use the capture GPU's driver, preventing the other GPU from being selected for encoding.

### Multi-GPU wlr Capture: `adapter_name`

**On multi-GPU systems with `capture = wlr`, Sunshine must be told which render node to use for DMA-BUF frame imports.** Without this, Sunshine auto-selects the wrong render node, producing a black screen even though the stream technically connects.

**The problem:** Sway renders on one GPU (e.g., NVIDIA RTX 5090 at `/dev/dri/renderD128`), but Sunshine may auto-select the other GPU's render node (e.g., AMD Radeon 8060S at `/dev/dri/renderD138`) for importing frames via DMA-BUF. Cross-device DMA-BUF imports fail silently on NVIDIA — no crash, no error log, just black frames.

**The fix:** Add `adapter_name` to `sunshine/sunshine.conf`, pointing to the render node of the GPU where Sway is rendering:

```ini
adapter_name = /dev/dri/renderD129
```

This tells Sunshine which render node to use for dmabuf imports during wlr capture. It must match the GPU where Sway renders (i.e., the GPU specified in `WLR_DRM_DEVICES` in `sway-sunshine.service`).

**How to detect the correct render node:**
```bash
ls -la /dev/dri/renderD*
# Match the render node to the GPU you want for capture:
ls -la /sys/class/drm/card*/device/vendor  # check vendor ID
# 0x10de = NVIDIA, 0x1002 = AMD
```

**Symptoms of missing `adapter_name`:**
- Stream connects (Moonlight shows "Connected")
- Black screen — no video received
- No frame capture errors in logs (unlike KMS mode which SEGV crashes)
- Sunshine logs show successful wlr-screencopy connection but no frames are captured
- `journalctl --user -u sunshine-headless.service` shows no encoder errors

**Reference:** Sunshine issue #5023, PR #5030 (merged April 21, 2026).

### What Does NOT Work on KDE Plasma Wayland

- **Nested Sway EGL** — KWin doesn't allow nested compositors DRM access. `eglQueryDeviceStringEXT(EGL_DRM_DEVICE_FILE_EXT)` returns `EGL_BAD_PARAMETER`. This works on GNOME/Mutter but not KWin. (The headless backend avoids this by using `WLR_BACKENDS=headless`.)
- **Portal capture for headless isolation** — Portal captures the active desktop session, not a separate headless session. Use wlr capture with headless Sway for headless isolation.
- **gamescope for headless capture** — Gamescope has resolution limitations based on display EDID compatibility (e.g., 1280x800@90 may not be supported). Use wlr capture with headless Sway instead, which supports arbitrary resolutions and refresh rates.

### Known Issues from Original Setup

The original Reddit post and GitHub repo were AI-generated and contain several mistakes. Documented here to prevent repeating them.

#### KDE `ID_INPUT` Stripping is Fundamentally Broken (Critical)

The udev rule `ENV{ID_INPUT}=""` strips input tags from Sunshine virtual devices, but this hides them from ALL consumers including libinput (which headless Sway uses). libinput reads udev properties and skips devices without `ID_INPUT`. The original setup incorrectly claimed "Devices remain accessible to headless Sway via libinput (which reads evdev directly)" — this is false.

**If input passthrough doesn't work:** The udev rule may have broken the virtual devices for libinput. Fix options (in order of preference):

1. **Use `seatd`** to separate the headless Sway session onto a different seat, so the main desktop's input grabs never reach it. This is the most reliable solution for KDE Plasma — proven working on CachyOS with dual GPU setups. Configure:
   - Install `seatd` package
   - Enable `seatd.service`
   - Change `LIBSEAT_BACKEND=noop` to `LIBSEAT_BACKEND=seatd` in `sway-sunshine.service`
   - Add `Environment=XDG_RUNTIME_DIR=/run/user/$(id -u)` if needed
2. **Remove the udev rule entirely.** The Sway config already handles input isolation via `input * events disabled` followed by explicit `input` enable rules for each Sunshine device. This works in most cases but KWin may still see the virtual devices (without grabbing them).
3. **Use KWin config filtering** (`kwinrules`) to exclude Sunshine virtual devices from KWin's input handling, without touching udev properties.

> **Note:** The GNOME `mutter-device-ignore` approach (used on GNOME/Mutter) does NOT have this problem — it targets Mutter specifically without stripping generic input properties.

#### GPU Vendor Support

Both AMD and NVIDIA GPUs are viable for game streaming:

- **AMD:** Mesa open-source drivers + VCN encoding via Vulkan. `WLR_RENDERER=vulkan` is preferred on modern wlroots versions; `gles2` works as fallback.
- **NVIDIA:** Proprietary or open-source (Nouveau) drivers + NVENC encoding via Vulkan. `WLR_RENDERER=gles2` is the safe default on older wlroots versions due to DRM atomic mode-setting issues; `vulkan` may work on wlroots >= 0.17 with recent driver versions.

The service template defaults to `WLR_RENDERER=gles2` for maximum compatibility. Change to `vulkan` if you have an AMD GPU or modern wlroots + NVIDIA setup and want better rendering performance.

#### NVIDIA Encoder Failures on Bleeding-Edge Drivers

Users on bleeding-edge distros (CachyOS, Nobara) with recent NVIDIA drivers have reported NVENC encoder failures where all encoders (NVENC, VAAPI, software) fail at startup. Symptoms include:
```
[2026-XX-XX XX:XX:XX.XXX]: Info: Trying encoder [nvenc]
[2026-XX-XX XX:XX:XX.XXX]: Info: Encoder [nvenc] failed
[2026-XX-XX XX:XX:XX.XXX]: Info: Trying encoder [vaapi]
[2026-XX-XX XX:XX:XX.XXX]: Info: Encoder [vaapi] failed
[2026-XX-XX XX:XX:XX.XXX]: Fatal: Unable to find display or encoder during startup.
```

**Troubleshooting steps:**
1. **Verify Wayland display number** — Stale `wayland-*` sockets from crashed sessions can confuse install.sh's auto-detection. Check with `ls /run/user/$(id -u)/wayland-*`. Run `./install.sh` to detect and stop any stale sway-sunshine session (via PID file) before re-detecting the display number. Verify the templated value: `grep WAYLAND_DISPLAY ~/.config/systemd/user/sway-sunshine.service`.
2. **Try `WLR_RENDERER=vulkan`** — Some NVIDIA driver versions work better with the Vulkan renderer than gles2. Update `WLR_RENDERER` in `sway-sunshine.service`.
3. **Check NVIDIA driver version** — Bleeding-edge drivers (e.g., 595+) may have regressions. Try rolling back to a stable driver version if issues persist.
4. **Verify Vulkan/VCN availability** — Run `vulkaninfo` and check that the NVIDIA Vulkan ICD is properly installed (`/usr/share/vulkan/icd.d/nvidia_icd.json` exists).

#### `WLR_DRM_DEVICES` Hardcoded in Service Template

The service template has `WLR_DRM_DEVICES=/dev/dri/renderD129` hardcoded (NVIDIA render node). On multi-GPU systems, this may point to the wrong GPU.

**To detect the correct render node:**
```bash
ls -la /dev/dri/renderD*
# Match the render node to the GPU you want for capture:
ls -la /sys/class/drm/card*/device/vendor  # check vendor ID
```

Then update `WLR_DRM_DEVICES` in `systemd/sway-sunshine.service` to the matching node. On single-GPU systems, `renderD128` is usually correct.

#### Steam Migration Kills All Steam Processes

`start-steam-game.sh` and `stop-steam-game.sh` kill ALL Steam processes system-wide (`pgrep -x steam`), not just the headless session's Steam. If Steam is running on the main desktop, it will be shut down and migrated to the headless session.

`stop-steam-game.sh` does NOT restart Steam on the main desktop — the comment saying it "restarts it on the main desktop" is outdated. The game session just ends with Steam fully stopped. Users running Steam on their main desktop should be aware that launching a game via Sunshine will terminate their desktop Steam session.

#### `sg input` Wrapper May Not Work on All Distributions

The `sunshine-headless.service` uses `ExecStart=/usr/bin/sg input -c /usr/bin/sunshine` to grant Sunshine access to the `input` group for device passthrough. On some distributions (notably Nobara and some CachyOS setups), this wrapper may fail because:
- The `sg` binary path differs (`/usr/bin/sg` vs other locations)
- The `input` group configuration differs from expectations

**If Sunshine fails to start with input-related errors:**
1. Check if `/usr/bin/sg` exists on your system
2. Try replacing `ExecStart=/usr/bin/sg input -c /usr/bin/sunshine` with `ExecStart=/usr/bin/sunshine` in `sunshine-headless.service` (Sunshine may already have the necessary permissions via udev rules)
3. Reload and restart: `systemctl --user daemon-reload && systemctl --user restart sunshine-headless.service`

### Prep-cmd Standardization

All apps.json entries should use `sway-sunshine/` scripts for prep-cmds:
- `~/.config/sway-sunshine/set-resolution.sh` (do)
- `~/.config/sway-sunshine/reset-resolution.sh` (undo for non-Steam)
- `~/.config/sway-sunshine/stop-steam-game.sh` (undo for Steam)
- `~/.config/sway-sunshine/restore-default-sink.sh` (do, undo empty)

### apps.json Cleanup Pattern

When cleaning apps.json:
1. Remove duplicate entries (same UUID) — keep first occurrence
2. For Steam games: use `stop-steam-game.sh` as resolution undo
3. For non-Steam games: use `reset-resolution.sh` as resolution undo
4. Keep `restore-default-sink.sh` entries as-is

### Research & Troubleshooting Tips

When stuck or in doubt, **always use the `searxng_searxng_web_search` tool** to search the web or check Reddit for solutions. This is especially important for:
- Renderer compatibility issues (wlroots + specific GPU/driver combos)
- Sunshine frame capture failures
- Wayland compositor crashes
- Distribution-specific issues (CachyOS, Nobara, Arch, etc.)

Search terms should include the specific error messages, software versions, and hardware details. Check:
- GitHub issues for Sunshine, Sway, wlroots
- Reddit (r/archlinux, r/CachyOS, r/selfhosted)
- Arch Linux forums
- NVIDIA developer forums

Document any new findings in AGENTS.md as you discover them.

### Headless Sway Renderer Issues on wlroots 0.19.3

**Known Issue:** wlroots 0.19.3 has a bug with the Vulkan renderer on the `headless` backend. The XR24 format errors (`Format XR24 can't be used with modifier INVALID`) occur on both NVIDIA and AMD GPUs, causing wlr-screencopy frame capture to fail.

**Affected setups:**
- NVIDIA RTX 5090 (Ada Lovelace) + wlroots 0.19.3
- AMD GPUs + wlroots 0.19.3 on headless backend

**Symptoms:**
- Sway logs: `Format XR24 (0x34325258) can't be used with modifier INVALID`
- Sunshine logs: `[wayland] Frame capture failed`
- Stream crashes with SEGV or black screen

**Workaround:** The XR24 errors are logged but non-fatal — Sway continues rendering. The wlr-screencopy capture may work intermittently. If the stream crashes, try:
1. Using the GLES2 renderer instead of Vulkan
2. Using the llvmpipe (software) renderer as a last resort
3. Upgrading to wlroots 0.20+ if available (fixes XR24 format handling)

**Sunshine PR #5030 (merged April 21, 2026):** Fixed multi-GPU segfault and reverted Vulkan encoder support for wlr capture. Users on Sunshine >= 2026.421 should have this fix. The wlr capture now falls back to VAAPI/NVENC instead of Vulkan encoding.

**Key insight:** The XR24 errors are from Sway's Vulkan renderer, not from Sunshine. They're a wlroots 0.19.3 bug on the headless backend. The stream may work despite these errors if frame capture succeeds.

## Hyprland / uwsm Session Env Injection: EGL Black Screen

**Symptom:** Streaming works on KDE Plasma but on Hyprland (omarchy) Moonlight shows a black screen with green/white horizontal noise lines, same boot, same NVIDIA driver.

**Root cause:** Hyprland is launched through uwsm. `~/.config/uwsm/env-hyprland` exports `__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json`, which uwsm pushes into the systemd user manager via DBus SetEnvironment. Every user service (including sunshine-headless.service and sway-sunshine.service) inherits it. GLVND is then restricted to Mesa-only EGL, so Sunshine cannot init NVIDIA EGL on `adapter_name=/dev/dri/renderD129`:
- `Couldn't initialize EGL display: [00003001]` (EGL_NOT_INITIALIZED) on NVENC/Vulkan/VAAPI
- falls back to software libx264
- every wlr-screencopy frame fails DMABUF import: `Couldn't import RGB Image: 00003009` (EGL_BAD_MATCH)
- result: black screen + noise

KDE Plasma is started directly by SDDM (`plasma.desktop`) and never sources uwsm env, so this var is absent and streaming works.

**Fix (in both `systemd/sway-sunshine.service` and `systemd/sunshine-headless.service`):**

```ini
UnsetEnvironment=__EGL_VENDOR_LIBRARY_FILENAMES
```

`UnsetEnvironment=` strips the var only from those units' processes (the manager retains it globally, which is fine). Verified 2026-08-13: stream uses hevc_nvenc at 60 FPS with zero import errors.

**Optional NVIDIA PRIME knobs** (folded into the templates for exact reproduction, but NOT required for streaming — they only affect X11/GLX/Vulkan PRIME render-offload for desktop apps):

```ini
Environment=__GL_GSYNC_ALLOWED=0
Environment=__NV_PRIME_RENDER_OFFLOAD=1
Environment=__VK_LAYER_NV_optimus=NVIDIA_only
```

**Debugging tip:** verify what the DE injects with:
```bash
systemctl --user show-environment | grep -i egl
```

**Note:** The old diagnosis that these 3 vars were 'inherited from the Hyprland session' was WRONG — they come from live-only drop-in overrides (`~/.config/systemd/user/*.service.d/override.conf`) present on both DEs and are constant. The true DE-specific differentiator is only `__EGL_VENDOR_LIBRARY_FILENAMES`.

## Current host snapshot (2026-08-02)

This section records the live configuration inspected on 2026-08-02. It is a diagnostic snapshot, not a replacement for the repository templates above.

### Host and GPU

- User is `moe` (UID 1000), running KDE Plasma Wayland (`XDG_CURRENT_DESKTOP=KDE`).
- The machine has an NVIDIA GeForce RTX 5090 (PCI vendor `10de`) and an AMD Strix Halo/Radeon 8050S/8060S display controller (vendor `1002`). Both `nvidia`/`nvidia_drm` and `amdgpu` kernel modules are loaded.
- Installed NVIDIA userspace is 610.43.03; the active Sunshine log confirms NVENC rather than VAAPI/software encoding.
- The configured render node is `/dev/dri/renderD129`. Keep this aligned across `WLR_DRM_DEVICES` and Sunshine `adapter_name`; verify node numbering after driver or kernel changes because render numbers are not a permanent hardware identity.

### Live Wayland and service topology

The main KDE socket is `wayland-0`; the headless Sway socket is `wayland-1`. The live session also has `/run/user/1000/sway-sunshine.sock` and a PID file. The intended boot path is:

```text
default.target
  └─ sway-sunshine.service (headless wlroots/Sway compositor)
       └─ sunshine-headless.service (Sunshine capture/encode server)
            └─ Moonlight client on the TV (network client)
```

`sway-sunshine.service` is enabled through `default.target`; it uses `WLR_BACKENDS=headless`, `WLR_RENDERER=gles2`, `LIBSEAT_BACKEND=noop`, `WLR_LIBINPUT_NO_DEVICES=1`, `WLR_DRM_DEVICES=/dev/dri/renderD129`, and `WAYLAND_DISPLAY=wayland-1`. The wrapper at `~/.config/sway-sunshine/sway-wrapper.sh` records `/run/user/1000/sway-sunshine.pid` and then starts Sway.

`sunshine-headless.service` requires the Sway service, waits two seconds, exports the same Wayland/Sway socket, and currently runs `/usr/bin/sunshine` directly. The checked-in template still uses `/usr/bin/sg input -c /usr/bin/sunshine`; this is an intentional live/template drift and must be resolved deliberately before the next deployment. Do not assume `systemctl --user` status from a restricted diagnostic shell; use a normal user session or inspect the Sunshine log and socket files.

There is also a separate `~/.config/systemd/user/sunshine.service` unit. It is not part of the headless dependency chain and can conflict with the headless instance if enabled, because it starts another `/usr/bin/sunshine` with the same user configuration and network ports. Use only `sunshine-headless.service` for this setup unless the standalone unit is intentionally redesigned.

### Live Sunshine and audio configuration

`~/.config/sunshine/sunshine.conf` currently contains:

```ini
adapter_name = /dev/dri/renderD129
audio_sink = sink-sunshine-stereo
capture = wlr
min_threads = 6
minimum_fps_target = 20
nvenc_preset = 3
```

Capture is WLR screencopy from Sway, not KWin. `adapter_name` pins DMA-BUF imports to the GPU used by Sway; the log shows `h264_nvenc`, `hevc_nvenc`, and `av1_nvenc` all available. The live log also shows successful capture of `HEADLESS-1`, a client session at 1920x1080, and the encoder switching to HEVC NVENC.

PipeWire creates the null sink `sink-sunshine-stereo` from `pipewire/sunshine-null-sink.conf`. Sunshine selects it on connection; `restore-default-sink.sh` starts a detached user watcher to restore the original host sink after disconnect.

### Sway output, input, and game launch

The Sway config disables physical outputs, enables `HEADLESS-1`, and advertises 1920x1080@60 plus 3840x2160@120. Sunshine prep commands change the mode to the Moonlight client's requested width, height, and FPS, then reset to 1080p/60 on disconnect. All physical input events are disabled; Sunshine virtual keyboard, mouse, touch, pen, and PS5-pad devices are explicitly enabled.

The live `apps.json` is Sunshine v2 with 18 entries. Most entries launch through detached helper scripts: Lutris (IDs such as 6, 10, 16, 19, 21, 24, 25, 26, 28), Heroic/Legendary, or Steam (appid 3130330 and Big Picture). Entries consistently run sink restoration and dynamic resolution; game-specific undo scripts stop the relevant launcher. The low-resolution desktop entry is an exception and still uses an `xrandr` command targeting `HDMI-1`, which belongs to the physical desktop rather than the headless Sway output.

The installed launcher scripts hardcode `WAYLAND_DISPLAY=wayland-1` and use `/run/user/$(id -u)/sway-sunshine.sock`; resolution scripts use `/run/user/1000`. If the headless socket changes, update source templates and redeploy rather than editing `~/.config` manually. Steam and Lutris helpers intentionally terminate all matching processes system-wide before launching in headless Sway; this can close a desktop game/launcher.

### Verified streaming evidence

`~/.config/sunshine/sunshine.log` from 2026-08-02 records Sunshine 2026.516 discovering `wayland-1`, `HEADLESS-1`, WLR screencopy, all three NVENC codecs, running the prep commands, starting Steam Big Picture, and accepting a client connection. This confirms the capture/encode path has worked on the current host. Credentials, certificates, API keys, and portal tokens under `~/.config/sunshine/credentials/` are intentionally not copied into this repository or this document.

## Operational checks

Run these from the real KDE user session (not a sandboxed shell):

```bash
systemctl --user status sway-sunshine.service sunshine-headless.service
journalctl --user -u sunshine-headless.service -n 100 --no-pager
ls -la /run/user/$(id -u)/wayland-* /run/user/$(id -u)/sway-sunshine.*
grep -E 'WAYLAND_DISPLAY|WLR_DRM_DEVICES|ExecStart' ~/.config/systemd/user/{sway-sunshine,sunshine-headless}.service
grep -iE 'encoder|nvenc|vcn|CLIENT CONNECTED|Frame capture|error|fatal' ~/.config/sunshine/sunshine.log | tail -100
flatpak run com.moonlight_stream.Moonlight stream localhost "Portal 2"
```

To change configuration, edit the corresponding repository file, review the diff, and run `./install.sh`. The installer may require package installation and system udev changes; it currently invokes `sudo` internally, so run it interactively and review its prompts. Never hand-edit the live service/config copies as the normal workflow, never push to a remote without explicit consent, and never kill the llama-server process.

### Heroic Games Launcher

Heroic Games Launcher is supported through `launchers/heroic.py`:

- Reads Heroic's local JSON files for installed games:
  - Epic/Legendary: `~/.config/heroic/legendaryConfig/legendary/installed.json` (or Flatpak path)
  - GOG: `~/.config/heroic/gog_store/installed.json`
  - Amazon/Nile: `~/.config/heroic/nile_config/nile/installed.json`
  - Sideload: `~/.config/heroic/sideload_apps/library.json`
- Returns `(game_id, title, "Heroic", runner)` where runner is one of: legendary/gog/nile/sideload
- Launch command: `heroic heroic://launch/<runner>/<game_id> --no-gui --no-sandbox`
- Detection: `which heroic` or `flatpak list | grep com.heroicgameslauncher.hgl`
- Native: `heroic`, Flatpak: `flatpak run com.heroicgameslauncher.hgl`

## Working Commit Reference

Working commit at the time of this snapshot: `6146626` (`fix: use recursive process tree kill to terminate Wine/Proton children`).
