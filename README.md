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

## AI classification prompt (see Task 13 for full content)

TODO: filled in by Task 13.

## Sheets configuration (see Task 13 for full content)

TODO: filled in by Task 13.
