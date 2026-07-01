# 個人時間記錄工具設計文件

**日期：** 2026-07-01
**狀態：** 設計定稿
**使用者：** 單一使用者（自用）

---

## 1. 目標與範圍

打造一個跨裝置（Windows + Android）的個人時間記錄工具，能夠**快速**新增一筆「開始做某事」的紀錄，並在完成時停止計時。所有紀錄同步到同一份 Google 試算表——**試算表本身就是資料庫、閱覽介面和最終歸檔位置**。

**這個工具負責自動收集的欄位：**

| 欄位 | 來源 |
|------|------|
| A 日期 | 自動 |
| B 開始時間 | 自動（按開始鍵時） |
| C 結束時間 | 自動（按停止鍵時 / 由下一筆任務推斷 / 由排程截止） |
| D 耗時（分鐘） | 自動計算 |
| E 任務內容 | 使用者輸入 |
| J 結束方式 | 自動（`manual` / `superseded` / `day_boundary`） |

**由 AI 事後（人肉貼上）填入的欄位：**

| 欄位 | 值範圍 |
|------|--------|
| F 情境 | 工作 / 個人 / 家庭 / 社交（固定四選一） |
| G 功能 | 維護 / 改善 / 產出 / 探索 / 休息（固定五選一） |
| H 專案 | 自由文字 |
| I 備註 | 自由文字 |

**設計原則：** 工具只收集不做語意判斷。分類與解讀交給使用者 + web 版 AI（複製貼上），不做 API 串接。

---

## 2. 架構總覽

```
┌─────────────────┐        ┌─────────────────┐
│  Windows (AHK)  │        │ Android(Termux) │
│                 │        │                 │
│  Alt+T → 彈窗    │        │  桌面圖示 or    │
│  Alt+Y → 停止    │        │   Edge Panel    │
│                 │        │    → 對話框     │
└────────┬────────┘        └────────┬────────┘
         │  HTTPS POST + token      │
         └───────────┬──────────────┘
                     ↓
         ┌─────────────────────────────┐
         │  Google Apps Script Web App │
         │  (doPost + 時間觸發器)      │
         └────────────┬────────────────┘
                      ↓
         ┌─────────────────────────────┐
         │  Google Sheet 「records」    │
         │  (資料庫 + 閱覽 + 歸檔)      │
         └─────────────────────────────┘
                      ↑
         ┌────────────────────────┐
         │  你透過瀏覽器 / Sheets  │
         │  App 直接看和分析       │
         └────────────────────────┘
```

**要點：**

- **一份 Google 試算表** 同時扮演三個角色：資料庫、每日檢視、AI 分析素材
- 兩個客戶端（AHK、Termux）都 **HTTPS POST 到同一個 Apps Script Web App URL**，帶 token
- Apps Script 是「後端」——處理開始 / 停止的商業邏輯，並執行每日排程收尾
- **不需要 Supabase、不需要 Vercel、不需要 SQL、不需要靜態網頁**

---

## 3. 資料層

### 3.1 Google Sheet 結構

一個檔案、一個工作表，名稱：`records`。

| 欄 | 名稱 | 型別 | 誰寫入 |
|----|------|------|--------|
| A | 日期 | 日期（`yyyy-MM-dd`） | 工具（開始時） |
| B | 開始時間 | 時間（`HH:mm`） | 工具（開始時） |
| C | 結束時間 | 時間（`HH:mm`） | 工具（停止 / 推斷 / 排程時） |
| D | 耗時 | 整數（分鐘） | 工具（結束時計算） |
| E | 任務 | 純文字 | 使用者透過 AHK / Termux 輸入 |
| F | 情境 | 純文字 | 你 + AI（事後貼上） |
| G | 功能 | 純文字 | 你 + AI（事後貼上） |
| H | 專案 | 純文字 | 你 + AI（事後貼上） |
| I | 備註 | 純文字 | 你 + AI（事後貼上） |
| J | 結束方式 | 純文字（見下） | 工具 |

**J 欄「結束方式」的四種值：**

| 值 | 觸發條件 | 分析意義 |
|----|---------|---------|
| （空） | 任務進行中，C 欄尚未寫入 | 該筆還沒結束 |
| `manual` | 使用者按 Alt+Y / Termux 停止鍵 | 正常結束 |
| `superseded` | 上一筆未結束、新一筆開始 → 上一筆自動關掉 | 「做到忘我沒切換」的訊號 |
| `day_boundary` | 排程在凌晨 4:00 掃到跨日仍未結束的紀錄 | 「整個忘記按停止」的訊號，手機端會偏多 |

**時間格式：**
- A、B、C 都以**使用者所在時區**（假設 `Asia/Taipei`）顯示
- 儲存也是本地時間字串（例如 `2026-07-01`、`09:12`），不用 ISO / UTC — 因為 Sheets 顯示、AI 讀取、人眼掃描都是本地時間

### 3.2 Apps Script Web App

單一 `.gs` 檔案，部署為 Web App。所有客戶端 POST JSON 到同一個 URL：

```
POST https://script.google.com/macros/s/{DEPLOYMENT_ID}/exec
Content-Type: application/json
```

**四個 action：**

#### 3.2.1 `start`

```json
{ "action": "start", "task": "讀論文 第3章", "token": "YOUR_TOKEN" }
```

流程：
1. 找 `records` 工作表最後一筆 C 欄為空的 row（若有）：
   - 若該筆 A 欄日期 = 今天 → J = `superseded`、C = 現在時間 (`HH:mm`)、D = 從「該筆 A+B 組成的 datetime」到現在的分鐘數（用真正的 datetime 相減，不是 `HH:mm` 字串直接減）
   - 若該筆 A 欄日期 < 今天（代表 `dayBoundary` trigger 那次漏掉或還沒跑到）→ J = `day_boundary`、C = `23:59`、D = 從該筆 A+B 到該日 23:59 的分鐘數
2. Append 新的 row：
   - A = 今日日期
   - B = 現在時間 (`HH:mm`)
   - E = `task`
   - 其他欄留空

回應 `{ ok: true }` 或 `{ ok: false, error: "..." }`。

#### 3.2.2 `stop`

```json
{ "action": "stop", "token": "YOUR_TOKEN" }
```

流程：
1. 找最後一筆 C 欄為空的 row。若無 → 回 `{ ok: false, error: "no_active" }`。
2. 若該筆 A 欄日期 < 今天（跨日停止的罕見情況）→ 走 `dayBoundary` 邏輯：C = `23:59`、D = 從 A+B 到該日 23:59、J = `day_boundary`（此時 `manual` 已無意義，因為你沒真的在該日結束時按停止）。
3. 否則（同日）→ C = 現在時間 (`HH:mm`)、D = 從 A+B 到現在的分鐘數、J = `manual`。
4. 回應 `{ ok: true, task: "...", duration_min: 23 }`。

#### 3.2.3 `dayBoundary`（由時間觸發器呼叫，不接受外部呼叫）

不掛在 `doPost`，是獨立的 Apps Script 函式，由 Apps Script Triggers 每天凌晨 4:00 自動觸發。

流程：
1. 掃描所有 rows：
   - **條件：C 欄為空 AND A 欄日期 < 今天**
2. 對每一筆命中的 row：
   - C = `23:59`（同一筆 A 欄日期的當天）
   - D = C - B（分鐘）
   - J = `day_boundary`
3. 完成後結束，沒有 HTTP 回應。

**邊界處理：** 若一筆從 21:00 開始、跨越午夜到隔天仍未結束，凌晨 4:00 排程會把它截在該筆 A 日期的 23:59。這是刻意接受的取捨——真的想紀錄跨日整段，事後手動改試算表那格。

#### 3.2.4 認證：token 檢查

`doPost` 進入點的第一件事：
```js
if (body.token !== SCRIPT_TOKEN) {
  return jsonResponse({ ok: false, error: "unauthorized" }, 401);
}
```

`SCRIPT_TOKEN` 是 Apps Script 檔案頂端的常數（一段隨機字串）。

**為什麼用 token 而不是 Google OAuth：**
- Apps Script Web App 部署時可以選「Execute as: me」+ 「Who has access: Anyone」
- 這樣任何知道 URL 的人都可以 POST，但腳本自己會拒絕沒帶正確 token 的請求
- 對單一使用者、非機敏資料的個人工具來說，這比 OAuth 簡單一百倍

---

## 4. Windows 客戶端（AHK）

### 4.1 整合位置

整合進既有的 `C:\Users\user\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\Seashell (2).ahk`。此腳本已存在、AHK v2 語法、開機自動載入。

**Alt+T 與 Alt+Y 目前皆未被佔用**，可安全新增。

### 4.2 快捷鍵行為

**Alt+T — 開始計時**

1. 彈出小型 AHK GUI，單一多行輸入框（Edit control with word-wrap）：
   - **Enter** 送出
   - **Shift+Enter** 換行
   - **Esc** 取消
2. 送出 → POST 到 Apps Script Web App，body `{"action":"start","task":"...","token":"..."}`
3. 送出成功後於右下角顯示一個永遠置頂的懸浮視窗：
   ```
   ● {任務內容前 20 字}
   00:00:34
   ```
   秒數即時更新（每秒重繪）
4. 送出失敗：`MsgBox` 顯示錯誤，不做 retry、不做本地快取

**Alt+Y — 停止計時**

1. POST 到 Apps Script Web App，body `{"action":"stop","token":"..."}`
2. 關閉懸浮視窗
3. 右下角跳一個一秒後自動消失的 tooltip：`已停止：{任務} ({N} 分鐘)`（由 Apps Script 回應中的 `task` 和 `duration_min` 產生）
4. 若 Apps Script 回 `error: "no_active"`，跳提示「沒有進行中的任務」

**無音效**——所有反饋都靠視覺元件。

### 4.3 實作細節

- HTTP 請求用 `ComObject("WinHttp.WinHttpRequest.5.1")`（AHK v2 內建）
- Web App URL 從 GET 到 POST 會有 302 重定向，需要 `req.Option(6) := true`（AutoRedirect）
- 常數區塊放在腳本頂端：
  ```ahk
  TIMER_WEBAPP_URL := "https://script.google.com/macros/s/DEPLOYMENT_ID/exec"
  TIMER_TOKEN      := "YOUR_TOKEN"
  ```
- HTTP header：`Content-Type: application/json`
- 懸浮視窗：`Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000")`，右下角固定位置
- 秒數更新用 `SetTimer` 每 1000ms 觸發
- 由於 Apps Script Web App 冷啟動可能要 1–2 秒，第一次按 Alt+T 可能有明顯延遲；後續請求 300–800ms

### 4.4 保留現有功能

`Seashell (2).ahk` 內既有的所有熱鍵（`!q`、`!w`、`!e`、`!b`、`!r`、`!a`、`!1`–`!4`、`^!a`）與函式（`SendText`、`SendBrackets`、`FuncProcessClipboard`）**完全保留、不得修改**。新程式碼追加在檔案尾端，並用註解區塊隔開。

---

## 5. Android 客戶端（Termux）

### 5.1 安裝需求

- Termux（F-Droid 版本，非 Play Store 版）
- Termux:Widget（用於建立桌面圖示）
- Termux:API（用於 `termux-dialog`、`termux-toast`）
- Termux 內執行 `pkg install termux-api jq curl`

### 5.2 腳本

**`~/.shortcuts/timer-start.sh`**
```bash
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

WEBAPP_URL="https://script.google.com/macros/s/DEPLOYMENT_ID/exec"
TOKEN="YOUR_TOKEN"

DIALOG=$(termux-dialog text -t "任務內容" -m || true)
TASK=$(printf '%s' "$DIALOG" | jq -r '.text // ""')
CODE=$(printf '%s' "$DIALOG" | jq -r '.code // 0')
if [ "$CODE" != "0" ] || [ -z "$TASK" ]; then exit 0; fi

BODY=$(jq -nc --arg t "$TASK" --arg tk "$TOKEN" '{action:"start", task:$t, token:$tk}')

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
```

**`~/.shortcuts/timer-stop.sh`**
```bash
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

WEBAPP_URL="https://script.google.com/macros/s/DEPLOYMENT_ID/exec"
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
```

**注意：**`curl -sSL` 中的 `-L` 是 follow redirects，Apps Script Web App 需要。

### 5.3 桌面 / Edge Panel

- Termux:Widget 會自動掃描 `~/.shortcuts/` 產生 launcher 捷徑
- Samsung Edge Panel 能否收納不保證，需實測

**無音效**——僅用 `termux-toast` 顯示反饋。

---

## 6. 閱覽與分析

**不建 Vercel、不建網頁**——直接用 Google Sheets 網頁版或手機 App。

### 6.1 日常檢視

- **電腦：** 瀏覽器打開 Sheets 連結
- **手機：** Google Sheets Android App

### 6.2 每日歸檔流程

1. **收工時按 Alt+Y**（若忘記，凌晨 4:00 排程會補救，但當晚就想歸檔的話要主動按）
2. 打開試算表 → 用 A 欄的日期篩選今天（Data → Create a filter）
3. 選取當天所有 rows 的 E 欄（任務內容）→ Ctrl+C
4. 打開 AI 對話網頁 → 貼上事先存好的 **prompt 樣板**（見 § 10）+ 剛剛的任務清單
5. AI 回覆 tab 分隔的 4 欄純文字（每行對應一筆任務）
6. 選取 AI 回覆的整塊文字 → Ctrl+C
7. 回試算表 → 點今天第一筆的 F 欄 → Ctrl+V
   - Sheets 會自動把 tab 分隔的文字拆進 F、G、H、I 欄
8. 視覺對一下第一筆和最後一筆的分類是否合理；不合理直接改，錯很多整批 Ctrl+Z 重來

### 6.3 定期 AI 分析

- 打開試算表 → 篩選近 N 天
- 選取 A2:J{N}（連 J 欄一起）→ Ctrl+C
- 貼給 AI：「以下是我這 N 天的紀錄，幫我算情境和功能的時間占比，並看 superseded / day_boundary 有沒有集中在哪些活動」
- AI 用文字回答

**J 欄對分析的價值：**
- 大量 `superseded` → 你單一情境沉浸時常忘記切換
- 大量 `day_boundary` → 手機端輸入的任務常忘停，或那時段其實已停止工作

---

## 7. 認證與安全

**威脅模型：** 個人工具，資料非敏感（任務名稱），但要防止有人不小心撞到 Web App URL 就亂寫入。

**核心機制：** 一個 shared token，寫在 Apps Script 檔案頂端當常數；所有客戶端 POST 時把 token 放進 JSON body。

| 端 | token 儲存方式 |
|----|----------------|
| AHK | 腳本頂端常數（本機檔案） |
| Termux | 腳本頂端常數（本機檔案） |
| Apps Script | 檔案頂端常數（Google 帳號登入才看得到） |

Web App 部署選項：`Execute as: me` + `Who has access: Anyone`——這代表 URL 是公開的，但 script 自己拒絕沒帶 token 的請求。

**不做的事情**（MVP 範圍外）：
- 沒有 token rotate 機制
- 沒有多使用者
- 沒有 rate limit（Apps Script 平台本身有防濫用配額）
- 沒有 audit log

---

## 8. 錯誤處理

原則：**單機小工具，簡單就好；失敗就明確告知，不做任何自動 retry 或本地快取。**

| 情境 | 行為 |
|------|------|
| AHK / Termux 網路失敗 | AHK 跳 `MsgBox`；Termux 用 `termux-toast` 顯示錯誤碼 |
| AHK / Termux 送出時已有進行中紀錄 | 由 Apps Script 端處理 `superseded`，客戶端無感 |
| AHK 停止時沒有進行中紀錄 | 跳提示「沒有進行中的任務」（server 回 `no_active`） |
| Termux 停止時沒有進行中紀錄 | `termux-toast "沒有進行中的任務"` |
| Apps Script 內部錯誤（例如試算表暫時無法寫入） | 回 `{ ok: false, error: "..." }`，客戶端顯示錯誤 |
| Token 錯誤 | Apps Script 回 401 `unauthorized`，客戶端顯示錯誤 |
| 排程漏掉某天 | 隔天照跑，該筆仍會被關（條件是「A 日期 < 今天」） |

---

## 9. 目錄結構

```
C:\Users\user\Desktop\timer\
├── docs\
│   └── superpowers\
│       ├── specs\
│       │   └── 2026-07-01-timer-design.md   （本文件）
│       └── plans\
│           └── 2026-07-01-timer.md
├── apps-script\
│   └── Code.gs                             （Apps Script Web App 原始碼）
├── ahk\
│   └── timer-snippet.ahk                   （追加到 Seashell (2).ahk 的內容）
├── termux\
│   ├── timer-start.sh
│   └── timer-stop.sh
├── .gitignore
└── README.md                               （部署步驟 + AI prompt 樣板 + Sheets 設定建議）
```

**部署方式：**

1. **Google Sheet：** 新建一個試算表，把工作表命名為 `records`，第一列填欄位標題 `日期、開始、結束、耗時、任務、情境、功能、專案、備註、結束方式`
2. **Apps Script：** 在該試算表選單 Extensions → Apps Script → 貼 `apps-script/Code.gs` → 填入 token 常數 → 「Deploy as Web App」（Execute as: me / Who has access: Anyone）→ 記下 URL
3. **時間觸發器：** Apps Script → Triggers → Add Trigger → Function `dayBoundary` / Event source `Time-driven` / `Day timer` / `4am to 5am`
4. **AHK：** 手動貼 `ahk/timer-snippet.ahk` 到 `Seashell (2).ahk` 尾端，填入 URL 和 token，重新載入
5. **Termux：** 複製 `termux/*.sh` 到 `~/.shortcuts/`，填入 URL 和 token，`chmod +x`

---

## 10. README 附加內容

README 除了部署步驟，還要包含以下兩份「使用者要自備的東西」：

### 10.1 AI 分類 prompt 樣板

存在你順手的地方（Notion / 記事本 / 手機備忘錄）。每天歸檔時用：

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

### 10.2 Sheets 建議設定

**條件式格式**（Format → Conditional formatting）：
- 規則 1：範圍 `A2:J`、公式 `=AND($E2<>"",$C2="")` → 底色淡黃 → 標示「未結束」
- 規則 2：範圍 `J2:J`、值 `superseded` → 底色淡橘
- 規則 3：範圍 `J2:J`、值 `day_boundary` → 底色淡紅

**Data validation**（Format → Data validation）：
- F 欄：清單 `工作,個人,家庭,社交`
- G 欄：清單 `維護,改善,產出,探索,休息`

（在 AI 填錯時能看出來，也提醒你手動改時的合法值）

**Freeze**：View → Freeze → 1 row（讓標題列常駐）

---

## 11. 不做的事情（明確排除）

- 不支援多使用者
- 不做 iOS 版本
- 不做原生 Android app
- 不做 Samsung Edge Panel plugin
- 不做離線快取或同步佇列
- 不做跨裝置即時同步（電腦懸浮視窗不會因為手機端按停止就消失）
- 不在此工具內做情境 / 功能 / 專案分類（那是使用者 + web AI 事後處理的工作）
- 不做編輯 / 刪除介面（直接改試算表）
- 不做通知 / 鬧鐘 / 每日總結
- 不做音效
- 不做深色模式或 UI 主題
- 不串接 AI API

---

## 12. MVP 完成標準

- [ ] Google Sheet 建好，標題列與 10 欄設定完成
- [ ] Apps Script Web App 部署成功，能用 curl / Postman 打通 start 和 stop 兩個 action
- [ ] Apps Script 時間觸發器（凌晨 4:00 `dayBoundary`）建立成功
- [ ] AHK 腳本可用 Alt+T / Alt+Y 開始 / 停止，懸浮視窗正常顯示
- [ ] Termux 桌面圖示可以觸發開始 / 停止腳本
- [ ] `superseded` 邏輯驗證：連按兩次 Alt+T（不按停止），第一筆的 J 欄變 `superseded`、C 欄自動補上
- [ ] `day_boundary` 邏輯驗證：手動在 Apps Script 執行 `dayBoundary` 函式，跨日的未結束紀錄被正確關閉
- [ ] 從三個裝置（Windows、Android、手機瀏覽器）中任一寫入的紀錄，其他裝置刷新試算表都能看到
- [ ] README 收錄 AI prompt 樣板與 Sheets 建議設定
