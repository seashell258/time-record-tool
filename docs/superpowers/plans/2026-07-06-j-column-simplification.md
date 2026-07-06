# J Column Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse `apps-script/Code.gs` J-column value set from four (`manual` / `superseded` / `day_boundary` / `manual_partial`) down to two (`stop_timer` / `manual_partial`), and remove the now-dead cross-day / day-boundary code paths.

**Architecture:** Pure edit to a single file. Rename two write sites in `actionStop` and `actionStart` to emit `stop_timer` instead of `manual` / `superseded`. Collapse `actionStart`'s cross-day else branch into the same-day path (no more 23:59 fudging). Delete `dayBoundary()` (trigger already unwired in GAS) and `endOfDay()` (becomes dead code). AHK client and Web App response format are untouched — `partial: true` semantics are preserved via the existing recovery branch in `actionStop`.

**Tech Stack:** Google Apps Script (V8 JavaScript). No local runtime, no CI. Verification is via (a) grep asserting the old strings/symbols are gone, (b) reading the file to confirm structure, and (c) optional manual run of the existing `_test*` helpers inside the GAS IDE after deployment.

**Spec:** `docs/superpowers/specs/2026-07-06-j-column-simplification-design.md`

---

## File Structure

Files touched (exhaustive):

- Modify: `apps-script/Code.gs` — four surgical edits (rename two strings, collapse one if/else, delete two functions)

No new files. No test files (there is no local test runner; the existing `_test*` functions inside `Code.gs` continue to work and are the only test surface).

---

## Task 1: Rename `'manual'` → `'stop_timer'` in `actionStop`

**Files:**
- Modify: `apps-script/Code.gs:182`

The `actionStop` `legit` branch currently marks the closed row with `'manual'`. Change to `'stop_timer'`. The `recovery` branch's `'manual_partial'` write (line 199) is intentionally left alone.

- [ ] **Step 1: Confirm current state**

Grep the file for `'manual'` (with quotes) — expect exactly one hit at line 182:

```
Grep pattern: 'manual'
Path: apps-script/Code.gs
Expected: single match on line 182:
  sh.getRange(active.rowNum, 10).setValue('manual');
```

- [ ] **Step 2: Apply the edit**

Edit `apps-script/Code.gs`:

Old:
```js
    sh.getRange(active.rowNum, 10).setValue('manual');
```

New:
```js
    sh.getRange(active.rowNum, 10).setValue('stop_timer');
```

- [ ] **Step 3: Verify**

Grep again:

```
Grep pattern: 'manual'
Path: apps-script/Code.gs
Expected: no matches. (The pattern includes the surrounding single quotes, so it will NOT match 'manual_partial' — that string has `_` after `manual`, not `'`.)
```

```
Grep pattern: 'stop_timer'
Path: apps-script/Code.gs
Expected: single match on the actionStop legit branch
```

- [ ] **Step 4: Commit**

```bash
git add apps-script/Code.gs
git commit -m "refactor(script): actionStop legit branch writes stop_timer"
```

---

## Task 2: Collapse `actionStart` — remove cross-day else branch, rename `'superseded'` → `'stop_timer'`

**Files:**
- Modify: `apps-script/Code.gs:150-163`

Currently `actionStart` splits on `active.dateStr === today`: the same-day branch writes `'superseded'`, the cross-day branch fabricates a 23:59 close and writes `'day_boundary'`. Simplify to a single unconditional close that always uses `now` as the end time and writes `'stop_timer'`.

- [ ] **Step 1: Confirm current state**

Read `apps-script/Code.gs:142-167` and verify the block matches:

```js
function actionStart(task) {
  if (!task) return { ok: false, error: 'empty_task' };
  const sh = sheet();
  const nowDt = now();
  const today = fmtDate(nowDt);
  const nowTime = fmtTime(nowDt);

  const active = findActiveRow(sh, today);
  if (active) {
    if (active.dateStr === today) {
      const startDt = composeDate(active.dateStr, active.startStr);
      const dur = durationMinutes(startDt, nowDt);
      sh.getRange(active.rowNum, 3, 1, 2).setValues([[asText(nowTime), dur]]);
      sh.getRange(active.rowNum, 10).setValue('superseded');
    } else {
      const startDt = composeDate(active.dateStr, active.startStr);
      const endDt = endOfDay(active.dateStr);
      const dur = durationMinutes(startDt, endDt);
      sh.getRange(active.rowNum, 3, 1, 2).setValues([[asText('23:59'), dur]]);
      sh.getRange(active.rowNum, 10).setValue('day_boundary');
    }
  }

  sh.appendRow([asText(today), asText(nowTime), '', '', task, '', '', '', '', '']);
  return { ok: true };
}
```

- [ ] **Step 2: Apply the edit**

Edit `apps-script/Code.gs` — replace the entire `if (active) { ... }` block:

Old:
```js
  if (active) {
    if (active.dateStr === today) {
      const startDt = composeDate(active.dateStr, active.startStr);
      const dur = durationMinutes(startDt, nowDt);
      sh.getRange(active.rowNum, 3, 1, 2).setValues([[asText(nowTime), dur]]);
      sh.getRange(active.rowNum, 10).setValue('superseded');
    } else {
      const startDt = composeDate(active.dateStr, active.startStr);
      const endDt = endOfDay(active.dateStr);
      const dur = durationMinutes(startDt, endDt);
      sh.getRange(active.rowNum, 3, 1, 2).setValues([[asText('23:59'), dur]]);
      sh.getRange(active.rowNum, 10).setValue('day_boundary');
    }
  }
```

New:
```js
  if (active) {
    const startDt = composeDate(active.dateStr, active.startStr);
    const dur = durationMinutes(startDt, nowDt);
    sh.getRange(active.rowNum, 3, 1, 2).setValues([[asText(nowTime), dur]]);
    sh.getRange(active.rowNum, 10).setValue('stop_timer');
  }
```

- [ ] **Step 3: Verify**

```
Grep pattern: 'superseded'
Path: apps-script/Code.gs
Expected: no matches
```

```
Grep pattern: 'day_boundary'
Path: apps-script/Code.gs
Expected: still 1 match — inside dayBoundary() function (removed in Task 3)
```

```
Grep pattern: endOfDay\(
Path: apps-script/Code.gs
Expected: 2 matches — function definition + dayBoundary() call (both removed in Tasks 3 & 4)
```

```
Grep pattern: 'stop_timer'
Path: apps-script/Code.gs
Expected: 2 matches — one in actionStop, one in actionStart
```

- [ ] **Step 4: Commit**

```bash
git add apps-script/Code.gs
git commit -m "refactor(script): actionStart uses single stop_timer path, drops cross-day fudge"
```

---

## Task 3: Delete `dayBoundary()` function

**Files:**
- Modify: `apps-script/Code.gs:208-233`

GAS-side time-driven trigger has already been unwired by the user; this function is dead. Delete the section comment header, blank line, and function body.

- [ ] **Step 1: Confirm current state**

Read `apps-script/Code.gs:208-233` and verify it matches:

```js
// --- Scheduled trigger (Time-driven, daily ~04:00) --------------------------

function dayBoundary() {
  const sh = sheet();
  const lastRow = sh.getLastRow();
  if (lastRow < 2) return;
  const today = fmtDate(now());
  const values = sh.getRange(2, 1, lastRow - 1, 10).getValues();
  const toUpdate = [];
  for (let i = 0; i < values.length; i++) {
    const dateStr = readDateStr(values[i][0]);
    const startStr = readTimeStr(values[i][1]);
    const endCell = values[i][2];
    const taskCell = values[i][4];
    if (!endCell && taskCell && dateStr < today) {
      const startDt = composeDate(dateStr, startStr);
      const endDt = endOfDay(dateStr);
      const dur = durationMinutes(startDt, endDt);
      toUpdate.push({ rowNum: i + 2, dur });
    }
  }
  toUpdate.forEach(u => {
    sh.getRange(u.rowNum, 3, 1, 2).setValues([[asText('23:59'), u.dur]]);
    sh.getRange(u.rowNum, 10).setValue('day_boundary');
  });
}
```

(Note: line numbers may have shifted slightly after Task 2. Grep for `function dayBoundary` to find the actual line.)

- [ ] **Step 2: Apply the edit**

Delete the section header comment (`// --- Scheduled trigger ...`), the blank line before `function dayBoundary`, and the full function body (through the closing `}`). Preserve any blank line separator that follows before the next section.

Use Edit with the entire block above as `old_string` and empty as `new_string`. If there's a trailing blank line, include it in `old_string` to avoid orphaning it.

- [ ] **Step 3: Verify**

```
Grep pattern: dayBoundary
Path: apps-script/Code.gs
Expected: no matches
```

```
Grep pattern: 'day_boundary'
Path: apps-script/Code.gs
Expected: no matches
```

- [ ] **Step 4: Commit**

```bash
git add apps-script/Code.gs
git commit -m "refactor(script): remove dead dayBoundary() function"
```

---

## Task 4: Delete `endOfDay()` helper

**Files:**
- Modify: `apps-script/Code.gs:136-138`

After Tasks 2 & 3, `endOfDay` has zero callers. Delete.

- [ ] **Step 1: Confirm dead**

```
Grep pattern: endOfDay
Path: apps-script/Code.gs
Expected: single match — the function definition itself (no callers)
```

If there is more than one match, stop and investigate — a previous task didn't fully remove a caller.

- [ ] **Step 2: Apply the edit**

Find the function (line numbers may have shifted) and delete it:

Old:
```js
function endOfDay(dateStr) {
  return composeDate(dateStr, '23:59');
}
```

New: (empty — delete these three lines plus any adjacent blank line that becomes orphaned)

- [ ] **Step 3: Verify**

```
Grep pattern: endOfDay
Path: apps-script/Code.gs
Expected: no matches
```

- [ ] **Step 4: Commit**

```bash
git add apps-script/Code.gs
git commit -m "refactor(script): remove now-unused endOfDay() helper"
```

---

## Task 5: Final sanity sweep

**Files:**
- Read only: `apps-script/Code.gs`

Confirm the finished file matches the spec's target state.

- [ ] **Step 1: Grep for banished symbols**

Run each of the following. All must return zero matches:

```
Grep pattern: 'manual'          Path: apps-script/Code.gs
Grep pattern: 'superseded'      Path: apps-script/Code.gs
Grep pattern: 'day_boundary'    Path: apps-script/Code.gs
Grep pattern: dayBoundary       Path: apps-script/Code.gs
Grep pattern: endOfDay          Path: apps-script/Code.gs
```

- [ ] **Step 2: Grep for surviving symbols**

All must return the expected non-zero count:

```
Grep pattern: 'stop_timer'      Path: apps-script/Code.gs   Expected: 2 (actionStop + actionStart)
Grep pattern: 'manual_partial'  Path: apps-script/Code.gs   Expected: 1 (actionStop recovery branch)
```

- [ ] **Step 3: Read the finished file**

Read `apps-script/Code.gs` end-to-end. Spot-check:
- `actionStop` legit branch writes `'stop_timer'`, recovery branch writes `'manual_partial'`
- `actionStart` has a single unconditional close block writing `'stop_timer'`
- No `dayBoundary` / `endOfDay` / `'day_boundary'` / `'superseded'` anywhere
- The `_test*` helpers (`_testIsStrictHHMM`, `_testClassifyRow`, `_testPickActiveRow`, `_dumpLastRows`) are still present and unmodified

- [ ] **Step 4: No commit**

Nothing to commit — this task is verification only.

---

## Post-Implementation (out of scope for the executor)

Deployment to Google Apps Script is manual (paste into the GAS editor or run `clasp push` if configured). Once deployed, the user can smoke-test via AHK Alt+T / Alt+Y or Termux scripts, and optionally run `_testIsStrictHHMM` / `_testClassifyRow` / `_testPickActiveRow` inside the GAS IDE as regression. The executor should not attempt to deploy.
