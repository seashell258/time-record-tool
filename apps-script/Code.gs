// =============================================================================
// Timer Web App — see docs/superpowers/specs/2026-07-01-timer-design.md
// =============================================================================

const SCRIPT_TOKEN = '0c885013e07e6ee6994e9a3a8ba7d56bb873ba48af7475b87389a66679100450';
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

// --- Time helpers ------------------------------------------------------------

function isStrictHHMM(s) {
  return typeof s === 'string' && /^\d{2}:\d{2}$/.test(s);
}

// Returns 'legit' (today's date + strict HH:MM) or 'recovery' (anything else).
function classifyRow(dateStr, startStr, today) {
  if (dateStr === today && isStrictHHMM(startStr)) return 'legit';
  return 'recovery';
}

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

// --- Actions -----------------------------------------------------------------

function actionStart(task) {
  if (!task) return { ok: false, error: 'empty_task' };
  const sh = sheet();
  const nowDt = now();
  const today = fmtDate(nowDt);
  const nowTime = fmtTime(nowDt);

  const active = findActiveRow(sh, today);
  if (active && active.kind === 'legit') {
    const startDt = composeDate(active.dateStr, active.startStr);
    const dur = durationMinutes(startDt, nowDt);
    sh.getRange(active.rowNum, 3, 1, 2).setValues([[asText(nowTime), dur]]);
    sh.getRange(active.rowNum, 10).setValue('stop_timer');
  }

  sh.appendRow([asText(today), asText(nowTime), '', '', task, '', '', '', '', '']);
  return { ok: true };
}

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
    sh.getRange(active.rowNum, 10).setValue('stop_timer');
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
