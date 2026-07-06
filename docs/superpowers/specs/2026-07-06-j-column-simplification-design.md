# J 欄標記簡化

## 動機

`records` 試算表 J 欄目前塞了太多語意類似的標記：`manual` / `superseded` / `day_boundary`（外加 Alt+Y spec 規劃中的 `manual_partial`）。使用者實際使用後認為這種細分沒有價值 —— 尤其 `day_boundary` 標的 23:59「假結束時間」反而製造雜訊。使用者已在 Google Apps Script 端解除 daily trigger、且不再想維護跨日補齊邏輯。

## 目標狀態

J 欄字典簡化為兩個值：

| 值 | 意義 | 誰寫入 |
|---|---|---|
| `manual_partial` | 使用者手動補的 row（Alt+Y recovery 分支） | Alt+Y spec 實作（此份 spec 不動） |
| `stop_timer` | 軟體計時器結束的 row | `actionStop` 與 `actionStart` 的同日 close 分支 |

其他值（`manual` / `superseded` / `day_boundary`）不再產生。

## 範圍

**只改** `apps-script/Code.gs`。不動 AHK、Termux、AI prompt template、任何 spec。

## 變更明細

### 1. `actionStop`（現行第 142–164 行）

- 第 155 行 `sh.getRange(active.rowNum, 10).setValue('manual');` → 改成 `'stop_timer'`
- 刪掉 else 分支（跨日補 23:59 + 寫 `day_boundary`），讓函式無條件走同日路徑

改完後的行為：不管 active row 是哪天的，`actionStop` 都用 `now` 當結束時間、算 duration、標 `stop_timer`。跨日的狀況會產生一個「異常大的分鐘數」（例如 1500 分鐘），使用者打開試算表自然會看到並手動修。

### 2. `actionStart`（現行第 115–140 行）

- 第 128 行 `sh.getRange(active.rowNum, 10).setValue('superseded');` → 改成 `'stop_timer'`
- 刪掉 else 分支（跨日補 23:59 + 寫 `day_boundary`），讓函式無條件走同日路徑

改完後的行為：跟 `actionStop` 一致 —— 遇到 active row 一律當同日結尾。

### 3. `dayBoundary()` function（現行第 168–191 行）

整段刪除。使用者已在 GAS 端解除對應的 time-driven trigger，此函式無人呼叫。移除可縮小維護面。

## 不變更的部分

- `findActiveRow` / `readDateStr` / `readTimeStr` / 時間工具函式：不動
- 回應格式：`actionStop` 回傳仍是 `{ok, task, duration_min}`，不加新欄位（Alt+Y spec 的 `partial` 欄位由 Alt+Y 實作時再加）
- Sheet 欄位排列（A–J）：不動
- `SCRIPT_TOKEN` / `SHEET_NAME` / `TZ`：不動

## 對 Alt+Y spec 的相容性

`docs/superpowers/specs/2026-07-03-alt-y-edge-case-protection-design.md` 規劃在 Alt+Y recovery 分支寫入 `manual_partial`。這與本 spec 的兩值字典相容，Alt+Y spec 本體不需修改。

**已知合併風險**：使用者另一台電腦已實作 Alt+Y（未 push）。那份實作沿用原 spec 的 `manual` / `superseded` / `day_boundary` 字串。之後 sync 過來時 `Code.gs` 會有衝突，需要手動保留本次簡化後的字串（`stop_timer`）並刪掉那邊的 `day_boundary` 分支。

## 測試方式

在 GAS 編輯器內執行、或用實體 AHK / Termux 觸發：

| 情境 | 預期 J 值 | 預期 D 值 |
|---|---|---|
| 有 active row (今日) → 呼叫 `/stop` | `stop_timer` | 合理分鐘數 |
| 有 active row (今日) → 呼叫 `/start` 新任務 | 舊 row `stop_timer`、新 row J 空 | 舊 row 合理分鐘數 |
| 有 active row (昨日) → 呼叫 `/stop` | `stop_timer` | 大量分鐘數（例：1500+），使用者自行處理 |
| 有 active row (昨日) → 呼叫 `/start` 新任務 | 舊 row `stop_timer`、新 row J 空 | 舊 row 大量分鐘數 |
| 沒有 active row → 呼叫 `/stop` | (無影響) | 回 `no_active` |

沒有 unit test 基礎設施，這些以手動 smoke test 為主。
