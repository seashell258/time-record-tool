#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

WEBAPP_URL="https://script.google.com/macros/s/AKfycbwwwq5LpWrQ2Xc7NgbpbgcbnLLgk5TooQkuJUFKdB-_oDiDMxSf5PHLlFQlwE5bEVg8lg/exec"
TOKEN="0c885013e07e6ee6994e9a3a8ba7d56bb873ba48af7475b87389a66679100450"

notify() {
  # Notification 比 toast 可靠（Android 12+ 會吞背景 app 的 toast）
  # 震動同步給觸覺反饋；3 秒後自動撤下通知，避免堆積
  termux-vibrate -d 120 >/dev/null 2>&1 || true
  termux-notification --title "Timer" --content "$1" --id timer-status --priority default
  (sleep 3 && termux-notification-remove timer-status >/dev/null 2>&1) &
}

DIALOG=$(termux-dialog text -t "任務內容" -m || true)
TASK=$(printf '%s' "$DIALOG" | jq -r '.text // ""')
if [ -z "$TASK" ]; then
  notify "已取消"
  exit 0
fi

BODY=$(jq -nc --arg t "$TASK" --arg tk "$TOKEN" \
  '{action:"start", task:$t, token:$tk}')

RESP=$(curl -sSL -X POST "$WEBAPP_URL" \
  -H "Content-Type: application/json" \
  -d "$BODY")

OK=$(printf '%s' "$RESP" | jq -r '.ok // false')
if [ "$OK" = "true" ]; then
  notify "已開始：$TASK"
else
  ERR=$(printf '%s' "$RESP" | jq -r '.error // "unknown"')
  notify "失敗：$ERR"
fi
