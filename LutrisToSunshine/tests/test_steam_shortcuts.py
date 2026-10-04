import os
import tempfile
import unittest
from unittest.mock import patch

import vdf

from launchers import steam
from sunshine import sunshine


class SteamShortcutTests(unittest.TestCase):
    def test_import_quotes_executable_path_with_spaces(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            config = os.path.join(root, "userdata", "123", "config")
            os.makedirs(config)
            path = os.path.join(config, "shortcuts.vdf")
            with open(path, "wb") as handle:
                vdf.binary_dump({"shortcuts": {}}, handle)

            with patch.object(steam, "_get_shortcuts_path", return_value=path):
                self.assertTrue(steam.add_nonsteam_game_to_vdf(
                    "Split Fiction", "/games/Split Fiction/SplitFiction.exe"
                ))

            with open(path, "rb") as handle:
                entry = next(iter(vdf.binary_load(handle)["shortcuts"].values()))
            self.assertEqual(entry["Exe"], '"/games/Split Fiction/SplitFiction.exe"')

    def test_nonsteam_shortcut_is_listed_with_launchable_id(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            config = os.path.join(root, "userdata", "123", "config")
            os.makedirs(config)
            with open(os.path.join(config, "localconfig.vdf"), "w") as handle:
                handle.write("")
            with open(os.path.join(config, "shortcuts.vdf"), "wb") as handle:
                vdf.binary_dump({"shortcuts": {"0": {
                    "appid": -474594709,
                    "AppName": "Control Resonant",
                    "Exe": "/games/control",
                }}}, handle)

            with patch.object(steam, "detect_steam_installation", return_value=(True, "native")), \
                 patch.object(steam, "get_steam_root", return_value=root), \
                 patch.object(steam, "_get_shortcuts_path", return_value=os.path.join(config, "shortcuts.vdf")):
                games = steam.list_steam_games()

        game_id = f"shortcut:{(((-474594709) & 0xffffffff) << 32) | 0x02000000}"
        self.assertIn((game_id, "Control Resonant"), games)
        self.assertEqual(
            sunshine.build_game_command(game_id, "Steam"),
            f"steam steam://rungameid/{game_id.removeprefix('shortcut:')}",
        )


if __name__ == "__main__":
    unittest.main()
