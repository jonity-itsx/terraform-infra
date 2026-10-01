#!/usr/bin/env python3
import datetime
import hashlib
import json
import logging
import os
import pwd
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
HOST = os.uname().nodename
CHANNEL_ID = os.environ["DISCORD_CHANNEL_ID"]
WEBHOOK_URL = os.environ["DISCORD_WEBHOOK_URL"]
STATE_DIRECTORY = os.environ.get("STATE_DIRECTORY", "/var/lib/team-discord-log-bot")
CURSOR_FILE = os.path.join(STATE_DIRECTORY, "journal.cursor")
MAX_EVENTS = 100
MAX_EVENT_LENGTH = 300
MAX_MESSAGE_LENGTH = 1800

SSH_RE = re.compile(
    r"^(?P<result>Accepted|Failed) (?P<method>\S+) for "
    r"(?:(?:invalid user) )?(?P<user>\S+) from (?P<ip>\S+) port (?P<port>\d+)"
)
AUDIT_ID_RE = re.compile(r"msg=audit\([^:]+:(\d+)\)")
AUDIT_FIELD_RE = re.compile(r'(\w+)=((?:"(?:\\.|[^"])*")|[^\s]+)')


def http_json(url, headers, body=None):
    data = None if body is None else json.dumps(body).encode()
    request_headers = {
        "User-Agent": "Team4-Jumphost-Log-Forwarder/1.0",
        **headers,
    }
    request = urllib.request.Request(url, data=data, headers=request_headers)
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.loads(response.read())


def webhook_url():
    parsed = urllib.parse.urlsplit(WEBHOOK_URL)
    if parsed.scheme != "https" or parsed.netloc != "discord.com" or not re.fullmatch(
        r"/api/webhooks/\d+/[^/]+", parsed.path
    ):
        raise ValueError("DISCORD_WEBHOOK_URL is not a Discord webhook URL")
    return WEBHOOK_URL


def post_to_discord(content):
    for attempt in range(4):
        try:
            http_json(
                webhook_url() + "?wait=true",
                {"Content-Type": "application/json"},
                {"content": content, "allowed_mentions": {"parse": []}},
            )
            return True
        except urllib.error.HTTPError as error:
            retry_after = 1
            try:
                detail = json.loads(error.read())
                retry_after = min(float(detail.get("retry_after", 1)), 30)
            except (ValueError, TypeError):
                pass
            if error.code < 500 and error.code != 429:
                logging.error("Discord rejected an audit notification: HTTP %s", error.code)
                return False
            logging.warning("Discord request failed (HTTP %s), retry %s", error.code, attempt + 1)
            if attempt < 3:
                time.sleep(retry_after if error.code == 429 else min(2**attempt, 15))
        except Exception as error:
            logging.warning(
                "Could not deliver audit notification (%s), retry %s",
                type(error).__name__, attempt + 1,
            )
            if attempt < 3:
                time.sleep(min(2**attempt, 15))
    logging.error("Audit notification delivery failed; journal cursor was not advanced")
    return False


def audit_fields(message):
    return {
        key: value[1:-1] if value.startswith('"') and value.endswith('"') else value
        for key, value in AUDIT_FIELD_RE.findall(message)
    }


def message_text(entry):
    # journald ger MESSAGE som en lista med bytes när meddelandet innehåller
    # kontrolltecken eller ogiltig UTF-8 (till exempel curls förloppsmätare i
    # google_hostname.sh vid varje uppstart), och som null när fältet är för
    # stort. En enda sådan post fick hela boten att krascha på samma cursor
    # varje minut, så att inga larm skickades.
    message = entry.get("MESSAGE")
    if isinstance(message, list):
        return bytes(b & 0xFF for b in message).decode("utf-8", "replace")
    if isinstance(message, str):
        return message
    return ""


def event_time(entry):
    try:
        timestamp = int(entry["__REALTIME_TIMESTAMP"]) / 1_000_000
        return datetime.datetime.fromtimestamp(timestamp).astimezone().strftime("%H:%M:%S")
    except (KeyError, TypeError, ValueError, OSError):
        return "unknown time"


def audit_message(records):
    syscall = next((record for record in records if record.get("type") == "SYSCALL"), None)
    if not syscall or syscall.get("key", "").strip('"') != "team_config":
        return None

    paths = sorted({record.get("name", "") for record in records if record.get("type") == "PATH"})
    paths = [path for path in paths if path and path != "(null)"]
    actor_id = syscall.get("auid", "")
    try:
        actor = pwd.getpwuid(int(actor_id)).pw_name
    except (KeyError, ValueError):
        actor = "system" if actor_id in ("", "4294967295", "unset") else actor_id
    executable = syscall.get("exe") or syscall.get("comm") or "unknown process"
    changed = ", ".join(paths[:5]) or "protected configuration"
    if len(paths) > 5:
        changed += f" and {len(paths) - 5} more"
    timestamp = records[0].get("journal_time", "unknown time")
    return f"{timestamp} CONFIG CHANGE on {HOST}: actor {actor}, process {executable}, paths: {changed}"


def collect_journal_events(cursor):
    command = ["journalctl", "--no-pager", "--output=json", "--show-cursor"]
    if cursor:
        command.append(f"--after-cursor={cursor}")
    else:
        command.append("--since=1 minute ago")

    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    latest_cursor = None
    events = []
    total_events = 0
    audit_groups = {}

    def add_event(message):
        nonlocal total_events
        total_events += 1
        if len(events) < MAX_EVENTS:
            events.append(message[:MAX_EVENT_LENGTH])

    for line in process.stdout:
        line = line.rstrip("\n")
        if line.startswith("-- cursor:"):
            latest_cursor = line.partition(":")[2].strip()
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue

        message = message_text(entry)
        ssh_match = SSH_RE.search(message)
        if ssh_match:
            result = "SUCCESS" if ssh_match["result"] == "Accepted" else "FAILED"
            add_event(
                f"{event_time(entry)} SSH {result} on {HOST}: {ssh_match['user']} "
                f"via {ssh_match['method']} from {ssh_match['ip']}:{ssh_match['port']}"
            )

        audit_id_match = AUDIT_ID_RE.search(message)
        if not audit_id_match:
            continue
        audit_id = audit_id_match.group(1)
        record = audit_fields(message)
        record["journal_time"] = event_time(entry)
        if record.get("type") == "EOE":
            grouped_records = audit_groups.pop(audit_id, [])
            result = audit_message(grouped_records)
            if result:
                add_event(result)
        else:
            audit_groups.setdefault(audit_id, []).append(record)

    return_code = process.wait()
    error_output = process.stderr.read()
    if return_code:
        raise RuntimeError(f"journalctl failed with status {return_code}: {error_output.strip()}")

    for grouped_records in audit_groups.values():
        result = audit_message(grouped_records)
        if result:
            add_event(result)

    return latest_cursor, events, total_events


def read_cursor():
    try:
        with open(CURSOR_FILE, encoding="utf-8") as cursor_file:
            return cursor_file.read().strip() or None
    except FileNotFoundError:
        return None


def save_cursor(cursor):
    os.makedirs(STATE_DIRECTORY, mode=0o750, exist_ok=True)
    temporary_path = f"{CURSOR_FILE}.tmp"
    with open(temporary_path, "w", encoding="utf-8") as cursor_file:
        cursor_file.write(cursor + "\n")
        cursor_file.flush()
        os.fsync(cursor_file.fileno())
    os.replace(temporary_path, CURSOR_FILE)
    directory_fd = os.open(STATE_DIRECTORY, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def discord_messages(events, total_events):
    omitted = total_events - len(events)
    summary = f"{HOST}: {total_events} log events in the last batch"
    if omitted:
        summary += f" ({omitted} event details omitted; batch limit {MAX_EVENTS})"
    messages = []
    current = summary
    for event in events:
        candidate = f"{current}\n{event}"
        if len(candidate) > MAX_MESSAGE_LENGTH:
            messages.append(current)
            current = event
        else:
            current = candidate
    if current:
        messages.append(current)
    return messages


def verify_webhook_channel():
    # Checked once per webhook URL and channel, not every minute. Only a hash
    # of the URL is stored, never the URL itself.
    verified_path = os.path.join(STATE_DIRECTORY, "webhook.verified")
    fingerprint = hashlib.sha256(f"{WEBHOOK_URL}\n{CHANNEL_ID}".encode()).hexdigest()
    try:
        with open(verified_path, encoding="utf-8") as verified_file:
            if verified_file.read().strip() == fingerprint:
                return
    except FileNotFoundError:
        pass
    webhook = http_json(webhook_url(), {})
    if str(webhook.get("channel_id")) != CHANNEL_ID:
        raise RuntimeError("Discord webhook channel does not match DISCORD_CHANNEL_ID")
    os.makedirs(STATE_DIRECTORY, mode=0o750, exist_ok=True)
    with open(verified_path, "w", encoding="utf-8") as verified_file:
        verified_file.write(fingerprint + "\n")


def main():
    verify_webhook_channel()

    latest_cursor, events, total_events = collect_journal_events(read_cursor())
    if latest_cursor is None:
        logging.info("No journal cursor was returned; nothing to checkpoint")
        return 0

    if events:
        for message in discord_messages(events, total_events):
            if not post_to_discord(message):
                return 1
        logging.info("Sent %s events (%s details) to Discord", total_events, len(events))

    save_cursor(latest_cursor)
    return 0


if __name__ == "__main__":
    sys.exit(main())