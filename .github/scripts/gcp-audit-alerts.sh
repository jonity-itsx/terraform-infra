#!/usr/bin/env bash
# Larmar i Discord när någon utanför teamet ändrar team 4:s resurser i det
# delade projektet. Alla studenter är editor i itsx25-lab, så vi kan inte
# hindra det, bara se det (F40, F41 i company-website/docs/miljogranskning.md).
#
# Läser bara Admin Activity-loggen: skrivningar och IAM-ändringar. Läsningar och
# skrivningar av objekt i tfstate-bucketen syns inte där.
#
# Fönstret räknas från förra lyckade körningens start till den här körningens
# start, båda minus LAG. Fönstren ligger då kant i kant: inga dubbletter och
# inga luckor, och en misslyckad körning tas igen av nästa.
set -euo pipefail

: "${PROJECT_ID:?}" "${TEAM:?}" "${DISCORD_WEBHOOK_URL:?}" "${GH_TOKEN:?}"
: "${GITHUB_REPOSITORY:?}" "${GITHUB_RUN_ID:?}"
LAG_SECONDS="${LAG_SECONDS:-300}"          # audit-loggen kan dröja några minuter
MAX_WINDOW_SECONDS="${MAX_WINDOW_SECONDS:-86400}"
ALLOWLIST="${ALLOWLIST:-$(dirname "$0")/gcp-audit-allowlist.txt}"
WORKFLOW_FILE="${WORKFLOW_FILE:-gcp-audit-alerts.yml}"

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# --- Fönster ---
this_start=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" --jq .run_started_at)
prev_start=$(gh api "repos/$GITHUB_REPOSITORY/actions/workflows/$WORKFLOW_FILE/runs?status=success&per_page=1" \
  --jq '.workflow_runs[0].run_started_at // empty')

end=$(( $(date -u -d "$this_start" +%s) - LAG_SECONDS ))
if [[ -n "$prev_start" ]]; then
  start=$(( $(date -u -d "$prev_start" +%s) - LAG_SECONDS ))
else
  start=$(( end - 1800 ))
fi
if (( end - start > MAX_WINDOW_SECONDS )); then
  echo "Fönstret är längre än ${MAX_WINDOW_SECONDS}s, kortar av. Äldre händelser kontrolleras inte."
  start=$(( end - MAX_WINDOW_SECONDS ))
fi
echo "Fönster: $(iso "$start") till $(iso "$end")"

# --- Hämta ---
# Bred fråga, och undantagen görs i jq nedan, där de går att testa.
filter="logName=\"projects/${PROJECT_ID}/logs/cloudaudit.googleapis.com%2Factivity\"
timestamp>=\"$(iso "$start")\" AND timestamp<\"$(iso "$end")\"
(
  protoPayload.resourceName:\"${TEAM}\"
  OR protoPayload.request.network:\"${TEAM}-vpc\"
  OR protoPayload.methodName:\"setCommonInstanceMetadata\"
  OR (resource.type=\"project\" AND protoPayload.methodName=\"SetIamPolicy\")
)"

entries=$(gcloud logging read "$filter" --project "$PROJECT_ID" --order=asc --limit=1000 --format=json)

allow_json=$({ grep -vE '^\s*(#|$)' "$ALLOWLIST" || true; } | jq -R . | jq -s .)

lines=$(jq -r --argjson allow "$allow_json" '
  .[]
  | (.protoPayload.authenticationInfo.principalEmail // "okänd") as $who
  | select($allow | index($who) | not)
  | "\(.timestamp[0:19])Z `\($who)` \(.protoPayload.methodName) `\(.protoPayload.resourceName // "-")`"
    + (if .protoPayload.requestMetadata.callerIp then " från \(.protoPayload.requestMetadata.callerIp)" else "" end)
    + (if (.protoPayload.status.code // 0) != 0 then " (nekad/fel)" else "" end)
' <<<"$entries")

count=0
[[ -n "$lines" ]] && count=$(wc -l <<<"$lines")
echo "Händelser från andra än teamet: $count"

# --- Skicka ---
# URL:en ges via stdin till curl, aldrig som argument: kommandorader kan läsas
# av andra processer och hamnar i loggar (F34).
post() {
  local content=$1 body response
  body=$(jq -n --arg c "$content" '{content: $c, allowed_mentions: {parse: []}}')
  response=$(curl -sS --fail-with-body -X POST \
    -H 'Content-Type: application/json' \
    -H 'User-Agent: team4-gcp-audit-alerts (github-actions)' \
    --data "$body" -K - <<<"url = \"${DISCORD_WEBHOOK_URL}?wait=true\"")
  # Med ?wait=true svarar Discord med meddelandet. Om kanal-ID är satt
  # kontrolleras att webhooken skriver i rätt kanal.
  if [[ -n "${DISCORD_CHANNEL_ID:-}" ]]; then
    local channel
    channel=$(jq -r '.channel_id // empty' <<<"$response")
    if [[ "$channel" != "$DISCORD_CHANNEL_ID" ]]; then
      echo "Webhooken skrev i kanal '${channel}', förväntade '${DISCORD_CHANNEL_ID}'." >&2
      return 1
    fi
  fi
}

if (( count > 0 )); then
  header=":rotating_light: **GCP: ${count} ändring(ar) av ${TEAM}-resurser av andra än teamet** ($(iso "$start") – $(iso "$end"))"
  chunk=$header
  while IFS= read -r line; do
    if (( ${#chunk} + ${#line} + 1 > 1900 )); then
      post "$chunk"
      chunk="(forts.)"
    fi
    chunk+=$'\n'"$line"
  done <<<"$lines"
  post "$chunk"
fi

# Livstecken en gång per dygn, i det fönster som innehåller 06:00 UTC. Annars
# går "inget i Discord" inte att skilja från "larmet är trasigt" (F31).
heartbeat=$(date -u -d "$(date -u -d "@$end" +%F) 06:00" +%s)
if (( start <= heartbeat && heartbeat < end )) || [[ "${FORCE_HEARTBEAT:-false}" == "true" ]]; then
  post ":white_check_mark: GCP-auditlarmet för ${TEAM} körs. Senaste fönster: $(iso "$start") – $(iso "$end"), ${count} avvikelse(r)."
fi
