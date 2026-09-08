#!/usr/bin/env python3
"""Live routing check; run during a Moonlight game stream. Probe is digital silence."""
import argparse
import json
import subprocess
import time


def pulse(*args):
    return subprocess.check_output(["pactl", *args], text=True).strip()


def check(game_name):
    sinks = {s["index"]: s["name"] for s in json.loads(pulse("-f", "json", "list", "sinks"))}
    streams = json.loads(pulse("-f", "json", "list", "sink-inputs"))
    default = pulse("get-default-sink")
    failures = []
    if "sunshine" in default:
        failures.append(f"desktop default is {default}")
    for name, streaming in [("isolation-host-probe", False), (game_name, True)]:
        matches = [s for s in streams if s["properties"].get("application.name") == name]
        if not matches:
            failures.append(f"no playback stream for {name}")
        for stream in matches:
            sink = sinks.get(stream["sink"], "<missing>")
            print(f"{name} -> {sink}")
            if streaming and sink != "sink-sunshine-stereo":
                failures.append(f"game audio leaks to {sink}")
            if not streaming and sink != default:
                failures.append(f"new desktop playback did not use {default}")
            if not streaming and "sunshine" in sink:
                failures.append("desktop audio leaks into stream")
    captures = json.loads(pulse("-f", "json", "list", "source-outputs"))
    sources = {s["index"]: s["name"] for s in json.loads(pulse("-f", "json", "list", "sources"))}
    sunshine = [s for s in captures if s["properties"].get("application.name") == "sunshine"]
    if not sunshine:
        failures.append("Sunshine is not recording")
    for capture in sunshine:
        source = sources.get(capture["source"], "<missing>")
        print(f"Sunshine captures {source}")
        if source != "sink-sunshine-stereo.monitor":
            failures.append(f"Sunshine captures host audio from {source}")
    for failure in failures:
        print(f"FAIL: {failure}")
    if not failures:
        print("PASS: host playback, game playback, and Sunshine capture are isolated")
    return not failures


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--game-name", required=True,
        help="PulseAudio application.name of the streamed game",
    )
    args = parser.parse_args()
    probe = subprocess.Popen([
        "paplay", "--raw", "--rate=48000", "--channels=2", "--volume=0",
        "--client-name=isolation-host-probe", "/dev/zero",
    ])
    try:
        time.sleep(0.7)
        success = check(args.game_name)
    finally:
        probe.terminate()
        probe.wait(timeout=5)
    raise SystemExit(0 if success else 1)
