#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

WEBAPP_URL="https://script.google.com/macros/s/AKfycbwwwq5LpWrQ2Xc7NgbpbgcbnLLgk5TooQkuJUFKdB-_oDiDMxSf5PHLlFQlwE5bEVg8lg/exec"
TOKEN="0c885013e07e6ee6994e9a3a8ba7d56bb873ba48af7475b87389a66679100450"

notify() {
  # Notification 比 toast 可靠（Android 12+ 會吞背景 app 的 toast）
  termux-vibrate -d 120 >/dev/null 2>&1 || true
  termux-notification --title "Timer" --content "$1" --id timer-status --priority default
  (sleep 3 && termux-notification-remove timer-status >/dev/null 2>&1) &
}

BODY=$(jq -nc --arg tk "$TOKEN" '{action:"stop", token:$tk}')

RESP=$(curl -sSL -X POST "$WEBAPP_URL" \
  -H "Content-Type: application/json" \
  -d "$BODY")

OK=$(printf '%s' "$RESP" | jq -r '.ok // false')
if [ "$OK" = "true" ]; then
  TASK=$(printf '%s' "$RESP" | jq -r '.task // ""')
  MIN=$(printf '%s' "$RESP" | jq -r '.duration_min // 0')
  notify "已停止：$TASK ($MIN 分鐘)"
else
  ERR=$(printf '%s' "$RESP" | jq -r '.error // "unknown"')
  if [ "$ERR" = "no_active" ]; then
    notify "沒有進行中的任務"
  else
    notify "失敗：$ERR"
  fi
fi
