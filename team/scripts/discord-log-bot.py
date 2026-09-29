#!/usr/bin/env python3
import base64
import json
import logging
import os
import pwd
import queue
import re
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
EVENTS = queue.Queue()
HOST = os.uname().nodename
CHANNEL_ID = os.environ["DISCORD_CHANNEL_ID"]
SECRET_RESOURCE = os.environ["DISCORD_SECRET_RESOURCE"]
BOT_TOKEN_CACHE = None
BOT_TOKEN_CACHE_UNTIL = 0

SSH_RE = re.compile(
    r"^(?P<result>Accepted|Failed) (?P<method>\S+) for "
    r"(?:(?:invalid user) )?(?P<user>\S+) from (?P<ip>\S+) port (?P<port>\d+)"
)
AUDIT_ID_RE = re.compile(r"msg=audit\([^:]+:(\d+)\)")
AUDIT_FIELD_RE = re.compile(r'(\w+)=((?:"(?:\\.|[^"])*")|[^\s]+)')


def http_json(url, headers, body=None):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.loads(response.read())


def metadata_token():
    request = urllib.request.Request(
        "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token",
        headers={"Metadata-Flavor": "Google"},
    )
    with urllib.request.urlopen(request, timeout=5) as response:
        return json.loads(response.read())["access_token"]


def webhook_url():
    global BOT_TOKEN_CACHE, BOT_TOKEN_CACHE_UNTIL
    if BOT_TOKEN_CACHE and time.monotonic() < BOT_TOKEN_CACHE_UNTIL:
        return BOT_TOKEN_CACHE

    access_token = metadata_token()
    resource = urllib.parse.quote(SECRET_RESOURCE, safe="/")
    secret = http_json(
        f"https://secretmanager.googleapis.com/v1/{resource}:access",
        {"Authorization": f"Bearer {access_token}"},
    )
    BOT_TOKEN_CACHE = base64.b64decode(secret["payload"]["data"]).decode().strip()
    parsed = urllib.parse.urlsplit(BOT_TOKEN_CACHE)
    if parsed.scheme != "https" or parsed.netloc != "discord.com" or not re.fullmatch(
        r"/api/webhooks/\d+/[^/]+", parsed.path
    ):
        raise ValueError("Secret Manager value is not a Discord webhook URL")
    BOT_TOKEN_CACHE_UNTIL = time.monotonic() + 300
    return BOT_TOKEN_CACHE


def post_to_discord(content):
    for attempt in range(4):
        try:
            http_json(
                webhook_url() + "?wait=true",
                {"Content-Type": "application/json"},
                {"content": content[:1900], "allowed_mentions": {"parse": []}},
            )
            return
        except urllib.error.HTTPError as error:
            retry_after = 1
            try:
                detail = json.loads(error.read())
                retry_after = min(float(detail.get("retry_after", 1)), 30)
            except (ValueError, TypeError):
                pass
            if error.code < 500 and error.code != 429:
                logging.error("Discord rejected an audit notification: HTTP %s", error.code)
                return
            logging.warning("Discord request failed (HTTP %s), retry %s", error.code, attempt + 1)
            time.sleep(retry_after if error.code == 429 else min(2**attempt, 15))
        except Exception as error:
            logging.warning(
                "Could not deliver audit notification (%s), retry %s",
                type(error).__name__, attempt + 1,
            )
            time.sleep(min(2**attempt, 15))
    logging.error("Dropping audit notification after retries")


def ssh_reader():
    command = [
        "journalctl", "--follow", "--lines=0", "--no-pager", "--output=json",
        "_COMM=sshd", "_COMM=sshd-session",
    ]
    while True:
        try:
            with subprocess.Popen(command, stdout=subprocess.PIPE, text=True) as process:
                for line in process.stdout:
                    try:
                        message = json.loads(line).get("MESSAGE", "")
                    except json.JSONDecodeError:
                        continue
                    match = SSH_RE.search(message)
                    if match:
                        result = "SUCCESS" if match["result"] == "Accepted" else "FAILED"
                        EVENTS.put(
                            f"SSH {result} on {HOST}: {match['user']} via {match['method']} "
                            f"from {match['ip']}:{match['port']}"
                        )
                process.wait()
        except Exception:
            logging.exception("SSH journal reader stopped")
        time.sleep(2)


def audit_fields(line):
    return {
        key: value[1:-1] if value.startswith('"') and value.endswith('"') else value
        for key, value in AUDIT_FIELD_RE.findall(line)
    }


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
    return f"CONFIG CHANGE on {HOST}: actor {actor}, process {executable}, paths: {changed}"


def audit_reader():
    path = "/var/log/audit/audit.log"
    current_id = None
    records = []
    while True:
        try:
            with open(path, encoding="utf-8", errors="replace") as audit_log:
                audit_log.seek(0, os.SEEK_END)
                while True:
                    line = audit_log.readline()
                    if not line:
                        time.sleep(0.25)
                        continue
                    event_match = AUDIT_ID_RE.search(line)
                    if not event_match:
                        continue
                    event_id = event_match.group(1)
                    if current_id is not None and event_id != current_id and records:
                        message = audit_message(records)
                        if message:
                            EVENTS.put(message)
                        records = []
                    current_id = event_id
                    record = audit_fields(line)
                    if record.get("type") == "EOE":
                        message = audit_message(records)
                        if message:
                            EVENTS.put(message)
                        records = []
                        current_id = None
                    else:
                        records.append(record)
        except FileNotFoundError:
            logging.warning("Waiting for auditd log at %s", path)
            time.sleep(2)
        except Exception:
            logging.exception("Audit log reader stopped")
            time.sleep(2)


def main():
    webhook = http_json(webhook_url(), {})
    if str(webhook.get("channel_id")) != CHANNEL_ID:
        raise RuntimeError("Discord webhook channel does not match DISCORD_CHANNEL_ID")
    threading.Thread(target=ssh_reader, daemon=True).start()
    threading.Thread(target=audit_reader, daemon=True).start()
    while True:
        post_to_discord(EVENTS.get())


if __name__ == "__main__":
    main()
