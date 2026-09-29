# Jumphost Discord logging

The jumphost collector reports successful and failed SSH authentication, plus
auditd writes and attribute changes under `/etc/ssh`, `/etc/sudoers.d`,
`/etc/systemd/system`, `/usr/local/bin`, and `/usr/local/sbin`. It reports the
actor, process, and affected paths, not file contents or shell commands. The
Discord bot must be in the target server and have permission to view the
channel and send messages there.

## Provision the bot token

Enable Secret Manager and create the secret once:

```sh
gcloud services enable secretmanager.googleapis.com --project=itsx25-lab
gcloud secrets create team4-log-bot-token --replication-policy=automatic --project=itsx25-lab
```

Add the bot token without putting it in shell history or Terraform state:

```sh
read -rsp "Discord bot token: " BOT_TOKEN
echo
printf '%s' "$BOT_TOKEN" | gcloud secrets versions add team4-log-bot-token --data-file=- --project=itsx25-lab
unset BOT_TOKEN
```

Grant the jumphost service account read access. This binding is intentionally
manual because the Terraform CI identity cannot set IAM policies:

```sh
gcloud secrets add-iam-policy-binding team4-log-bot-token --project=itsx25-lab --member='serviceAccount:team4-jumphost@itsx25-lab.iam.gserviceaccount.com' --role='roles/secretmanager.secretAccessor'
```

## Configure and activate

Copy the target Discord channel's ID (not its name) into `team/terraform.tfvars`:

```hcl
discord_channel_id = "YOUR_CHANNEL_ID"
```

Apply Terraform, then reboot the jumphost once so its startup script installs
auditd and enables the collector. The startup script only enables notifications
when `discord_channel_id` is set.

Check the service on the jumphost with:

```sh
sudo systemctl status team-discord-log-bot
sudo journalctl -u team-discord-log-bot -f
```

If Discord returns an authorization error, check that the bot is in the server,
can send messages in the selected channel, and that the token in Secret Manager
is the bot token (not a webhook URL).