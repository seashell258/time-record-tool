#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

WEBAPP_URL="YOUR_WEBAPP_URL"
TOKEN="YOUR_TOKEN"

BODY=$(jq -nc --arg tk "$TOKEN" '{action:"stop", token:$tk}')

RESP=$(curl -sSL -X POST "$WEBAPP_URL" \
  -H "Content-Type: application/json" \
  -d "$BODY")

OK=$(printf '%s' "$RESP" | jq -r '.ok // false')
if [ "$OK" = "true" ]; then
  TASK=$(printf '%s' "$RESP" | jq -r '.task // ""')
  MIN=$(printf '%s' "$RESP" | jq -r '.duration_min // 0')
  termux-toast "已停止：$TASK ($MIN 分鐘)"
else
  ERR=$(printf '%s' "$RESP" | jq -r '.error // "unknown"')
  if [ "$ERR" = "no_active" ]; then
    termux-toast "沒有進行中的任務"
  else
    termux-toast "失敗：$ERR"
  fi
fi
