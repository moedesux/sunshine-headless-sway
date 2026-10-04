import os
import shlex
import tempfile
import unittest
from unittest.mock import patch

from launchers import lutris


class LutrisPathTests(unittest.TestCase):
    def test_resolved_command_preserves_spaces_in_executable_path(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            exe = os.path.join(root, "Split Fiction", "SplitFiction.exe")
            os.makedirs(os.path.dirname(exe))
            open(exe, "wb").close()
            with open(os.path.join(root, "split-fiction-1.yml"), "w") as handle:
                handle.write(f"game:\n  exe: {exe}\n")

            with patch.object(lutris, "LUTRIS_GAMES_DIR", root):
                game = lutris.resolve_lutris_game("split-fiction")

            self.assertIsNotNone(game)
            self.assertEqual(shlex.split(game["resolved_cmd"]), [exe])


if __name__ == "__main__":
    unittest.main()
