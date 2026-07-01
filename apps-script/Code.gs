// =============================================================================
// Timer Web App — see docs/superpowers/specs/2026-07-01-timer-design.md
// =============================================================================

const SCRIPT_TOKEN = 'YOUR_TOKEN';
const SHEET_NAME   = 'records';
const TZ           = 'Asia/Taipei';

// --- Entry point -------------------------------------------------------------

function doPost(e) {
  try {
    const body = JSON.parse(e.postData.contents);
    if (body.token !== SCRIPT_TOKEN) return respond({ ok: false, error: 'unauthorized' });
    if (body.action === 'start')      return respond(actionStart(String(body.task || '').trim()));
    if (body.action === 'stop')       return respond(actionStop());
    return respond({ ok: false, error: 'unknown_action' });
  } catch (err) {
    return respond({ ok: false, error: 'internal: ' + err.message });
  }
}

function respond(obj) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}

// --- Sheet access ------------------------------------------------------------

function sheet() {
  return SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_NAME);
}

// Robust reads: Sheets may hand back Date objects even when the column is
// "Plain text", so coerce back to strings we can parse.
function readDateStr(v) {
  if (v instanceof Date) return Utilities.formatDate(v, TZ, 'yyyy-MM-dd');
  return String(v);
}

function readTimeStr(v) {
  if (v instanceof Date) return Utilities.formatDate(v, TZ, 'HH:mm');
  return String(v);
}

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

// --- Time helpers ------------------------------------------------------------

function now() {
  return new Date();
}

function fmtDate(d) {
  return Utilities.formatDate(d, TZ, 'yyyy-MM-dd');
}

function fmtTime(d) {
  return Utilities.formatDate(d, TZ, 'HH:mm');
}

// Prefix with apostrophe to force Sheets to store as text (prevents auto-
// conversion of "2026-07-01" to a Date object or "11:05" to a Time object).
// The apostrophe is invisible on display and stripped by getValue()/getValues().
function asText(s) {
  return "'" + s;
}

// Compose a Date from "yyyy-MM-dd" and "HH:mm" strings in TZ.
function composeDate(dateStr, timeStr) {
  const [y, mo, d] = dateStr.split('-').map(Number);
  const [h, mi] = timeStr.split(':').map(Number);
  const asIfUtc = new Date(Date.UTC(y, mo - 1, d, h, mi, 0));
  const offsetMin = tzOffsetMinutes(asIfUtc);
  return new Date(asIfUtc.getTime() - offsetMin * 60000);
}

function tzOffsetMinutes(d) {
  const s = Utilities.formatDate(d, TZ, 'Z');
  const sign = s[0] === '-' ? -1 : 1;
  const h = parseInt(s.substring(1, 3), 10);
  const m = parseInt(s.substring(3, 5), 10);
  return sign * (h * 60 + m);
}

function durationMinutes(from, to) {
  return Math.round((to.getTime() - from.getTime()) / 60000);
}

function endOfDay(dateStr) {
  return composeDate(dateStr, '23:59');
}

// --- Actions -----------------------------------------------------------------

function actionStart(task) {
  if (!task) return { ok: false, error: 'empty_task' };
  const sh = sheet();
  const nowDt = now();
  const today = fmtDate(nowDt);
  const nowTime = fmtTime(nowDt);

  const active = findActiveRow(sh);
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
