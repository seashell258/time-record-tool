#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

WEBAPP_URL="YOUR_WEBAPP_URL"
TOKEN="YOUR_TOKEN"

DIALOG=$(termux-dialog text -t "任務內容" -m || true)
TASK=$(printf '%s' "$DIALOG" | jq -r '.text // ""')
CODE=$(printf '%s' "$DIALOG" | jq -r '.code // 0')
if [ "$CODE" != "0" ] || [ -z "$TASK" ]; then
  exit 0
fi

BODY=$(jq -nc --arg t "$TASK" --arg tk "$TOKEN" \
  '{action:"start", task:$t, token:$tk}')

RESP=$(curl -sSL -X POST "$WEBAPP_URL" \
  -H "Content-Type: application/json" \
  -d "$BODY")

OK=$(printf '%s' "$RESP" | jq -r '.ok // false')
if [ "$OK" = "true" ]; then
  termux-toast "已開始：$TASK"
else
  ERR=$(printf '%s' "$RESP" | jq -r '.error // "unknown"')
  termux-toast "失敗：$ERR"
fi
