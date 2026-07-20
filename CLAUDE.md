# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A team task scheduler: a single-file HTML/JS front end (`scheduler_v3.html`) backed by a Windows **PowerShell 5.1** data/API layer (`Scheduler.psm1`) that serves the UI and answers `/api/...` calls over HTTP on localhost. Storage is local JSON files — no database, no service, no installer. The UI is Hebrew / RTL. `Scheduler_PowerShell_Spec.docx` is the original build spec.

**Fully air-gapped / offline.** There are no external dependencies of any kind — no CDNs, web fonts, analytics, or outbound calls. The front end's only `fetch` targets relative `/api/...` paths on the local server; the backend binds `localhost` only. Keep it that way: inline all CSS/JS, use system fonts, never add a `<script src>`/`<link>`/CDN. Remote is `https://github.com/itamartz/TeamScheduler` (`main`).

## The single hardest constraint: no admin rights

Everything must run as an ordinary user with no elevation. This dictates the whole design and must be preserved:

- **HTTP:** `System.Net.HttpListener` is bound to the literal prefix `http://localhost:$Port/`. Windows special-cases `localhost` so a non-admin process can register it. **Never** bind to `+`, `*`, or the machine name, and **never** run `netsh http add urlacl` — those need admin. If the port is taken, use another high port (`-Port 8771`), don't escalate.
- **Storage:** JSON under `%LOCALAPPDATA%\TeamScheduler\` (always user-writable). Never write to Program Files.
- **Target runtime is Windows PowerShell 5.1 only** (`powershell.exe`, not `pwsh`). No PS7 syntax (`??`, `?.`, ternary), no modules that install to Program Files.

## Run

From the `TeamScheduler/` folder, in a **non-admin** shell:

```
powershell -ExecutionPolicy Bypass -File .\Run-Scheduler.ps1        # port 8770, opens browser
powershell -ExecutionPolicy Bypass -File .\Run-Scheduler.ps1 -Port 8771 -NoBrowser
```

`Run-Scheduler.ps1` imports the module and calls `Start-SchedulerServer`, which blocks until Ctrl+C.

**`-Debug` mode** (`Run-Scheduler.ps1 -Debug` → `Start-SchedulerServer -Debug`): sets `$script:DebugMode`, surfaced to the UI as a `debug` boolean in `/api/bootstrap`. When true, the front end's `applyDebugIds()` prefixes every in-memory entity label with `#<id> ` (people/customers/environments/projects/holidays/templates `name`, tasks `title`) right after `loadAll()` fetches — so **every render site shows the id with no per-site changes**, and it's **never persisted** (server data stays clean; `stripDbgId()` removes the prefix wherever a value is read back into an edit field — `eName`, `tTitle`, `hName`, `tplName`). `-Debug` is a plain switch (works because `Start-SchedulerServer` is not an advanced function). Default is off.

Do **not** launch the server from an agent/automation shell that is elevated: an elevated `HttpListener` behaves differently and will bind/behave inconsistently, and it runs against the wrong user context. When the user needs the server started, have them run it themselves (e.g. the `! <command>` prefix runs in their own session).

## Critical operational fact: what a reload picks up

`Start-SchedulerServer` re-reads `scheduler_v3.html` from disk **on every request**, but it imports `Scheduler.psm1` **once at startup**.

- Changed **only `scheduler_v3.html`** (HTML/CSS/JS) → the user just **reloads the browser**.
- Changed **`Scheduler.psm1`** (any backend logic) → the user must **restart the server** (Ctrl+C, re-run) or the old functions stay in memory. Always tell the user which one applies after a change.

**Backup on shutdown:** `Start-SchedulerServer`'s `finally` block calls `Backup-SchedulerData`, which zips all root `*.json` files into `<DataDir>\backups\backup_<yyyy-MM-dd_HHmmss>.zip` (the `backups\` folder itself is excluded). This runs on a graceful **Ctrl+C** stop — the same path that prints "Scheduler stopped." A hard kill of the console window won't run it. Backups accumulate; there is no auto-pruning.

## Git workflow

**Commit after every self-contained change** (one feature / fix / doc update = one commit) with a clear message, as you go — don't batch many unrelated changes into a big commit. Keep commits local while iterating.

**Push only when the work is finished and verified with no errors** — the front-end script passes `node --check`, any backend change passes its ad-hoc PowerShell test, and the change was exercised (browser/HTTP) without errors. Don't push mid-task or with a known failure. When the user says to push (or the task is done and clean), push all the accumulated commits together.

**Every time you push, update the landing `README.md` (repo root — this is what the GitHub project page shows) so it reflects the new user-facing features in that push.** Add/adjust the **Highlights** bullets, and refresh or add a **screenshot** under `docs/` when a feature is visual (capture it from the running app — see the screenshot recipe below). The root `README.md` is the public face of the repo; do not let it drift behind the app. (`TeamScheduler/README.md` is the run/API doc and should stay in sync too, but the root README is the priority on a push.)

Screenshot recipe (no live user server needed): seed a throwaway data dir, start `Start-SchedulerServer` on a spare port pointed at it (optionally with a temp `-HtmlPath` copy that auto-navigates to the view you want), then `chrome.exe --headless --screenshot=<path> --window-size=W,H http://localhost:<port>/` → copy the PNG into `docs/`. Always tear the throwaway server + temp data down afterward.

## Testing

There is no test framework. Verification is done with ad-hoc PowerShell scripts and browser checks:

- **Backend:** call `Set-SchedulerDataDir -Path <throwaway dir>` before `Initialize-Store`, then exercise the CRUD functions directly and assert. This keeps tests off the user's real `%LOCALAPPDATA%\TeamScheduler\` data. Run with `powershell -NoProfile -ExecutionPolicy Bypass -File <test>.ps1`.
- **HTTP/UI:** start a throwaway server on a spare port pointed at a **copy** of the real data (`Set-SchedulerDataDir` to a temp dir, `Copy-Item` the JSON in), drive it, then stop it. Never verify against the live port 8770 / real data. **Stopping it correctly matters:** an `HttpListener` port is registered by the HTTP.sys kernel driver, so `Get-NetTCPConnection -LocalPort N` reports the owner as **System (PID 4)** — `... | Stop-Process` targets PID 4 and silently fails, leaking the server. Kill the `powershell.exe` process by its script path instead: `Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"` → match `CommandLine` on your temp launcher → `Stop-Process -Id`. Never kill the user's own `Run-Scheduler.ps1` process.
- To add sample data, generate tasks via `New-Task` against the real data dir; the server does not need to be running (it reads the files on next start).
- **Front-end logic (offline):** pure functions in `scheduler_v3.html` can be unit-tested without the server or a browser — slice the relevant block out of the `<script>` and `new Function(...)` it in Node with mocked globals (`iso`, `dayDate`, `chainOf`, `taskCache`, …), then assert on the returned HTML/data. The print report functions were verified this way. `node --check` on the extracted script also catches syntax errors before a reload.
- **Live UI:** the browser-automation tools can drive the running app (read `#…` element state, dispatch `change`/`click`, inspect `document.styleSheets`). Never call `window.print()` while automating — it opens a blocking dialog; stub it (`window.print = ()=>{}`) to verify the print path instead.

## PowerShell 5.1 gotchas already handled — preserve them

These are load-bearing; changing them silently breaks Hebrew, gradients, or array handling:

- **`ConvertFrom-Json` emits a whole JSON array as a single `Object[]`.** `Get-Entities` unwraps with `@((… | ConvertFrom-Json) | ForEach-Object { $_ })` so 0/1/N-item files all return flat arrays. Wrap every collection use in `@(...)`; index/`.Count` on a raw parse result will be wrong. This is the opposite of the usual "1-element collapses to scalar" trap and bit this project more than once.
- **`ConvertTo-Json` defaults to `-Depth 2`**, which truncates nested gradient color objects. Always `-Depth 10`, and serialize with `-InputObject $arr` so empty/1-item arrays stay JSON arrays.
- **UTF-8 without BOM** is mandatory (Hebrew round-trip + clean JSON): write via `[System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))`, never `Out-File -Encoding UTF8` (writes a BOM).
- **Do not put Hebrew string literals in a `.ps1`** — PS 5.1 reads script files as ANSI unless they have a BOM, so Hebrew becomes mojibake and can even cause parse errors. Put Hebrew in a UTF-8 `.json` and read it with `[System.IO.File]::ReadAllText(path, [Text.Encoding]::UTF8)`. (Seed data lives in `seed-data.json` for this reason.)

## Architecture

**Entity hierarchy (strict):** `Customer → Environment (a.k.a. "domain") → Project → Task`. A `Task` references a `project_id` and a `person_id`; it resolves environment/customer/color by walking up the chain. **People are a single flat list shared across all customers** — a person is not owned by any customer and can have tasks under any project.

**`person_id === 0` means UNASSIGNED** — a task that belongs to a project but no person. `New-Task`/`Set-Task` accept `0` (they skip the person-exists check for it). In the UI this surfaces as a virtual `UNASSIGNED = {id:0, name:"לא משובץ"}` pool row/column, appended by `boardPeopleForDays()` only when in-scope unassigned tasks exist. Anything that iterates `people` for **stats** must add `UNASSIGNED` (see `projectStats`, `statsForProjects`) or unassigned hours vanish; anything that looks a person up by id must special-case `0`.

**Field naming is snake_case everywhere** (`person_id`, `project_id`, `domain_id`, `customer_id`, `start_min`, `duration_min`, `created_at`, `closed_at`, `depends_on`) — chosen to match the front end so the UI needs no field translation. Keep new fields snake_case.

**Project dependencies** (`depends_on`: array of project ids): a project may depend on other projects **in the same customer** (crossing environments is allowed, crossing customers is rejected); self-links and cycles are rejected. Enforced by `Test-ProjectDependencies` (uses `Get-ProjectCustomerId`, `Get-ProjectDependsOn`). The UI shows two soft (non-blocking) warnings on project cards: a ⚠ **schedule** warning when the project's earliest task starts before a dependency's earliest task, and a ⛔ **missing-in-environment** warning when a dependency has no same-named project in this project's own environment. Because a stored 1-element array can serialize back as a scalar (PS 5.1), the UI's `depsOf()` normalizes array | scalar | "" | absent → array.

**Colors** are either a solid hex string (`"#3f6d8f"`) or a gradient object (`{type:"linear", angle, stops:[...]}`). Only Customer/Environment/Project carry color; a Task inherits (project color for its accent bar, environment color for its corner tag). **Environment colors must be unique** across all environments — enforced on create/update (`Test-EnvironmentColorUnique`, keyed via `ConvertTo-ColorKey`).

**Storage layer** (`Scheduler.psm1`): one JSON file per entity type in `$script:DataDir` plus `meta.json` holding id counters. `Set-SchedulerDataDir` overrides the dir (used by tests). Go through `Get-Entities` / `Save-Entities` / `Get-NextId` rather than touching files directly.

**CRUD + rules:** `New-/Get-/Set-/Remove-` per entity. Referential rules:
- Delete customer / environment: refused if it has children, unless `-Force`, which **cascades** (customer → its environments → their projects → those projects' tasks; environment → projects → tasks). People are never removed by a cascade.
- Delete project: refused if it has tasks unless `-Force` (cascade its tasks); prefer `Close-Project` (soft delete: `status="closed"`, stamps `closed_at`) over hard delete. `Open-Project` reopens.
- Delete task: always allowed. Delete person: refused if they still have tasks, **unless `-ReassignTo <otherId>`**, which moves all their tasks to that person first (`Remove-Person`).
- **`Copy-ProjectToEnvironment -Id -ToDomainId`** clones a project **and its whole dependency chain** into another environment of the same customer, rewiring the copies' `depends_on` to the target-environment equivalents and **reusing** any same-named project already there (so the copy has no missing-dependency gaps). This is the intended way to replicate a project across environments.
- **Dates are local `yyyy-MM-dd` strings, never UTC** (Israeli users must not see a day shift). `start_min` is minutes from midnight (480 = 08:00).
- **Project deadline** (`deadline`, optional local `yyyy-MM-dd` or `null`): set on create/edit via `New-/Set-Project -Deadline` (empty string clears it; validated by `Test-DateString`; `Add-Member -Force` upgrades projects created before the field existed). The front end renders a `projDeadlineHtml()` badge on project cards and the project page — neutral, ⛔ **overdue** (past & still active), or ⚠ **at-risk** (a task is scheduled after it). Individual offending tasks get a ⏰ tag via `taskPastDeadline()` / `dlFlag()` on chips, daily blocks, and project-page rows.
- **Derived deadlines — deadline pressure flows BACKWARDS along `depends_on`.** A project with a deadline makes everything it depends on urgent, even when those blockers carry no deadline themselves (SharePoint's 01/08 target is what makes SQL and Server 2025 urgent). Each project has **`lead_days`** (int, default `$script:DefaultLeadDays` = 14, 0 allowed, negatives rejected by `Test-LeadDays`): the build time **it** needs before its own deadline, and therefore how much earlier its dependencies must finish. `Get-ProjectLeadDays` defaults projects stored before the field existed; `Copy-ProjectToEnvironment` carries it to the copies. The front end's `effDeadlineOf(id)` computes, over the **reverse** dependency graph (memoized in `_effDlCache`, invalidated in `loadAll()`, cycle-guarded even though the server rejects cycles):

  > `effDl(P) = min( P's own deadline, for every active Q depending on P: effDl(Q) − leadDaysOf(Q) )`

  It **compounds** — each level subtracts its own build time, so a 3-deep chain at 14d shifts 4 weeks. It returns `{date, own, root, via}` (`own` = P's own deadline won; `root` = the project whose real deadline it ultimately derives from; `via` = the immediate dependent) or `null`. A **closed** dependent imposes nothing. `projDeadlineHtml()` shows `🎯 יעד` when `own`, else an italic `🎯 יעד נגזר … · נדרש ל־<via>` (`.pdl.derived`); `taskPastDeadline()` and every ⛔/⚠/⏰ warning now fire against `deadlineDateOf()` (the **effective** date), not `pr.deadline`. Edited via `#eLead` in the project editor.

**All-day / multi-day span tasks:** a task is either **timed** (the original: one `date` + `start_min` + `duration_min`) or an **all-day span** (`all_day:true`) that covers whole days `date`..`end_date` (inclusive, `end_date >= date` enforced; a span carries no time, so `start_min`/`duration_min` are stored as `0`). `New-/Set-Task` take `-AllDay`/`-EndDate`; the POST route + `Set-TaskFromBody` bridge `all_day`/`end_date`, and `Set-Task` normalizes on every write (all-day ⇒ valid span + zeroed time; timed ⇒ `end_date=null` + validated time). The editor's **"יום מלא / מספר ימים"** checkbox (`#tAllDay`) swaps the time row for a span row that keeps **number-of-days** (`#tDays`) and **end date** (`#tEndDate`) in sync from the start date — `#tSpanMode` chooses which one you edit — with a live `#tSpanSummary` range line; days are **inclusive** (15 days from 1/1 = 1/1..15/1). Front-end model: spans are kept **out of `taskIndex`** (which stays timed-only) in a separate `spanTasks` list; `isSpan`/`spanEnd`/`spanDayCount`/`spanCoversIso`/`spansForDayIdx` are the helpers. Rendering — the **weekly board** draws each span as connected `.spanbar` segments in every covered day column (`spanBarHtml`: rounds the true start/end edges, leaves week-crossing edges square, prints the title+range once on the first covered column — the app is RTL so the start date is the **right** edge); the **daily view** shows covering spans in an `.alldayband` above the hour grid; the **project page** and all five **print layouts** show the range / `כל היום` instead of a time. `weekStats`/`projectStats` count a span once as a **zero-hour** task; `taskPastDeadline`/`projDeadlineHtml` at-risk checks use the span's **end** date. **Duplicate:** the editor's `שכפול` button (`#tDup`, existing tasks only) calls `duplicateTask()` → `buildTaskPayload()` (shared with `saveTask`) → POST a copy → reopen the new copy for tweaking; the weekend/overlap `confirm()` guards apply to timed tasks only.

**Weekend guard (front end):** the board only renders Sun–Thu (`DAYS` = 5 days), so a task on **Fri/Sat is invisible** on the weekly/daily/per-person views (it still exists in data and shows on the project page + print report). The task editor surfaces this: `updateWeekendWarn()` shows a `#tWeekendWarn` notice when the chosen date is Fri/Sat, and `saveTask()` `confirm()`s before saving one. Weekday index comes from `parseIso(date).getDay()` (5=Fri, 6=Sat).

**Holidays** (`holidays.json`, global flat list like people — not owned by any customer): each is `{id, name, from, to}` with inclusive local `yyyy-MM-dd` range dates (`from == to` = single day). CRUD via `New-/Get-/Set-/Remove-Holiday`; validated by `Test-DateString` + an end‑≥‑start check. **Warn-but-allow, never block**: a task may still be created on a holiday date — the UI only tints the day and shows a non-blocking notice. `holidayOn(dateIso)` (front end) returns the covering holiday by string comparison over the range. Managed from the `🎌 חגים` header button (`#holModal`: add / edit / delete). The weekly board tints holiday columns (`th.holiday` + `td.day.holiday`) and labels them (`.holname`); the daily view shows a `.holbanner`; the task editor shows `#tHolWarn`. Because a store predating this feature has a `meta.json` without a `holiday` id counter, `Get-NextId` adds any missing kind on first use (so existing installs upgrade in place; no `-Depth`/BOM concerns beyond the usual).

**Task templates** (`templates.json`, global reusable library): each is `{id, name, tasks:[{title, duration_min}]}` — deliberately time-agnostic and project-agnostic (**titles + durations only**). CRUD via `New-/Get-/Set-/Remove-Template` (validated by `ConvertTo-TemplateTasks`: each task needs a title and a positive duration). **Applying** a template to a project is `Add-TemplateToProject -Id -ProjectId -Date [-StartMin 480] [-PersonId 0]` → `POST /api/templates/{id}/apply {project_id, date, start_min?, person_id?}`: it creates one task per template entry, laid out **back-to-back** from `StartMin` on `Date`, all **UNASSIGNED** by default. Deleting a template never touches tasks already created from it. PS 5.1 collapses a 1-item `tasks` array to a scalar on read, so the front end normalizes with `tplTasksOf()` (array | scalar | absent → array) — mirror this anywhere you read a template's tasks. The **`Add-TemplateToProject` return must stay unwrapped** (`return $created`, not `,@(...)`); the route re-wraps with `,@(...)` for a flat JSON array — double-wrapping produces `[[...]]`. UI: the `📋 תבניות` header button manages the library (`#tplModal`: name + task rows); `החל תבנית` on project cards / the project page opens the apply dialog (`#applyTplModal`).

**HTTP layer** (`Scheduler.psm1`): `Start-SchedulerServer` runs the `HttpListener` loop; `Invoke-ApiRoute` dispatches `Method + /api/<entity>[/<id>][/<sub>]` to the CRUD functions; `Write-JsonResponse` serializes. `GET /api/bootstrap` returns all seven collections (people, customers, environments, projects, tasks, holidays, templates) in one payload (the UI's startup call). Sub-routes/queries in use: `POST /api/projects/{id}/{close|open|copy}` (copy takes `{to_domain_id}`), `DELETE …?force=1` (cascade for customer/environment/project), `DELETE /api/people/{id}?reassign_to=N`. `Set-<Entity>FromBody` bridges a JSON body to named parameters, passing only present fields (partial updates). Errors throw and are returned as `{error}` with HTTP 400.

**Front end** (`scheduler_v3.html`): vanilla HTML/CSS/JS, no build step, no dependencies. On load it fetches `/api/bootstrap` and fills the in-memory `people/customers/domains/projects/holidays/templates` arrays + a task cache (`taskCache`, indexed by `person_id|date` in `taskIndex`), then `render()`s. Views: customers hub → environments hub → board (weekly grid / daily / projects / per-person), driven by a `nav` object (`level`, `customerId`, `domainId`) and a `mode`. Two **full-page** overlays live outside the board and are hidden by `render()` on any navigation: the print gallery (`#printPage`) and the **project page** (`#projPage`, opened by clicking a project title / "כל המשימות" on a project card) — a scrollable table of **every** task for one project across all dates (`buildProjectPage` reads `taskCache`, not the week scope). The task editor sets `returnToProject` so a save/delete from the project page reopens it instead of dropping to the board. Every mutation calls the matching endpoint then `loadAll()` to refresh. The workweek is Sun–Thu; the day window is 08:00–19:00 (`DAY_START`/`DAY_END`).

Front-end things worth knowing before editing:
- **Full entity management lives in the UI**: create/edit/delete customers & environments via ✎ pencils on hub cards; projects via card buttons (edit / copy-to-env / close / delete / + task); people via clicking a name cell (edit, with reassign-on-delete). The task editor uses **cascading Customer → Environment → Project** selects (only branches containing an active project are offered) and can **create new dependency projects inline** (typed names in the deps picker are created on save, in the project's environment, then linked).
- **Board interactions**: click an empty weekly cell or a daily track to add a task (prefilled person + time); click a chip/block to edit; plain arrow keys pan the board while **Ctrl+arrow** moves the date; drag empty board space to pan. The pan handler must **not** `preventDefault` on mousedown (only once a drag actually starts) or it kills text selection/copy.
- The top-of-board **color legend** is a matrix (customers × environment-names, cell = that env's color), shown only on the board with no customer selected.
- Global CSS `table{width:100%;min-width:900px}` and `th,td{border…}` leak into any table you add — override `width/min-width/border` (as the legend table does).

**Print reporting** (the `🖨 הדפסה` button → `#printPage` gallery + `#printout`): a self-contained subsystem near the bottom of the `<script>`. The button opens a **full-page gallery** (not a modal) with one **card per layout**, each showing a live scaled-down preview. Five layouts live in the `REPORTS` map — three team reports (`table` flat rows, `grid` person×day text matrix with one column per date, `project` grouped) and two per-person (`agenda`, `ptable`). Each is a **pure function returning an HTML string** built from `printRows()`. Mechanics that are easy to break:
- Reports render into `#printout` (which carries class `paper`). `@media print` hides `body > *` and shows only `#printout`, at `@page { size: A4 landscape }`. The report typography is scoped to `.paper` and defined **outside** the `@media print` block **on purpose**, so the exact same markup styles both the on-screen preview cards and the printed page. Don't move it back inside `@media print`.
- Print is **B&W by design**: colour coding is replaced by text columns (project / environment / customer). Don't reintroduce colour.
- Scope/range are **print-only state** (`printCustomer`, `printProject`, `printPerson`, `printPerPage`, `printFrom`, `printTo`) — deliberately independent of the board's `nav`; all default to "all"/current week. `inPrintScope()` (project filter overrides customer) + `printRangeDates()` + `printRows()` drive filtering over an **arbitrary date range**, not just the anchored week. `printRows()` labels each row's weekday from its real date via `DOW_HE` (Sun–Sat), so ranges may include Fri/Sat.
- Quick-range buttons `שבוע קודם / השבוע / שבוע הבא` set `printFrom/printTo` to week ±7. The **End date is constrained ≥ From** (`prTo` gets `min`, plus a clamp in the change handlers); **From is intentionally unconstrained** (future dates allowed) — do not put a `max` on From.
- `render()` sets `#printPage` to `display:none`, so any board navigation exits the gallery; `buildPrintPage()` rebuilds the whole page (and its previews) on every filter change.

Note there are **two** copies of `scheduler_v3.html`: the one in `TeamScheduler/` is the live app wired to the API; the copy in the repo root is the original static/mock design and is not served. `TeamScheduler/print-layouts-preview.html` is a separate, self-contained mockup (hard-coded sample data, no API) kept only as a design reference for the print layouts — also not served.

## Files

- `TeamScheduler/Scheduler.psm1` — storage, CRUD, validation, HTTP server + routing (the whole backend).
- `TeamScheduler/Run-Scheduler.ps1` — entry point.
- `TeamScheduler/scheduler_v3.html` — the served UI.
- `TeamScheduler/seed-data.json` — demo data seeded by `Import-SeedData` only when the store is empty.
- `TeamScheduler/print-layouts-preview.html` — standalone, self-contained mockup of the print layouts (design reference; not served, no API).
- `TeamScheduler/README.md` — run instructions and API table.
- `README.md` (repo root) — the GitHub landing page; keep in sync on every push (see "When pushing to GitHub").
- `docs/*.png` — screenshots referenced by the root README (captured via the screenshot recipe).
- `scheduler_v3.html` (repo root) — the original static/mock design, **not served** (the live UI is the copy under `TeamScheduler/`).
- `Scheduler_PowerShell_Spec.docx` — the original build spec.
