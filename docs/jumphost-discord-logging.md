# Jumphost Discord Logging Report

**Status:** Implemented; timer-based redesign in progress.

## Purpose and scope

The jumphost forwards SSH authentication and selected system-configuration
changes to a Discord channel. This is intended to make relevant activity visible
to the team without requiring someone to watch the VM's local logs.

The audit rules cover writes and attribute changes under `/etc/ssh`,
`/etc/sudoers`, `/etc/sudoers.d`, `/etc/systemd/system`, `/usr/local/bin`, and
`/usr/local/sbin`. Notifications include the actor, process, and affected paths.
The collector does not send file contents or shell command text. SSH events are
reported as successful or failed authentications.

## Current design

The forwarder is a Python one-shot service, not a continuously running daemon.
A systemd timer starts it once per minute. Each run reads new journal entries,
collects SSH and audit events, and sends a batch to Discord. The implementation
uses Python's standard library and installs no Python packages.

Journald is configured for persistent storage with a 100 MB cap and a 14-day
retention limit. auditd's syslog plugin forwards audit records into journald, so
both SSH and audit events can use one journal cursor. The saved cursor is stored
in the systemd-managed state directory at
`/var/lib/team-discord-log-bot/journal.cursor`.

The cursor is written atomically only after all Discord messages for a run have
been accepted. If delivery fails, the cursor remains unchanged and the timer
will retry those events on a later run. If part of a multi-message batch was
accepted before another part failed, those accepted messages may be duplicated
on retry. Delivery is therefore at-least-once, not exactly-once.

To keep resource use and Discord traffic bounded, one run retains at most 100
event details. It reports the total event count and how many details were
omitted when that cap is exceeded. Messages are split below Discord's size
limit. `Persistent=true` on the timer allows a missed timer activation to run
after the VM returns.

## Credentials and permissions

`discord_channel_id` in `team/terraform.tfvars` is the non-secret target channel
ID. The incoming webhook URL is the credential; the webhook ID and token are
already contained in it. A Discord application token and guild ID are not used.

The URL is held in `/etc/team-discord-webhook.env`, a root-only file on the
jumphost. It is not put in Terraform state or Secret Manager, so no additional
GCP IAM grant is needed. The service runs as a systemd dynamic user with access
to the journal and a private state directory, and has systemd filesystem and
privilege restrictions. If the VM is replaced, provision the webhook file
again. Any webhook URL exposed publicly must be revoked and replaced.

## Deployment and verification

Run Terraform commands in the local repository workspace, not in an SSH shell:

```sh
terraform -chdir=team plan
terraform -chdir=team apply
```

After an apply that changes startup metadata, reboot the jumphost so its startup
script configures persistent journald, auditd forwarding, the service, and the
timer. Enter the webhook URL on the jumphost at a hidden prompt; never put it in
Terraform files or paste it into diagnostics.

On the jumphost, verify the timer and latest run:

```sh
sudo systemctl list-timers team-discord-log-bot.timer
sudo systemctl status --no-pager team-discord-log-bot.service
sudo journalctl -u team-discord-log-bot.service -n 50 --no-pager
sudo auditctl -l | grep team_config
```

Test both event paths separately: make a fresh SSH connection for an SSH alert,
and create then remove a temporary file under `/usr/local/bin` for audit alerts.

## Issues encountered and resolutions

| Issue | Resolution |
| --- | --- |
| Secret Manager IAM binding returned HTTP 403 because the active account lacked `secretmanager.secrets.setIamPolicy`. | Dropped Secret Manager; use a root-only webhook file on the VM. |
| The service unit was missing because the startup script referenced a repository path that exists only on the Terraform runner. | Embed the collector into startup metadata with `base64encode(file(...))`. |
| Restarting the service before startup setup returned `Unit not found`. | Apply Terraform and reboot first; writing the credential file alone does not install the unit. |
| Discord's webhook check returned HTTP 403 without an explicit User-Agent. | Add `Team4-Jumphost-Log-Forwarder/1.0`; the same webhook check then returned HTTP 200 with the expected channel. |
| The first design tailed an audit log file and ran continuously as root. | Switch to journald cursor-based batches on a timer, and run the sender as a restricted dynamic user. |
| Startup used `set -e`; an auditd package-install failure could stop unrelated setup. | Make optional auditd installation failure skip the notification setup while allowing the rest of startup to continue. |
| Commands were run in the wrong shell. | Run Terraform/Git locally; run service, auditd, credential-file, and journal commands on the jumphost. |

## Limitations and tradeoffs

- Journald retention is bounded to 100 MB and 14 days. Events older than retained
  journal data cannot be recovered by this forwarder; VM destruction also loses
  its local journal and cursor unless the disk is retained.
- At the 100-detail per-run cap, additional event details are intentionally
  omitted, although the total count is reported.
- A network failure after Discord accepts a message but before the cursor is
  saved can result in duplicate notifications on retry.
- The first run without a cursor looks back one minute. It does not backfill the
  full historical journal.
- The timer limits idle resource use, but a large backlog can still take longer
  to process than one minute. Systemd will not run concurrent instances of the
  same service.

## Validation record

Terraform formatting and validation passed. Local tests cover SSH/audit parsing,
batch-size limits, cursor reuse, and the rule that failed delivery does not
advance the cursor. The webhook endpoint returned HTTP 200 for the configured
channel, and a Discord notification was observed. The timer-based deployment
must be applied and rebooted on the jumphost before these timer-specific checks
can be confirmed on the VM.