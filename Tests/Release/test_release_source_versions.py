from __future__ import annotations

import json
import plistlib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class ReleaseSourceVersionTests(unittest.TestCase):
    def test_app_and_codex_companion_manifest_share_one_version(self) -> None:
        with (ROOT / "LLMPulse/Resources/Info.plist").open("rb") as handle:
            app_version = plistlib.load(handle)["CFBundleShortVersionString"]

        manifest = ROOT / "Plugin/.codex-plugin/plugin.json"
        document = json.loads(manifest.read_text(encoding="utf-8"))

        self.assertEqual(document["version"], app_version)


if __name__ == "__main__":
    unittest.main()
