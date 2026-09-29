# Jumphost Discord logging

The jumphost collector reports successful and failed SSH authentication, plus
auditd writes and attribute changes under `/etc/ssh`, `/etc/sudoers.d`,
`/etc/systemd/system`, `/usr/local/bin`, and `/usr/local/sbin`. It reports the
actor, process, and affected paths, not file contents or shell commands. The
Discord incoming webhook must target the configured channel.

## Configure and activate

The provided channel ID is configured in `team/terraform.tfvars`. The collector
reads the webhook URL from `/etc/team-discord-webhook.env` and checks that it
belongs to that channel before forwarding logs. The URL is not stored in
Terraform or Secret Manager, so no GCP IAM grant is needed. It is stored on the
VM in a root-only file and must be provisioned again if the VM is replaced.

Any webhook URL previously shared publicly should be deleted and recreated.
Apply Terraform, then reboot the jumphost once so its startup script installs
auditd and enables the collector. On the jumphost, enter the replacement URL at
the hidden prompt:

```sh
sudo bash -c 'read -rsp "Replacement Discord webhook URL: " url; echo; umask 077; printf "DISCORD_WEBHOOK_URL=%s\n" "$url" > /etc/team-discord-webhook.env; unset url; systemctl restart team-discord-log-bot'
```

Notifications are enabled when `discord_channel_id` is set.

Check the service on the jumphost with:

```sh
sudo systemctl status team-discord-log-bot
sudo journalctl -u team-discord-log-bot -f
```

If Discord rejects a message, check that the recreated webhook targets the
configured channel and that `/etc/team-discord-webhook.env` exists on the VM.