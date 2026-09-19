#!/usr/bin/env python3
"""Keep streaming-server selection deterministic when both servers exist."""

from pathlib import Path
import unittest


ROOT = Path(__file__).parents[1]


class InstallerServerDetectionTests(unittest.TestCase):
    def test_apollo_is_checked_before_sunshine(self) -> None:
        installer = (ROOT / "install.sh").read_text()

        apollo_check = installer.index("if command -v apollo")
        sunshine_check = installer.index("elif command -v sunshine", apollo_check)

        self.assertLess(apollo_check, sunshine_check)
        self.assertIn('STREAM_SERVER_NAME="Apollo"', installer)
        self.assertIn('STREAM_SERVER_NAME="Sunshine"', installer)


if __name__ == "__main__":
    unittest.main()
