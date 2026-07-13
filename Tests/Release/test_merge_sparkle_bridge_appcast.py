from __future__ import annotations

import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "merge_sparkle_bridge_appcast.py"
SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SPARKLE = f"{{{SPARKLE_NAMESPACE}}}"


def appcast(build: str, *, minimum: str | None = None, duplicate: bool = False) -> str:
    minimum_element = (
        f"<sparkle:minimumUpdateVersion>{minimum}</sparkle:minimumUpdateVersion>"
        if minimum is not None
        else ""
    )
    item = f"""
      <item>
        <title>{build}</title>
        <sparkle:version>{build}</sparkle:version>
        {minimum_element}
        <enclosure url="https://example.invalid/{build}.dmg" length="42"
          sparkle:edSignature="signature-{build}" />
      </item>
    """
    return f"""<?xml version="1.0"?>
    <rss xmlns:sparkle="{SPARKLE_NAMESPACE}" version="2.0">
      <channel><title>Fixture</title>{item}{item if duplicate else ""}</channel>
    </rss>
    """


class MergeSparkleBridgeAppcastTests(unittest.TestCase):
    def run_merge(self, current_xml: str, bridge_xml: str) -> tuple[subprocess.CompletedProcess, Path]:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        current = root / "current.xml"
        bridge = root / "bridge.xml"
        output = root / "appcast.xml"
        current.write_text(current_xml)
        bridge.write_text(bridge_xml)
        result = subprocess.run(
            [
                "python3",
                str(SCRIPT),
                "--current",
                str(current),
                "--bridge",
                str(bridge),
                "--output",
                str(output),
                "--current-build",
                "7",
                "--bridge-build",
                "6",
                "--minimum-update-build",
                "6",
                "--channel-title",
                "LLM Pulse",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        return result, output

    def test_merges_current_then_bridge_and_preserves_update_gate(self):
        result, output = self.run_merge(
            appcast("7", minimum="6"),
            appcast("6"),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        root = ET.parse(output).getroot()
        channel = root.find("channel")
        self.assertIsNotNone(channel)
        self.assertEqual(channel.findtext("title"), "LLM Pulse")
        items = channel.findall("item")
        self.assertEqual(
            [item.findtext(f"{SPARKLE}version") for item in items],
            ["7", "6"],
        )
        self.assertEqual(items[0].findtext(f"{SPARKLE}minimumUpdateVersion"), "6")
        self.assertIsNone(items[1].find(f"{SPARKLE}minimumUpdateVersion"))

    def test_rejects_current_item_without_expected_minimum_update_build(self):
        result, output = self.run_merge(appcast("7"), appcast("6"))

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())
        self.assertIn("minimumUpdateVersion", result.stderr)

    def test_rejects_duplicate_bridge_items(self):
        result, output = self.run_merge(
            appcast("7", minimum="6"),
            appcast("6", duplicate=True),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())
        self.assertIn("exactly one item", result.stderr)


if __name__ == "__main__":
    unittest.main()
