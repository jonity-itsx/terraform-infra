# Inloggningsinfo. Körs sist i startup-scriptet på både jumphost och primary
# och installerar ett skript som pam_motd kör vid varje SSH-inloggning.

# Debians egna rader ersätts av vår rubrik: 10-uname visar kärnan, som nu står
# i rubriken, och /etc/motd innehåller bara licenstexten.
chmod -x /etc/update-motd.d/10-uname 2>/dev/null || true
: > /etc/motd

cat > /etc/update-motd.d/50-team-info <<'MOTD'
#!/bin/bash
# Genererad av terraform-infra (team/scripts/login-motd.sh). Ändra där.
#
# Körs som root vid varje inloggning, så allt här måste gå snabbt. Antalet
# uppdateringar cachas och räknas om i bakgrunden när cachen är äldre än 6 h.

# ${#} räknar tecken bara i en UTF-8-locale, och pam_motd kör ofta med C.
export LC_ALL=C.UTF-8
# Maskinerna har olika tidszon. Loggarna får vara kvar i sin, men här visas svensk tid.
export TZ=Europe/Stockholm

b=$'\e[1m'; d=$'\e[2m'; y=$'\e[33m'; r=$'\e[31m'; g=$'\e[32m'; c=$'\e[36m'; n=$'\e[0m'
row() { printf '  %s%*s %s\n' "$1" $((18 - ${#1})) '' "$2"; }
section() { printf '\n  %s%s%s\n' "$c$b" "$1" "$n"; }
rep() { local i s=""; for ((i = 0; i < $2; i++)); do s+=$1; done; printf '%s' "$s"; }
# Stapel för en procentsats: grön, gul från 70 %, röd från 85 %.
bar() {
  local p=$1 f=$(($1 * 20 / 100)) col=$g
  [ "$p" -ge 70 ] && col=$y
  [ "$p" -ge 85 ] && col=$r
  printf '%s%s%s%s%s %3d %%' "$col" "$(rep █ "$f")" "$d" "$(rep ░ $((20 - f)))" "$n" "$p"
}

# --- Rubrik ---------------------------------------------------------------
printf '%s' "$c$b"
cat <<'LOGO'

         _             __________
        (_)___  ____  /  _/_  __/_  __
       / / __ \/ __ \ / /  / / / / / /
      / / /_/ / / / // /  / / / /_/ /
   __/ /\____/_/ /_/___/ /_/  \__, /
  /___/                      /____/
LOGO
printf '%s' "$n"
. /etc/os-release
printf '\n  %s%s%s %s· %s · kärna %s · %s%s\n' "$b" "$(hostname)" "$n" "$d" \
  "${PRETTY_NAME/GNU\/Linux /}" "$(uname -r | cut -d+ -f1)" "$(date '+%Y-%m-%d %H:%M')" "$n"

# --- System ---------------------------------------------------------------
section "System"
read -r l1 l5 l15 _ < /proc/loadavg
row "Uppe sedan" "$(uptime -p | sed 's/^up //; s/weeks/veckor/; s/\bweek\b/vecka/; s/days/dagar/; s/\bday\b/dag/;
  s/hours/timmar/; s/\bhour\b/timme/; s/minutes/minuter/; s/\bminute\b/minut/')"
row "Last 1/5/15 min" "$l1  $l5  $l15  ${d}($(nproc) vCPU)$n"
read -r mt ma st su < <(free -m | awk '/^Mem:/{t=$2; a=$7} /^Swap:/{print t, a, $2, $3}')
row "Minne" "$(bar $(((mt - ma) * 100 / mt)))  $ma av $mt MB ledigt"
read -r dt du dp < <(df -P / | awk 'NR==2{printf "%.1f %.1f %d", $2/1048576, $3/1048576, $5}')
row "Disk /" "$(bar "$dp")  $du av $dt GB"
row "Swap" "$su av $st MB använt"

# --- Tjänster -------------------------------------------------------------
section "Tjänster"
svc=""
for s in ssh auditd tailscaled headscale k3s; do
  systemctl cat "$s" >/dev/null 2>&1 || continue
  if systemctl is-active -q "$s"; then svc+="$g●$n $s   "; else svc+="$r●$n $s   "; fi
done
[ -n "$svc" ] && row "Status" "$svc"
failed=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print $1}' | xargs)
if [ -n "$failed" ]; then row "Felade enheter" "$r$failed$n"; else row "Felade enheter" "inga"; fi

# --- k3s (bara primary) ---------------------------------------------------
if command -v k3s >/dev/null; then
  section "k3s"
  # Första anropet efter en stunds vila tar tid när k3s-binären ska läsas in
  # från disk igen. 6 s räcker med marginal; en timeout visas som en timeout.
  node=$(timeout 6 k3s kubectl get nodes --no-headers 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 124 ]; then
    row "Nod" "${y}svarade inte inom 6 s$n"
  elif [ -z "$node" ]; then
    row "Nod" "${r}svarar inte$n"
  else
    read -r _ status _ _ version <<<"$node"
    col=$g; [ "$status" = Ready ] || col=$r
    row "Nod" "$col$status$n  ${d}$version$n"
  fi
  pods=$(timeout 4 k3s kubectl get pods -A --no-headers 2>/dev/null)
  if [ -n "$pods" ]; then
    bad=$(awk '$4!="Running" && $4!="Completed"' <<<"$pods")
    if [ -n "$bad" ]; then
      row "Poddar" "$(wc -l <<<"$pods") st, $r$(wc -l <<<"$bad") med problem$n"
      awk '{printf "    %s/%s  %s\n", $1, $2, $4}' <<<"$bad"
    else
      row "Poddar" "$(wc -l <<<"$pods") st, alla kör"
    fi
  fi
fi

# --- Uppdateringar --------------------------------------------------------
section "Uppdateringar"
cache=/var/cache/team-motd/updates
mkdir -p "${cache%/*}"
if [ ! -s "$cache" ] || [ -n "$(find "$cache" -mmin +360)" ]; then
  setsid bash -c "apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null |
    awk '/^Inst/{t++; if (/-security/) s++} END{print t+0, s+0}' > '$cache.tmp' &&
    mv '$cache.tmp' '$cache'" </dev/null >/dev/null 2>&1 &
fi
if [ -s "$cache" ]; then
  read -r total sec < "$cache"
  when=$(date -r "$cache" '+%H:%M')
  if [ "$total" -gt 0 ]; then
    col=$y; [ "$sec" -gt 0 ] && col=$r
    row "Väntande" "$col$total paket, varav $sec säkerhet$n  ${d}räknat $when$n"
    row "" "${d}sudo apt update && sudo apt upgrade$n"
  else
    row "Väntande" "inga  ${d}räknat $when$n"
  fi
else
  row "Väntande" "${d}räknas, visas vid nästa inloggning$n"
fi
eval "$(apt-config shell uu APT::Periodic::Unattended-Upgrade)"
if [ "${uu:-0}" != 0 ]; then row "Automatiska" "på  ${d}säkerhetsuppdateringar installeras varje dag$n"
else row "Automatiska" "${y}av$n"; fi
[ -f /run/reboot-required ] && row "Omstart" "${r}krävs$n"

# --- Inloggningar ---------------------------------------------------------
# Debian 13 loggar inloggningar från sshd-session, äldre versioner från sshd.
section "Senaste inloggningar"
logins=$(journalctl -q --no-pager -o short-iso --since -7d _COMM=sshd _COMM=sshd-session -g '^Accepted' -n 5 2>/dev/null |
  sed -E 's/^([0-9-]+)T([0-9]{2}:[0-9]{2}).*Accepted ([a-z-]+) for ([^ ]+) from ([^ ]+).*/  \1 \2  \4  från \5/')
if [ -n "$logins" ]; then echo "$logins"; else echo "  ${d}inga de senaste 7 dagarna$n"; fi
fails=$(journalctl -q --no-pager --since -24h _COMM=sshd _COMM=sshd-session -g 'Failed|Invalid user' 2>/dev/null | wc -l)
col=""; [ "$fails" -gt 0 ] && col=$y
row "Misslyckade 24 h" "$col$fails$n"
echo
MOTD
chmod 755 /etc/update-motd.d/50-team-info
