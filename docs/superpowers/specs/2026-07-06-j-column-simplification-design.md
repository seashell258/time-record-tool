# J 欄標記簡化

## 動機

`records` 試算表 J 欄目前有四個值：`manual` / `superseded` / `day_boundary` / `manual_partial`。使用者實際使用後認為 `manual` 與 `superseded` 的區分沒有實用價值（兩者都是軟體寫的、時間都可信）、而 `day_boundary` 那組跨日補 23:59 的邏輯反而製造雜訊（假結束時間看起來像真的）。使用者已在 Google Apps Script 端解除對應的 daily trigger、且不再想維護跨日補齊邏輯。

## 目標狀態

J 欄字典簡化為兩個值：

| 值 | 意義 | 誰寫入 |
|---|---|---|
| `stop_timer` | 軟體計時器結束的一般 row（時間可信） | `actionStop` 的 legit 分支、`actionStart` 遇到既有 active row |
| `manual_partial` | 使用者手打的 row 被 Alt+Y 撿起來收尾（起訖時間至少一個不可信） | `actionStop` 的 recovery 分支（現況已如此）|

其他值（`manual` / `superseded` / `day_boundary`）不再產生。

## 範圍

**只改** `apps-script/Code.gs`。不動 AHK、Termux、AI prompt template、既有 spec。

## 目前程式狀態確認

- `actionStop`（第 169–206 行）已有 `legit` / `recovery` 分支：legit 寫 `'manual'`、recovery 寫 `'manual_partial'`
- `actionStart`（第 142–167 行）尚未套用 Alt+Y 的 `kind` 分派邏輯，仍是舊的同日 → `superseded`、跨日 → `day_boundary` 二分
- `dayBoundary()` function（第 210–233 行）仍存在，但 GAS 端的 daily trigger 已解除，實務上不會被叫
- `ahk/timer-snippet.ahk` 已支援 `partial: true` 回應（`TimerStop` 內 `partial` 分支已寫），本次改動不影響回應結構，AHK 完全不用動

## 變更明細（`apps-script/Code.gs`）

### 1. `actionStop` — 只改字串

第 182 行：
```
sh.getRange(active.rowNum, 10).setValue('manual');
```
改為：
```
sh.getRange(active.rowNum, 10).setValue('stop_timer');
```

recovery 分支（第 199 行的 `'manual_partial'`）**不動**。

### 2. `actionStart` — 拿掉跨日分支、改字串

現行結構：
```js
if (active) {
  if (active.dateStr === today) {
    // 同日 close，寫 superseded
  } else {
    // 跨日 close 到 23:59，寫 day_boundary
  }
}
```

改為無條件走同日邏輯：
```js
if (active) {
  const startDt = composeDate(active.dateStr, active.startStr);
  const dur = durationMinutes(startDt, nowDt);
  sh.getRange(active.rowNum, 3, 1, 2).setValues([[asText(nowTime), dur]]);
  sh.getRange(active.rowNum, 10).setValue('stop_timer');
}
```

行為變化：
- 跨日仍有 active row 時，`actionStart` 會直接以「昨天 startStr → 現在」算 duration，寫進 D 欄。使用者會看到誇張大的分鐘數（幾百到上千），自然發現異常再手動修。
- 若 active row 的 `dateStr` / `startStr` 是壞資料（例如空字串、非嚴格 HH:MM），`composeDate` 會回 `Invalid Date`、`durationMinutes` 會回 `NaN`，D 欄會存 `NaN`。這是可接受的失敗模式 —— 使用者一樣會看到就處理。
- `pickActiveRow` 現行邏輯會優先挑 `legit`（今日 + 嚴格 HH:MM）的 row，所以壞資料能被挑到當 active 的機率很低（除非畫面上完全沒有 legit）。

### 3. 刪掉 `dayBoundary()` function

第 208–233 行整段刪除。GAS 端 trigger 已解除、此函式無人呼叫。

### 4. 刪掉 `endOfDay()` helper

第 136–138 行整段刪除。此函式原本只有 `dayBoundary()` 與 `actionStart` 的跨日分支使用；#2、#3 之後變成 dead code。

### 5. 其他不動

- `findActiveRow` / `pickActiveRow` / `classifyRow` / `isStrictHHMM` / `readDateStr` / `readTimeStr` / `composeDate` / `tzOffsetMinutes` / `durationMinutes` / `now` / `fmtDate` / `fmtTime` / `asText`：不動
- 所有 `_test*` 函式（第 237–332 行）：不動（它們測的都是仍存在的 helper）
- `_dumpLastRows`：不動
- Web App 回應格式（`{ ok, task, duration_min }` + 可能的 `partial`）：不動
- `SCRIPT_TOKEN` / `SHEET_NAME` / `TZ`：不動

## 對既有 spec 的影響

- `docs/superpowers/specs/2026-07-01-timer-design.md`：若當初有寫「跨日補 23:59 + `day_boundary`」的行為描述，這裡的變更會讓那段過時，但不強制回頭改。
- `docs/superpowers/specs/2026-07-03-alt-y-edge-case-protection-design.md`：`manual_partial` 分支完全保留，該 spec 描述的核心行為不變。可選擇性地在該 spec 補一行說 J 欄的可能值已縮到兩個。

## 手動測試

沒有 CI；以 GAS 編輯器內執行或實體 AHK / Termux 觸發為主。

| 情境 | 預期 J 值 | 預期 D 值 |
|---|---|---|
| 有 legit active row (今日) → `/stop` | `stop_timer` | 合理分鐘數 |
| 有 recovery active row → `/stop` | `manual_partial`（不變）| 依原邏輯 |
| 有 legit active row (今日) → `/start` 新任務 | 舊 row `stop_timer`、新 row J 空 | 舊 row 合理分鐘數 |
| 有 legit active row (**昨日**) → `/stop` | `stop_timer` | 大量分鐘數（例：1500+）|
| 有 legit active row (**昨日**) → `/start` 新任務 | 舊 row `stop_timer`、新 row J 空 | 舊 row 大量分鐘數 |
| 無 active row → `/stop` | (無影響) | 回 `no_active` |

Alt+Y 相關現有測試（`_testIsStrictHHMM` / `_testClassifyRow` / `_testPickActiveRow`）不受影響，可繼續當回歸測試跑。

## 非目標（Out of scope）

- 不重構 `actionStart` 去比照 `actionStop` 的 `kind` 分派 —— 那是更大的一致性重構，另案處理
- 不清理歷史列（試算表裡舊有的 `manual` / `superseded` / `day_boundary` 值不 migrate）
- 不動 AHK 的 toast 文案
