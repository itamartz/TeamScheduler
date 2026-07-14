# TeamScheduler

Team task scheduler: the `scheduler_v3.html` UI backed by a Windows PowerShell 5.1
data/API layer. **No admin rights, no installer, no database engine.**

## Run

```
powershell -ExecutionPolicy Bypass -File .\Run-Scheduler.ps1
```

The browser opens `http://localhost:8770/` automatically. Stop with **Ctrl+C**.

Options: `-Port 8771` (if 8770 is taken), `-NoBrowser`.

`-ExecutionPolicy Bypass` is a per-process setting and needs no elevation.

## Why no admin is needed

- **HTTP:** `System.Net.HttpListener` is bound to `http://localhost:PORT/`.
  Windows special-cases the literal `localhost` prefix so a standard user may
  register it — no `netsh http add urlacl`, no elevation. If `Start()` fails,
  the port is taken; pick another high port. Never fall back to `netsh`.
- **Storage:** JSON files under `%LOCALAPPDATA%\TeamScheduler\` (always
  user-writable): `people.json`, `customers.json`, `environments.json`,
  `projects.json`, `tasks.json`, `meta.json` (id counters).
- **First run** seeds the demo customers/environments/projects/people from
  `seed-data.json` (only when `customers.json` is empty).

## Using the UI

- Click the **customers** cards to drill down, or "כל הצוות · לוח מלא" for the full board.
- **+ משימה** button (or double-click an empty weekly cell) adds a task.
- **Click any task** (weekly chip / daily block) to edit or delete it.
- Project cards have **סגור פרויקט / פתח מחדש** (soft close; tasks stay and render muted).

## API (all JSON, snake_case to match the UI)

| Method | Path | Notes |
|---|---|---|
| GET | `/api/bootstrap` | all five collections in one payload |
| GET/POST | `/api/people`, `/api/customers`, `/api/environments`, `/api/projects`, `/api/tasks` | create with a JSON body |
| PUT/DELETE | `/api/<entity>/{id}` | PUT takes any subset of fields |
| POST | `/api/projects/{id}/close` / `/api/projects/{id}/open` | soft close / reopen |
| GET | `/api/tasks?from=YYYY-MM-DD&to=YYYY-MM-DD&person_id=N` | filters, all optional |
| DELETE | `/api/projects/{id}?force=1` | hard delete incl. cascade of its tasks |

Rules enforced server-side: environment colors must be unique; deleting a
customer/environment with children is refused; dates are local `yyyy-MM-dd`
(never UTC — no day shifts); Hebrew round-trips as UTF-8 without BOM.

The module (`Scheduler.psm1`) can also be used directly from PowerShell:

```powershell
Import-Module .\Scheduler.psm1
Initialize-Store
New-Task -PersonId 1 -ProjectId 1 -Title "משימה" -Date "2026-07-14" -StartMin 480 -DurationMin 30
Get-Tasks -From "2026-07-12" -To "2026-07-16" -PersonId 1
```
