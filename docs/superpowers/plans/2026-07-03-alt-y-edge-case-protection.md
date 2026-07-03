# Alt+Y Edge Case Protection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Alt+Y (stop timer) safe when the Sheet contains manually-added incomplete rows, replacing the current `#NUM!` / 23:59 / `day_boundary` misbehavior with a recovery path.

**Architecture:** Split "unclosed row" candidates into `legit` (today's date + strict HH:MM start) and `recovery` (anything else). `actionStop` prefers `legit`; falls back to `recovery` which fills today's date + now's time and leaves start/duration blank when the start is unusable. AHK toast gets a `partial` branch so the user can see when Alt+Y did recovery instead of a normal stop.

**Tech Stack:** Google Apps Script (V8, `apps-script/Code.gs`), AutoHotkey v2 (`ahk/timer-snippet.ahk`).

**Spec:** `docs/superpowers/specs/2026-07-03-alt-y-edge-case-protection-design.md`

---

## Pre-Work

The working copy has uncommitted changes in `apps-script/Code.gs`, `ahk/timer-snippet.ahk`, and `docs/superpowers/specs/2026-07-01-timer-design.md`. Decide what to do with them (commit / stash / discard) **before** starting Task 1, so subsequent commits stay focused.

**Google Apps Script deployment note:** Every server-side change (Tasks 1-5) requires re-deploying the web app in the Apps Script editor (**Deploy → Manage deployments → New version**) to take effect at `TIMER_WEBAPP_URL`. Do this once at the start of Task 6's smoke tests — not after every commit.

---

## File Structure

| File | Change | Responsibility after change |
|---|---|---|
| `apps-script/Code.gs` | Modify | Adds `isStrictHHMM`, `classifyRow`, `pickActiveRow`; refactors `findActiveRow` to return `{...row, kind}`; splits `actionStop` into `legit` vs `recovery` branches; keeps `actionStart` / `dayBoundary` unchanged. |
| `ahk/timer-snippet.ahk` | Modify | Adds `TimerExtractBool`; extends `TimerStop`'s toast to distinguish `partial` responses. |
| `docs/superpowers/specs/2026-07-03-alt-y-edge-case-protection-design.md` | (Already committed) | Reference spec. |

All other files (`termux/*`, `apps-script/Code.gs::actionStart`, `apps-script/Code.gs::dayBoundary`) are explicitly out of scope.

---

## Task 1: Add `isStrictHHMM` helper

**Files:**
- Modify: `apps-script/Code.gs` (add near existing "Time helpers" block, before `now()`)

- [ ] **Step 1: Add the failing test function**

Add this at the bottom of `Code.gs` under a new `// --- Test functions (run manually in Apps Script IDE) ---` section:

```javascript
// --- Test functions (run manually in Apps Script IDE) --------------------

function _testIsStrictHHMM() {
  const cases = [
    ['09:00', true],
    ['00:00', true],
    ['23:59', true],
    ['9:00',  false],   // single-digit hour
    ['09:5',  false],   // single-digit minute
    ['9:5',   false],
    ['',      false],
    ['abc',   false],
    ['09時00', false],
    ['09:00 AM', false],
    ['9點',   false],
    ['24:00', true],    // regex only, semantic bounds not enforced — documented in spec
  ];
  cases.forEach(([input, expected]) => {
    const actual = isStrictHHMM(input);
    if (actual !== expected) {
      throw new Error(`isStrictHHMM(${JSON.stringify(input)}) = ${actual}, expected ${expected}`);
    }
  });
  Logger.log('isStrictHHMM: PASS (' + cases.length + ' cases)');
}
```

- [ ] **Step 2: Run test and verify it fails**

In the Apps Script editor, select `_testIsStrictHHMM` from the function dropdown and click **Run**.
Expected: `ReferenceError: isStrictHHMM is not defined`.

- [ ] **Step 3: Add the helper**

Insert this above the existing `function now()` line in `Code.gs`:

```javascript
function isStrictHHMM(s) {
  return typeof s === 'string' && /^\d{2}:\d{2}$/.test(s);
}
```

- [ ] **Step 4: Run test again and verify it passes**

Run `_testIsStrictHHMM` in the Apps Script editor.
Expected log: `isStrictHHMM: PASS (12 cases)`.

- [ ] **Step 5: Commit**

```bash
git add apps-script/Code.gs
git commit -m "feat(script): add isStrictHHMM helper for Alt+Y edge case handling"
```

---

## Task 2: Add `classifyRow` pure function

Extracts the classification decision so it can be tested without a sheet.

**Files:**
- Modify: `apps-script/Code.gs`

- [ ] **Step 1: Add the failing test function**

Append to the "Test functions" section at the bottom of `Code.gs`:

```javascript
function _testClassifyRow() {
  const cases = [
    // [dateStr, startStr, today, expectedKind]
    ['2026-07-03', '09:00', '2026-07-03', 'legit'],
    ['2026-07-03', '09:00', '2026-07-04', 'recovery'],  // yesterday's row
    ['2026-07-03', '9:00',  '2026-07-03', 'recovery'],  // bad HH:MM
    ['',           '09:00', '2026-07-03', 'recovery'],  // blank date
    ['2026-07-03', '',      '2026-07-03', 'recovery'],  // blank start
    ['',           '',      '2026-07-03', 'recovery'],
    ['garbage',    'garbage','2026-07-03', 'recovery'],
  ];
  cases.forEach(([dateStr, startStr, today, expected]) => {
    const actual = classifyRow(dateStr, startStr, today);
    if (actual !== expected) {
      throw new Error(`classifyRow(${dateStr}, ${startStr}, ${today}) = ${actual}, expected ${expected}`);
    }
  });
  Logger.log('classifyRow: PASS (' + cases.length + ' cases)');
}
```

- [ ] **Step 2: Run test and verify it fails**

Run `_testClassifyRow`.
Expected: `ReferenceError: classifyRow is not defined`.

- [ ] **Step 3: Add the function**

Insert this right after `isStrictHHMM`:

```javascript
// Returns 'legit' (today's date + strict HH:MM) or 'recovery' (anything else).
function classifyRow(dateStr, startStr, today) {
  if (dateStr === today && isStrictHHMM(startStr)) return 'legit';
  return 'recovery';
}
```

- [ ] **Step 4: Run test and verify it passes**

Expected log: `classifyRow: PASS (7 cases)`.

- [ ] **Step 5: Commit**

```bash
git add apps-script/Code.gs
git commit -m "feat(script): add classifyRow pure helper"
```

---

## Task 3: Add `pickActiveRow` pure function

Picks the best row from a list of candidates: prefers latest `legit`, else latest `recovery`.

**Files:**
- Modify: `apps-script/Code.gs`

- [ ] **Step 1: Add the failing test function**

Append to test section:

```javascript
function _testPickActiveRow() {
  const today = '2026-07-03';

  // Case A: empty list
  if (pickActiveRow([], today) !== null) throw new Error('empty list should return null');

  // Case B: only recovery
  const b = pickActiveRow(
    [{ rowNum: 2, dateStr: '', startStr: '', task: 'foo' }],
    today
  );
  if (!b || b.kind !== 'recovery' || b.rowNum !== 2) throw new Error('B failed: ' + JSON.stringify(b));

  // Case C: only legit
  const c = pickActiveRow(
    [{ rowNum: 3, dateStr: today, startStr: '09:00', task: 'foo' }],
    today
  );
  if (!c || c.kind !== 'legit' || c.rowNum !== 3) throw new Error('C failed: ' + JSON.stringify(c));

  // Case D: legit + recovery coexist → legit wins even if recovery is later
  const d = pickActiveRow(
    [
      { rowNum: 4, dateStr: today, startStr: '09:00', task: 'real' },
      { rowNum: 5, dateStr: '',    startStr: '',      task: 'manual' },  // later row
    ],
    today
  );
  if (!d || d.kind !== 'legit' || d.rowNum !== 4) throw new Error('D failed: ' + JSON.stringify(d));

  // Case E: two legits → pick latest (highest rowNum)
  const e = pickActiveRow(
    [
      { rowNum: 6, dateStr: today, startStr: '09:00', task: 'older' },
      { rowNum: 7, dateStr: today, startStr: '10:00', task: 'newer' },
    ],
    today
  );
  if (!e || e.rowNum !== 7) throw new Error('E failed: ' + JSON.stringify(e));

  // Case F: two recoveries → pick latest
  const f = pickActiveRow(
    [
      { rowNum: 8, dateStr: '', startStr: '', task: 'older' },
      { rowNum: 9, dateStr: '', startStr: '', task: 'newer' },
    ],
    today
  );
  if (!f || f.rowNum !== 9) throw new Error('F failed: ' + JSON.stringify(f));

  Logger.log('pickActiveRow: PASS (6 cases)');
}
```

- [ ] **Step 2: Run test and verify it fails**

Expected: `ReferenceError: pickActiveRow is not defined`.

- [ ] **Step 3: Add the function**

Insert after `classifyRow`:

```javascript
// candidates: [{ rowNum, dateStr, startStr, task }, ...] in ascending rowNum order.
// Returns the best pick with `kind` attached, or null.
function pickActiveRow(candidates, today) {
  let latestLegit = null;
  let latestRecovery = null;
  for (const c of candidates) {
    const kind = classifyRow(c.dateStr, c.startStr, today);
    const entry = Object.assign({}, c, { kind });
    if (kind === 'legit') latestLegit = entry;
    else latestRecovery = entry;
  }
  return latestLegit || latestRecovery;
}
```

- [ ] **Step 4: Run test and verify it passes**

Expected log: `pickActiveRow: PASS (6 cases)`.

- [ ] **Step 5: Commit**

```bash
git add apps-script/Code.gs
git commit -m "feat(script): add pickActiveRow selector preferring legit over recovery"
```

---

## Task 4: Refactor `findActiveRow` to use the new pipeline

**Files:**
- Modify: `apps-script/Code.gs` — replace the existing `findActiveRow` (currently at lines 48-65).

- [ ] **Step 1: Replace the function**

Current implementation:

```javascript
// Returns { rowNum, dateStr, startStr, task } or null.
function findActiveRow(sh) {
  const lastRow = sh.getLastRow();
  if (lastRow < 2) return null;
  const values = sh.getRange(2, 1, lastRow - 1, 10).getValues();  // columns A..J
  for (let i = values.length - 1; i >= 0; i--) {
    const endCell = values[i][2];
    const taskCell = values[i][4];
    if (!endCell && taskCell) {
      return {
        rowNum:   i + 2,
        dateStr:  readDateStr(values[i][0]),
        startStr: readTimeStr(values[i][1]),
        task:     String(taskCell),
      };
    }
  }
  return null;
}
```

Replace with:

```javascript
// Returns { rowNum, dateStr, startStr, task, kind } or null.
// kind: 'legit' (today + strict HH:MM) or 'recovery' (anything else).
// Prefers the latest legit row; falls back to the latest recovery row.
function findActiveRow(sh, today) {
  const lastRow = sh.getLastRow();
  if (lastRow < 2) return null;
  const values = sh.getRange(2, 1, lastRow - 1, 10).getValues();
  const candidates = [];
  for (let i = 0; i < values.length; i++) {
    const endCell = values[i][2];
    const taskCell = values[i][4];
    if (!endCell && taskCell) {
      candidates.push({
        rowNum:   i + 2,
        dateStr:  readDateStr(values[i][0]),
        startStr: readTimeStr(values[i][1]),
        task:     String(taskCell),
      });
    }
  }
  return pickActiveRow(candidates, today);
}
```

- [ ] **Step 2: Update `actionStart` call site**

Find the line in `actionStart` (around line 122):

```javascript
const active = findActiveRow(sh);
```

Change to:

```javascript
const active = findActiveRow(sh, today);
```

(`today` is already computed on the line above; no other change to `actionStart`.)

- [ ] **Step 3: Update `dayBoundary` — no change needed**

`dayBoundary()` does not call `findActiveRow`; it scans directly. Verify by grepping:

```bash
grep -n "findActiveRow" apps-script/Code.gs
```

Expected: matches only in `actionStart`, `actionStop`, and the definition itself.

- [ ] **Step 4: Commit**

```bash
git add apps-script/Code.gs
git commit -m "refactor(script): route findActiveRow through pickActiveRow"
```

---

## Task 5: Rewrite `actionStop` with legit / recovery split

**Files:**
- Modify: `apps-script/Code.gs` — replace the existing `actionStop` (currently at lines 142-164).

- [ ] **Step 1: Replace the function**

Current implementation:

```javascript
function actionStop() {
  const sh = sheet();
  const active = findActiveRow(sh);
  if (!active) return { ok: false, error: 'no_active' };

  const nowDt = now();
  const today = fmtDate(nowDt);
  const nowTime = fmtTime(nowDt);
  const startDt = composeDate(active.dateStr, active.startStr);

  if (active.dateStr === today) {
    const dur = durationMinutes(startDt, nowDt);
    sh.getRange(active.rowNum, 3, 1, 2).setValues([[asText(nowTime), dur]]);
    sh.getRange(active.rowNum, 10).setValue('manual');
    return { ok: true, task: active.task, duration_min: dur };
  } else {
    const endDt = endOfDay(active.dateStr);
    const dur = durationMinutes(startDt, endDt);
    sh.getRange(active.rowNum, 3, 1, 2).setValues([[asText('23:59'), dur]]);
    sh.getRange(active.rowNum, 10).setValue('day_boundary');
    return { ok: true, task: active.task, duration_min: dur };
  }
}
```

Replace with:

```javascript
function actionStop() {
  const sh = sheet();
  const nowDt = now();
  const today = fmtDate(nowDt);
  const nowTime = fmtTime(nowDt);

  const active = findActiveRow(sh, today);
  if (!active) return { ok: false, error: 'no_active' };

  if (active.kind === 'legit') {
    const startDt = composeDate(active.dateStr, active.startStr);
    const dur = durationMinutes(startDt, nowDt);
    sh.getRange(active.rowNum, 3, 1, 2).setValues([[asText(nowTime), dur]]);
    sh.getRange(active.rowNum, 10).setValue('manual');
    return { ok: true, task: active.task, duration_min: dur };
  }

  // kind === 'recovery'
  // Force date to today; fill end = now; compute duration only if start is
  // strict HH:MM and lands in the past on today's date. Leave B (start) alone
  // so we don't destroy user input.
  const updates = { A: asText(today), C: asText(nowTime), D: '' };
  if (isStrictHHMM(active.startStr)) {
    const startDt = composeDate(today, active.startStr);
    if (startDt.getTime() <= nowDt.getTime()) {
      updates.D = durationMinutes(startDt, nowDt);
    }
  }
  sh.getRange(active.rowNum, 1).setValue(updates.A);
  sh.getRange(active.rowNum, 3, 1, 2).setValues([[updates.C, updates.D]]);
  sh.getRange(active.rowNum, 10).setValue('manual_partial');
  return {
    ok: true,
    task: active.task,
    duration_min: updates.D === '' ? null : updates.D,
    partial: true,
  };
}
```

- [ ] **Step 2: Add smoke test function**

Append to the test section at the bottom:

```javascript
// Prints the current sheet's last 5 rows for visual inspection during smoke tests.
function _dumpLastRows() {
  const sh = sheet();
  const lastRow = sh.getLastRow();
  if (lastRow < 2) { Logger.log('(empty)'); return; }
  const start = Math.max(2, lastRow - 4);
  const rows = sh.getRange(start, 1, lastRow - start + 1, 10).getValues();
  rows.forEach((r, i) => {
    Logger.log('row ' + (start + i) + ': ' + JSON.stringify(r));
  });
}
```

- [ ] **Step 3: Commit**

```bash
git add apps-script/Code.gs
git commit -m "feat(script): actionStop recovery branch for manual rows"
```

---

## Task 6: Deploy + manual smoke tests in Google Sheet

Server logic is done; now verify end-to-end against a real sheet.

- [ ] **Step 1: Deploy the new version**

In the Apps Script editor: **Deploy → Manage deployments → (existing) → Edit (pencil) → Version: New version → Deploy**.
Confirm `TIMER_WEBAPP_URL` in `ahk/timer-snippet.ahk:6` still matches the deployment URL (it should — same deployment, new version).

- [ ] **Step 2: Reload the AHK script**

Right-click the AHK tray icon → **Reload Script**. This ensures the AHK side is running the current file even though we haven't changed it yet.

- [ ] **Step 3: Smoke test A — legit today active (regression check)**

1. Press **Alt+T**, type "smoke A", submit.
2. Wait ~30 seconds.
3. Press **Alt+Y**.

Expected in sheet: new row appended earlier now has C=current time, D=~0 or 1, J=`manual`. Tray toast: `已停止：smoke A (N 分鐘)`.

- [ ] **Step 4: Smoke test B — manual row, task only**

1. Confirm no unclosed rows in the sheet (all rows have column C filled).
2. In the sheet, manually append a new row with only column E = "smoke B" (leave A, B, C blank).
3. Press **Alt+Y**.

Expected: row updates to A=today, B blank, C=current time, D blank, J=`manual_partial`. Tray toast: **either the existing "N 分鐘" toast** (partial handling not yet in AHK) or an error. Sheet state is what matters here.

- [ ] **Step 5: Smoke test C — manual row, task + valid start**

1. Append a row with E = "smoke C" and B = a valid HH:MM in the past (e.g., `09:00` if now is later).
2. Press **Alt+Y**.

Expected: A=today, B unchanged (`09:00`), C=now, D=computed minutes, J=`manual_partial`.

- [ ] **Step 6: Smoke test D — manual row, task + garbage start**

1. Append a row with E = "smoke D" and B = `9:5` (invalid).
2. Press **Alt+Y**.

Expected: A=today, B unchanged (`9:5`), C=now, D blank, J=`manual_partial`.

- [ ] **Step 7: Smoke test E — real active + manual row coexist**

1. Press **Alt+T**, type "real active", submit.
2. Immediately (without Alt+Y) go to the sheet and append a row below with only E = "manual sibling".
3. Press **Alt+Y**.

Expected: the "real active" row closes normally (D computed, J=`manual`). The "manual sibling" row is **untouched** (still has C blank).

- [ ] **Step 8: Smoke test F — no unclosed rows**

1. Confirm every row's C is filled.
2. Press **Alt+Y**.

Expected: tray toast `沒有進行中的任務`. Sheet unchanged.

- [ ] **Step 9: Clean up smoke test rows**

Delete rows E="smoke A" through E="manual sibling" from the sheet. (No git action; sheet cleanup only.)

- [ ] **Step 10: No commit needed** — no source changes in this task.

---

## Task 7: Add `TimerExtractBool` helper in AHK

**Files:**
- Modify: `ahk/timer-snippet.ahk` — insert near existing `TimerExtractInt` (around line 187).

- [ ] **Step 1: Add the function**

After `TimerExtractInt` and before `TimerJsonUnescape`, insert:

```ahk
TimerExtractBool(json, key) {
    if RegExMatch(json, '"' . key . '"\s*:\s*(true|false)', &m)
        return m[1] = "true"
    return false
}
```

- [ ] **Step 2: Reload the AHK script**

Right-click the AHK tray icon → **Reload Script**.
Expected: no error dialog on load. If AHK complains about syntax, fix before continuing.

- [ ] **Step 3: Commit**

```bash
git add ahk/timer-snippet.ahk
git commit -m "feat(ahk): add TimerExtractBool helper"
```

---

## Task 8: Update `TimerStop` toast for partial responses

**Files:**
- Modify: `ahk/timer-snippet.ahk` — the `TimerStop` function currently at lines 153-174.

- [ ] **Step 1: Replace the function body**

Current implementation:

```ahk
TimerStop() {
    global TimerCurrentTask
    try {
        body := TimerJsonBody(Map("action", "stop", "token", TIMER_TOKEN))
        resp := TimerHttp(body)
        if InStr(resp, '"error":"no_active"') {
            TimerFlashTip("沒有進行中的任務")
            return
        }
        if !InStr(resp, '"ok":true') {
            MsgBox("停止失敗（server）：" . resp, "Timer", "IconX")
            return
        }
        task := TimerExtractString(resp, "task")
        minutes := TimerExtractInt(resp, "duration_min")
        TimerHideFloat()
        TimerCurrentTask := ""
        TimerFlashTip("已停止：" . SubStr(task, 1, 30) . " (" . minutes . " 分鐘)")
    } catch as e {
        MsgBox("停止失敗：" . e.Message . "`n`n" . e.What . " at " . e.File . ":" . e.Line, "Timer", "IconX")
    }
}
```

Replace with:

```ahk
TimerStop() {
    global TimerCurrentTask
    try {
        body := TimerJsonBody(Map("action", "stop", "token", TIMER_TOKEN))
        resp := TimerHttp(body)
        if InStr(resp, '"error":"no_active"') {
            TimerFlashTip("沒有進行中的任務")
            return
        }
        if !InStr(resp, '"ok":true') {
            MsgBox("停止失敗（server）：" . resp, "Timer", "IconX")
            return
        }
        task := TimerExtractString(resp, "task")
        partial := TimerExtractBool(resp, "partial")
        hasMinutes := RegExMatch(resp, '"duration_min"\s*:\s*(-?\d+)')
        minutes := TimerExtractInt(resp, "duration_min")
        TimerHideFloat()
        TimerCurrentTask := ""
        shortTask := SubStr(task, 1, 30)
        if (partial && hasMinutes)
            TimerFlashTip("已補紀錄：" . shortTask . " (" . minutes . " 分鐘)")
        else if (partial)
            TimerFlashTip("已補紀錄：" . shortTask . "（未算耗時）")
        else
            TimerFlashTip("已停止：" . shortTask . " (" . minutes . " 分鐘)")
    } catch as e {
        MsgBox("停止失敗：" . e.Message . "`n`n" . e.What . " at " . e.File . ":" . e.Line, "Timer", "IconX")
    }
}
```

Note: `hasMinutes` uses a fresh RegExMatch (rather than trusting `TimerExtractInt`) to distinguish "duration_min = 0" from "duration_min = null / missing", which matters for the partial+no-minutes toast.

- [ ] **Step 2: Reload the AHK script**

Right-click the AHK tray icon → **Reload Script**.
Expected: no syntax error dialog.

- [ ] **Step 3: Commit**

```bash
git add ahk/timer-snippet.ahk
git commit -m "feat(ahk): partial toast branch for Alt+Y recovery responses"
```

---

## Task 9: End-to-end AHK toast verification

Repeat the smoke tests from Task 6 but this time also verify the AHK toast message.

- [ ] **Step 1: Confirm no unclosed rows** in the sheet.

- [ ] **Step 2: Re-run smoke test A (regression)**

- Alt+T "smoke A2" → wait 30s → Alt+Y.
- Expected toast: `已停止：smoke A2 (N 分鐘)` (unchanged).

- [ ] **Step 3: Re-run smoke test B (task only)**

- Manually append row with only E = "smoke B2" → Alt+Y.
- Expected toast: `已補紀錄：smoke B2（未算耗時）`.
- Expected sheet: A=today, B blank, C=now, D blank, J=`manual_partial`.

- [ ] **Step 4: Re-run smoke test C (task + valid start)**

- Manually append row with E = "smoke C2", B = a valid past HH:MM → Alt+Y.
- Expected toast: `已補紀錄：smoke C2 (N 分鐘)`.
- Expected sheet: D=computed, J=`manual_partial`.

- [ ] **Step 5: Re-run smoke test D (task + garbage start)**

- Manually append row with E = "smoke D2", B = `9:5` → Alt+Y.
- Expected toast: `已補紀錄：smoke D2（未算耗時）`.
- Expected sheet: B unchanged (`9:5`), D blank, J=`manual_partial`.

- [ ] **Step 6: Re-run smoke test E (real active + manual sibling)**

- Alt+T "real active 2" → append E="manual sibling 2" row while running → Alt+Y.
- Expected toast: `已停止：real active 2 (N 分鐘)` (no `partial`).
- Expected sheet: real active row closed normally; manual sibling untouched.

- [ ] **Step 7: Re-run smoke test F (nothing to close)**

- Ensure all rows have C filled → Alt+Y.
- Expected toast: `沒有進行中的任務`.

- [ ] **Step 8: Clean up smoke test rows**

Delete smoke test rows from the sheet.

- [ ] **Step 9: No commit needed** — verification only.

---

## Task 10: Update spec status (optional)

- [ ] **Step 1: Mark spec as implemented**

In `docs/superpowers/specs/2026-07-03-alt-y-edge-case-protection-design.md`, change the top-of-file status line:

```markdown
**狀態：** 設計定稿
```

to:

```markdown
**狀態：** 已實作（2026-07-03）
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-07-03-alt-y-edge-case-protection-design.md
git commit -m "docs: mark Alt+Y edge case spec as implemented"
```

---

## Completion Criteria

- [ ] All 6 smoke test scenarios in Task 9 produce the expected toast and sheet state
- [ ] No new `#NUM!` values appear in column D
- [ ] `manual_partial` appears in J for recovery cases; `manual` still appears for legit stops
- [ ] `git log` shows a clean sequence of small, focused commits
