import importlib.util
import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

os.environ.setdefault("DISCORD_CHANNEL_ID", "123456789012345678")
os.environ.setdefault(
    "DISCORD_WEBHOOK_URL",
    "https://discord.com/api/webhooks/123456789012345678/test-token",
)

SCRIPT_PATH = Path(__file__).with_name("discord-log-bot.py")
SPEC = importlib.util.spec_from_file_location("discord_log_bot", SCRIPT_PATH)
collector = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(collector)


class FakeJournalctl:
    def __init__(self, lines):
        self.stdout = io.StringIO("\n".join(lines) + "\n")
        self.stderr = io.StringIO()

    def wait(self):
        return 0


class DiscordLogBotTests(unittest.TestCase):
    def test_collects_ssh_and_audit_events_and_cursor(self):
        entries = [
            {
                "MESSAGE": "Accepted publickey for liam from 203.0.113.5 port 22 ssh2",
                "__REALTIME_TIMESTAMP": "1760000000000000",
            },
            {
                "MESSAGE": (
                    'type=SYSCALL msg=audit(1760000000.1:42): '
                    'auid=4294967295 key="team_config" exe="/usr/bin/vi"'
                ),
                "__REALTIME_TIMESTAMP": "1760000001000000",
            },
            {
                "MESSAGE": (
                    'type=PATH msg=audit(1760000000.1:42): '
                    'name="/etc/ssh/sshd_config"'
                ),
                "__REALTIME_TIMESTAMP": "1760000001000000",
            },
            {
                "MESSAGE": "type=EOE msg=audit(1760000000.1:42):",
                "__REALTIME_TIMESTAMP": "1760000001000000",
            },
        ]
        lines = [json.dumps(entry) for entry in entries]
        lines.append("-- cursor: cursor-42")

        with mock.patch.object(
            collector.subprocess, "Popen", return_value=FakeJournalctl(lines)
        ) as popen:
            cursor, events, total = collector.collect_journal_events(None)

        self.assertIn("--since=1 minute ago", popen.call_args.args[0])
        self.assertEqual(cursor, "cursor-42")
        self.assertEqual(total, 2)
        self.assertEqual(len(events), 2)
        self.assertTrue(any("SSH SUCCESS" in event for event in events))
        self.assertTrue(any("/etc/ssh/sshd_config" in event for event in events))

    def test_uses_saved_cursor_for_next_read(self):
        lines = ["-- cursor: cursor-43"]
        with mock.patch.object(
            collector.subprocess, "Popen", return_value=FakeJournalctl(lines)
        ) as popen:
            cursor, events, total = collector.collect_journal_events("cursor-42")

        self.assertIn("--after-cursor=cursor-42", popen.call_args.args[0])
        self.assertEqual(cursor, "cursor-43")
        self.assertEqual(events, [])
        self.assertEqual(total, 0)

    def test_webhook_channel_is_checked_once(self):
        with tempfile.TemporaryDirectory() as directory:
            with (
                mock.patch.object(collector, "STATE_DIRECTORY", directory),
                mock.patch.object(
                    collector, "http_json", return_value={"channel_id": collector.CHANNEL_ID}
                ) as http_json,
            ):
                collector.verify_webhook_channel()
                collector.verify_webhook_channel()
                self.assertEqual(http_json.call_count, 1)

            stored = (Path(directory) / "webhook.verified").read_text()
            self.assertNotIn("test-token", stored)

    def test_webhook_channel_mismatch_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            with (
                mock.patch.object(collector, "STATE_DIRECTORY", directory),
                mock.patch.object(collector, "http_json", return_value={"channel_id": "1"}),
            ):
                with self.assertRaises(RuntimeError):
                    collector.verify_webhook_channel()
            self.assertFalse((Path(directory) / "webhook.verified").exists())

    def test_cursor_is_saved_after_successful_delivery(self):
        with tempfile.TemporaryDirectory() as directory:
            cursor_path = Path(directory) / "journal.cursor"
            with (
                mock.patch.object(collector, "CURSOR_FILE", str(cursor_path)),
                mock.patch.object(collector, "STATE_DIRECTORY", directory),
                mock.patch.object(collector, "http_json", return_value={"channel_id": collector.CHANNEL_ID}),
                mock.patch.object(
                    collector,
                    "collect_journal_events",
                    return_value=("cursor-44", ["SSH SUCCESS"], 1),
                ),
                mock.patch.object(collector, "post_to_discord", return_value=True),
            ):
                self.assertEqual(collector.main(), 0)

            self.assertEqual(cursor_path.read_text().strip(), "cursor-44")

    def test_cursor_is_not_advanced_when_delivery_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            cursor_path = Path(directory) / "journal.cursor"
            with (
                mock.patch.object(collector, "CURSOR_FILE", str(cursor_path)),
                mock.patch.object(collector, "STATE_DIRECTORY", directory),
                mock.patch.object(collector, "http_json", return_value={"channel_id": collector.CHANNEL_ID}),
                mock.patch.object(
                    collector,
                    "collect_journal_events",
                    return_value=("cursor-45", ["SSH SUCCESS"], 1),
                ),
                mock.patch.object(collector, "post_to_discord", return_value=False),
            ):
                self.assertEqual(collector.main(), 1)

            self.assertFalse(cursor_path.exists())

    def test_batches_respect_discord_message_limit(self):
        messages = collector.discord_messages(["x" * 300 for _ in range(10)], 120)

        self.assertGreater(len(messages), 1)
        self.assertTrue(all(len(message) <= collector.MAX_MESSAGE_LENGTH for message in messages))
        self.assertIn("110 event details omitted", messages[0])


if __name__ == "__main__":
    unittest.main()
