from __future__ import annotations

import concurrent.futures
import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HOOK = ROOT / "Plugin" / "hooks" / "record_event.sh"
HOOKS_CONFIG = ROOT / "Plugin" / "hooks" / "hooks.json"
MAX_JOURNAL_BYTES = 8 * 1024 * 1024


class RecordEventHookTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.home = Path(self.temporary_directory.name)
        self.events_file = (
            self.home
            / "Library"
            / "Application Support"
            / "GPT Pulse"
            / "events"
            / "events.jsonl"
        )

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def run_hook(self, payload: object | str) -> subprocess.CompletedProcess[str]:
        raw_payload = payload if isinstance(payload, str) else json.dumps(payload)
        environment = os.environ.copy()
        environment["HOME"] = str(self.home)
        return subprocess.run(
            ["/bin/sh", str(HOOK)],
            input=raw_payload,
            text=True,
            capture_output=True,
            check=False,
            env=environment,
            timeout=5,
        )

    def read_events(self) -> list[dict[str, str]]:
        if not self.events_file.exists():
            return []
        return [
            json.loads(line)
            for line in self.events_file.read_text(encoding="utf-8").splitlines()
            if line
        ]

    def test_records_only_whitelisted_scalar_fields(self) -> None:
        result = self.run_hook(
            {
                "session_id": "thread-1",
                "turn_id": "turn-1",
                "cwd": "/tmp/project",
                "hook_event_name": "UserPromptSubmit",
                "model": "gpt-5",
                "prompt": "private prompt",
                "tool_input": {"secret": "never persist"},
                "timestamp": "2026-07-10T12:00:00.000Z",
            }
        )

        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "{}\n")
        self.assertEqual(
            self.read_events(),
            [
                {
                    "session_id": "thread-1",
                    "turn_id": "turn-1",
                    "hook_event_name": "UserPromptSubmit",
                    "timestamp": "2026-07-10T12:00:00.000Z",
                }
            ],
        )

    def test_adds_timestamp_and_owner_only_permissions(self) -> None:
        result = self.run_hook(
            {"session_id": "thread-1", "hook_event_name": "SessionStart"}
        )

        self.assertEqual(result.stdout, "{}\n")
        [event] = self.read_events()
        self.assertTrue(event["timestamp"].endswith("Z"))
        self.assertEqual(
            stat.S_IMODE(self.events_file.parent.stat().st_mode),
            0o700,
        )
        self.assertEqual(stat.S_IMODE(self.events_file.stat().st_mode), 0o600)

    def test_ignores_invalid_unsupported_and_oversized_input(self) -> None:
        for payload in (
            "not-json",
            {"session_id": "thread-1", "hook_event_name": "UnknownEvent"},
            {"hook_event_name": "SessionStart"},
            {
                "session_id": "x" * 257,
                "hook_event_name": "SessionStart",
            },
            " " * (8 * 1024 * 1024 + 1),
        ):
            result = self.run_hook(payload)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "{}\n")

        self.assertEqual(self.read_events(), [])

    def test_rejects_symlink_destination(self) -> None:
        self.events_file.parent.mkdir(parents=True)
        target = self.home / "do-not-touch.jsonl"
        target.write_text("sentinel\n", encoding="utf-8")
        self.events_file.symlink_to(target)

        self.run_hook(
            {"session_id": "thread-1", "hook_event_name": "SessionStart"}
        )

        self.assertEqual(target.read_text(encoding="utf-8"), "sentinel\n")

    def test_concurrent_hooks_append_complete_json_lines(self) -> None:
        def invoke(index: int) -> subprocess.CompletedProcess[str]:
            return self.run_hook(
                {
                    "session_id": f"thread-{index}",
                    "hook_event_name": "PostToolUse",
                    "timestamp": "2026-07-10T12:00:00.000Z",
                }
            )

        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as executor:
            results = list(executor.map(invoke, range(24)))

        self.assertTrue(all(result.stdout == "{}\n" for result in results))
        events = self.read_events()
        self.assertEqual(len(events), 24)
        self.assertEqual(
            {event["session_id"] for event in events},
            {f"thread-{index}" for index in range(24)},
        )

    def test_compacts_without_losing_live_waiting_state(self) -> None:
        self.events_file.parent.mkdir(parents=True)
        retained_lines = [
            json.dumps(
                {
                    "session_id": "thread-live",
                    "turn_id": "turn-live",
                    "hook_event_name": "UserPromptSubmit",
                    "timestamp": "2026-07-10T11:59:00.000Z",
                }
            ),
            json.dumps(
                {
                    "session_id": "thread-live",
                    "turn_id": "turn-live",
                    "hook_event_name": "PermissionRequest",
                    "timestamp": "2026-07-10T12:00:00.000Z",
                }
            ),
        ]
        retained = ("\n".join(retained_lines) + "\n").encode()
        filler = b"x" * (MAX_JOURNAL_BYTES - len(retained) - 8) + b"\n"
        self.events_file.write_bytes(filler + retained)

        self.run_hook(
            {"session_id": "thread-new", "hook_event_name": "Stop"}
        )

        self.assertLess(self.events_file.stat().st_size, 1024)
        events = self.read_events()
        self.assertEqual(
            [event["hook_event_name"] for event in events],
            ["UserPromptSubmit", "PermissionRequest", "Stop"],
        )
        self.assertEqual(events[0]["session_id"], "thread-live")
        self.assertEqual(events[-1]["session_id"], "thread-new")

    def test_hook_configuration_matches_runtime_events(self) -> None:
        config = json.loads(HOOKS_CONFIG.read_text(encoding="utf-8"))
        self.assertEqual(
            set(config["hooks"]),
            {
                "SessionStart",
                "UserPromptSubmit",
                "PermissionRequest",
                "PostToolUse",
                "Stop",
            },
        )
        for registrations in config["hooks"].values():
            for registration in registrations:
                for hook in registration["hooks"]:
                    self.assertEqual(hook["type"], "command")
                    self.assertEqual(
                        hook["command"],
                        '/bin/sh "${PLUGIN_ROOT}/hooks/record_event.sh"',
                    )


if __name__ == "__main__":
    unittest.main()
