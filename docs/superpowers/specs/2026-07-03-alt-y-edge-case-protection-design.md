# Alt+Y 邊界防護設計文件

**日期：** 2026-07-03
**狀態：** 設計定稿
**範圍：** `apps-script/Code.gs` 的 `actionStop` 路徑 + `ahk/timer-snippet.ahk` 的 Alt+Y toast

---

## 1. 背景與問題

現行 `findActiveRow`（`Code.gs:48-65`）只用「C 欄（結束時間）空 + E 欄（任務）有內容」判斷「進行中」。當使用者在沒計時的狀況下手動在 Sheet 補一列（通常只填任務、或任務+開始時間，日期時間可能空著或亂打）時：

1. Alt+Y 觸發 `actionStop` → `findActiveRow` 撿到這列手動列
2. 因為 `active.dateStr` 不是今天（可能為空或非 `yyyy-MM-dd`），流程走 else 分支，寫入 `23:59` 與 `day_boundary`
3. `composeDate('', '')` 回傳 NaN → `durationMinutes` 為 NaN → D 欄顯示 `#NUM!`

結果：與現在幾點、任務實際耗時無關，都變成 `23:59 / #NUM! / day_boundary`。

## 2. 目標

- Alt+Y 遇到「手動列」時做合理的補救，不再產生 `#NUM!` / 錯誤的 `day_boundary`
- 若使用者真的在計時（正常 active 列存在），手動列不能搶掉真正的 active
- 不動 `actionStart`（Alt+T）；同類問題未來再處理

## 3. 分類原則

按 Alt+Y 時，把所有「C 空 + E 有內容」的候選列分兩類：

| 類別 | 條件 |
|---|---|
| **legit today** | A 欄 = 今天（`yyyy-MM-dd`）**且** B 欄符合嚴格正規式 `^\d{2}:\d{2}$` |
| **recovery** | 其他任何情況（A 空/亂寫/非今天，或 B 空/亂寫/非嚴格 HH:MM） |

「嚴格 HH:MM」定義：必須兩位小時 + 冒號 + 兩位分鐘。`9:5`、`9點`、`9:00 AM` 全部一律當「沒填」。這是使用者確認的立場（"其他一律當沒填"）。

## 4. 多筆候選的選擇規則

`findActiveRow` 改為由下往上掃：

1. **先傳回最新一列 legit today**
2. 若無 legit today，才傳回最新一列 recovery 候選
3. 若兩者皆無，傳回 null（維持現有 `no_active` 行為）

這保證：真的在計時時，手動列不會搶到 Alt+Y。

## 5. 處理路徑

### 5.1 Legit today 分支
保持現有邏輯不動：

- C 欄 = 現在 (HH:MM)
- D 欄 = `now - start` 分鐘數
- J 欄 = `manual`
- 回傳 `{ok: true, task, duration_min: <分鐘>}`

### 5.2 Recovery 分支（新增）
補救邏輯：

- **A 欄**：覆蓋成今天。無論原本是空、非今天日期、或亂寫，一律以今天為準。（跨日忘關的罕見情境放棄準確性換簡潔——使用者確認）
- **C 欄**：現在 (HH:MM)
- **B 欄**：
  - 若原本符合嚴格 HH:MM → 保留
  - 若不符合 → **保留原字，不覆蓋、不清空**（避免破壞使用者輸入）
- **D 欄**：
  - 若 B 原本符合嚴格 HH:MM **且** `composeDate(today, B) <= now` → 計算 `durationMinutes(startDt, now)` 寫入
  - 否則 → 留空
- **J 欄**：一律 `manual_partial`（新值，方便日後 AI 分析辨識）
- 回傳 `{ok: true, task, duration_min: <算出的分鐘 或 null>, partial: true}`

### 5.3 無候選
回傳 `{ok: false, error: "no_active"}`，AHK 顯示「沒有進行中的任務」——維持現行。

## 6. AHK 端 toast 對應

`timer-snippet.ahk` 的 `TimerStop` 目前只讀 `duration_min` 顯示：`已停止：<task> (N 分鐘)`。新增 partial 分支：

- 一般（無 `partial` 欄或為 false）：`已停止：<task> (N 分鐘)`（不變）
- `partial: true` + `duration_min` 有值：`已補紀錄：<task> (N 分鐘)`
- `partial: true` + `duration_min` 為 null / 缺欄：`已補紀錄：<task>（未算耗時）`

JSON 解析：既有 `TimerExtractString` / `TimerExtractInt` 都是基於 regex，null 時 `TimerExtractInt` 會回 0，因此偵測 partial 應以 `partial:true` 是否存在 + `duration_min` 是否有數字為準。新增小函式 `TimerExtractBool(json, key)` 判斷 `"partial":true`。

## 7. 不動的部分

- `actionStart` (Alt+T) 完全不動——同類 bug 未來另行處理
- 排程 `dayBoundary()` 不動
- 現有「legit today」正常收尾路徑不動
- Termux 端不動（本次僅修 AHK Alt+Y）

## 8. 邊界情境檢核表

| 情境 | 期望結果 |
|---|---|
| 無任何未結束列，按 Alt+Y | `no_active` 提示（不變） |
| 有真 active（今天 + 合法 HH:MM），按 Alt+Y | 正常收尾（不變） |
| 有真 active + 手動列，按 Alt+Y | 收尾真 active，手動列不動 |
| 只有手動列（僅 E 有內容），按 Alt+Y | 覆 A=今天、C=現在、B 保留、D 空、J=`manual_partial` |
| 只有手動列（E + B 為 `09:00`），按 Alt+Y | 覆 A=今天、C=現在、B 保留、D=`now-09:00`、J=`manual_partial` |
| 只有手動列（E + B 為 `9:5`），按 Alt+Y | 覆 A=今天、C=現在、B 保留原字、D 空、J=`manual_partial` |
| 只有手動列（E + A=今天 + B 為 `09:00`）| 這其實符合 legit today，走原邏輯，J=`manual` |
| 手動列 A 填非今天日期 | 覆 A=今天，其餘照 recovery |
| 跨日忘按 Alt+Y 的合法列（罕見） | 被當 recovery 處理（日期被覆成今天）——使用者接受，罕見且可手改 |

## 9. 實作變更點

### 9.1 `apps-script/Code.gs`
- 新增 `isStrictHHMM(s)` 助手（回傳 boolean）
- `findActiveRow(sh)` 改簽名為 `findActiveRow(sh, today)`，回傳 `{ rowNum, dateStr, startStr, task, kind: 'legit' | 'recovery' }`；掃描時先收 legit 再退回 recovery
- `actionStop` 依 `active.kind` 分派：
  - `legit` → 現有 today 分支邏輯（`manual`）
  - `recovery` → 新分支（`manual_partial`，見 §5.2）
- 舊 `actionStop` 內的 else `day_boundary` 分支**移除**（原本只有跨日 legit 才會走到，改由 recovery 統一處理）

### 9.2 `ahk/timer-snippet.ahk`
- 新增 `TimerExtractBool(json, key)` 助手
- `TimerStop` 讀 `partial`，依 §6 顯示對應 toast

### 9.3 不改的檔案
- `apps-script/Code.gs` 的 `actionStart` 與 `dayBoundary`
- `termux/*.sh`
- `docs/superpowers/specs/2026-07-01-timer-design.md`（保留為原始 MVP 設計）

## 10. 明確排除

- 不處理 Alt+T (`actionStart`) 撞到手動列的同類問題
- 不做 Sheet UI 的視覺標記（例如條件格式標紅），使用者可透過 J 欄 `manual_partial` 值自行辨識
- 不加校驗前端（Sheet 表單），繼續讓使用者直接編輯 Sheet
- 不動 Termux 端 stop 腳本
