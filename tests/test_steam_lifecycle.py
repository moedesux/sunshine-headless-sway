#!/usr/bin/env python3
"""Keep Sunshine's Steam launcher lifecycle aligned with the Steam process."""

import json
from pathlib import Path
import unittest


ROOT = Path(__file__).parents[1]


class SteamLifecycleTests(unittest.TestCase):
    def test_big_picture_uses_a_tracked_launcher(self) -> None:
        apps = json.loads((ROOT / "sunshine/apps.json").read_text())["apps"]
        app = next(app for app in apps if app["name"] == "Steam Big Picture")

        self.assertEqual(
            app["cmd"],
            "/home/YOUR_USER/.config/sway-sunshine/start-steam-game.sh bigpicture --wait",
        )
        self.assertFalse(app["auto-detach"])
        self.assertNotIn("detached", app)

    def test_steam_launcher_owns_sleep_inhibitor_for_its_lifetime(self) -> None:
        launcher = (ROOT / "sway-sunshine/start-steam-game.sh").read_text()

        self.assertIn("exec systemd-inhibit", launcher)
        self.assertIn("--what=sleep:idle", launcher)
        self.assertIn("--mode=block", launcher)
        self.assertIn("SUNSHINE_STEAM_INHIBITED=1", launcher)

    def test_every_steam_launcher_waits_for_steam_to_exit(self) -> None:
        launcher = (ROOT / "sway-sunshine/start-steam-game.sh").read_text()

        self.assertNotIn("WAIT_FOR_EXIT", launcher)
        self.assertIn('while pgrep -x steam >/dev/null 2>&1; do', launcher)


if __name__ == "__main__":
    unittest.main()
