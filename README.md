# Timer

Personal cross-device time-tracker.

- Design: `docs/superpowers/specs/2026-07-01-timer-design.md`
- Plan: `docs/superpowers/plans/2026-07-01-timer.md`

## Deployment overview

Every committed script contains two placeholder strings that must be substituted at the deployment target:

- `YOUR_WEBAPP_URL` — the Apps Script Web App deployment URL
- `YOUR_TOKEN` — a shared secret you generate once (e.g. `openssl rand -hex 32`)

### Order

1. Google Sheet — create the sheet, name the tab `records`, add headers, set column formats.
2. Apps Script — paste `apps-script/Code.gs` into the sheet's bound Apps Script project, substitute `YOUR_TOKEN`, deploy as Web App.
3. Time trigger — add a daily trigger for `dayBoundary` at 04:00.
4. AHK — append `ahk/timer-snippet.ahk` (with substitutions) to `Seashell (2).ahk`, reload.
5. Termux — copy `termux/*.sh` (with substitutions) to `~/.shortcuts/`, add home-screen widgets.

## AI classification prompt

Save this somewhere handy (Notion, memo app, etc.). Every day: copy today's E-column tasks, then use this prompt with them:

```
以下是我今天的任務清單。請依據每一筆任務內容判斷四個欄位：

- 情境：只能是「工作 / 個人 / 家庭 / 社交」四選一
- 功能：只能是「維護 / 改善 / 產出 / 探索 / 休息」五選一
- 專案：可留空。若能明確辨識出專案名稱（例如某個 side project、報告名稱）就填
- 備註：可留空。若有值得記錄的細節就寫

輸出規則：
- 一行對應一筆任務，順序跟輸入完全一致
- 每行四個欄位，用單一 Tab 分隔（不是空格、不是逗號）
- 不要加標題列、不要編號、不要說明文字
- 有 N 行輸入就有 N 行輸出

任務清單：
{在這裡貼上從 Sheets 複製的 E 欄}
```

Paste AI's response into F2 of the day's first row — Sheets auto-splits Tab-separated text into F, G, H, I columns.

## Sheets configuration

Set these up once via the Google Sheets UI.

### Conditional formatting

Format → Conditional formatting. Add three rules (all with "Custom formula is"):

1. **Unfinished tasks (yellow):** range `A2:J`, formula `=AND($E2<>"", $C2="")`, fill: light yellow
2. **Superseded (orange):** range `J2:J`, single color, "Text is exactly" `superseded`, fill: light orange
3. **Day-boundary (red):** range `J2:J`, single color, "Text is exactly" `day_boundary`, fill: light red

### Data validation (for the AI-filled columns)

Data → Data validation:

- Column F: List of items → `工作,個人,家庭,社交` → Show warning (or Reject)
- Column G: List of items → `維護,改善,產出,探索,休息` → Show warning (or Reject)

### Sort / filter helpers

- Data → Create a filter (persistent filter view on A:J)
- For day-of analysis: filter A column = today's date
- For rolling analysis: sort by A descending so newest is at top

### Freeze

View → Freeze → 1 row (should already be done in Task 2).
