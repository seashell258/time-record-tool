# 個人時間記錄工具設計文件

**日期：** 2026-07-01
**狀態：** 設計定稿
**使用者：** 單一使用者（自用）

---

## 1. 目標與範圍

打造一個跨裝置（Windows + Android）的個人時間記錄工具，能夠**快速**新增一筆「開始做某事」的紀錄，並在完成時停止計時。所有紀錄同步到同一個資料源。

**這個工具負責收集的欄位：**

| 欄位 | 來源 |
|------|------|
| 日期 | 自動 |
| 開始時間 | 自動（按開始鍵時） |
| 結束時間 | 自動（按停止鍵時） |
| 耗時 | 自動計算 |
| 任務內容 | 使用者輸入（自由文字，可長可短） |

**不由此工具收集的欄位**（事後手動把當日紀錄丟給 AI 處理）：

- 情境（工作 / 個人 / 家庭 / 社交，固定四選一）
- 功能（維護 / 改善 / 產出 / 探索 / 休息，固定五選一）
- 專案（自由文字）
- 備註（自由文字）

以上四個欄位由 AI 依據任務內容推斷與分類，不在 MVP 的輸入介面裡出現。

---

## 2. 架構總覽

```
┌─────────────────┐        ┌─────────────────┐
│  Windows (AHK)  │        │ Android(Termux) │
│                 │        │                 │
│  Alt+T → 彈窗    │        │  桌面圖示 or    │
│  Alt+Y → 停止    │        │   Edge Panel    │
│                 │        │    → 對話框     │
│                 │        │    → 送出       │
└────────┬────────┘        └────────┬────────┘
         │                          │
         │      HTTPS + API Key     │
         └───────────┬──────────────┘
                     ↓
         ┌────────────────────────┐
         │      Supabase          │
         │  (Postgres + REST API) │
         └────────┬───────────────┘
                  │
                  ↓
         ┌────────────────────────┐
         │  Vercel 靜態閱覽頁      │
         │  選日期 → 顯示純文字    │
         └────────────────────────┘
```

**要點：**

- 兩個客戶端（AHK、Termux）都**直接**呼叫 Supabase REST API，不經任何後端框架
- Vercel 上只有一個靜態 `index.html`，讀取資料並格式化為純文字，方便複製貼給 AI
- 所有「自動關閉遺留紀錄」「計算耗時」等邏輯都放在 Supabase 端的 trigger，客戶端保持極簡

---

## 3. 資料層

### 3.1 資料表

```sql
create table records (
  id           bigserial primary key,
  task         text not null,
  started_at   timestamptz not null default now(),
  ended_at     timestamptz,
  duration_s   integer,
  auto_closed  boolean not null default false
);

create index on records (started_at desc);
create index on records (ended_at) where ended_at is null;
```

**欄位說明：**

- `task`：任務內容，自由文字，使用者可以只寫短短一句，也可以寫很長。所有與這筆任務相關的描述都塞在這裡。
- `started_at` / `ended_at`：`timestamptz` 儲存 UTC，顯示時再依裝置時區轉換。
- `ended_at is null` 代表「目前正在計時」，不需要另外的 status 欄位。
- `duration_s`：以秒為單位的整數，結束時由 trigger 計算並寫入。
- `auto_closed`：`true` 表示這筆的 `ended_at` 是被下一筆任務的 `started_at` 推斷出來的，並非使用者主動按下停止。

### 3.2 Trigger：自動關閉遺留紀錄

當有人按下開始時，如果先前存在一筆未結束的紀錄，自動幫它補上 `ended_at`、`duration_s` 並標記 `auto_closed = true`。

```sql
create or replace function auto_close_previous() returns trigger as $$
begin
  update records
     set ended_at    = new.started_at,
         duration_s  = extract(epoch from new.started_at - started_at)::int,
         auto_closed = true
   where ended_at is null and id <> new.id;
  return new;
end;
$$ language plpgsql;

create trigger t_auto_close before insert on records
for each row execute function auto_close_previous();
```

### 3.3 Trigger：停止時計算耗時

```sql
create or replace function fill_duration() returns trigger as $$
begin
  if new.ended_at is not null and old.ended_at is null then
    new.duration_s := extract(epoch from new.ended_at - new.started_at)::int;
  end if;
  return new;
end;
$$ language plpgsql;

create trigger t_fill_duration before update on records
for each row execute function fill_duration();
```

### 3.4 RLS 政策

單一使用者透過一個 shared secret 保護資料表。

```sql
alter table records enable row level security;

create policy "gated by shared secret" on records
  for all
  using      (current_setting('request.headers', true)::json->>'x-api-key' = 'YOUR_LONG_RANDOM_SECRET')
  with check (current_setting('request.headers', true)::json->>'x-api-key' = 'YOUR_LONG_RANDOM_SECRET');
```

`YOUR_LONG_RANDOM_SECRET` 由使用者自己產生一個足夠長的隨機字串（例如 `openssl rand -hex 32`）。

---

## 4. Windows 客戶端（AHK）

### 4.1 整合位置

整合進既有的 `C:\Users\user\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\Seashell (2).ahk`。此腳本已存在、為 AHK v2 語法、開機自動載入。

**Alt+T 與 Alt+Y 目前皆未被佔用**，可安全新增。

### 4.2 快捷鍵行為

**Alt+T — 開始計時**

1. 彈出小型 AHK GUI，單一多行輸入框（Edit control with word-wrap）：
   - **Enter** 送出
   - **Shift+Enter** 換行
   - **Esc** 取消
2. `POST /rest/v1/records`，body 為 `{"task": "..."}`
3. 送出成功後於右下角顯示一個永遠置頂的懸浮視窗：
   ```
   ● {任務內容前 20 字}
   00:00:34
   ```
   秒數即時更新（每秒重繪）
4. 送出失敗：`MsgBox` 顯示錯誤，不做 retry、不做本地快取

**Alt+Y — 停止計時**

1. `PATCH /rest/v1/records?ended_at=is.null&order=started_at.desc&limit=1`，body 為 `{"ended_at": "當前 UTC 時間"}`
2. 關閉懸浮視窗
3. 右下角跳一個一秒後自動消失的 tooltip：`已停止：{任務} ({N} 分鐘)`
4. 若沒有進行中的紀錄，跳提示「沒有進行中的任務」

**無音效**——所有反饋都靠視覺元件。

### 4.3 實作細節

- HTTP 請求用 `ComObject("WinHttp.WinHttpRequest.5.1")`（AHK v2 內建，不依賴外部套件）
- 常數區塊放在腳本頂端：
  ```ahk
  SUPABASE_URL := "https://xxxx.supabase.co"
  SUPABASE_ANON_KEY := "eyJhbGciOi..."
  API_SECRET := "YOUR_LONG_RANDOM_SECRET"
  ```
- HTTP header 帶三個：`apikey`、`Authorization: Bearer {anon_key}`、`x-api-key: {API_SECRET}`
- 懸浮視窗：`Gui("+AlwaysOnTop -Caption +ToolWindow")`，右下角固定位置，可拖動但關閉需靠 Alt+Y
- 秒數更新用 `SetTimer` 每 1000ms 觸發

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
SUPABASE_URL="https://xxxx.supabase.co"
SUPABASE_ANON_KEY="eyJhbGciOi..."
API_SECRET="YOUR_LONG_RANDOM_SECRET"

TASK=$(termux-dialog text -t "任務內容" | jq -r '.text')
[ -z "$TASK" ] && exit

curl -s -X POST "$SUPABASE_URL/rest/v1/records" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
  -H "x-api-key: $API_SECRET" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=minimal" \
  -d "$(jq -n --arg t "$TASK" '{task:$t}')"

termux-toast "已開始：$TASK"
```

**`~/.shortcuts/timer-stop.sh`**
```bash
#!/data/data/com.termux/files/usr/bin/bash
SUPABASE_URL="https://xxxx.supabase.co"
SUPABASE_ANON_KEY="eyJhbGciOi..."
API_SECRET="YOUR_LONG_RANDOM_SECRET"

ID=$(curl -s "$SUPABASE_URL/rest/v1/records?ended_at=is.null&order=started_at.desc&limit=1" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
  -H "x-api-key: $API_SECRET" | jq -r '.[0].id')

if [ "$ID" = "null" ] || [ -z "$ID" ]; then
  termux-toast "沒有進行中的任務"
  exit
fi

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
curl -s -X PATCH "$SUPABASE_URL/rest/v1/records?id=eq.$ID" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
  -H "x-api-key: $API_SECRET" \
  -H "Content-Type: application/json" \
  -d "{\"ended_at\":\"$NOW\"}"

termux-toast "已停止"
```

### 5.3 桌面 / Edge Panel

- Termux:Widget 會自動掃描 `~/.shortcuts/` 產生 launcher 捷徑，長按桌面選 widget 加入即可
- Samsung Edge Panel 能否收納 Termux:Widget 捷徑不保證，需要實測；若不行，本 MVP 就止於桌面圖示

**無音效**——僅用 `termux-toast` 顯示反饋。

---

## 6. Vercel 閱覽頁

### 6.1 用途

在瀏覽器選擇日期範圍，把該範圍內的紀錄格式化為**純文字**顯示在畫面上，讓使用者複製整段貼給 AI 做後續分類。

**不提供** CSV 下載、不提供編輯、不提供刪除。純唯讀 + 純文字輸出。

### 6.2 介面

```
┌──────────────────────────────────────────────┐
│  日期範圍： [2026-07-01] ~ [2026-07-01]      │
│  [ 產生 ]  [ 複製全部 ]                       │
├──────────────────────────────────────────────┤
│  ┌──────────────────────────────────────┐   │
│  │ 2026-07-01 | 讀論文 第3章 | 09:12 |  │   │
│  │             10:45* | 93 分鐘         │   │
│  │ 2026-07-01 | 寫程式 修 bug | 10:45 | │   │
│  │             12:03 | 78 分鐘          │   │
│  │                                       │   │
│  │ * 結束時間為推斷（由下一筆任務開始    │   │
│  │   時間補上）                          │   │
│  └──────────────────────────────────────┘   │
└──────────────────────────────────────────────┘
```

- 純文字輸出放在 `<pre>` 塊，方便框選複製
- 「複製全部」按鈕呼叫 `navigator.clipboard.writeText`
- 預設日期範圍 = 今天

### 6.3 輸出格式

每行一筆：
```
{日期} | {任務內容} | {開始 HH:MM} | {結束 HH:MM}{*} | {分鐘} 分鐘
```

- 時間顯示使用瀏覽器所在裝置時區
- `*` 只有在 `auto_closed = true` 時出現
- 若有任何一筆 `auto_closed`，段尾附上一行說明：
  ```
  * 結束時間為推斷（由下一筆任務開始時間補上）
  ```
- 尚未結束的紀錄（`ended_at is null`）不出現在結果中——匯出的都是已完成的紀錄

### 6.4 認證

- 首次載入頁面時彈出 `prompt("Secret:")`
- 使用者輸入正確 secret → 存進 `localStorage.timerSecret` → 之後不再彈
- 每次查詢自動帶入 `x-api-key` header；如果 Supabase 回 4xx，清除 `localStorage` 並重新彈框

### 6.5 實作細節

- 單一 `index.html`，內嵌 `<script>` 使用 Supabase JS SDK（透過 CDN 引入）
- 部署：靜態專案丟 Vercel，`vercel.json` 或直接空的都可以
- 不用 Next.js、不用建置流程

---

## 7. 認證與安全模型

**威脅模型：** 這是個人工具，資料非敏感（任務名稱），但要防止有人不小心撞到 Vercel URL 就對資料庫亂寫入或刪除。

**核心機制：** 一個 shared secret，透過 RLS 政策檢查 request header。

| 端 | secret 儲存方式 |
|----|----------------|
| AHK | 腳本頂端常數（本機檔案） |
| Termux | 腳本頂端常數（本機檔案） |
| Vercel | `localStorage`，首次載入時 `prompt()` |

**Supabase anon key** 本來就是公開資訊，可以放進 git、可以出現在 Vercel 頁面原始碼；**真正的門檻是那個 `x-api-key`**。

**不做的事情**（MVP 範圍外）：
- 沒有 secret rotate 機制
- 沒有 `.env` 檔（腳本直接寫死；資料夾要不要 git 由使用者自行決定）
- 沒有多使用者
- 沒有 audit log
- 沒有 rate limit

---

## 8. 錯誤處理

原則：**單機小工具，簡單就好；失敗就明確告知，不做任何自動 retry 或本地快取。**

| 情境 | 行為 |
|------|------|
| AHK / Termux 網路失敗 | AHK 跳 `MsgBox`；Termux 用 `termux-toast` 顯示錯誤 |
| AHK / Termux 送出時已有進行中紀錄 | 由 Supabase trigger 自動關閉舊的，客戶端無感 |
| AHK 停止時沒有進行中紀錄 | 跳提示「沒有進行中的任務」 |
| Termux 停止時沒有進行中紀錄 | `termux-toast "沒有進行中的任務"` |
| Vercel secret 錯誤 | 清 `localStorage`，重新 `prompt` |
| Vercel 查詢區間無資料 | 顯示「（無紀錄）」 |

---

## 9. 目錄結構

```
C:\Users\user\Desktop\timer\
├── docs\
│   └── superpowers\
│       └── specs\
│           └── 2026-07-01-timer-design.md   （本文件）
├── sql\
│   ├── 001_schema.sql          （表 + index）
│   ├── 002_triggers.sql        （auto_close, fill_duration）
│   └── 003_rls.sql             （RLS 政策）
├── ahk\
│   └── timer-snippet.ahk       （要追加到 Seashell (2).ahk 的內容）
├── termux\
│   ├── timer-start.sh
│   └── timer-stop.sh
└── vercel\
    └── index.html              （閱覽頁）
```

**部署方式：**

1. Supabase：把 `sql/` 底下三份 SQL 依序在 Supabase SQL Editor 執行
2. AHK：把 `ahk/timer-snippet.ahk` 內容手動貼到 `Seashell (2).ahk` 尾端，填入 secret，重新載入腳本
3. Termux：把 `termux/*.sh` 複製到 `~/.shortcuts/`，填入 secret，`chmod +x`
4. Vercel：把 `vercel/index.html` 部署到 Vercel（可以 drag-drop 到 dashboard 或用 CLI），填入 Supabase URL + anon key

---

## 10. 不做的事情（明確排除）

- 不支援多使用者
- 不做 iOS 版本
- 不做原生 Android app
- 不做 Samsung Edge Panel plugin
- 不做離線快取或同步佇列
- 不在此工具內做情境 / 功能 / 專案分類（那是 AI 事後處理的工作）
- 不做編輯、不做刪除介面（如需修改直接進 Supabase Table Editor）
- 不做通知、不做鬧鐘、不做每日總結
- 不做音效
- 不做深色模式或 UI 主題

---

## 11. MVP 完成標準

- [ ] Supabase 資料表、trigger、RLS 建立完成
- [ ] AHK 腳本可用 Alt+T / Alt+Y 開始 / 停止，懸浮視窗正常顯示
- [ ] Termux 桌面圖示可以觸發開始 / 停止腳本
- [ ] Vercel 閱覽頁可以選日期、產生純文字、複製到剪貼簿
- [ ] auto_closed 機制驗證通過（連續開始兩個任務時舊的自動關閉，`*` 標記正確顯示）
- [ ] 從三個裝置（Windows、Android、瀏覽器）中任一裝置寫入的紀錄，其他兩端都能看到
