# TeamScheduler

Team task scheduler: the `scheduler_v3.html` UI backed by a Windows PowerShell 5.1
data/API layer. **No admin rights, no installer, no database engine.**

## Run

```
powershell -ExecutionPolicy Bypass -File .\Run-Scheduler.ps1
```

The browser opens `http://localhost:8770/` automatically. Stop with **Ctrl+C** — on shutdown the data is zipped to `%LOCALAPPDATA%\TeamScheduler\backups\backup_<timestamp>.zip`.

Options: `-Port 8771` (if 8770 is taken), `-NoBrowser`.

`-ExecutionPolicy Bypass` is a per-process setting and needs no elevation.

## Why no admin is needed

- **HTTP:** `System.Net.HttpListener` is bound to `http://localhost:PORT/`.
  Windows special-cases the literal `localhost` prefix so a standard user may
  register it — no `netsh http add urlacl`, no elevation. If `Start()` fails,
  the port is taken; pick another high port. Never fall back to `netsh`.
- **Storage:** JSON files under `%LOCALAPPDATA%\TeamScheduler\` (always
  user-writable): `people.json`, `customers.json`, `environments.json`,
  `projects.json`, `tasks.json`, `holidays.json`, `templates.json`, `meta.json` (id counters).
- **First run** seeds the demo customers/environments/projects/people from
  `seed-data.json` (only when `customers.json` is empty).

## Using the UI

- Click the **customers** cards to drill down, or "כל הצוות · לוח מלא" for the full board.
- **+ משימה** button (or double-click an empty weekly cell) adds a task.
- **Click any task** (weekly chip / daily block) to edit or delete it.
- Project cards have **סגור פרויקט / פתח מחדש** (soft close; tasks stay and render muted).
- **🎌 חגים** button manages holidays (name + date range). A holiday tints that day on the board and shows a notice when you schedule on it — it warns but does **not** block.
- In the **פרויקטים** view, click a project's **name** (or **כל המשימות**) to open a full page listing every task for that project across all dates.
- **📋 תבניות** button manages reusable task templates (a name + a list of title/duration tasks). Apply one to a project with **החל תבנית**: pick a start date/time and it creates the tasks back-to-back, unassigned.

## API (all JSON, snake_case to match the UI)

| Method | Path | Notes |
|---|---|---|
| GET | `/api/bootstrap` | all seven collections in one payload |
| GET/POST | `/api/people`, `/api/customers`, `/api/environments`, `/api/projects`, `/api/tasks`, `/api/holidays`, `/api/templates` | create with a JSON body |
| PUT/DELETE | `/api/<entity>/{id}` | PUT takes any subset of fields |
| POST | `/api/projects/{id}/close` / `/api/projects/{id}/open` | soft close / reopen |
| POST | `/api/templates/{id}/apply` | body `{project_id, date, start_min?, person_id?}` — creates the template's tasks back-to-back on the project |
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
