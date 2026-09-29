# Jumphost Discord logging

The jumphost collector reports successful and failed SSH authentication, plus
auditd writes and attribute changes under `/etc/ssh`, `/etc/sudoers.d`,
`/etc/systemd/system`, `/usr/local/bin`, and `/usr/local/sbin`. It reports the
actor, process, and affected paths, not file contents or shell commands. The
Discord bot must be in the target server and have permission to view the
channel and send messages there.

## Provision the webhook URL

Enable Secret Manager and create the secret once:

```sh
gcloud services enable secretmanager.googleapis.com --project=itsx25-lab
gcloud secrets create team4-discord-webhook-url --replication-policy=automatic --project=itsx25-lab
```

The webhook URL previously shared in chat should be deleted and recreated in
Discord because its credential is exposed. Add the replacement URL directly to
Secret Manager without putting it in shell history or Terraform state:

```sh
read -rsp "Replacement Discord webhook URL: " WEBHOOK_URL
echo
printf '%s' "$WEBHOOK_URL" | gcloud secrets versions add team4-discord-webhook-url --data-file=- --project=itsx25-lab
unset WEBHOOK_URL
```

Grant the jumphost service account read access. This binding is intentionally
manual because the Terraform CI identity cannot set IAM policies:

```sh
gcloud secrets add-iam-policy-binding team4-discord-webhook-url --project=itsx25-lab --member='serviceAccount:team4-jumphost@itsx25-lab.iam.gserviceaccount.com' --role='roles/secretmanager.secretAccessor'
```

## Configure and activate

The provided channel ID is configured in `team/terraform.tfvars`. The collector
checks that the webhook belongs to that channel before forwarding logs. Apply
Terraform, then reboot the jumphost once so its startup script installs auditd
and enables the collector. Notifications are enabled when `discord_channel_id`
is set.

Check the service on the jumphost with:

```sh
sudo systemctl status team-discord-log-bot
sudo journalctl -u team-discord-log-bot -f
```

If Discord rejects a message, check that the recreated webhook targets the
configured channel and that the jumphost service account can access the secret.