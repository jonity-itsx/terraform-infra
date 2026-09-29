# Inloggningsinfo. Körs sist i startup-scriptet på både jumphost och primary
# och installerar ett skript som pam_motd kör vid varje SSH-inloggning.
cat > /etc/update-motd.d/50-team-info <<'MOTD'
#!/bin/bash
# Genererad av terraform-infra (team/scripts/login-motd.sh). Ändra där.
#
# Körs som root vid varje inloggning, så allt här måste gå snabbt. Antalet
# uppdateringar cachas och räknas om i bakgrunden när cachen är äldre än 6 h.

b=$'\e[1m'; d=$'\e[2m'; y=$'\e[33m'; r=$'\e[31m'; g=$'\e[32m'; n=$'\e[0m'
# ${#} räknar tecken bara i en UTF-8-locale, och pam_motd kör ofta med C.
export LC_ALL=C.UTF-8
row() { printf '  %s%*s %s\n' "$1" $((20 - ${#1})) '' "$2"; }
section() { printf '\n  %s%s%s\n' "$b" "$1" "$n"; }

printf '\n  %s%s%s %s· team 4 · %s%s\n' "$b" "$(hostname)" "$n" "$d" "$(date '+%Y-%m-%d %H:%M')" "$n"

# --- System ---------------------------------------------------------------
section "System"
read -r l1 l5 l15 _ < /proc/loadavg
row "Uppe sedan" "$(uptime -p | sed 's/^up //; s/weeks/veckor/; s/\bweek\b/vecka/; s/days/dagar/; s/\bday\b/dag/;
  s/hours/timmar/; s/\bhour\b/timme/; s/minutes/minuter/; s/\bminute\b/minut/')"
row "Last 1/5/15 min" "$l1 $l5 $l15 ($(nproc) vCPU)"
row "Minne" "$(free -m | awk -v r="$r" -v n="$n" '/^Mem:/{c=($7<$2/10)?r:""; printf "%s%d av %d MB ledigt%s", c, $7, $2, n}')"
row "Swap" "$(free -m | awk '/^Swap:/{printf "%d av %d MB använt", $3, $2}')"
row "Disk /" "$(df -P / | awk -v r="$r" -v n="$n" 'NR==2{p=$5+0; c=(p>=85)?r:""; printf "%s%.1f av %.1f GB (%d%%)%s", c, $3/1048576, $2/1048576, p, n}')"

# --- Tjänster -------------------------------------------------------------
svc=""
for s in ssh auditd tailscaled headscale k3s; do
  systemctl cat "$s" >/dev/null 2>&1 || continue
  if systemctl is-active -q "$s"; then svc+="$g$s$n  "; else svc+="$r$s$n  "; fi
done
section "Tjänster"
[ -n "$svc" ] && row "Status" "$svc"
failed=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print $1}' | xargs)
if [ -n "$failed" ]; then row "Felade enheter" "$r$failed$n"; else row "Felade enheter" "inga"; fi

# --- k3s (bara primary) ---------------------------------------------------
if command -v k3s >/dev/null; then
  section "k3s"
  node=$(timeout 3 k3s kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | xargs)
  row "Nod" "${node:-${r}svarar inte${n}}"
  pods=$(timeout 3 k3s kubectl get pods -A --no-headers 2>/dev/null)
  if [ -n "$pods" ]; then
    bad=$(awk '$4!="Running" && $4!="Completed"' <<<"$pods")
    row "Poddar" "$(wc -l <<<"$pods") st, $( [ -n "$bad" ] && echo "$r$(wc -l <<<"$bad") med problem$n" || echo "alla kör")"
    [ -n "$bad" ] && awk '{printf "    %s/%s  %s\n", $1, $2, $4}' <<<"$bad"
  fi
fi

# --- Uppdateringar --------------------------------------------------------
cache=/var/cache/team-motd/updates
mkdir -p "${cache%/*}"
if [ ! -s "$cache" ] || [ -n "$(find "$cache" -mmin +360)" ]; then
  setsid bash -c "apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null |
    awk '/^Inst/{t++; if (/-security/) s++} END{print t+0, s+0}' > '$cache.tmp' &&
    mv '$cache.tmp' '$cache'" </dev/null >/dev/null 2>&1 &
fi
section "Uppdateringar"
if [ -s "$cache" ]; then
  read -r total sec < "$cache"
  when=$(date -r "$cache" '+%H:%M')
  if [ "$total" -gt 0 ]; then
    c=$y; [ "$sec" -gt 0 ] && c=$r
    row "Väntande" "$c$total paket, varav $sec säkerhet$n ${d}(räknat $when)$n"
    row "" "${d}sudo apt update && sudo apt upgrade$n"
  else
    row "Väntande" "inga ${d}(räknat $when)$n"
  fi
else
  row "Väntande" "${d}räknas, visas vid nästa inloggning$n"
fi
[ -f /run/reboot-required ] && row "Omstart" "${r}krävs$n"

# --- Inloggningar ---------------------------------------------------------
section "Senaste inloggningar (7 dagar)"
logins=$(journalctl -q --no-pager -o short-iso --since -7d _COMM=sshd -g '^Accepted' -n 5 2>/dev/null |
  sed -E 's/^([0-9-]+)T([0-9]{2}:[0-9]{2}).*Accepted ([a-z-]+) for ([^ ]+) from ([^ ]+).*/    \1 \2  \4  från \5/')
if [ -n "$logins" ]; then echo "$logins"; else echo "    ${d}inga i journalen$n"; fi
fails=$(journalctl -q --no-pager --since -24h _COMM=sshd -g 'Failed|Invalid user' 2>/dev/null | wc -l)
c=""; [ "$fails" -gt 0 ] && c=$y
row "Misslyckade 24 h" "$c$fails$n"
echo
MOTD
chmod 755 /etc/update-motd.d/50-team-info
