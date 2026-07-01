#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

WEBAPP_URL="https://script.google.com/macros/s/AKfycbwwwq5LpWrQ2Xc7NgbpbgcbnLLgk5TooQkuJUFKdB-_oDiDMxSf5PHLlFQlwE5bEVg8lg/exec"
TOKEN="0c885013e07e6ee6994e9a3a8ba7d56bb873ba48af7475b87389a66679100450"

DIALOG=$(termux-dialog text -t "任務內容" -m || true)
TASK=$(printf '%s' "$DIALOG" | jq -r '.text // ""')
# Termux:API 多行對話框用 back 鍵送出，會回 code=-1 但文字有保留。
# 只在文字完全是空時才當取消。
if [ -z "$TASK" ]; then
  termux-toast "已取消"
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
