-- pm database. Change it with pm; after a hand edit run `pm validate`.
PRAGMA user_version = 30;

CREATE TABLE milestone (
    id             INTEGER PRIMARY KEY,
    subject        TEXT NOT NULL CHECK (trim(subject) <> ''),
    status         TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'on-hold', 'implemented')),
    body           TEXT NOT NULL DEFAULT '',               -- Markdown
    created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    implemented_at TEXT,
    queue_index    INTEGER NOT NULL DEFAULT 0,             -- its tasks are queued lowest index first, then by priority
    CONSTRAINT "implemented_at is set exactly when implemented" CHECK ((status = 'implemented') = (implemented_at IS NOT NULL))
) STRICT;

CREATE TABLE plan (
    id              INTEGER PRIMARY KEY,
    milestone_id    INTEGER NOT NULL REFERENCES milestone (id),
    subject         TEXT NOT NULL CHECK (trim(subject) <> ''),
    priority        INTEGER,                               -- NULL: 0
    body            TEXT NOT NULL CONSTRAINT "a plan needs a body" CHECK (trim(body) <> ''),
    intro           TEXT NOT NULL DEFAULT '',              -- plain English for an outsider; required by pm since schema 23
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    created_by_task INTEGER REFERENCES task (id)
) STRICT;

CREATE TABLE task (
    id              INTEGER PRIMARY KEY,
    plan_id         INTEGER REFERENCES plan (id),          -- NULL: exec, and only exec
    subject         TEXT NOT NULL CHECK (trim(subject) <> ''),
    kind            TEXT NOT NULL DEFAULT 'work' CHECK (kind IN ('work', 'plan', 'masterplan', 'split', 'cleanup', 'revise', 'investigate', 'merge', 'exec')),
    status          TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'done', 'dropped')),
    priority        INTEGER,                               -- NULL: the plan's
    note            TEXT,                                  -- done: date, files; dropped: reason
    body            TEXT NOT NULL DEFAULT '',              -- Markdown
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    retired_at      TEXT,                                  -- done or dropped
    created_by_task INTEGER REFERENCES task (id),
    web             INTEGER NOT NULL DEFAULT 0 CHECK (web IN (0, 1)),  -- 1: its worker gets WebSearch and WebFetch
    model           TEXT CHECK (model IS NULL OR trim(model) <> ''),  -- claude --model; NULL: [models] in the config
    worktree        TEXT CHECK (worktree GLOB '[a-z0-9]*' AND worktree NOT GLOB '*[^a-z0-9-]*'),  -- [worktrees]; NULL: the trunk
    CONSTRAINT "an open task needs a body" CHECK (status <> 'open' OR trim(body) <> ''),
    CONSTRAINT "retired_at is set exactly when done or dropped" CHECK ((status = 'open') = (retired_at IS NULL)),
    CONSTRAINT "an exec task has no plan, every other task has one" CHECK ((kind = 'exec') = (plan_id IS NULL)),
    CONSTRAINT "exec, planning and cleanup tasks run in the trunk" CHECK (kind NOT IN ('exec', 'masterplan', 'split', 'revise', 'cleanup') OR worktree IS NULL)
) STRICT;

CREATE TABLE decision (
    id              INTEGER PRIMARY KEY,
    subject         TEXT NOT NULL CHECK (trim(subject) <> ''),
    status          TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'answered', 'irrelevant')),
    options         TEXT NOT NULL DEFAULT '[]' CHECK (json_type(options) = 'array'),  -- recommended first
    body            TEXT NOT NULL DEFAULT '',
    intro           TEXT NOT NULL DEFAULT '',              -- plain English: what is to be decided; required since schema 23
    answer          TEXT,
    reason          TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    closed_at       TEXT,
    created_by_task INTEGER REFERENCES task (id),
    signoff         TEXT CHECK (signoff IN ('masterplan', 'plan', 'task-queue', 'web')),  -- made by pm; NULL: a question
    kind            TEXT NOT NULL DEFAULT 'rule' CHECK (kind IN ('rule', 'once')),  -- once: a go-ahead, not in the log
    decided_by_task INTEGER REFERENCES task (id),          -- a worker's own choice (`pm decision record`); NULL: the human
    consequences    TEXT NOT NULL DEFAULT '',              -- what changed because of the answer; appended
    CONSTRAINT "a sign-off is only approved"
    CHECK (signoff IS NULL OR status <> 'irrelevant' AND coalesce(answer, 'approve') = 'approve'),
    CONSTRAINT "only an answered question has a decider and consequences"
    CHECK (status = 'answered' AND signoff IS NULL OR decided_by_task IS NULL AND consequences = ''),
    CONSTRAINT "pending: no answer, reason or closed_at; answered: answer and closed_at; irrelevant: reason and closed_at"
    CHECK (status = 'pending' AND answer IS NULL AND reason IS NULL AND closed_at IS NULL
           OR status = 'answered' AND answer IS NOT NULL AND closed_at IS NOT NULL
           OR status = 'irrelevant' AND reason IS NOT NULL AND closed_at IS NOT NULL)
) STRICT;

CREATE TABLE run (                                         -- one worker run of `pm run`
    id                    INTEGER PRIMARY KEY,
    task_id               INTEGER NOT NULL REFERENCES task (id),
    started_at            TEXT NOT NULL,
    ended_at              TEXT,                            -- NULL: running
    result                TEXT NOT NULL CHECK (result IN ('running', 'done', 'blocked', 'failed', 'limit', 'killed')),
    reason                TEXT,                            -- failed: why; limit: the message; killed: by `pm kill`
    exit_code             INTEGER,
    base_commit           TEXT,                            -- HEAD when the run started
    worktree              TEXT,                            -- the task's work tree then; NULL: the trunk
    model                 TEXT,                            -- from here on: the worker's JSON output, if any
    session_id            TEXT,
    continues_run         INTEGER REFERENCES run (id),     -- warm hand-off: the run whose Claude session it resumed
    turns                 INTEGER,
    input_tokens          INTEGER,
    output_tokens         INTEGER,
    cache_read_tokens     INTEGER,
    cache_creation_tokens INTEGER,
    cost_usd              REAL,
    context_tokens        INTEGER,                         -- the session's context at the run's last turn
    cache_minutes         INTEGER,                         -- its prompt cache's lifetime: 60 (1 h writes) or 5
    pid                   INTEGER,                         -- the `pm run` process
    CONSTRAINT "ended_at is set exactly when not running" CHECK ((result = 'running') = (ended_at IS NULL))
) STRICT;

CREATE TABLE task_decision (                               -- the task waits while the decision is pending
    task_id     INTEGER NOT NULL REFERENCES task (id),
    decision_id INTEGER NOT NULL REFERENCES decision (id),
    PRIMARY KEY (task_id, decision_id)
) STRICT;

CREATE TABLE task_prerequisite_tasks (                     -- the task waits until the prerequisite task is done
    task_id         INTEGER NOT NULL REFERENCES task (id),
    prerequisite_id INTEGER NOT NULL REFERENCES task (id),
    PRIMARY KEY (task_id, prerequisite_id),
    CHECK (task_id <> prerequisite_id)
) STRICT;

CREATE TABLE decision_supersedes (                         -- decision_id's answer replaces superseded_id's
    decision_id   INTEGER NOT NULL REFERENCES decision (id),
    superseded_id INTEGER NOT NULL REFERENCES decision (id),
    note          TEXT NOT NULL DEFAULT '',                -- '': all of it; else partly, e.g. "scope only"
    PRIMARY KEY (decision_id, superseded_id),
    CHECK (decision_id <> superseded_id)
) STRICT;

CREATE TABLE summary (                                     -- an executive summary, written by a summary task
    id          INTEGER PRIMARY KEY,
    task_id     INTEGER NOT NULL REFERENCES task (id),
    body        TEXT NOT NULL CHECK (trim(body) <> ''),     -- Markdown
    head_commit TEXT,                                      -- git HEAD when written: the next summary's delta starts here
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
) STRICT;

CREATE TABLE resource_use_report (                         -- where the effort went, by category; by an exec task
    id          INTEGER PRIMARY KEY,
    task_id     INTEGER NOT NULL REFERENCES task (id),
    head_commit TEXT,                                      -- git HEAD when written
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
) STRICT;

CREATE TABLE resource_use_category (                       -- one of a report's mutually exclusive categories
    id        INTEGER PRIMARY KEY,
    report_id INTEGER NOT NULL REFERENCES resource_use_report (id),
    name      TEXT NOT NULL CHECK (trim(name) <> ''),
    criteria  TEXT NOT NULL CHECK (trim(criteria) <> ''),  -- one sentence: which tasks belong here
    UNIQUE (report_id, name)
) STRICT;

CREATE TABLE resource_use_task (                           -- each task done when the report was written, in one category
    report_id   INTEGER NOT NULL REFERENCES resource_use_report (id),
    task_id     INTEGER NOT NULL REFERENCES task (id),
    category_id INTEGER NOT NULL REFERENCES resource_use_category (id),
    PRIMARY KEY (report_id, task_id)
) STRICT;

CREATE TABLE custom_report (                               -- the human's question, answered in one paragraph by an exec task
    id          INTEGER PRIMARY KEY,
    task_id     INTEGER NOT NULL UNIQUE REFERENCES task (id),
    question    TEXT NOT NULL CHECK (trim(question) <> ''),
    answer      TEXT,                                      -- NULL: not answered yet
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    answered_at TEXT,
    CONSTRAINT "answered_at is set exactly when answered" CHECK ((answer IS NULL) = (answered_at IS NULL))
) STRICT;

CREATE INDEX plan_milestone ON plan (milestone_id);

CREATE INDEX task_plan ON task (plan_id);

CREATE INDEX task_decision_decision ON task_decision (decision_id);

CREATE INDEX task_prerequisite ON task_prerequisite_tasks (prerequisite_id);

CREATE INDEX decision_superseded ON decision_supersedes (superseded_id);

CREATE INDEX run_task ON run (task_id);

CREATE UNIQUE INDEX run_running ON run (coalesce(worktree, '')) WHERE result = 'running';

CREATE VIEW queue AS
SELECT coalesce(t.priority, p.priority, 0) AS priority, t.id AS task_id, t.subject, t.kind,
       coalesce(m.queue_index, 0) AS queue_index, t.worktree
FROM task t
LEFT JOIN plan p ON p.id = t.plan_id
LEFT JOIN milestone m ON m.id = p.milestone_id
WHERE (m.status = 'open' OR t.kind = 'exec') AND t.status = 'open'
  AND NOT EXISTS (SELECT 1 FROM task_decision td JOIN decision d ON d.id = td.decision_id
                  WHERE td.task_id = t.id AND d.status = 'pending')
  AND NOT EXISTS (SELECT 1 FROM task_prerequisite_tasks r JOIN task q ON q.id = r.prerequisite_id
                  WHERE r.task_id = t.id AND q.status <> 'done')
ORDER BY coalesce(m.queue_index, 0), priority DESC, m.id, p.id, t.id;

INSERT INTO milestone (id, subject, status, body, created_at, implemented_at, queue_index) VALUES (1, 'first version build', 'implemented', 'build the app according to the idea specified in airbnb-bookkeeping-spec.md

* create an architecture-spec.md early on and have me decide on it before continuing
* apart from that, keep human decisions minimal, follow your own recommendations', '2026-10-23T19:11:39Z', '2026-10-23T20:31:38Z', 0);
INSERT INTO milestone (id, subject, status, body, created_at, implemented_at, queue_index) VALUES (2, 'visual design update', 'implemented', 'use daisy ui and tailwind css to make everything look more visually appealing. add playful elements that refer to bookkeeping and accounting; where possible re-create a spreadsheet feel.

* don''t change functionality
* add a favicon', '2026-10-23T22:34:21Z', '2026-10-24T00:33:52Z', 0);
INSERT INTO milestone (id, subject, status, body, created_at, implemented_at, queue_index) VALUES (3, 'add a proper client-side framework', 'implemented', 'the architecture spec are terrible. we want a proper client-side framework. your choice. we totally can have build steps. this becomes a classic web app, only that its server runs locally on my pc.', '2026-10-23T22:40:12Z', '2026-10-23T23:25:52Z', 0);
INSERT INTO milestone (id, subject, status, body, created_at, implemented_at, queue_index) VALUES (4, 'first round of improvements', 'open', 'the spreadsheet look is great, but the "new expense" button should just be a plus and the form to add an expense should be inlined into the spreadsheet-styled table; same with recurring expense; the date field must be pre-filled with today''s date

the "new booking" button doesn''t make sense. correct me if i am wrong, but i want all the income from airbnb enter the accounting via the .csv export 

i don''t understand "blocked days" and it can be probably removed completely

i don''t understand the time page

i don''t understand the exchange rate page. i want the whole tool to run internally on USD. whenever an expense or income is added, the exchange rate that correspond to its date must be fetched to convert to USD if necessary. e.g. for income from airbnb the reference date would be the first day of booking. for recurring expenses it would be the first day of the month. the page should then allow to change the display currency: all amounts convert to COP or EUR based on the current exchange rate, fetched at the moment the currency is changed

i don''t understand the quit button', '2026-10-24T03:15:59Z', NULL, 0);

INSERT INTO plan (id, milestone_id, subject, priority, body, intro, created_at, created_by_task) VALUES (1, 1, 'masterplan', 1000, 'Build the first version of the app described in `airbnb-bookkeeping-spec.md`: a local, single-user, single-property bookkeeping tool that allocates all income and costs per calendar day, imports the Airbnb transaction CSV (`airbnb_.csv` is a real sample), and shows a dashboard with metrics, a rolling 90-day chart and an expense breakdown. Only the spec''s "v1" features are in scope; its "Later" list is not.

**The tasks of this masterplan are not implementation work: each of them writes the plan for one part** (`--kind plan`), and that plan is then split into work tasks.

Ground rules from `milestone 1: first version build`:
- An `architecture-spec.md` comes first, and the human decides on it before any other part is planned or built.
- Apart from that, keep human decisions to a minimum: workers follow their own recommendations and record lasting choices with `pm decision record`.

## Order and dependencies

- Part 1 runs first. Its plan''s work task writes `architecture-spec.md` and raises the one human decision ("approve the architecture"); every other masterplan task waits for that decision (`pm task-pending-decision`), so nothing else is planned against an unapproved architecture.
- The plan-writing tasks for parts 2–9 run in the listed order, each requiring the previous one, so a plan writer can see the earlier plans'' task ids and add `--requires` across plans (e.g. the dashboard''s tasks require the metrics tasks).
- Suggested plan priorities are given per part; plan writers may adjust them per the usual scale.

## Parts

### 1. Architecture spec (priority 950)
- One work task (`--model opus`) writes `architecture-spec.md`, then raises the approval decision and links the remaining masterplan tasks to it as pending.
- Must settle the spec''s open decisions with a recommendation each: tech stack and UI style (desktop GUI, TUI, or a local web server on localhost), how Nix packaging looks (flake package, dev shell, NixOS / home-manager module), code layout, test approach, DB location and migrations.
- Must settle the Airbnb CSV mapping, checked against `airbnb_.csv`: columns are `Date, Type (Reservation/Payout/…), Confirmation code, Start date, End date, Nights, Currency, Amount, Paid out, Service fee, Cleaning fee, Gross earnings, …`; dates are `MM/DD/YYYY`; reservations come in **COP and USD** and payouts in **EUR**, while the spec stores money as integer COP. The spec must say how non-COP reservations become COP (e.g. store original currency and amount plus an exchange rate) — this is a real gap in `airbnb-bookkeeping-spec.md`.
- Short and readable for the owner: one recommended option per question, alternatives only where the choice matters.

### 2. Project skeleton and Nix packaging (priority 920)
- Source tree, build, test runner, linter/formatter per the architecture.
- `flake.nix`: keep the existing dev shell (`pm`, git) and add the toolchain; add the app package (`nix build`) and a runnable app (`nix run`).
- A trivial app that starts and a trivial test that passes, so later parts only add code.

### 3. Database schema and storage (priority 900)
- SQLite schema for `bookings`, `expenses`, `recurring_expenses`, `blocked_days`, `time_log`, `settings`, plus whatever part 1 adds for currencies.
- Migrations from an empty DB; DB at the default local path (outside Dropbox), overridable for tests.
- Constraints from the spec: integer COP, ISO dates, exclusive check-out, unique confirmation code, `useful_life_days` required for capex, `booking_id` for per-booking costs.
- Settings defaults (hourly value of own time, long-term rental benchmark, currency, per-booking allocation mode).

### 4. Daily allocation engine (priority 650)
- The core principle: build the per-day view `days` (`date, available, occupied, income, cost_* , hours, profit`).
- Rules: booking net payout ÷ nights on each stayed night, only up to today; fixed monthly costs ÷ days of the month; per-night costs on occupied nights; per-booking costs on check-in or spread (setting); capex ÷ useful life from the purchase date; maintenance and tax on their date; blocked days not available.
- Generating monthly `expenses` rows from `recurring_expenses` (idempotent).
- Integer rounding rule so per-day amounts sum exactly to the original amount; thorough unit tests (month lengths, leap years, stays across months, future bookings).

### 5. Metrics (priority 600)
- For any date range: occupancy, ADR, RevPAR, profit, variable cost per night, break-even occupancy, profit vs. long-term rental, profit per hour and profit after valuing own time, remaining capex book value.
- Standard ranges: all-time, last 30 and 90 days, calendar month, custom.
- Rolling 90-day series of RevPAR, ADR and occupancy; expense breakdown by category.
- Defined behaviour for division by zero (no occupied nights, no hours); unit tests on small hand-checked data.

### 6. Airbnb CSV import (priority 700)
- Parse the transaction-history CSV per the mapping in `architecture-spec.md` (BOM, `MM/DD/YYYY`, multiple rows per reservation, currencies).
- Create or update bookings, dedup by confirmation code; ignore or report payout and other rows as the spec decides.
- Import summary (new, updated, skipped, problems) for the user.
- Tests against `airbnb_.csv` (or a trimmed copy as a fixture).

### 7. Data entry screens (priority 450)
- Create, list, edit and delete bookings, expenses, recurring expenses, blocked days and time log entries, plus a settings screen.
- The CSV import reachable from the UI.
- Input validation matching the schema rules (e.g. capex needs a useful life).

### 8. Dashboard and charts (priority 400)
- Metrics for the standard ranges side by side, and for a custom range.
- Chart of rolling 90-day RevPAR, ADR and occupancy over time.
- Expense breakdown by category for a chosen range.
- Plain, readable presentation; no visual polish beyond that in v1.

### 9. Backup, install and final check (priority 300)
- Backup with `sqlite3 … ".backup …"` into a Dropbox folder, named `books-YYYY-MM-DD.db`, keeping the last N (e.g. 30): on app exit and via a daily systemd user timer, shipped as a NixOS / home-manager module in the flake.
- Restore described in a README section (copy a backup over the live file while the app is closed).
- README: install, run, import, backup and restore.
- End-to-end check: fresh DB, import `airbnb_.csv`, add a few expenses, open the dashboard and verify the numbers by hand for one month.', 'This is the overall roadmap for building the first working version of a small, private bookkeeping app for one Airbnb apartment. The app turns every booking and every cost into amounts per calendar day, so it can answer whether hosting pays off, whether prices are set well, and how things are trending. The roadmap splits the build into parts, starting with a short architecture document the owner approves before anything else is built, and ending with a check against the real Airbnb export.', '2026-10-23T19:11:39Z', NULL);
INSERT INTO plan (id, milestone_id, subject, priority, body, intro, created_at, created_by_task) VALUES (2, 1, 'architecture spec', 950, 'Part 1 of `plan 1: masterplan`. Produces `architecture-spec.md` and gets the owner''s approval of it before any other part is planned or built.

## The work task (one, `--model opus`, work tree `main`)

Subject: "write architecture-spec.md and ask for its approval".

Inputs: `airbnb-bookkeeping-spec.md` (the product idea), `airbnb_.csv` (a real Airbnb transaction-history export), the existing `flake.nix`.

Writes `architecture-spec.md` at the repo root: short and readable for the owner, **one recommended option per question**, alternatives only where the choice really matters. It must settle:

- **Tech stack and UI style:** language, libraries, and whether the UI is a desktop GUI, a TUI, or a local web server on localhost; how charts are drawn.
- **Nix packaging:** flake package (`nix build`), `nix run`, dev shell (keep `pm` and git, add the toolchain), and the NixOS / home-manager module for the backup timer.
- **Code layout:** source tree and module boundaries (storage, allocation engine, metrics, import, UI).
- **Test approach:** test runner, unit tests for allocation and metrics, fixture for the CSV import.
- **DB location and migrations:** default path (outside Dropbox, e.g. under `$XDG_DATA_HOME`), override for tests, how schema migrations run.
- **Airbnb CSV mapping**, checked against `airbnb_.csv`:
  - columns (`Date, Arriving by date, Type, Confirmation code, Booking date, Start date, End date, Nights, Guest, Listing, Details, Reference code, Currency, Amount, Paid out, Service fee, Fast pay fee, Cleaning fee, Gross earnings, Airbnb remitted tax, Earnings year`), UTF-8 BOM, dates `MM/DD/YYYY`;
  - which row types become bookings, which are ignored or reported (payouts, adjustments, …), and what happens with several rows per confirmation code;
  - **currencies:** reservations come in COP and USD, payouts in EUR, but the spec stores integer COP. The spec must say how a non-COP amount becomes COP (recommended direction: keep original currency and amount plus an exchange rate and the derived integer COP), where the rate comes from, and whether EUR payouts are used at all.

Then, in the same task:

1. Stage `architecture-spec.md`.
2. Raise one human decision "approve the architecture" with `pm decision add` (intro in plain English; the body points to `architecture-spec.md` and lists its main recommendations; option "approve" recommended).
3. Make every still-open task of `plan 1: masterplan` wait for it: `pm task-pending-decision <task> <decision>` for each (at least tasks 4–11 as far as still open), so no other part is planned against an unapproved architecture.
4. Record lasting choices that are not part of the human''s approval with `pm decision record`, if any.

Done when `architecture-spec.md` is staged, the decision exists, and the open masterplan tasks are pending on it.

## Ordering (the split must do this)

The other masterplan tasks have priority 1000 and would otherwise run before this plan''s work task. After creating the work task, the split must run `pm task requires 4 <work task id>` so `task 4: write the plan for part 2: project skeleton and Nix packaging` waits for it; tasks 5–11 already chain behind task 4.', 'Before any code is written, the owner needs a short document that fixes the big technical choices for the bookkeeping app: what it is built with, what the screen looks like, how it is installed, where the data file lives, and how the Airbnb export is read, including how bookings paid in dollars become pesos. Writing this down first, and having the owner approve it, means every later piece is built on choices the owner has agreed to, instead of being reworked afterwards.', '2026-10-23T19:20:02Z', 3);
INSERT INTO plan (id, milestone_id, subject, priority, body, intro, created_at, created_by_task) VALUES (3, 1, 'project skeleton and Nix packaging', 920, 'Part 2 of `plan 1: masterplan`. Builds the empty frame of the app as fixed in `architecture-spec.md` (approved, `decision 3: approve the architecture`): Python 3, Flask + Jinja2 + waitress, pytest, ruff, everything from nixpkgs, app and command name `airbnb-books`.

Out of scope here (later parts): DB, migrations, `config.py` paths (part 3), the backup command and the NixOS / home-manager module (part 9), real pages.

## Task 1: Python project skeleton (work tree `main`)

- `pyproject.toml` (setuptools build backend, `src/` layout): package `airbnb_books`, dependencies `flask`, `jinja2`, `waitress`; console script `airbnb-books = airbnb_books.cli:main`; pytest config (`testpaths = ["tests"]`); ruff config (line length 100, rules `E,F,I,UP,B`, ruff format).
- `src/airbnb_books/__init__.py`, `cli.py`, `web/__init__.py`, `web/app.py`, `web/templates/index.html`:
  - `web/app.py`: `create_app()` factory returning a Flask app with one route `/` that renders a placeholder page ("airbnb-books" and the version).
  - `cli.py`: `argparse` with subcommand `serve` (the default when none is given): starts waitress on `127.0.0.1`, a free port unless `--port` is given, prints the URL, opens the browser unless `--no-browser`; Ctrl-C stops it cleanly. Other subcommands from the spec (`backup`, `import`, `migrate`) are not added yet.
- `tests/test_web.py`: Flask test client, `GET /` returns 200 and contains "airbnb-books".
- `flake.nix` dev shell: keep `pm`, the pm dashboard and git; add `python3.withPackages` (flask, jinja2, waitress, pytest), `ruff`, `sqlite`. The shell must let `pytest` import the package from `src/` without installing it (e.g. `pythonpath = ["src"]` in the pytest config).
- `.gitignore`: `__pycache__/`, `*.egg-info/`, `.pytest_cache/`, `.ruff_cache/`, `result`.
- Done when, inside `nix develop`: `pytest` passes, `ruff check` and `ruff format --check` are clean, and `python -m airbnb_books.cli --no-browser` (or `PYTHONPATH=src …`) serves the page on localhost (check with `curl`, then stop it by PID).

## Task 2: Nix package and app (work tree `main`, requires task 1)

- `flake.nix`: `packages.default` = `python3Packages.buildPythonApplication` from `pyproject.toml` (`pyproject = true`, `build-system = [ setuptools ]`, dependencies from nixpkgs, `nativeCheckInputs = [ pytestCheckHook ]` so the tests run in the build); `apps.default` runs `bin/airbnb-books`; `checks.default` = the package, plus a ruff check derivation (`ruff check` and `ruff format --check` over the source), so `nix flake check` runs tests and lint.
- Keep the existing `devShells.default`; for all listed systems.
- Done when `nix build` succeeds (tests run in it), `nix flake check` passes, and `nix run . -- --no-browser` serves the page on localhost (check with `curl`, then stop it by PID).', 'Before any bookkeeping feature is written, the app needs an empty but working frame: a place for the code, a way to run its tests and check its style, and a way to install and start it with the owner''s Nix setup. This part builds that frame with a tiny app that only starts and shows one page, and one test that passes. Every later part then just adds its own code and tests to it, instead of each one fighting with tooling.', '2026-10-23T19:30:52Z', 4);
INSERT INTO plan (id, milestone_id, subject, priority, body, intro, created_at, created_by_task) VALUES (4, 1, 'database schema and storage', 900, 'Part 3 of `plan 1: masterplan`. Builds the storage layer fixed in `architecture-spec.md` (approved, `decision 3: approve the architecture`), sections 3, 5, 6 and 7, for the data model of `airbnb-bookkeeping-spec.md`.

Out of scope (later parts): the daily allocation and generating monthly expenses from recurring ones (part 4; this part only gives the table and a dedup key), parsing the CSV (part 6), screens (part 7), the backup itself (part 9; this part only leaves a hook for it).

## Ground rules

- Python''s `sqlite3`; **only `storage/` contains SQL**; the rest of the app uses the dataclasses in `model.py`.
- All tables `STRICT` (SQLite ≥ 3.37; nixpkgs has 3.5x), `PRAGMA foreign_keys = ON` on every connection.
- Money: `INTEGER` whole COP. Original foreign amounts: `INTEGER` minor units (cents). Rates: `INTEGER` COP per unit in hundredths (4123.45 → 412345).
- Dates: ISO `TEXT`, checked with `CHECK (date(x) IS x)`; months `YYYY-MM`. Check-out exclusive.
- Own time is stored as **whole minutes** (no floats anywhere).
- Booking money totals (`gross`, `airbnb_fee`, `net_payout`) are **not stored**: a view sums them from `booking_lines`; a hand-entered booking gets one line of type `Manual`. One source of truth, nothing to keep in sync after a rate change.

## Schema (`storage/migrations/0001_init.sql`)

- `bookings`: `id`, `airbnb_code` (unique, NULL allowed for hand-entered stays without one), `listing`, `guest_name`, `check_in`, `check_out` (`check_out > check_in`), `guests` (NULL or > 0), `notes`.
- `booking_lines`: `id`, `booking_id` (→ bookings, `ON DELETE CASCADE`), `type` (`Reservation`, `Adjustment`, `Resolution Adjustment`, `Resolution Payout`, `Co-Host payout`, `Manual`), `date`, `currency` (3 upper-case letters), `amount_minor`, `service_fee_minor`, `cleaning_fee_minor`, `gross_minor` (NULL allowed), `rate` (hundredths; NULL = no rate yet; COP lines 100), `amount_cop` (NULL until a rate exists). Unique `(booking_id, type, date, currency, amount_minor)`: the import''s dedup key.
- View `booking_totals`: per booking `net_payout` (Σ `amount_cop` of all lines except `Co-Host payout`), `cohost_cost` (−Σ of co-host lines, a positive cost), `gross`, `airbnb_fee` (converted with each line''s rate), `needs_rate` (any line with `amount_cop` NULL), nights.
- `exchange_rates`: `date`, `currency`, `rate` (> 0); primary key `(date, currency)`.
- `expenses`: `id`, `date`, `amount`, `category` (`fixed`, `per_night`, `per_booking`, `maintenance`, `capex`, `tax`), `booking_id` (→ bookings, `ON DELETE RESTRICT`; required for `per_booking`), `useful_life_days` (required and > 0 for `capex`, NULL otherwise), `description`, `recurring_expense_id` (→ recurring_expenses, `ON DELETE SET NULL`), unique `(recurring_expense_id, date)` so generating a month twice is a no-op.
- `recurring_expenses`: `id`, `description`, `amount`, `category` (`fixed`, `per_night`, `maintenance`, `tax`: the ones needing no booking or useful life), `start_month`, `end_month` (NULL or ≥ start).
- `blocked_days`: `date` primary key, `reason` (`buffer`, `owner`, `maintenance`, `other`), `note`.
- `time_log`: `id`, `date`, `minutes` (> 0), `booking_id` (→ bookings, `ON DELETE SET NULL`), `description`.
- `settings`: `key` primary key, `value` TEXT. Defaults live in code, not in the table (a new setting needs no migration):
  - `hourly_value_cop` = 0 (own time not valued until set)
  - `long_term_rent_cop_per_month` = 0 (no benchmark until set)
  - `currency` = `COP` (fixed in v1)
  - `per_booking_allocation` = `check_in` (or `spread`)
  - `property_listings` = empty list (JSON; empty = not chosen yet, the import asks)
  - `backup_keep` = 30

## Tasks

### 1. Paths, connection and migrations runner (work tree `main`)
- Requires the task "Python project skeleton" of `plan 3: project skeleton and Nix packaging` (the split of plan 3 creates it; use its id).
- `config.py`: DB path from `--db`, else env `AIRBNB_BOOKS_DB`, else `$XDG_DATA_HOME/airbnb-books/books.db` (`~/.local/share/…` when unset); creates the parent directory. Refuses (clear error) a DB path inside a directory named `Dropbox`. Backup dir resolution (`--backup-dir`, `AIRBNB_BOOKS_BACKUP_DIR`, default `~/Dropbox/airbnb-books`) is added here too, so part 9 only uses it.
- `storage/db.py`: `connect(path)` (foreign keys on, `sqlite3.Row`, ISO text dates), `migrate(conn, before_migrate=None)`: applies the numbered files in `storage/migrations/` above `PRAGMA user_version`, each in one transaction that also sets `user_version`; calls `before_migrate(path)` once when the DB is not new and something is pending (part 9 passes the backup). Migration files are packaged (package data in `pyproject.toml`, so `nix build` includes them).
- `cli.py`: global `--db`; subcommand `migrate`; `serve` migrates before starting.
- A placeholder `0001_init.sql` (one trivial table is fine) so the runner is testable; task 2 replaces it before release.
- Tests (`tests/test_storage.py`, `tmp_path`): new DB gets all migrations; second run applies nothing; a failing migration rolls back and leaves `user_version`; hook called only for an existing DB with pending migrations; path resolution order; Dropbox refusal.
- Done when `pytest`, `ruff check`, `ruff format --check` pass and `airbnb-books --db /tmp/x.db migrate` creates the file.

### 2. Initial schema (work tree `main`, requires task 1)
- Write the real `0001_init.sql` per the schema above (tables, constraints, view, indexes on `booking_lines(booking_id)`, `expenses(date)`, `time_log(date)`).
- Tests insert raw SQL and assert each constraint: bad date, `check_out <= check_in`, duplicate code, capex without useful life, per-booking without booking, unknown category/reason/type, float or text in a money column (STRICT), deleting a booking with expenses fails, its lines cascade, duplicate line rejected, duplicate recurring month rejected; `booking_totals` sums on a small hand-checked example (COP + USD line with rate, co-host line, line without rate → `needs_rate`).
- Done when the tests and lint pass.

### 3. Model and repository: bookings, lines, exchange rates (work tree `main`, requires task 2)
- `model.py`: dataclasses `Booking` (with totals and `needs_rate`), `BookingLine`, `ExchangeRate`.
- `money.py`: `to_cop(amount_minor, rate) -> int` = amount_minor × rate / 10 000, rounded half away from zero, integer arithmetic only.
- `storage/repo.py`: create / get / list (by date range, by listing) / update / delete bookings; a hand-entered booking is created with its `Manual` line (amount in COP) and editing its amount edits that line; add lines (ignoring duplicates, returning whether new) for the import; find booking by code; exchange rates CRUD and `rate_for(currency, date)` (latest on or before); `recompute_lines()` fills or updates `rate` / `amount_cop` of every non-COP line from `exchange_rates`, called after any rate change.
- Tests: CRUD round trips, totals, rate lookup on/before the date, recompute after adding and after changing a rate, `to_cop` rounding (incl. negatives).

### 4. Repository: expenses, recurring expenses, blocked days, time log, settings (work tree `main`, requires task 3)
- `model.py`: `Expense`, `RecurringExpense`, `BlockedDay`, `TimeEntry`, `Settings` (typed fields with the defaults above).
- `storage/repo.py`: CRUD for each; list by date range; `insert_generated_expense` that ignores an existing `(recurring_expense_id, date)` (used by part 4); `load_settings()` / `save_settings()` (defaults for missing keys, `property_listings` as JSON); one `load_inputs(conn)` returning everything the allocation engine needs (bookings with totals and co-host cost, expenses, blocked days, time log, settings) as dataclasses.
- Constraint violations surface as one `ValidationError` with a readable message (for the screens of part 7).
- Tests: CRUD round trips, defaults, settings round trip, the generated-expense dedup, `load_inputs` on a small DB.', 'The app keeps all its records (stays, guest payments, costs, blocked days, hours worked, exchange rates and settings) in one small database file on the owner''s computer. This part designs that file''s layout, the rules that keep the data sound (amounts in whole pesos, valid dates, a useful life for every large purchase), and the code every other part uses to read and write it. It also makes sure the file is created and upgraded automatically, lives outside Dropbox, and that tests never touch the real data.', '2026-10-23T19:32:15Z', 5);
INSERT INTO plan (id, milestone_id, subject, priority, body, intro, created_at, created_by_task) VALUES (5, 1, 'daily allocation engine', 650, 'Part 4 of `plan 1: masterplan`. Builds `allocation.py` (pure: inputs + today → `list[Day]`) and the generation of monthly expenses from recurring templates, as fixed in `architecture-spec.md` section 3 (approved, `decision 3: approve the architecture`) for the rules of `airbnb-bookkeeping-spec.md` ("Core principle", "Derived daily view").

Inputs come from `load_inputs(conn)` and the dataclasses of `plan 4: database schema and storage` (its task "Repository: expenses, recurring expenses, blocked days, time log, settings"). Out of scope: metrics, ranges, rolling series, capex book value (part 5), screens (part 7).

## Rules

- **Rounding:** `split(amount, n) -> list[int]`: each of the n days gets `amount // n`, the first `amount % n` days one more (Python floor semantics, so negative amounts work too). Every allocated item sums exactly to its amount.
- **Range:** days from `start` (default: earliest date of any booking, expense, blocked day or time entry) to `today` inclusive. Each item is split over its **full** span, future days included, and only days ≤ today are kept (`decision 7: the per-day view ends today; nothing after today is counted`). No clock inside the engine: `today` is a parameter.
- **Bookings:** `net_payout` split over the nights `[check_in, check_out)`; those days are `occupied`. Overlapping bookings: occupied once, incomes add. Lines without a rate are simply missing from `net_payout` (the dashboard shows the `needs_rate` count; not the engine''s job).
- **Available:** a day is available unless it is a blocked day; an occupied night is always available (a booking wins over a block).
- **fixed:** split over all days of the expense''s calendar month (28–31).
- **per_night:** split over the occupied nights of the expense''s month; none → over all days of the month (`decision 8: a per-night expense is spread over the occupied nights of its month`).
- **per_booking** (expense with `booking_id`) and the booking''s **co-host cost**: setting `per_booking_allocation` = `check_in` → whole amount on the check-in day; `spread` → split over the booking''s nights. The expense''s own date is ignored. Both go to `cost_per_booking` (`architecture-spec.md` section 7).
- **capex:** split over `useful_life_days` days starting on the purchase date.
- **maintenance, tax:** whole amount on their date.
- **Time:** `minutes` per day summed from `time_log` (`decision 6: own time is stored in whole minutes`); the `days` column `hours` is `minutes` here, metrics converts.
- **Day:** `date, available, occupied, income, cost_fixed, cost_per_night, cost_per_booking, cost_maintenance, cost_capex, cost_tax, minutes`, property `profit` = income − all costs. All ints/bools.
- **Recurring templates** (`decision 9: monthly expenses generated from templates are dated the 1st and come back if deleted`): one expense per template and month from `start_month` to `min(end_month, month of today)`, dated `YYYY-MM-01`, copied amount, category, description; inserted with `insert_generated_expense` (no-op if it exists).

## Tasks

### 1. Day model, split helper and income/occupancy (work tree `main`, `--model opus`)
- Requires plan 4''s task "Repository: expenses, recurring expenses, blocked days, time log, settings" (use its id from the split of plan 4).
- `model.py`: `Day` dataclass as above. `allocation.py`: `split`, calendar helpers (days in month, date range, months between), `allocate(inputs, today, start=None) -> list[Day]` with bookings, availability, blocked days and time log; cost columns stay 0 for now.
- `tests/test_allocation.py`: `split` sums exactly for many (amount, n) incl. negative and `amount < n`; a stay across a month end and across a year end; a stay running past today (only past nights, no future rows); a future booking (nothing); overlapping bookings; blocked + booked same day; default start; empty inputs → empty list.

### 2. Cost rules (work tree `main`, `--model opus`, requires task 1)
- Add fixed, per-night (with fallback), per-booking and co-host (both modes), capex, maintenance and tax to `allocate`.
- Tests with hand-checked numbers: fixed in February of a leap year (29 days) and a non-leap year, 30- and 31-day months, a fixed expense dated mid-month covers its whole month; per-night over the month''s occupied nights and the no-occupancy fallback; per-booking on check-in vs spread, booking across months; co-host cost; capex across a leap day and its total after full life equals the amount; capex starting before `start`; maintenance and tax on their date; every test also checks that each column sums (over the full span) to the input total.

### 3. Recurring expenses and the entry point (work tree `main`, requires task 2)
- `recurring.py`: pure `due_expenses(templates, today) -> list[Expense]` per the rule above; `generate_recurring(conn, today) -> int` (rows created) via `repo.insert_generated_expense`; `load_days(conn, today, start=None) -> list[Day]` = generate, `load_inputs`, `allocate`: the one call metrics and the web use.
- `cli.py` `serve`: call `generate_recurring` after migrating.
- Tests: months from start to end, open end stops at today''s month, template starting in the future → nothing, December → January; running `generate_recurring` twice creates rows once; an edited generated row is kept; `load_days` on a small temp DB (a booking, a recurring fixed cost, a capex) gives the hand-checked totals.
- Done when `pytest`, `ruff check` and `ruff format --check` pass.', 'The heart of the app turns every stay, payment and cost into amounts per calendar day: a guest''s payout is shared over the nights they stayed, a monthly bill over the days of its month, a big purchase over the days of its useful life. Every figure on the dashboard is then just a sum over a range of days, which makes all time windows comparable. This part builds that daily view, the rules for each kind of cost, the automatic monthly entries for regular bills, and careful tests so that the daily amounts always add up exactly to what was paid.', '2026-10-23T19:36:41Z', 6);
INSERT INTO plan (id, milestone_id, subject, priority, body, intro, created_at, created_by_task) VALUES (6, 1, 'metrics', 600, 'Part 5 of `plan 1: masterplan`. Builds `src/airbnb_books/metrics.py`, pure (`list[Day]` + range + settings → numbers, no DB, no clock), as fixed in `architecture-spec.md` section 3 (approved, `decision 3: approve the architecture`), for the "Metrics" section of `airbnb-bookkeeping-spec.md`.

Input: the `Day` list of `plan 5: daily allocation engine` (`date, available, occupied, income, cost_fixed, cost_per_night, cost_per_booking, cost_maintenance, cost_capex, cost_tax, minutes`, `profit`; days run to today only, `decision 7: the per-day view ends today; nothing after today is counted`), its `split` helper, and `Settings` / `Expense` from `plan 4: database schema and storage`. Out of scope: loading from the DB (`load_days` of plan 5), the dashboard and charts (part 8).

## Rules

- **Ranges:** `DateRange(start, end)`, both inclusive, clipped to the days that exist (≤ today). `standard_ranges(today, first_day)` → all-time (first_day..today), last 30 days (today−29..today), last 90 days, current calendar month (1st..today); `month_range(year, month)` and `custom(start, end)` for the rest. A range with no days gives sums 0 and ratios None.
- **Types:** money results are `int` COP; per-night/per-hour money rounded half away from zero with integer arithmetic (reuse `money.py`''s rounding if it fits); ratios (occupancy, break-even) are `float` 0..1 (break-even may exceed 1). Undefined → `None` (`decision 10: a figure that cannot be computed is shown as empty, not as zero`).
- **Per range** (`summarize(days, rng, settings) -> Metrics`):
  - available nights, occupied nights, income, each cost column, total cost, profit, minutes.
  - occupancy = occupied ÷ available; ADR = income ÷ occupied; RevPAR = income ÷ available.
  - variable cost per night = (cost_per_night + cost_per_booking) ÷ occupied.
  - break-even occupancy = ((fixed + maintenance + capex + tax) ÷ available) ÷ (ADR − variable cost per night), None when the divisor ≤ 0 (`decision 11: break-even occupancy treats fixed, maintenance, capex and tax costs as fixed`). Compute on exact values (`Fraction`), round only the result.
  - benchmark = Σ per day of `long_term_rent_cop_per_month` split over the days of each month (`decision 12: the long-term rental benchmark is spread over the days of each month`); profit vs. long-term rental = profit − benchmark; never None (benchmark 0 when unset).
  - profit per hour = profit × 60 ÷ minutes (None when no minutes); own-time value = minutes × `hourly_value_cop` ÷ 60; profit after own time = profit − own-time value.
- **Capex book value** `capex_book_value(expenses, as_of) -> int`: Σ over capex of amount − the part of its `split(amount, useful_life_days)` falling on days ≤ as_of (as_of on the purchase date: amount minus that one day; after full life: 0). Purchases after `as_of` are not counted. Shown for the range end.
- **Rolling series** `rolling_90(days) -> list[RollingPoint(date, revpar, adr, occupancy)]` per `decision 13: the rolling 90-day chart starts once 90 days of history exist`; linear time (running sums), not 90 × days.
- **Expense breakdown** `expense_breakdown(days, rng) -> list[(category, amount, share)]`: the six cost columns (co-host cost is inside per-booking), fixed order, share of total cost as float, None when total is 0.

## Tasks

### 1. Ranges and per-range metrics (work tree `main`, `--model opus`)
- Requires plan 5''s task "Day model, split helper and income/occupancy" (use its id from the split of plan 5); `Day` objects are built by hand in tests, so the cost rules need not be done.
- `metrics.py`: `DateRange`, `standard_ranges`, `month_range`, `custom`, `Metrics` dataclass and `summarize` per the rules above.
- `tests/test_metrics.py`, small hand-checked data: a 10-day example with known occupancy/ADR/RevPAR/profit; break-even with a computed value, with ADR ≤ variable cost (None) and with no occupancy; benchmark over a full month equals the monthly figure, and over a range across February/March in a leap year; profit per hour and after own time, with and without minutes; empty range and a range entirely before the first day; last 30 days when fewer than 30 days exist; current month on the 1st.

### 2. Rolling series, expense breakdown, capex book value (work tree `main`, requires task 1)
- Add `rolling_90`, `expense_breakdown`, `capex_book_value`.
- Tests: rolling on 89 days → empty, on 90 → one point equal to `summarize` over those days, on 200 days each point equals `summarize` of its window (check a few); a window with no available nights → None values; breakdown sums to total cost and shares sum to 1, all-zero → None shares; capex book value before, during (hand-checked, incl. a leap day) and after the useful life, and two purchases.
- Done when `pytest`, `ruff check` and `ruff format --check` pass.', 'The dashboard answers three questions: is hosting worth it, are prices right, and where are things heading. This part computes the figures behind those answers for any period, from the amounts the app has already spread over each calendar day: occupancy, average nightly price, revenue per available night, profit, the occupancy needed to break even, the comparison with a long-term rental, profit per hour of own work, and what is left to write off on big purchases. It also produces the 90-day trend series and the split of costs by kind, and defines what is shown when a figure cannot be computed.', '2026-10-23T19:42:49Z', 7);
INSERT INTO plan (id, milestone_id, subject, priority, body, intro, created_at, created_by_task) VALUES (7, 1, 'Airbnb CSV import', 700, 'Part 6 of `plan 1: masterplan`. Implements section 6 of `architecture-spec.md` (approved, `decision 3: approve the architecture`) on top of the storage of `plan 4: database schema and storage`: tables `bookings`, `booking_lines`, `exchange_rates`, setting `property_listings`, and the repo functions of its tasks 3 and 4. Totals are never stored, they come from the lines (`decision 5: booking money totals are derived from booking lines, not stored`).

Out of scope: the import screen (part 7 calls the functions here), the allocation of co-host lines as costs (part 4), the dashboard''s "needs exchange rate" count (part 8).

## Rules (from the architecture spec, checked against `airbnb_.csv`)

- Read with `utf-8-sig`; columns by header name; a missing required column (`Date, Type, Confirmation code, Start date, End date, Nights, Listing, Guest, Currency, Amount, Service fee, Cleaning fee, Gross earnings, Paid out`) is a file error.
- Dates `MM/DD/YYYY` → ISO; `End date` is the exclusive check-out.
- Amounts: strip thousands commas, parse with `Decimal`, store as integer hundredths (`amount_minor`) for every currency, COP included; more than 2 decimals or junk → a problem row. Empty fee columns → 0, empty `Gross earnings` → NULL.
- Types: `Reservation`, `Adjustment`, `Resolution Adjustment`, `Resolution Payout`, `Co-Host payout` → booking lines; `Payout` → ignored, counted; anything else → problem.
- One booking per confirmation code; a line is identified by the schema''s unique key (booking, type, date, currency, amount). Re-importing adds only unknown lines.
- Only rows whose `Listing` is in the setting `property_listings` are imported; others are skipped and counted per listing. When the setting is empty, the import reports the listings found and imports nothing until the user chooses; the chosen list is saved to the setting.
- COP lines get rate 100 (hundredths); other currencies get the rate on or before the line''s `Date`, or none (booking flagged "needs exchange rate").
- Booking fields on re-import (`decision 14: Airbnb import: which rows set a booking''s dates, listing and guest name`): dates, listing and guest name follow the latest-dated `Reservation` row of the code (any row type when there is none); a re-import updates them when they differ and reports it; `guests` and `notes` are never touched.
- Overlapping stays among the imported listings → warnings, not errors.

## Tasks

### 1. Test fixture and CSV parser (work tree `main`)
- Requires `task 21: Model and repository: bookings, lines, exchange rates` (it creates `money.py` and the model).
- `tests/fixtures/airbnb_sample.csv`: a trimmed copy of `airbnb_.csv` with BOM and the original header, keeping one example of each case: the monthly rows of one long stay, a co-host payout, an adjustment (incl. `-0.01`), a resolution adjustment and payout, payout rows (EUR and USD), COP and USD reservations, an amount with a thousands comma, at least two listings. Guest names and the owner''s name/IBAN in `Details` replaced with fake ones.
- `money.py`: `parse_minor(text) -> int` (hundredths, exact, raises on junk or >2 decimals).
- `importer/airbnb_csv.py`: `parse(file) -> ParsedFile` (pure, no DB): typed rows (type, code, dates, nights, listing, guest, currency, amounts in minor units), payout count, listings found with row counts, problems with CSV line numbers. Checks `End − Start = Nights` (mismatch is a problem).
- Tests (`tests/test_import.py`): the fixture parses with the expected counts; BOM; comma amounts; negative and empty fields; missing column; unknown type; bad date; bad amount.
- Done when pytest and ruff pass.

### 2. Import plan and apply (work tree `main`, requires task 1 and `task 22: Repository: expenses, recurring expenses, blocked days, time log, settings`)
- `importer/airbnb_csv.py`: `plan_import(conn, parsed, listings=None) -> ImportPlan` (reads only): new bookings, updated bookings (new lines or changed dates/listing/guest name, with what changed), skipped (payout rows, known lines, rows of other listings per listing), problems, warnings (overlapping stays, lines without a rate). `listings=None` uses the setting; empty setting → plan with `needs_listing_choice` and the listings found.
- `apply_import(conn, plan)`: one transaction through `repo` (no SQL here); saves a given listing choice to `property_listings`; fills rates via `repo.recompute_lines()`; returns the summary (new, updated, skipped, problems, warnings, bookings needing a rate).
- Tests on a temp DB with the fixture: first import creates the expected bookings and lines; totals of one long stay and of a USD stay with a rate hand-checked; co-host line stored as its own type; second import of the same file → nothing new or updated; an overlapping file with one extra row → one updated booking; a row of another listing skipped; empty setting → nothing imported until listings given; user-edited `guests`/`notes` survive a re-import; USD stay without a rate flagged, then filled after adding a rate.
- Done when pytest and ruff pass.

### 3. Command line import (work tree `main`, requires task 2)
- `cli.py`: `airbnb-books import <csv> [--listing NAME …] [--dry-run]`: migrates, plans, prints a readable summary (counts plus the problem and warning lines), applies unless `--dry-run` or listings still need choosing (then prints the listings found and how to pass `--listing`, exit code 2).
- Test: run `main([...])` on a temp DB with the fixture (dry run changes nothing; real run imports; exit code 2 without listings). One test imports the real `airbnb_.csv` from the repo root (skipped when the file is absent) with all its listings and asserts there are no problems.
- Done when pytest and ruff pass and the command works on `airbnb_.csv` in the dev shell.

### 4. Exchange-rate (TRM) import (work tree `main`, requires task 3, web access)
- The user downloads the official Colombian TRM history by hand from datos.gov.co ("Tasa de Cambio Representativa del Mercado – Histórico"); check its real column names, date and number format there.
- `importer/trm_csv.py`: parse → (date, COP per USD in hundredths) using each row''s start-of-validity date; problems with line numbers. Apply: upsert into `exchange_rates` for `USD` through `repo`, then `repo.recompute_lines()`; summary (rates added, changed, lines recomputed, bookings still needing a rate).
- `cli.py`: `airbnb-books import-rates <csv> [--currency USD]`.
- Fixture `tests/fixtures/trm_sample.csv` (a few weeks, in the real format); tests: parse, re-import changes nothing, a changed rate recomputes a booking''s COP.
- Done when pytest and ruff pass.', 'Airbnb lets the owner download a spreadsheet of every payment it made: guest stays, corrections, damage reimbursements, the co-host''s share and the bank transfers. This part reads that file and turns it into the app''s records of stays and their money, without counting anything twice when the same or an overlapping file is loaded again. It also reads the official Colombian dollar exchange-rate history, so stays paid in dollars can be shown in pesos, and tells the owner after each import what was added, changed, skipped and what needs attention.', '2026-10-23T19:44:20Z', 8);
INSERT INTO plan (id, milestone_id, subject, priority, body, intro, created_at, created_by_task) VALUES (8, 1, 'data entry screens', 450, 'Part 7 of `plan 1: masterplan`. Builds the CRUD screens of `web/` as fixed in `architecture-spec.md` (approved, `decision 3: approve the architecture`): Flask routes, Jinja2 templates, plain HTML forms, server-rendered, no JavaScript framework, no CDN. The screens only call `repo`, `recurring`, `importer` (never SQL), on the storage of `plan 4: database schema and storage`.

Out of scope: the dashboard and charts on `/` (part 8, `plan` written by task 10), the Quit button and backup on exit (part 9).

## Ground rules

- One page per entity: list (newest first, filter by date range where it has dates), "new" form, edit form with a Delete button. POST → redirect → GET; a flash message says what was saved or deleted.
- Validation errors re-show the form with the typed values and one message per field; the repo''s `ValidationError` (constraint violations) is shown the same way, never as a 500.
- Input formats per `decision 15: data entry forms: how money and hours are typed`; dates with `<input type="date">`, months with `<input type="month">`. Amounts shown with thousands dots, ratios not needed here.
- Booking pickers (per-booking expenses, time log): a `<select>` of bookings, newest first, labelled `check-in – check-out · guest name · listing`.
- Simple cross-site protection: a POST whose `Origin` (or `Referer`) header names another host than the app''s is rejected with 403 (a web page in the normal browser could otherwise post to the local server).
- Tests in `tests/test_web.py` with Flask''s test client on a temp DB (one fixture creates the app on a migrated `tmp_path` DB): each page renders, each form creates, edits and deletes, and each validation rule is checked once.
- Every task is done when `pytest`, `ruff check` and `ruff format --check` pass and the screens work in the browser (`airbnb-books --db /tmp/x.db --no-browser`, checked with `curl`, stopped by PID).

## Screens and rules

- **Bookings:** list with listing filter and a "needs exchange rate" mark; detail page with totals (net payout, gross, Airbnb fee, co-host cost, nights) and its lines read-only. New = hand-entered stay: check-in, check-out (> check-in), net payout in COP (≥ 0, stored as one `Manual` line), optional confirmation code (unique), listing (preset when the property has exactly one listing), guest name, guests (> 0 or empty), notes. Edit per `decision 17: bookings from the Airbnb import: dates, listing and guest name are read-only in the edit form`. Saving a booking that overlaps another one shows a warning, not an error. Delete: refused with a readable message when expenses point to it; for imported bookings the confirmation says that a re-import brings it back.
- **Expenses:** list filtered by date range and category, generated rows marked with their template. Fields: date, amount (> 0), category, booking (required for `per_booking`, hidden otherwise), useful life in days (required and > 0 for `capex`, hint "3 years ≈ 1095"; hidden otherwise), description.
- **Recurring expenses:** list; fields description, amount (> 0), category (`fixed`, `per_night`, `maintenance`, `tax`), start month, end month (empty or ≥ start). After saving, `generate_recurring(conn, today)` runs so due months appear at once. Edits follow `decision 16: changing a recurring expense template only affects months not yet generated`; the template''s page lists its generated expenses with links.
- **Blocked days:** list; add a range (from, to, reason `buffer`/`owner`/`maintenance`/`other`, note) in one form; days already blocked are skipped and reported; a blocked day inside a booking gives a warning. Edit reason/note, delete one day.
- **Time log:** list with hours per entry and total for the filter; fields date, hours (> 0), optional booking, description.
- **Settings:** hourly value of own time (COP, ≥ 0), long-term rental benchmark per month (COP, ≥ 0), per-booking allocation (`check_in` / `spread`), listings of this property (checkboxes of all listings found in bookings, plus a text field for another name), backups to keep (≥ 1); currency shown as COP, not editable.
- **Exchange rates:** list by currency and date; fields date, currency (3 letters, default USD), COP per unit (> 0, up to 2 decimals). Any change calls `repo.recompute_lines()` (unless the repo does it already) and the flash says how many bookings still need a rate.
- **Import:** upload the Airbnb CSV → preview of the import plan (new, updated with what changed, skipped per reason and listing, problems with CSV line numbers, warnings) → "Import" applies it, then the summary. When no listings are chosen yet, the preview shows the listings found as checkboxes and the choice goes with the apply. The uploaded file is kept in a temp directory under a random token between preview and apply; apply re-parses and re-plans it (cheap, never stale), the file is deleted after apply. A second upload field loads the TRM exchange-rate CSV and shows its summary.

## Tasks (all in work tree `main`)

### 1. Web frame: layout, form helpers, app on a real DB
- Requires `task 22: Repository: expenses, recurring expenses, blocked days, time log, settings`.
- `create_app(db_path)`: one connection per request; `serve` passes the resolved DB path. `base.html` with the navigation (Bookings, Expenses, Recurring, Blocked days, Time, Rates, Import, Settings; `/` stays the placeholder until part 8), flash messages, minimal CSS inline in the template.
- `web/forms.py`: parse and format money, hours, rates, dates, months per `decision 15: data entry forms: how money and hours are typed`; a small helper that turns a POST into values + field errors; mapping of `ValidationError` to a form error; booking picker options.
- Origin check for POSTs; the test fixture (app on a temp DB).
- Tests: parsing/formatting tables (`1.234.567`, `1,234,567`, `1234567`, `12,5` → error for money; `1.5`, `1,5`, `1:30` → 90 min; bad input), foreign Origin → 403, every nav link renders.

### 2. Booking screens (requires task 1)
- List, detail, new, edit, delete as above. Tests: hand-entered booking created with its `Manual` line and correct net payout, edited amount changes the line, check-out ≤ check-in rejected, duplicate code rejected, imported booking (lines added through `repo` in the test) only accepts guests/notes, delete refused while an expense points to it.

### 3. Expense and recurring expense screens (requires task 1 and `task 26: Recurring expense generation and load_days entry point`)
- As above. Tests: capex without useful life rejected, per-booking without booking rejected, fields hidden/ignored for other categories, filter by category and dates, new template generates its due months, editing a template leaves generated rows unchanged, end month before start rejected.

### 4. Blocked days and time log screens (requires task 1)
- As above. Tests: a range of 5 days with 2 already blocked adds 3 and reports 2, blocked day inside a booking warns, hours `1:30` stored as 90 minutes and shown as 1.5 h, zero hours rejected, total for a filter.

### 5. Settings and exchange-rate screens (requires task 1)
- As above. Tests: settings round trip and defaults shown on an empty DB, negative value rejected, listing choice saved as the `property_listings` list; adding a rate fills a booking''s COP that needed one (booking with a USD line created through `repo`), changing it recomputes, invalid currency rejected.

### 6. Import screen (requires task 1, `task 32: Airbnb import plan and apply` and `task 34: Exchange-rate (TRM) import`)
- As above. Tests with `tests/fixtures/airbnb_sample.csv`: upload on an empty DB asks for listings and imports nothing; choosing listings then applying creates the bookings; uploading the same file again previews nothing new; a broken file shows the file error; the temp file is gone after apply; TRM fixture upload shows its summary.', 'The owner needs to type in and correct everything the app counts: stays, costs, regular monthly costs, days the place was not for rent, hours of own work, exchange rates and a few settings, and to load the Airbnb export from the browser. This part builds those plain browser forms and lists, with checks that catch mistakes such as a large purchase without a useful life or a cost that belongs to a stay but names none. It does not build the dashboard, which comes next and reads what these screens store.', '2026-10-23T19:46:33Z', 9);
INSERT INTO plan (id, milestone_id, subject, priority, body, intro, created_at, created_by_task) VALUES (9, 1, 'dashboard and charts', 400, 'Part 8 of `plan 1: masterplan`. Builds the dashboard on `/` and `web/charts.py` as fixed in `architecture-spec.md` (approved, `decision 3: approve the architecture`): server-rendered Jinja2, charts as inline SVG drawn by our own module, no JavaScript, no chart library, no CDN. The page only calls `recurring.load_days`, `metrics` and `repo` (never SQL).

Builds on `plan 6: metrics` (`task 27: Metrics: date ranges and per-range summary`, `task 28: Metrics: rolling 90-day series, expense breakdown, capex book value`), `task 26: Recurring expense generation and load_days entry point` of `plan 5: daily allocation engine`, and the web frame of `plan 8: data entry screens` (its task "Web frame: layout, form helpers, app on a real DB": `base.html`, navigation, `web/forms.py` money formatting, test fixture). Out of scope: Quit button and backup (part 9), any visual polish.

## Layout (`decision 18: dashboard layout: which periods are shown and which period the cost breakdown uses`)

- **Metrics table:** one column per period: all-time, last 90 days, last 30 days, this month, a chosen month (`?month=YYYY-MM`, default last month), custom (`?from=…&to=…`, column only when set). Column headers show the period''s dates.
- **Rows:** available nights, occupied nights, occupancy %, ADR, RevPAR, income, total cost, profit, variable cost per night, break-even occupancy %, long-term rental benchmark, profit vs. long-term rental, hours, profit per hour, profit after own time; then remaining capex book value at the period''s end.
- **Formatting:** money with thousands dots and "COP" in the header, not per cell (`web/forms.py` formatter); ratios as `57.3 %` (one decimal; break-even above 100 % shown as it is); hours with one decimal; `None` as a dash (`decision 10: a figure that cannot be computed is shown as empty, not as zero`). Negative profit marked (minus sign, plain red text is enough).
- **Period form:** one GET form at the top (month input, from/to date inputs, Apply, Reset link). Invalid input (bad date, from > to) → the table without that column and one message, never a 500.
- **Rolling chart:** two stacked line charts sharing the date axis: money (ADR and RevPAR, COP) and occupancy (0–100 %); one point per day from `metrics.rolling_90`; `None` breaks the line; fewer than 90 days → the text "the 90-day chart starts once 90 days of history exist" (`decision 13: the rolling 90-day chart starts once 90 days of history exist`).
- **Expense breakdown:** for the custom range if set, else the chosen month: horizontal bar chart plus a small table (category, amount, share %), the six categories in `metrics.expense_breakdown`''s order; all zero → "no costs in this period".
- **Notices:** above everything, when any booking needs an exchange rate: "N bookings need an exchange rate" linking to the rates screen; an empty DB shows a short "nothing here yet: import the Airbnb CSV or add a booking" with links instead of a table of dashes.
- `today` comes from one place (`date.today()` in the route, overridable in tests through the app config) and is passed to `load_days` and `metrics`.

## Charts module (`web/charts.py`)

- Pure functions returning SVG markup strings (`markupsafe.Markup`): `line_chart(series, *, y_format, y_min=None, y_max=None, width, height)` with `series = [(label, [(date, value|None), …])]`, and `bar_chart(items, *, value_format)` with `items = [(label, value)]`.
- Fixed size via `viewBox` (scales to the page width), a few y-axis gridlines with labels at round values, x-axis labels at month starts, a legend, one colour per series from a fixed small palette (readable in print and for colour-blind users: different line dashes too), `<title>` elements so hovering shows the value.
- Labels escaped; empty input → an empty-state SVG or `None` the template handles; all values None → same.

## Tasks (all in work tree `main`)

### 1. SVG chart module
- Requires `task 17: Python project skeleton` only (no data dependency).
- `web/charts.py` as above. Tests in `tests/test_charts.py`: output parses as XML (`xml.etree`), one `<polyline>`/`<path>` segment per run of non-None values (a None in the middle gives two segments), y labels at round values for a sample range, a label with `<&>` is escaped, bar widths proportional to values, zero and empty inputs don''t divide by zero.

### 2. Dashboard: metrics table and period form
- Requires task 1 of this plan, `task 27: Metrics: date ranges and per-range summary`, `task 26: Recurring expense generation and load_days entry point`, and the "Web frame" task of `plan 8: data entry screens`.
- Route `/` replaces the placeholder: period parsing, the metrics table, notices, empty state, as above.
- Tests in `tests/test_web.py` on a temp DB with a booking, a fixed expense and a time entry (hand-checked numbers): all standard columns present, `?month=` and `?from/to` add/change columns, invalid custom range shows the message and status 200, a booking with a USD line without rate shows the notice, empty DB shows the empty state, None shown as a dash.

### 3. Dashboard: rolling chart and expense breakdown
- Requires task 2 of this plan and `task 28: Metrics: rolling 90-day series, expense breakdown, capex book value`.
- Add the two rolling charts, the breakdown chart and table, and the capex book value row.
- Tests: with fewer than 90 days the message appears and no chart; with 120 days of data the page contains two `<svg>` charts with the series labels; breakdown follows the custom range when given, else the chosen month; capex row matches `capex_book_value` at the period end.
- Done when `pytest`, `ruff check` and `ruff format --check` pass and the dashboard works in the browser on a DB with `airbnb_.csv` imported (`airbnb-books --db /tmp/x.db --no-browser`, checked with `curl`, stopped by PID).', 'The dashboard is the page the owner opens to see whether hosting pays off, whether prices are right and where things are heading. It shows the key figures for several periods side by side, a chart of how the average nightly price, the revenue per available night and the occupancy developed over the last 90 days, and how the costs of a chosen period split by kind. Everything is plain and readable, drawn on the owner''s own computer without any online service.', '2026-10-23T19:47:43Z', 10);
INSERT INTO plan (id, milestone_id, subject, priority, body, intro, created_at, created_by_task) VALUES (10, 1, 'backup, install and final check', 300, 'Part 9 of `plan 1: masterplan`. Builds the backup, the NixOS / home-manager module, the README and the final end-to-end check, as fixed in `architecture-spec.md` sections 2 and 5 (approved, `decision 3: approve the architecture`) and the "Storage and backup" section of `airbnb-bookkeeping-spec.md`. Rules for pruning, keep count and failures: `decision 19: backups: which files are pruned, how many are kept, and what a failed backup does`.

Already provided by earlier parts (use, don''t rebuild):
- `config.py` resolves the backup dir (`--backup-dir`, `AIRBNB_BOOKS_BACKUP_DIR`, default `~/Dropbox/airbnb-books`) and the DB path: `task 19: Paths, connection and migrations runner`.
- `storage/db.migrate(conn, before_migrate=…)` hook for a backup before migrations: same task.
- Setting `backup_keep` (default 30): `task 22: Repository: expenses, recurring expenses, blocked days, time log, settings`.
- Layout of the web pages: `task 36: Web frame: layout, form helpers, app on a real DB`.

## Tasks (all in work tree `main`)

### 1. Backup module and `backup` command
- Requires `task 19` and `task 22`.
- `backup.py`: `backup(db_path, backup_dir, keep, today)` → path written. Uses `sqlite3.Connection.backup` (online backup, safe while the app runs) into a temp file in `backup_dir`, then renames it to `books-YYYY-MM-DD.db` (same day overwrites). Creates `backup_dir` if missing. Then prunes: only files matching `books-YYYY-MM-DD.db`, newest `keep` kept.
- `cli.py`: subcommand `backup [--backup-dir] [--keep]`; keep = flag, else setting `backup_keep`, else 30. Non-zero exit and a message on stderr on failure.
- `serve` and `migrate` pass the backup as `before_migrate`; a failure there aborts the migration.
- `tests/test_backup.py`: backup is a readable copy with the same rows; same-day overwrite; pruning keeps N and leaves foreign files alone; keep precedence; migration hook called only for a non-new DB.

### 2. Backup on exit and Quit button
- Requires task 1 of this plan and `task 36`.
- `serve` takes a backup when the server stops: Ctrl-C, SIGTERM, or a **Quit** button in the page header (POST `/quit`: shows "airbnb-books has stopped, you can close this tab", then stops waitress cleanly).
- A failed backup at exit is printed, the app still exits (`decision 19`).
- Tests: `/quit` with the test client triggers the shutdown callback (inject it, don''t kill the test process); the exit path calls the backup once.
- Done when, by hand: start with `--no-browser` on a temp DB and backup dir, press Quit via `curl -X POST`, the process ends and today''s backup file exists.

### 3. NixOS and home-manager module
- Requires task 1 of this plan and `task 18: Nix package, app and flake checks`.
- `nix/module.nix`, exposed as `homeManagerModules.default` and `nixosModules.default` (NixOS: `systemd.user` units for all users). Options `services.airbnb-books-backup = { enable; package ? the flake''s package; backupDir; keep ? 30; dbPath ? null (app default); onCalendar ? "daily"; }`.
- `airbnb-books-backup.service` (oneshot, runs `airbnb-books backup --backup-dir … --keep …` and `--db` when set) and `airbnb-books-backup.timer` (`OnCalendar`, `Persistent = true`, wanted by `timers.target`).
- A flake check that evaluates the NixOS module in a minimal `nixosSystem` and asserts the generated unit''s `ExecStart` and timer settings (no VM test needed). The home-manager module shares the same file; home-manager is not added as a flake input just for a check.
- Done when `nix flake check` passes.

### 4. README
- Requires tasks 2 and 3 of this plan, `task 33: Command line Airbnb import`, `task 34: Exchange-rate (TRM) import` and `task 41: Import screen`.
- `README.md`, short, for the owner: what the app is; install (`nix run`, or the flake as an input with the package and the backup module, a home-manager example); run and quit; import the Airbnb CSV (where to download it, the listings question on the first import, re-imports are safe); exchange rates (TRM file from datos.gov.co or typing one); backup (on exit, daily timer, where files go, how many are kept, `airbnb-books backup` by hand); **restore**: close the app, copy `books-YYYY-MM-DD.db` over the live DB path, start the app; where the DB lives and how to override it.
- Every command in it is tried once in the dev shell against a temp DB.

### 5. End-to-end check (`--model opus`)
- Requires task 4 of this plan, `task 37: Booking screens`, `task 38: Expense and recurring expense screens`, `task 40: Settings and exchange-rate screens`, `task 41`, `task 44: Dashboard: rolling chart and expense breakdown` and `task 45: Dashboard: metrics table and period form` (and any later task of `plan 9: dashboard and charts`).
- In the real app on a fresh temp DB: import `airbnb_.csv` through the import screen, choose the listings, add the USD rates needed for one chosen month, add a few expenses (a recurring fixed cost, a per-night cost, a capex item with useful life, a maintenance cost) and a time log entry; open the dashboard.
- Pick one month with several stays (one crossing a month boundary) and recompute its figures independently from the CSV rows and the expenses (a short throwaway script or by hand, not by calling the app''s code): nights, occupancy, income, costs by category, profit, ADR, RevPAR, profit per hour. They must match the dashboard exactly (integer COP).
- Then: Quit, check the backup file, restore it per the README and see the same dashboard.
- Make it repeatable: `tests/test_e2e.py` does the same on `tests/fixtures/airbnb_sample.csv` (no real guest names in the repo) and asserts the hand-checked numbers for one month.
- Every mismatch or bug found is a follow-up task in the plan it belongs to, not fixed here; done note lists the month checked and the result.', 'The bookkeeping database lives only on the owner''s computer, so it needs regular copies in a Dropbox folder: each time the app closes and once a day, keeping the last month of copies. This part adds those backups, a ready-made setting for the owner''s Nix system that runs the daily copy, a short guide for installing, using, backing up and restoring the app, and a final run-through of the whole app with real data where one month''s numbers are checked by hand.', '2026-10-23T19:49:14Z', 11);
INSERT INTO plan (id, milestone_id, subject, priority, body, intro, created_at, created_by_task) VALUES (11, 2, 'masterplan', 1000, 'Milestone `milestone 2: visual design update`: daisyUI + Tailwind CSS everywhere, playful bookkeeping/accounting elements, a spreadsheet feel where possible, a favicon, **no change in functionality**.

**This masterplan''s own tasks are not implementation work: each of them writes the plan for one part below** (`pm plan add 2 …`, with the priority given here). The implementation tasks come from those plans.

## Ground rules for every part

- No functional change: same routes, URLs, form field names and values, redirects, flash messages, numbers and their formats (`decision 15: data entry forms: how money and hours are typed`, `decision 10: a figure that cannot be computed is shown as empty, not as zero`, dashboard structure of `decision 18: dashboard layout: which periods are shown and which period the cost breakdown uses`). `tests/test_web.py` and `tests/test_e2e.py` keep passing; change a test only where it asserts on markup that the restyle replaces, never on behaviour.
- Offline as before (`decision 3: approve the architecture`): no CDN, no web fonts or icon fonts from the network, no new JavaScript beyond the existing cosmetic snippets (e.g. the category toggle in `expense_form.html`). Icons and decorations are inline SVG or plain CSS.
- How Tailwind/daisyUI CSS is produced and shipped waits for `decision 23: How do Tailwind CSS and daisyUI get into an app that promised no build step and no network?`; the split links the plan-writing task of part 1 to it.
- Readability first: playful touches never hide numbers or labels; negatives stay clearly red; works in light mode (dark mode optional, part 1 decides).
- Checks after every change: `pytest`, `ruff check src tests`, `ruff format --check src tests`, `nix flake check` where the packaging changed; look at the pages by running the app (ad-hoc screenshots are fine, no new test suites).

## Parts

1. **Styling foundation** (priority 350, runs first; parts 2–4 require its implementation)
   - The CSS toolchain as decided in `decision 23`, a `web/static/` folder served by Flask and listed in `pyproject.toml` package data, Nix package and dev shell updated.
   - A custom daisyUI theme with a "ledger" palette: paper background, ledger green/blue rules, red ink for negatives, tabular/monospace figures for numbers.
   - `base.html` rebuilt: the inline `<style>` replaced; the nav as a daisyUI navbar or tab bar (like sheet tabs), active page highlighted, Quit button styled; flash messages as daisyUI alerts (keep categories `warning`/`error`); the main area as a "sheet of paper" card.
   - Shared conventions written down for parts 2–4 (which daisyUI components and classes to use for tables, forms, buttons, hints, errors), e.g. as Jinja macros or a short section in README.md.
2. **Spreadsheet-style tables and dashboard** (priority 300)
   - All list tables (bookings, expenses, blocked days, time log, rates, recurring expenses, import preview/summary, booking detail lines) and the dashboard metric table look like a spreadsheet: grid lines, header row like column headers (optionally A, B, C… letters and a row-number gutter as decoration), zebra rows, right-aligned tabular numbers, red negatives via a class instead of the inline style in `index.html`.
   - Dashboard: period form (month, from, to, Apply, Reset) as a compact toolbar like a spreadsheet''s formula bar; headings and the "needs an exchange rate" warning restyled.
   - Charts (`web/charts.py`): only colours, fonts and grid look aligned with the theme; same data, same series, same SVG approach.
3. **Forms and actions** (priority 300)
   - Every form (booking, expense, blocked days, time entry, rate, recurring expense, settings, CSV import upload) uses daisyUI inputs, selects, labels, hint and error styles; field names, order of fields and validation unchanged.
   - Buttons: primary Save/Apply, secondary Cancel/Reset links, danger Delete (confirm dialogs kept); a "journal entry" feel for forms (e.g. a form card styled like a ledger entry slip).
4. **Playful bookkeeping touches and favicon** (priority 200, after parts 2 and 3 so it decorates finished pages)
   - Favicon: a small ledger/abacus/calculator motif as SVG plus a PNG/ICO fallback in `web/static/`, linked from `base.html`.
   - Decorations: an app title/logo in the navbar, small inline-SVG icons per section (bookings, expenses, time, rates…), friendly empty states (e.g. "the ledger is blank" with a doodle), a styled "stopped" page after Quit, subtle touches like a double underline under totals, a "balanced ✓" stamp or rubber-stamp look on the import summary.
   - Wording changes only in decorative text; existing messages and labels stay.

## Order

Part 1''s plan, then (after `decision 23` is answered and part 1 is implemented) parts 2 and 3 in any order, then part 4. Where a later part''s tasks need the foundation, they `--requires` part 1''s implementation tasks.', 'The bookkeeping app works, but it looks like a bare web page from the nineties. This work gives every screen a friendly, consistent look built on two popular styling toolkits, makes the tables feel like a spreadsheet, adds small playful touches that nod to ledgers and accounting, and gives the browser tab its own little icon. Nothing the app does changes: the same screens, buttons and numbers, only better looking.', '2026-10-23T22:34:21Z', NULL);
INSERT INTO plan (id, milestone_id, subject, priority, body, intro, created_at, created_by_task) VALUES (12, 3, 'masterplan', 1000, 'Milestone `milestone 3: add a proper client-side framework`: replace the server-rendered Jinja pages with a client-side app; build steps are fine; still a local app (server on 127.0.0.1, started by `rios-de-asia-accounting`).

**This masterplan''s own tasks are not implementation work: each of them writes the plan for one part below** (`pm plan add 3 …`, with the priority given here). The implementation tasks come from those plans.

## The choice (binding for every part)

`decision 24: client-side framework: React with TypeScript, built by Vite, on top of a JSON API from the existing Python server`:
- `frontend/`: React 19 + TypeScript + Vite single-page app; React Router (URLs), TanStack Query (server data), Tailwind CSS + daisyUI (styling), Biome (lint/format), Vitest only for pure helpers.
- Python/Flask stays: domain code (`allocation`, `metrics`, `importer`, `recurring`, `backup`, `storage`) unchanged; `web/` becomes a JSON API under `/api` plus serving the built bundle.
- The bundle is built by Nix (`buildNpmPackage` + `importNpmLock`), not committed; dev shell adds `nodejs`.

## Ground rules for every part

- **No functional change**: same screens, actions, numbers, rules. Binding answers stay binding, especially `decision 15: data entry forms: how money and hours are typed`, `decision 10: a figure that cannot be computed is shown as empty, not as zero`, `decision 17: bookings from the Airbnb import: dates, listing and guest name are read-only in the edit form`, `decision 18: dashboard layout: which periods are shown and which period the cost breakdown uses` (period choices in the URL, bookmarkable).
- **Server stays authoritative**: parsing and validation stay in Python (`web/forms.py` parsers); the client sends what the user typed as strings and shows the per-field errors and warnings the API returns. The client may format for display (money with dot thousands) but never re-implements bookkeeping rules.
- **Same URLs** for screens as today (`/`, `/bookings`, `/bookings/<id>`, `/expenses`, …) so bookmarks keep working; Flask answers every non-`/api` path with `index.html`.
- **Local and offline**: no CDN, no web fonts from the network, no runtime network access; POST/PUT/DELETE keep the same-origin guard of `web/app.py`.
- **Tests sparse** (AGENTS.md): API tests with Flask''s test client replace the HTML assertions of `tests/test_web.py`/`tests/test_e2e.py`; Vitest only for pure TS helpers; no browser test suite — check screens by running the app (ad-hoc headless screenshots are fine).
- **Checks**: `pytest`, `ruff check/format --check src tests`, in `frontend/`: `npm run build`, `tsc --noEmit`, `biome check`; `nix flake check` once packaging changed.
- **Relation to `milestone 2: visual design update`** waits for `decision 25: In which order do the visual design update and the new client-side framework happen, and does the design work move onto the new screens?`; the split links the plan-writing tasks of parts 1, 3, 4 and 5 to it. Whatever the answer, the new screens use Tailwind + daisyUI classes; the answer decides whether they get the plain default look or the full ledger look of plan 11. The plan-writing task that is the last to wait for it records the consequences (including what happens to plan 11 and `decision 23`).

## Parts

1. **Architecture and client toolchain** (priority 850, first)
   - Rewrite `architecture-spec.md` sections 1–3 (stack, Nix packaging, code layout) for the new architecture; keep what still holds (DB, migrations, backups, import).
   - `frontend/` skeleton: Vite + React + TS + Tailwind + daisyUI + Biome + Vitest, `package-lock.json`, an app shell with the nav of today (`NAV` in `web/app.py`) and a Quit button, routing, an API client helper (JSON, errors, same-origin).
   - Flask serves the built bundle (`web/static/` or a `dist` folder as package data) and falls back to `index.html`; dev workflow: Vite dev server with a proxy to `rios-de-asia-accounting --no-browser --port …`, documented in README.
   - Nix: frontend derivation built offline from the lock file, its output copied into the Python package; dev shell with `nodejs`; flake checks for frontend lint/typecheck.
2. **JSON API** (priority 800; independent of part 1, can run in parallel)
   - Endpoints under `/api` for every current screen and action: dashboard (metric table per period, rolling series and breakdown data for charts, rate warnings), bookings (list, detail with lines, create, edit, delete, overlap warning), expenses, recurring templates, blocked days, time log, rates, settings, CSV import (upload → preview → listing choice → confirm, TRM rates import), quit.
   - One response shape for errors (`422` with per-field messages from the existing parsers) and for warnings/notices (today''s flash messages).
   - Money and minutes as integers in JSON; display formatting on the client; documented in one place (a short API section in `architecture-spec.md`) that the TS types mirror.
   - Reuse the current route modules'' logic (`web/bookings.py`, `web/expenses.py`, …); API tests with the test client (one or two per resource, not exhaustive).
   - The HTML routes stay until part 6 so the app keeps working in between.
3. **Data screens** (priority 500; requires parts 1 and 2)
   - Lists and forms for bookings (incl. detail lines, read-only fields of imported bookings), expenses (category toggle), recurring templates, blocked days, time log, rates, settings.
   - Shared components: table, form field with error/hint, money/hours/date inputs, confirm-before-delete, notices/toasts; after save, navigate as the current redirects do.
4. **Dashboard and charts** (priority 490; requires parts 1 and 2)
   - Period controls (month, from, to, Apply, Reset) bound to URL query params as in `decision 18`; metric table with empty cells per `decision 10`; rate warning.
   - Charts: rolling 90-day line chart and expense breakdown bar chart as React SVG components drawn from API data (port of `web/charts.py`: same series, ticks, `decision 13: the rolling 90-day chart starts once 90 days of history exist`), no chart library unless the plan argues for one.
5. **Import flow** (priority 480; requires parts 1 and 2)
   - Airbnb CSV upload, preview (new / updated / skipped / problems), first-import listing choice, confirm, summary; TRM rates CSV upload; counts of bookings lacking a rate.
6. **Retire the server-rendered pages** (priority 400; after parts 3–5)
   - Delete Jinja templates, HTML routes, `web/charts.py` if fully ported, unused Jinja filters; `pyproject.toml` package data updated.
   - `tests/test_web.py`/`tests/test_e2e.py` reduced to API tests; README (run, develop, build) and `architecture-spec.md` final; an end-to-end check with the real `airbnb_.csv` through the running app.

## Order

Parts 1 and 2 first (in parallel), then 3, 4, 5 in any order, then 6. Parts 1, 3, 4 and 5 wait for `decision 25`. Implementation tasks of parts 3–5 `--requires` the implementation tasks of parts 1 and 2 they build on; part 6 requires parts 3–5.', 'Today every screen of the bookkeeping app is assembled on the owner''s computer by the Python program and sent to the browser as a finished page. This work turns it into a modern browser application: the screens are built with React, a widely used toolkit, while the Python program keeps the bookkeeping rules, the data and the backups and only answers the browser''s requests for data. The app keeps doing exactly what it does now and still runs only on the owner''s computer, without internet, but it becomes easier to grow, faster to use and ready for the planned new look.', '2026-10-23T22:40:12Z', NULL);
INSERT INTO plan (id, milestone_id, subject, priority, body, intro, created_at, created_by_task) VALUES (13, 3, 'JSON API', 800, 'Part 2 of `plan 12: masterplan`: a JSON API under `/api` for every current screen and action, next to the existing HTML routes (those stay until part 6). Independent of part 1 (client toolchain) and of `decision 25`; parts 3–5 (screens) build on it.

Binding: `decision 24: client-side framework: React with TypeScript, built by Vite, on top of a JSON API from the existing Python server` (server stays authoritative), `decision 15: data entry forms: how money and hours are typed`, `decision 10: a figure that cannot be computed is shown as empty, not as zero` (`null` in JSON, never `0`), `decision 17: bookings from the Airbnb import: dates, listing and guest name are read-only in the edit form`, `decision 18: dashboard layout: which periods are shown and which period the cost breakdown uses`, `decision 13: the rolling 90-day chart starts once 90 days of history exist`.

## Conventions (fixed by the foundation task, used by all others)

- Code: package `src/rios_de_asia_accounting/web/api/`, one Flask blueprint at `/api`, one module per resource (`bookings.py`, `expenses.py`, …), registered in `create_app`.
- **Reuse, don''t copy**: the API calls the same parsing (`web/forms.py` `Form` and parsers) and the same helpers as the HTML routes (`_read`, `_overlaps`, `_needs_rate_message`, …). Logic that today sits inside an HTML view function (e.g. the dashboard''s period handling, the import steps) is moved into a plain function both the HTML view and the API call — no behaviour change for the HTML pages.
- **Input**: write requests send a JSON object of strings exactly as typed (`{"net_payout": "1.234.567", "check_in": "2026-01-05"}`), multi-value fields as arrays of strings; it is fed into `Form(data, lists)` so the existing parsers and messages apply. File uploads are `multipart/form-data`.
- **Output values**: money as integer pesos, minutes as integer minutes, exchange rates as the stored integer (COP × 100), dates as `YYYY-MM-DD`, months as `YYYY-MM`, ratios as plain numbers (0.42, not 42 %); uncomputable figures `null`. Display formatting (`1.234.567`, hours `1.5`, rates) is the client''s.
- **Reads** (`GET`) return the resource JSON directly; options a form needs (listing names, expense categories, booking choices) come with a small `GET /api/<resource>/options`.
- **Writes** (`POST` create, `PUT` update, `DELETE`) return `200 {"data": <saved item or null>, "notices": [...]}`.
- **Notices** (today''s flash messages): `{"level": "info" | "warning" | "error", "text": "…"}` with today''s texts (e.g. "Booking saved.", the overlap warning as `warning`).
- **Errors**: invalid input → `422 {"errors": {"<field>": "<message>"}}`, one message per field from the parsers, form-level errors (repo `ValidationError`) under key `""`; unknown id → `404`, cross-origin write → `403`, bad method → `405`, all as `{"error": "<text>"}` (JSON, not HTML pages) under `/api`.
- **Same-origin guard** of `web/app.py` extended from POST to every non-GET method.
- Docs: a short "JSON API" section in `architecture-spec.md`: the conventions above plus one line per endpoint (method, path, request, response); each task adds its endpoints. Part 3''s TypeScript types mirror this section.
- Tests (AGENTS.md: sparse): one or two Flask test-client tests per resource in its own file `tests/test_api_<resource>.py` (one happy path, one 422 or notice); no exhaustive coverage.
- Checks per task: `pytest`, `ruff check src tests`, `ruff format --check src tests`.

## Tasks (in this order; tasks 2–7 each require task 1, otherwise independent)

1. **Foundation**: blueprint, JSON request reading into `Form`, `ok(data, notices)` / `invalid(form)` helpers, JSON error handlers for `/api`, guard for PUT/DELETE, `POST /api/quit` (shuts down after the response, like `/quit`), the "JSON API" section with the conventions, one test (quit or 404 shape + cross-origin 403).
2. **Bookings**: list with today''s filters (`from`, `to`, `listing`), detail with booking lines and derived totals and an `imported` flag, options (listing names), create, update (imported bookings: only guests and notes accepted, per `decision 17`), delete (blocked when expenses point at it → 422 form-level error with today''s text), overlap warning as a `warning` notice.
3. **Expenses and recurring templates**: expense list (filters incl. category), detail, options (categories, booking choices from `booking_options`), create/update/delete; recurring templates list/detail/create/update/delete with today''s notices ("… N expense(s) generated", "the expenses it generated are kept").
4. **Blocked days and time log**: blocked days list/create (incl. the inside-a-booking notice and day ranges as today)/update/delete; time entries list/create/update/delete, minutes as integers.
5. **Rates and settings**: exchange rates list/create/update/delete by (day, currency) with the "N bookings still need a rate" notice; settings get/update (listings as array).
6. **Dashboard**: `GET /api/dashboard?month=&from=&to=` with today''s parameter handling and messages (as `error` notices); returns column heads (label, start, end), metric rows (key, label, kind: int/pct/money/minutes, one value per column, `null` where uncomputable) incl. remaining capex book value, count of bookings needing a rate, an `empty` flag, the rolling 90-day series as raw daily points (`date`, `adr`, `revpar`, `occupancy`; empty list before 90 days of history, `decision 13`) and the expense breakdown (range, items with key, label, amount, share). Chart geometry (ticks, scales) is not computed here: part 4 ports it to the client.
7. **Import**: `POST /api/import/airbnb` (multipart upload → token + preview: new / updated / skipped / problems, whether a listing choice is needed and which listings the file has), `POST /api/import/airbnb/apply` (`token`, `listings`, `other_listing` → summary; missing listing choice → 422 with the preview again), `DELETE /api/import/airbnb/<token>` (cancel, notice "Import cancelled; nothing was changed."), `POST /api/import/rates` (multipart file + currency → summary and problems, or 422). Same temp-file and token handling as `web/importing.py`, shared, not copied.

Done when: every screen and action of today is reachable through `/api` with the shapes above, documented in `architecture-spec.md`, HTML pages unchanged, checks green.', 'The bookkeeping app is moving from pages built on the server to an app that runs in the browser and asks the server only for data. This part gives the server that data interface: every screen and every action of today (dashboard, bookings, expenses, time, rates, settings, CSV import) becomes a request that answers in a simple structured format. All checks of what the user typed stay on the server, so the numbers and rules stay exactly as they are; the old pages keep working until the new screens replace them.', '2026-10-23T22:44:30Z', 64);
INSERT INTO plan (id, milestone_id, subject, priority, body, intro, created_at, created_by_task) VALUES (14, 3, 'architecture and client toolchain', 850, 'Part 1 of `plan 12: masterplan`: the client toolchain and the architecture text everything else builds on. Parts 3–5 (screens) build their pages into the shell made here; part 2 (`plan 13: JSON API`) delivers the data.

Binding:
- `decision 24: client-side framework: React with TypeScript, built by Vite, on top of a JSON API from the existing Python server` (stack, Nix build, server authoritative).
- `decision 25: In which order do the visual design update and the new client-side framework happen, and does the design work move onto the new screens?`: the design update waits until this milestone is done, so the shell uses **plain daisyUI defaults** (one built-in light theme, no custom theme, no ledger look of `plan 11: masterplan`); keep styling to daisyUI component classes so a later theme can be swapped in.
- Masterplan ground rules: offline (no CDN, no network fonts), same screen URLs as today, same-origin guard for writes.

## Choices this plan makes

- **Layout**: `frontend/` at the repo root (own `package.json`, `package-lock.json`, `vite.config.ts`, `tsconfig.json`, `biome.json`, `src/`). Vite builds into `src/rios_de_asia_accounting/web/dist/` (git-ignored, shipped as package data `web/dist/**/*`).
- **Flask serving**: assets at `/assets/…` from `web/dist`; every `GET` that no Flask route matches and is not under `/api` gets `web/dist/index.html` (a 404 handler, not a catch-all route). So while the Jinja pages still exist (until part 6) they keep their URLs, and the built app takes them over automatically when part 6 deletes the HTML routes. Without a built bundle (pytest, Python-only work) the fallback answers a short plain 404 "frontend not built" — tests never need the bundle.
- **Seeing new screens before part 6**: through the Vite dev server (`npm run dev`, port 5173), which serves the app at every URL and proxies `/api` to `rios-de-asia-accounting --no-browser --port 8080`. The proxy must pass the same-origin guard by rewriting the `Origin` header to the target (e.g. `changeOrigin` plus a `configure` hook), never by weakening the guard.
- **Routing**: React Router with today''s paths: `/` (dashboard) and the `NAV` entries of `web/app.py` (`/bookings`, `/expenses`, `/recurring`, `/blocked-days`, `/time`, `/rates`, `/import`, `/settings`); each a placeholder page here, replaced by parts 3–5; a not-found page.
- **API client** (`frontend/src/api.ts`): `fetch` with relative URLs only (same origin), JSON in/out, types for the shapes of `plan 13: JSON API` (`{data, notices}` on writes, `422 {errors: {field: message}}`, `{error}` otherwise) — an `ApiError` carrying status, field errors and text; a TanStack Query `QueryClient` set up in `main.tsx`.
- **Quit**: button in the header → `POST /api/quit` → a "stopped" screen with today''s text (`templates/stopped.html`).

## Tasks (in this order)

1. **Spec rewrite**: `architecture-spec.md` sections 1–3 (stack and UI, Nix packaging, code layout) for React + Vite + Flask JSON API, with the choices above; sections 4–7 (tests, DB and migrations, import, schema) kept, only touched where they name Jinja/HTML/`charts.py` (mark those as "until part 6").
2. **Frontend skeleton and shell**: Vite + React 19 + TS (strict) + React Router + TanStack Query + Tailwind v4 + daisyUI 5 + Biome + Vitest; scripts `dev`, `build`, `typecheck` (`tsc --noEmit`), `lint` (`biome check`), `test` (`vitest run`); app shell with nav, Quit, placeholder routes; `api.ts` with one Vitest test of its error parsing. `nodejs` added to the dev shell in `flake.nix` (only that line; packaging is task 4).
3. **Flask serving and dev workflow**: the bundle serving and fallback above in `web/app.py`, `.gitignore` for `web/dist/` and `frontend/node_modules/`, package data in `pyproject.toml`, the Vite proxy, README section "Develop" (two terminals: server on 8080, `npm run dev`; `npm run build` to serve the bundle from Flask). One test of the fallback (no bundle → 404 plain; `/api/...` unknown stays JSON 404 once `plan 13: JSON API` exists).
4. **Nix packaging**: `frontend` derivation with `buildNpmPackage` + `importNpmLock` (offline, from `package-lock.json`), its `dist` copied into `src/rios_de_asia_accounting/web/dist` before the Python build; checks `frontend-lint` (`biome check`, `tsc --noEmit`, `vitest run`); `nix build`, `nix run` (open the app, see the shell) and `nix flake check` green. Watch Biome''s platform-specific binary packages under `importNpmLock` (fallback: `pkgs.biome` pinned to the lock''s version).

Cross-plan: task 2''s Quit and task 3''s `/api` 404 check use the foundation task of `plan 13: JSON API` (`POST /api/quit`, JSON errors): tasks 2 and 3 `--requires` it.

Checks per task: `pytest`, `ruff check/format --check src tests`; from task 2 on in `frontend/`: `npm run build`, `npm run typecheck`, `npm run lint`, `npm test`; task 4 also `nix flake check`.

Done when: `nix run` starts the app with the bundle inside; the Vite dev server shows the shell with today''s nav and a working Quit; the spec describes the new architecture.', 'The bookkeeping app is being rebuilt so its screens run as a modern application in the browser, while the existing program on the computer keeps doing the bookkeeping and storing the data. This part lays the groundwork: it rewrites the technical description of how the app is built, sets up the new browser project with its tools, an empty app frame with today''s menu and a Quit button, and makes the installed program ship and serve the new screens. Nothing visible changes for daily use yet; the later parts fill the frame screen by screen.', '2026-10-23T22:45:41Z', 63);
INSERT INTO plan (id, milestone_id, subject, priority, body, intro, created_at, created_by_task) VALUES (15, 3, 'data screens', 500, 'Part 3 of `plan 12: masterplan`: React lists and forms for every data screen, built into the app shell of `plan 14: architecture and client toolchain` on the endpoints of `plan 13: JSON API`. Dashboard (part 4) and import (part 5) are not in scope. The Jinja pages stay until part 6.

Binding:
- `decision 24: client-side framework: React with TypeScript, built by Vite, on top of a JSON API from the existing Python server`: server authoritative; forms send what was typed as strings and show the API''s per-field errors; the client never re-implements a parser or rule.
- `decision 15: data entry forms: how money and hours are typed`: money inputs show and accept `1.234.567`, hours `1.5` / `1,5` / `1:30`, rates up to 2 decimals.
- `decision 17: bookings from the Airbnb import: dates, listing and guest name are read-only in the edit form`.
- `decision 16: changing a recurring expense template only affects months not yet generated`: the template''s page lists its generated expenses with links.
- `decision 10: a figure that cannot be computed is shown as empty, not as zero` (`null` → dash).
- `decision 25: In which order do the visual design update and the new client-side framework happen, and does the design work move onto the new screens?`: the design update waits until this milestone is done → plain daisyUI default classes only (`table`, `input`, `select`, `btn`, `alert`, `modal`, `fieldset`), no custom theme, no ledger look of `plan 11: masterplan`.

## Choices this plan makes

- **No form library**: a form is a `Record<string, string>` (plus `string[]` for multi-value fields like settings listings) in React state, sent as JSON. On `422` the `errors` map goes next to each field, `""` above the form. Typed text stays in the inputs after an error (like today''s `form.raw`).
- **Edit forms are pre-filled** from the API''s integer values with TS ports of `web/forms.py`''s `format_money`, `format_hours`, `format_rate` (same output, so what the server parses back is what it sent). These formatters plus display helpers (money with dot thousands, dash for `null`) live in `frontend/src/format.ts` with the only Vitest tests of this plan.
- **Shared components** (`frontend/src/components/`): `DataTable` (columns, rows, empty text, right-aligned number columns, row links), `Field` (label, hint, error), `MoneyInput` / `HoursInput` / `RateInput` (text inputs with `inputMode`, no client parsing), `DateInput` (native `type="date"`), `Select`, `ConfirmDelete` (daisyUI modal with today''s texts, e.g. "Delete this expense?"), `Notices`.
- **Notices** (today''s flash messages): writes return `notices`; a small React context in the shell keeps them and shows them as daisyUI alerts above the page after navigation (info/warning/error), dismissable, replaced by the next write''s notices.
- **One save hook** (`useSave`): TanStack Query mutation → on success push notices, invalidate the resource''s queries, navigate where today''s redirect goes; on 422 return the errors to the form; other errors as an error notice.
- **Same URLs as today**: `/bookings`, `/bookings/new`, `/bookings/:id`, `/bookings/:id/edit`, `/expenses`, `/expenses/new`, `/expenses/:id/edit`, `/recurring`, `/recurring/new`, `/recurring/:id`, `/blocked-days`, `/blocked-days/new`, `/blocked-days/:day`, `/time`, `/time/new`, `/time/:id/edit`, `/rates`, `/rates/new`, `/rates/:day/:currency`, `/settings`. List filters in the URL query as today.
- **After save, as today''s redirects**: booking create/edit → its detail page; booking delete → list (blocked delete → stays on detail with the error notice); expense save/delete → expense list; recurring save → its own page (notice "… N expense(s) generated"), delete → list; blocked day, time entry, rate save/delete → their lists; settings save → settings.
- TS types for each resource mirror the "JSON API" section of `architecture-spec.md`.

## Tasks (in this order; tasks 2–4 require task 1, otherwise independent)

1. **Form kit and time log**: `format.ts` (+ Vitest), the shared components, notices context, `useSave`, then the time log screens (list, new, edit, delete) as the first user of all of it. Needs task 2 of `plan 14: architecture and client toolchain` (frontend skeleton and shell) and `plan 13: JSON API` tasks 70 (foundation) and 73 (blocked days and time log).
2. **Bookings**: list with filters (from, to, listing) in the URL; detail with fields, derived totals, lines table (amount, COP or "needs rate") and the needs-rate warning linking to rates; new/edit (imported: dates, listing, guest name and amount shown read-only, only guests and notes editable, with today''s hint); listing suggestions from the options endpoint; overlap warning notice; delete with confirm (imported text: "It was imported from Airbnb; a re-import brings it back."), blocked delete shown as today. Needs task 1 and task 71 (JSON API: bookings).
3. **Expenses and recurring templates**: expense list with filters; form with category select that shows the booking field only for `per_booking` and useful life only for `capex` (cosmetic, server ignores the rest); hint and link when generated from a template; recurring list, new, own page with form plus its generated expenses linked, delete with today''s notice. Needs task 1 and task 72.
4. **Blocked days, rates and settings**: blocked days list, new as a from/to range with reason and note (hint "Days that are already blocked are skipped.", notices as today), edit by day, delete; rates list, new, edit by (day, currency), delete, with the "N bookings still need a rate" notice; settings form (money fields, allocation select, listing checkboxes plus "another listing", backups to keep, currency shown as COP). Needs task 1 and tasks 73 and 74.

Checks per task, in `frontend/`: `npm run build`, `npm run typecheck`, `npm run lint`, `npm test`; plus `pytest` if Python was touched (it shouldn''t be). Verify each screen by running the server (`--no-browser --port 8080`) and the Vite dev server against a copy of the real database: list, create, edit with an error, delete; ad-hoc headless screenshots are fine, no browser test suite.

Gaps in the API found while building a screen (a missing field or option): follow-up task in `plan 13: JSON API`, not a client-side workaround.

Done when: every data screen of today works through the Vite dev server with the same fields, messages and navigation as the Jinja page it replaces, checks green.', 'The bookkeeping app is moving to screens that run in the browser. This part rebuilds every data entry screen there: the lists and forms for bookings, expenses, monthly recurring expenses, blocked days, logged hours, exchange rates and settings. They look plain for now and behave exactly as today: same fields, same messages, same pages after saving. The server keeps checking everything the user types, so no bookkeeping rule changes.', '2026-10-23T22:47:12Z', 65);
INSERT INTO plan (id, milestone_id, subject, priority, body, intro, created_at, created_by_task) VALUES (16, 3, 'dashboard and charts', 490, 'Part 4 of `plan 12: masterplan`: the dashboard screen at `/` in React. It is built into the app shell of `plan 14: architecture and client toolchain` and reads `GET /api/dashboard` of `plan 13: JSON API`. The Jinja dashboard (`web/dashboard.py`, `templates/index.html`, `web/charts.py`) stays until part 6 and is the reference: same rows, numbers, texts and charts.

Binding:
- `decision 24: client-side framework: React with TypeScript, built by Vite, on top of a JSON API from the existing Python server`: the server does all period handling and metrics. The client only formats numbers and draws.
- `decision 18: dashboard layout: which periods are shown and which period the cost breakdown uses`: one column per period (all-time, last 90, last 30, this month, chosen month, custom range when set). The breakdown uses the custom range, else the chosen month. Period choices live in the URL (`?month=&from=&to=`), so a view can be bookmarked.
- `decision 10: a figure that cannot be computed is shown as empty, not as zero`: `null` → "–" in the table and a gap in the line chart.
- `decision 13: the rolling 90-day chart starts once 90 days of history exist`: an empty series → today''s text.
- `decision 25: In which order do the visual design update and the new client-side framework happen, and does the design work move onto the new screens?`: the design update waits until this milestone is done. So the dashboard uses plain daisyUI default classes (`table`, `input`, `btn`, `alert`), no custom theme.

## Choices this plan makes

- **No chart library.** There are only two simple charts, and `web/charts.py` already draws them by hand in about 170 lines. A port to React SVG keeps the same look, ticks and labels, adds no dependency and works offline. A library (Recharts, visx) would bring other ticks and a different look, which would be a functional change.
- **Period controls**: a small form (Month `type="month"`, From and To `type="date"`, Apply, Reset) bound to `useSearchParams`.
  - The inputs start from the `form` field of the API response (the effective month, which defaults to last month, plus `from` and `to`).
  - Apply writes the non-empty values to the URL. Reset goes to `/` with no query. The TanStack Query key includes the query string.
  - Parameter errors (API notices with level `error`, e.g. "enter both a from and a to date") show under the form, as today, not as global notices.
- **Table**:
  - Header cell "COP unless stated"; each column shows its label plus "start – end" as a hint.
  - Values by kind: `pct` → `x*100` with 1 decimal + " %"; `minutes` → hours with 1 decimal; `money` → `format_money` with dot thousands, after truncating like today''s `int(value)`; negatives use "−" (U+2212) and red (`text-error`); `int` as is; `null` → "–".
  - Reuse `frontend/src/format.ts` from `task 84: Form kit (format.ts, shared components, notices, useSave) and time log screens`. Don''t write a second money formatter.
- **Texts as today**:
  - The rate warning "N booking(s) need(s) an exchange rate" is a warning alert linking to `/rates`.
  - Empty state: "Nothing here yet: import the Airbnb CSV or add a booking." (links to `/import` and `/bookings/new`).
  - "Last 90 days, day by day" with "The 90-day chart starts once 90 days of history exist." before the history exists, and "Nothing to chart." for an all-null series.
  - "Expense breakdown" with the range as a hint; "No costs in this period." when all amounts are 0; otherwise the bar chart plus a Category / COP / Share table (share `null` → "–").
- **Chart port** (`frontend/src/charts/`):
  - Pure helpers in `chartMath.ts`: `niceTicks(lo, hi, target=5)`; the y-range logic of `line_chart` (`y_min`/`y_max`, ticks clipped); month-start x labels with the first day labelled when it is not a 1st, thinned by `stride = ceil(n*48/plotWidth)`; splitting a series into runs at `null`.
  - Components: `LineChart` (series, yFormat, yMin, yMax, width, height) and `BarChart` (items, valueFormat, width=600). They keep the same layout constants, Okabe-Ito palette and dash patterns, `<title>` tooltips on points and bars, the legend under the plot, `viewBox` with `width="100%"`.
  - Dashboard charts as today: "ADR and RevPAR (COP)" (800×280, yMin 0, money labels) and "Occupancy" (800×220, 0..1, labels `x*100` with 0 decimals + " %").
  - Dates: do day arithmetic on `YYYY-MM-DD` strings via UTC, so a timezone can''t shift a day. Month labels come from a fixed English list ("Jan 2026"), not from the locale.
- Vitest only for `chartMath.ts`: a few cases whose expected values come from running the Python functions.

## Tasks (in this order)

1. **Dashboard screen without charts**: the route `/` with period controls, error messages, rate warning, empty state, metric table, and breakdown heading plus table. Leave placeholders where the two charts go. TS types for the dashboard response mirror the "JSON API" section of `architecture-spec.md`. Needs `task 80: Frontend skeleton and app shell in frontend/`, `task 75: JSON API: dashboard` and `task 84: Form kit (format.ts, shared components, notices, useSave) and time log screens`.
2. **Charts**: `chartMath.ts` (+ Vitest), `LineChart`, `BarChart`, wired into the dashboard in place of the placeholders. Needs task 1.

Checks per task, in `frontend/`: `npm run build`, `npm run typecheck`, `npm run lint`, `npm test`. Verify by running the server (`--no-browser --port 8080`) and the Vite dev server against a copy of the real database. Compare with the Jinja page at `http://127.0.0.1:8080/` for the default view, `?month=…`, `?from=…&to=…` and an invalid range: same numbers, texts and chart shapes. Ad-hoc headless screenshots are fine; no browser test suite.

Gaps in the API found while building (a missing field): follow-up task in `plan 13: JSON API`, not a client-side workaround. Deleting `web/charts.py` and the Jinja dashboard belongs to part 6.

Done when: the dashboard in the Vite dev server shows the same table, warnings, charts and breakdown as the Jinja page for the same URL, period choices are bookmarkable, and the checks are green.', 'The dashboard is the app''s overview page: a table that compares income, costs, occupancy and profit over several periods, a chart of the last 90 days and a chart of how costs split by kind. This part rebuilds that page as part of the new in-browser app, with the same figures, the same period choices that can be bookmarked, and the same two hand-drawn charts. It looks plain for now; a new look comes later.', '2026-10-23T22:48:37Z', 66);
INSERT INTO plan (id, milestone_id, subject, priority, body, intro, created_at, created_by_task) VALUES (17, 3, 'import flow', 480, 'Part 5 of `plan 12: masterplan`: the import screen at `/import` in React, built into the app shell of `plan 14: architecture and client toolchain` on the import endpoints of `plan 13: JSON API` (`task 76: JSON API: Airbnb and exchange-rate import`). The Jinja pages (`web/importing.py`, `templates/import.html`, `import_preview.html`, `import_summary.html`) stay until part 6 and are the reference: same steps, texts, counts and links.

Binding:
- `decision 24: client-side framework: React with TypeScript, built by Vite, on top of a JSON API from the existing Python server`: parsing, planning and applying the import stay in Python; the client uploads the file and shows what the API returns. No CSV reading in the browser.
- `decision 14: Airbnb import: which rows set a booking''s dates, listing and guest name`: the preview shows the changes the server reports (field: old → new); nothing to decide on the client.
- `decision 25: In which order do the visual design update and the new client-side framework happen, and does the design work move onto the new screens?`: the design update waits until this milestone is done → plain daisyUI default classes only (`table`, `input`, `file-input`, `checkbox`, `btn`, `alert`), no custom theme.

## Choices this plan makes

- **One route, steps in component state**: `/import` shows upload forms → preview → summary without changing the URL (today the preview and summary are POST responses with no URL of their own either). A reload or leaving the page goes back to the upload forms; the kept upload file is left as today (only Cancel and Import delete it).
- **Uploads**: a small `postFile(path, FormData)` in `frontend/src/api.ts` next to the JSON helpers (no `Content-Type` header, the browser sets the multipart boundary; same `ApiError` handling). Writes stay same-origin (the browser sends `Origin`; the guard is untouched).
- **Airbnb steps** (texts as today):
  - Upload: "You see what would change before anything is written.", file input (`.csv,text/csv`), Preview. No file chosen → "choose the Airbnb CSV file"; a file error (wrong columns, …) from the API shown above the form.
  - Preview, listing choice needed: today''s paragraph ("No listings of this property are chosen yet. …"), one checkbox per listing found with its row count (in the server''s order, most rows first), "Another listing name". Import with nothing chosen → the API''s 422 "choose at least one listing" above the form, preview kept.
  - Preview otherwise: "Listings imported: …"; tables for new bookings (code, check-in – check-out, guest, listing, lines) and updated bookings (code, changes `field: old → new` or "new lines only", new lines); skipped (payout rows, already imported lines, rows of other listings with per-listing counts); problems ("line N: message", as errors) and warnings.
  - Import → summary: "N new booking(s), N updated, N line(s) added", "N booking(s) need an exchange rate (rates)" linking to `/rates`, skipped counts, problems, warnings, link to `/bookings`.
  - Cancel → `DELETE` → back to the upload forms with the notice "Import cancelled; nothing was changed." via the notices context of `task 84: Form kit (format.ts, shared components, notices, useSave) and time log screens`.
  - "The uploaded file is gone; upload it again" (API error on apply) → back to the upload form with that error.
- **Exchange rates (TRM)** on the same page: hint "CSV from datos.gov.co with the columns VALOR and VIGENCIADESDE.", file input, Currency (default `USD`, typed text kept after an error), "Load rates"; field errors via the `Field` component; success → "USD rates: N added, N changed; N line(s) recomputed; N booking(s) still need an exchange rate." plus the problem list.
- **After a successful Airbnb import or rates load**: invalidate all TanStack queries (bookings, rates, dashboard all change), so other screens show fresh data.
- TS types for the import responses mirror the "JSON API" section of `architecture-spec.md`. No Vitest tests (no pure helpers worth testing here).

## Tasks (in this order)

1. **Airbnb import flow**: `postFile` in `api.ts`, the `/import` route replacing the shell''s placeholder with the Airbnb upload, preview (both variants), listing choice, Import, Cancel and summary as above. Needs `task 76: JSON API: Airbnb and exchange-rate import`, `task 80: Frontend skeleton and app shell in frontend/`, `task 81: Flask serves the built frontend; Vite dev proxy; README Develop section` and `task 84: Form kit (format.ts, shared components, notices, useSave) and time log screens`.
2. **Exchange-rate import**: the TRM section on the same page as above. Needs task 1.

Checks per task, in `frontend/`: `npm run build`, `npm run typecheck`, `npm run lint`, `npm test`. Verify by running the server (`--no-browser --port 8080`) on a **copy** of the real database (and once on an empty one, for the listing choice) with the Vite dev server: upload `airbnb_.csv` (preview counts equal the Jinja page''s for the same file and database), Cancel, upload again and Import, re-import (everything skipped), a non-CSV file (error); TRM: a fixture from `tests/fixtures`, a bad currency. Ad-hoc headless screenshots are fine; no browser test suite.

Gaps in the API found while building (a missing count or field): follow-up task in `plan 13: JSON API`, no client-side workaround. Deleting the Jinja import pages belongs to part 6.

Done when: the import screen in the Vite dev server goes through every step of today''s import pages with the same texts and counts, checks green.', 'The app reads two kinds of files: the earnings export from Airbnb, which brings in bookings and their payouts, and a list of official dollar-to-peso exchange rates. This part rebuilds the import page as part of the new in-browser app: upload the Airbnb file, see what would change before anything is written, pick which listings belong to the property the first time, confirm, and read a short summary, plus the upload of exchange rates. It looks plain for now and behaves exactly like today''s page.', '2026-10-23T22:49:54Z', 67);
INSERT INTO plan (id, milestone_id, subject, priority, body, intro, created_at, created_by_task) VALUES (18, 3, 'retire the server-rendered pages', 400, 'Part 6 of `plan 12: masterplan`: delete the Jinja pages once the React screens of parts 3–5 replace them, so the Flask app is only the JSON API plus the built bundle. No functional change: same screens, numbers, texts and URLs, now all served by the React app (the 404 fallback of `plan 14: architecture and client toolchain` answers every non-`/api` URL with `index.html` once the HTML routes are gone).

Binding: `decision 24: client-side framework: React with TypeScript, built by Vite, on top of a JSON API from the existing Python server` (Flask = JSON API + bundle; parsing stays in `web/forms.py`), `decision 10: a figure that cannot be computed is shown as empty, not as zero`, `decision 13: the rolling 90-day chart starts once 90 days of history exist` (the chart now lives in `frontend/src/charts/`), `decision 25: In which order do the visual design update and the new client-side framework happen, and does the design work move onto the new screens?` (its consequences already say `plan 11: masterplan` targets the templates deleted here; nothing more to record).

## What goes, what stays

- **Goes**: `web/templates/` (all 21 templates incl. `stopped.html`), the HTML view functions and `register(app)` calls of `web/dashboard.py`, `bookings.py`, `expenses.py`, `blocked.py`, `timelog.py`, `settings.py`, `importing.py`; `POST /quit` (the API''s `POST /api/quit` stays); the Jinja filters `money`, `rate`, `hours` and the `nav` context processor in `web/app.py`; `app.secret_key` and `flash` if nothing uses them any more; `web/charts.py` and `tests/test_charts.py` (ported to `frontend/src/charts/` by `plan 16: dashboard and charts`; check `web/api/` does not import it first).
- **Stays**: `web/forms.py` (parsers, `Form`, `format_*` used by the API), `web/app_db.py`, the same-origin guard, the bundle serving and fallback, `NAV` only if something still reads it (else delete; the React shell has its own nav).
- **Shared helpers** the API still uses from the old modules (`_overlaps`, `_needs_rate_message`, the dashboard''s period handling, the import''s token/temp-file handling, `booking_options`, …): move them next to their API module or into one plain helper module in `web/`, so no module is left that only exists for deleted pages. No behaviour change; drop the leading underscore where they become cross-module.
- **Packaging**: `pyproject.toml` package data without `web/templates/*.html` (keeps `web/dist/**/*` and migrations); explicit `jinja2` dependency dropped from `pyproject.toml` and `flake.nix` (Flask still pulls it in), `nix flake check` green.

## Tests (AGENTS.md: sparse)

- `tests/test_web.py`: keep the parser and helper tests (`parse_money`, `parse_hours`, `format_*`, `Form`, `booking_options`, one connection per request), renamed to `tests/test_forms.py` if that''s all that is left; delete the HTML route tests. Before deleting one, check its rule is covered by a `tests/test_api_<resource>.py` test of `plan 13: JSON API`; port only the uncovered ones as API tests (likely: typed rate equals TRM-imported rate, expense fields ignored for other categories, recurring edit keeps generated rows). Don''t grow the suite beyond that.
- `tests/test_e2e.py`: same scenario and same hand-computed October 2026 numbers (the docstring stays the reference), driven through `/api` instead of HTML scraping: import with listing choice, rates, expenses, time, dashboard JSON values, `/api/quit`, backup and restore. This rewrite can happen before the deletion (it needs only the API), so the deletion task then runs on a green suite.

## Tasks (in this order)

1. **End-to-end test through the API**: rewrite `tests/test_e2e.py` as above; same assertions on the numbers. Requires the JSON API tasks of `plan 13: JSON API` (70–76) only, not the screens.
2. **Delete the server-rendered pages**: everything under "Goes", the helper moves, packaging, the `tests/test_web.py` reduction and `tests/test_charts.py` deletion as above. Check with a built bundle that `GET /`, `/bookings/<id>`, `/rates/<day>/<currency>` answer `200` with `index.html`, unknown `/api/...` stays JSON 404, `/assets/...` load. Requires task 1, `task 81: Flask serves the built frontend; Vite dev proxy; README Develop section`, `task 82: Nix packaging of the frontend bundle and frontend-lint check` and every implementation task of parts 3–5: `task 84: Form kit (format.ts, shared components, notices, useSave) and time log screens`, `task 85: Booking screens: list with filters, detail, new/edit, delete`, `task 86: Expense and recurring template screens`, `task 87: Blocked days, exchange rate and settings screens`, `task 89: Dashboard screen without charts`, `task 90: Dashboard charts: chartMath, LineChart, BarChart`, `task 92: Import screen: Airbnb import flow in React`, `task 93: Import screen: exchange-rate (TRM) import in React`.
3. **README and architecture spec final**: README sections Install, Run and quit, Import, Exchange rates kept but checked against the new screens; "Develop" (from task 81) and a "Build" section (`nix build`, `npm run build` for a local bundle, which checks run where); `architecture-spec.md` without any "until part 6" marks, Jinja, `charts.py` or HTML-route mentions; the "JSON API" section checked against the actual endpoints. Requires task 2.
4. **End-to-end check with the real export**: `nix build` and run the built app (`--no-browser --port …`) on a fresh database in a temp dir; through the browser (ad-hoc headless screenshots are fine): import `airbnb_.csv` with the listing choice, load a TRM file or type a rate, add an expense, a recurring template, a blocked day, a time entry, edit settings, check the dashboard (month, custom range, both charts), bookmark-style reload of a few URLs (`/bookings/<id>`, `/?month=…`), Quit. Compare dashboard numbers with a run of the pre-deletion app (git checkout of the commit before task 2) on the same file. Anything wrong: a follow-up task in the plan it belongs to, not a fix here. Done when every screen worked and findings are recorded (task note). Requires tasks 2 and 3.

Checks per task: `pytest`, `ruff check src tests`, `ruff format --check src tests`; task 2 also, in `frontend/`, `npm run build`, `npm run typecheck`, `npm run lint`, `npm test`, and `nix flake check`.

Done when: no Jinja template, HTML route or `charts.py` is left, every URL of today opens the React screen, tests are API tests, README and spec describe the app as it is, and the real export went through the running app.', 'The bookkeeping app''s screens have been rebuilt to run in the browser, but the old pages that the server used to assemble itself are still there alongside them. This last step removes the old pages and the code and tests that only existed for them, so there is one way the app works instead of two. It also brings the user and technical documentation up to date and finishes with a full run-through of the real Airbnb export in the finished app, to confirm nothing was lost on the way.', '2026-10-23T22:51:21Z', 68);
INSERT INTO plan (id, milestone_id, subject, priority, body, intro, created_at, created_by_task) VALUES (19, 2, 'styling foundation', 350, 'Part 1 of `plan 11: masterplan` (`milestone 2: visual design update`): the theme, the app shell and the shared styling conventions that parts 2–4 build on.

## Where things stand (read first)

The masterplan was written for the Jinja templates; `milestone 3: add a proper client-side framework` replaced them (`decision 24: client-side framework: React with TypeScript, built by Vite, on top of a JSON API from the existing Python server`, `decision 26: Once the in-browser screens are done, how does the visual design update continue?`). So:

- **No toolchain work.** `decision 23: How do Tailwind CSS and daisyUI get into an app that promised no build step and no network?` is answered by the current code: `frontend/src/index.css` already loads Tailwind 4 and daisyUI 5 (npm devDependencies), Vite builds the CSS, Nix builds the bundle offline (`flake.nix`: `packages.frontend`, check `frontend-lint`). Nothing to add to `pyproject.toml` or the dev shell.
- `base.html` → `frontend/src/App.tsx` (shell, nav, Quit), `frontend/src/components/Notices.tsx` (flash messages, levels `warning`/`error` from the API), `frontend/src/pages/Stopped.tsx`.
- `web/static/` → `frontend/public/` (Vite copies it into the bundle as is; for the favicon in part 4).
- Tables: `frontend/src/components/DataTable.tsx` + the dashboard table in `pages/Dashboard.tsx`; forms: `components/Field.tsx`, `components/inputs.tsx`, `components/ConfirmDelete.tsx`; charts: `frontend/src/charts/`.

## Ground rules (from the masterplan, for every task here)

- No functional change: same routes, API calls, form fields, validation, notices, numbers and their formats (`decision 15: data entry forms: how money and hours are typed`, `decision 10: a figure that cannot be computed is shown as empty, not as zero`, `decision 18: dashboard layout: which periods are shown and which period the cost breakdown uses`).
- Offline: no CDN, no web fonts or icon fonts, no new npm dependencies (system font stacks; icons are inline SVG or CSS). New behaviour-free JS only where React needs it for a cosmetic detail.
- Readability first: playful touches never hide numbers or labels; negatives stay clearly red. Light theme only (`pm decision record` by this plan''s writer: "visual design: one light ledger theme, no dark mode").
- Checks after every change: in `frontend/`: `npm run typecheck`, `npm run lint`, `npm test`, `npm run build`; `pytest`; `nix flake check` (runs biome/tsc/vitest and the package build). Look at the pages by running the app (`npm run build` then `rios-de-asia-accounting --no-browser`; ad-hoc screenshots with a headless browser if one is at hand, no new test suites).

## Tasks

1. **Ledger theme** (`frontend/src/index.css`, `frontend/index.html`)
   - A custom daisyUI theme `ledger` (`@plugin "daisyui/theme" { name: "ledger"; default: true; … }`) replacing `light`: warm off-white paper `base-100`, slightly darker `base-200/300` for chrome and header rows, ledger green as `primary`, ledger blue as `secondary`/`info`, a clear red ink `error`, readable `warning`; `--radius-*` small (paper, not bubbly); `data-theme="ledger"` in `index.html`; `color-scheme: light`.
   - Shared utility classes in `index.css` (`@layer components` or `@utility`): `num` (tabular-nums, right-aligned, monospace system stack) and `neg` (red ink, `color: var(--color-error)`), plus CSS variables for the rule colours (e.g. `--ledger-rule` green/blue) that parts 2 and 4 use for grid lines and underlines.
   - Contrast: body text and `error` on `base-100` at least WCAG AA.
   - Done when the app builds and every page renders in the new colours with nothing else changed.
2. **App shell** (`App.tsx`, `components/Notices.tsx`, `pages/Stopped.tsx`), requires 1
   - Nav as sheet tabs along the top (daisyUI `tabs` `tabs-lift` or `tabs-border`, `NavLink` active → `tab-active`), same entries from `nav.ts`, same order and paths; the app name link to `/` stays; wraps or scrolls on narrow windows.
   - Quit as a small outlined button on the right, still disabled while pending; its error alert kept.
   - Notices as daisyUI alerts with a small inline-SVG icon per level, `alert-warning`/`alert-error` from the notice level, Dismiss kept.
   - `<main>` as a "sheet of paper": centred card (`card bg-base-100 shadow`, max width), on a `base-200` desk background, attached to the active tab.
   - `Stopped.tsx` on the same paper card (part 4 decorates it further). Same texts.
3. **Shared conventions** (README section "Styling conventions", small components), requires 2
   - `PageTitle` (h1, optional slot for part 4''s section icon) and `SectionTitle` (h2) components replacing the repeated `text-2xl font-bold mb-4` / `text-xl font-bold …` classes in `pages/*.tsx`; same texts.
   - README section listing what parts 2–4 use: numbers `num`/`neg`; tables via `DataTable` (part 2 restyles it, pages don''t add table classes); forms via `Field` + `inputs.tsx`, form actions in one `flex gap-2 mt-4` row; buttons: `btn btn-primary` Save/Apply, `btn btn-ghost` or `btn-soft` Cancel/Reset links, `btn btn-error` Delete via `ConfirmDelete`; errors: page-level `alert alert-error`, field-level `text-error` under the field (in `Field`); hints: `Field`''s `hint`; muted notes `opacity-70`; icons inline SVG components in `frontend/src/components/icons.tsx` (created by part 4).
   - Done when no page uses the old heading classes and the README section exists.', 'The bookkeeping app is getting a friendlier look inspired by paper ledgers and spreadsheets, without changing what any screen does. This first step sets up the shared groundwork: a colour scheme like ruled ledger paper with red ink for losses, the frame around every screen (the menu, the messages, the page area), and a short guide for how tables, forms and buttons should be styled. The later design steps build on it, so the whole app ends up looking consistent.', '2026-10-24T00:12:11Z', 57);
INSERT INTO plan (id, milestone_id, subject, priority, body, intro, created_at, created_by_task) VALUES (20, 2, 'spreadsheet-style tables and dashboard', 300, 'Part 2 of `plan 11: masterplan` (`milestone 2: visual design update`): every table and the dashboard in spreadsheet style. Builds on `plan 19: styling foundation`; read its "Where things stand" section first (the app is React now, `decision 26: Once the in-browser screens are done, how does the visual design update continue?`).

## What exists

- `frontend/src/components/DataTable.tsx`: the shared list table (`columns` with `header`, `cell`, `numeric`, `href`; `empty` text row; optional `footer` rows). Used by bookings, booking detail lines, expenses (list + recurring + generated), blocked days, time log, rates. Expenses and Time pass footer total rows (`<th colSpan=…>Total</th>` …).
- Hand-built tables: booking detail key/value table (`pages/Bookings.tsx` `BookingDetail`), import preview''s two tables (`pages/Import.tsx`, new bookings / changed bookings), dashboard metric table and expense breakdown table (`pages/Dashboard.tsx`).
- Dashboard: `PeriodForm` (Month, From, To, Apply, Reset link to `/`, error lines below), the "N booking(s) need(s) an exchange rate" warning, `cell()` formatting with the real minus sign `−` and `text-error` for negative money.
- Charts: `frontend/src/charts/LineChart.tsx`, `BarChart.tsx`, colours `PALETTE`/`DASHES` in `chartMath.ts`, hard-coded `GRID`/`TEXT` greys, `fontFamily="sans-serif"`.

## Ground rules (every task)

- No functional change: same texts, numbers and formats (`decision 10: a figure that cannot be computed is shown as empty, not as zero` dash, the `−` sign, `%` and hours formats, `decision 15: data entry forms: how money and hours are typed`), same columns and order, links, URL parameters and dashboard structure (`decision 18: dashboard layout: which periods are shown and which period the cost breakdown uses`).
- Offline, no new npm dependencies, no web fonts; one light theme (`decision 28: visual design: one light ledger theme, no dark mode`).
- Use part 1''s conventions: `num` / `neg` classes, the `--ledger-rule` colour variables, `PageTitle` / `SectionTitle`, the README "Styling conventions" section. Add to that README section what this part introduces (the `sheet` table classes).
- Decorations (column letters, row numbers) are `aria-hidden` and never replace a real header or value.
- Checks: in `frontend/`: `npm run typecheck`, `npm run lint`, `npm test`, `npm run build`; `pytest`; `nix flake check`. Look at the pages in the running app (`rios-de-asia-accounting --no-browser`), with a few rows of data and with none.

## Tasks

1. **Spreadsheet table style and `DataTable`** (requires part 1''s "ledger theme" and "shared conventions" tasks)
   - A `sheet` component class in `frontend/src/index.css` (on top of daisyUI `table`): thin grid lines on every cell in the ledger rule colour, header cells like spreadsheet column headers (`base-200`, small, semibold), zebra rows, compact cell padding, hover highlight of the row; footer rows (totals) set off with a heavier top rule (part 4 may add a double underline).
   - `DataTable` uses it, wrapped in `overflow-x-auto`: numeric columns get `num` instead of `text-right`; a decorative letter row (A, B, C … one per column) above the real header row and a row-number gutter (1, 2, 3 …) on the left, both `aria-hidden`, muted, like a spreadsheet''s frame; the empty-state row keeps its text and spans all columns.
   - Footer rows need a gutter cell too: export a small helper (e.g. `SheetFooterRow` or a `gutter` cell) and use it in the Expenses and Time footers; their total cells get `num`.
   - Optional `negative?: (row) => boolean` on `Column` that adds `neg`; use it for booking detail lines (`Amount`, `COP` below zero). Only the colour changes, not the text.
   - Done when all `DataTable` pages show the sheet look with the same columns, texts and links.
2. **Other tables on the sheet style** (requires 1)
   - Import preview: the two tables use `sheet` (via `DataTable` where it fits without changing text, else the same classes and gutter by hand); the import summary stays a list (part 4 decorates it).
   - Booking detail key/value table: a two-column sheet with the labels as a header column (`base-200`), money values `num`.
   - Done when no table in `pages/` other than the dashboard uses plain `className="table"`.
3. **Dashboard metric table, toolbar and headings** (requires 1)
   - Metric table and expense breakdown table on `sheet`: period columns as column headers (label + muted date range), metric labels as a frozen first column (`sticky left-0` with background) so wide tables scroll under it, values `num`, negatives `neg` instead of `text-error` (same `cell()` text with `−`).
   - `PeriodForm` as a compact "formula bar": one bordered strip (`base-200`, small inputs `input-sm`, short inline labels Month/From/To, an `fx`-like decorative marker, `aria-hidden`), Apply `btn-primary btn-sm`, Reset `btn-ghost btn-sm` link to `/`; same input names, same submit behaviour, error lines below the strip as `text-error`. Wraps on narrow windows.
   - Headings via `PageTitle`/`SectionTitle` (if part 1 did not already), chart sub-headings (`h3`) in the same style one size smaller; date range after "Expense breakdown" muted.
   - The exchange-rate warning as the same alert style as part 1''s notices (warning icon), still a link to `/rates` with the same text; the "Nothing here yet" empty text unchanged (part 4 may decorate it).
   - Done when the dashboard reads like one sheet with a toolbar on top and every number is where it was.
4. **Charts in the ledger colours** (requires part 1''s "ledger theme" task)
   - `chartMath.ts` `PALETTE`, `LineChart.tsx`, `BarChart.tsx`: series colours from the theme (ledger green, ledger blue, then two more distinguishable inks; no red for a series, red means negative), keep `DASHES` so series differ without colour; grid lines in the ledger rule colour, axis text in the base content colour, `fontFamily` the app''s system stack (or `inherit`), tick labels with tabular figures; bars in ledger green.
   - Colours via CSS variables (`style`/Tailwind `stroke-*`/`fill-*` classes; SVG presentation attributes don''t resolve `var()`), so the theme stays the single source.
   - Same data, series, sizes, labels, `<title>` tooltips; `chartMath.test.ts` keeps passing (adjust only an assertion on literal colour values).
   - Done when the charts match the theme in the running app.', 'The app''s lists of bookings, expenses, hours and rates, and the summary figures on its front page, are going to look like a spreadsheet: ruled grid lines, a header row like column headings, alternating row shading, numbers lined up on the right and losses in red ink. The front page''s period picker becomes a slim toolbar like the formula bar of a spreadsheet, and the charts take on the same paper-and-ink colours. Nothing about what is shown or how it is calculated changes; the point is that the books look and read like books.', '2026-10-24T00:13:47Z', 58);
INSERT INTO plan (id, milestone_id, subject, priority, body, intro, created_at, created_by_task) VALUES (21, 2, 'forms and actions', 300, 'Part 3 of `plan 11: masterplan` (`milestone 2: visual design update`): every form and every action button. Builds on `plan 19: styling foundation`; read its "Where things stand" section first (the app is React now, `decision 26: Once the in-browser screens are done, how does the visual design update continue?`). The dashboard''s period form is not here: `plan 20: spreadsheet-style tables and dashboard` turns it into a "formula bar".

## What exists

- `frontend/src/components/Field.tsx`: daisyUI `fieldset` label with `fieldset-legend`, optional `hint` (muted) and `error` (`text-error`) under the control.
- `frontend/src/components/inputs.tsx`: `MoneyInput`, `HoursInput`, `RateInput`, `DateInput`, `MonthInput`, `TextField` (all plain text/date/month `input`s, typed text goes to the server as is), `Select`, `TextArea`.
- `frontend/src/components/ConfirmDelete.tsx`: outlined red trigger button + `<dialog class="modal">` with Delete / Cancel.
- Entry forms (`max-w-lg`, actions in `flex gap-2 mt-4`, Save `btn-primary`, Cancel `btn` link, ConfirmDelete in a `mt-6` block below): booking (`pages/Bookings.tsx`, Airbnb bookings with read-only fields, `decision 17: bookings from the Airbnb import: dates, listing and guest name are read-only in the edit form`), expense and recurring expense (`pages/Expenses.tsx`, category-dependent Booking / Useful life fields, own `FormError`), blocked days, time entry, rate, settings (listing checkboxes in a `fieldset`).
- Page-level errors: `<div role="alert" className="alert alert-error mb-4">` repeated in every page, `FormError` in Expenses, `Alert` in Import.
- List filter bars on Bookings, Expenses, Blocked days, Time, Rates: `flex flex-wrap items-end gap-2` with From/To/…, a plain `btn` Filter and a `btn-primary` "New …" link. Booking detail: Edit (`btn-primary`) / Back (`btn`) links.
- Import (`pages/Import.tsx`): Airbnb CSV upload (`file-input`, Upload), preview form (listing checkboxes, "Another listing name", Import / Cancel buttons), TRM upload (file, Currency, "Load rates"), success `alert-success`.

## Ground rules (every task)

- No functional change: same field names, labels, hints, order, which fields show when, read-only rules, validation and error texts, notices, button labels, links, `disabled` while pending, confirm dialogs with the same question/detail (`decision 15: data entry forms: how money and hours are typed`: inputs stay plain text, no client-side parsing or masks).
- Offline, no new npm dependencies, no web fonts, inline SVG only; one light theme (`decision 28: visual design: one light ledger theme, no dark mode`); no new JavaScript behaviour.
- Use part 1''s conventions (README "Styling conventions", `PageTitle`/`SectionTitle`, `num`, `--ledger-rule` variables) and add to that README section what this part introduces (`FormSlip`, `FormActions`, `FormError`, `Toolbar`, button roles).
- Accessibility kept: every control keeps its label, errors stay next to their field, focus rings visible, dialogs still `showModal()`.
- Checks: in `frontend/`: `npm run typecheck`, `npm run lint`, `npm test`, `npm run build`; `pytest`; `nix flake check`. Look at each form in the running app (`rios-de-asia-accounting --no-browser`) empty, filled and with server errors (submit nonsense).

## Tasks

1. **Form building blocks** (requires part 1''s "ledger theme" and "PageTitle/SectionTitle + README" tasks)
   - `FormSlip` (new, `components/FormSlip.tsx`): the "journal entry slip" card around a form: paper `base-100` card with a thin border, a ledger-ruled header strip (`base-200`, small caps label such as "Entry" passed in, plus an optional decorative entry-number/date slot, `aria-hidden`), a red vertical margin rule on the left like ledger paper (CSS, `--ledger-rule` / error colour at low opacity), `max-w-lg`; children are the form.
   - `Field`: daisyUI 5 `fieldset` + `label` styling, inputs full width inside the slip, hint as a muted `label`/`fieldset-label` line, error as `text-error` with a small inline-SVG warning mark; money/hours/rate inputs get `num` (tabular, right-aligned) via `inputs.tsx`; read-only values (Airbnb bookings) styled as "inked" text, not as disabled inputs, if they are inputs today keep them as they are.
   - `FormActions` (row: primary first, then secondary links/buttons, `flex flex-wrap gap-2 mt-4`, a ruled top border like the slip''s foot) and `FormError` (page-level `alert alert-error` with icon) as shared components; the Expenses `FormError` and Import `Alert` move there.
   - Button roles: primary submit `btn btn-primary`, Cancel/Back/Reset `btn btn-ghost` (or `btn-soft`), Delete trigger `btn btn-error btn-outline btn-sm` under a thin rule ("void entry" area); `ConfirmDelete` dialog as a small slip (`modal-box` with the same header strip, question, muted detail), Delete `btn-error`, Cancel `btn-ghost`; same texts, same `pending` handling.
   - Done when the components exist, `ConfirmDelete` is restyled, README updated, and nothing else changed yet.
2. **Booking and expense forms on the slip** (requires 1): `pages/Bookings.tsx` form + detail actions (Edit/Back), `pages/Expenses.tsx` expense and recurring forms; wrap in `FormSlip`, use `FormActions`/`FormError`, two-column grid for paired fields (Check-in/Check-out, Date/Amount) only where they are already side by side. Done when these forms show the slip with the same fields, conditions and errors.
3. **Blocked days, time, rate and settings forms on the slip** (requires 1): same treatment for `pages/Blocked.tsx`, `pages/Time.tsx`, `pages/Rates.tsx`, `pages/Settings.tsx` (listing checkboxes as daisyUI `checkbox` rows inside the slip''s fieldset).
4. **Import forms** (requires 1): `pages/Import.tsx` Airbnb upload and TRM upload as slips ("file-input" styled, Currency short input), preview form''s listing choice and Import/Cancel via `FormActions`; success message stays `alert-success` (part 4 adds the stamp).
5. **List filter toolbars** (requires 1): the filter bars of Bookings, Expenses, Blocked days, Time, Rates as one compact `Toolbar` strip (`base-200`, bordered, `input-sm`/`select-sm`, Filter `btn-sm btn-secondary` or `btn-soft`, the "New …" link `btn-sm btn-primary` pushed to the right), matching the dashboard''s formula-bar look from `plan 20: spreadsheet-style tables and dashboard` (reuse its class if it exists by then, else define `Toolbar` and let part 2 reuse it); filter errors stay below the strip.', 'Every screen where something is typed in (a booking, an expense, hours worked, an exchange rate, the settings, a file to import) is going to look like a filled-in journal entry slip from an old-fashioned ledger: a paper card with ruled lines, tidy labelled fields and clear hints and error messages. Buttons get a consistent meaning by colour: the main action stands out, cancel and reset are quiet, and delete is red and still asks before doing anything. What each form asks for, in which order, and how it checks the input stays exactly as it is.', '2026-10-24T00:14:53Z', 59);
INSERT INTO plan (id, milestone_id, subject, priority, body, intro, created_at, created_by_task) VALUES (22, 2, 'playful bookkeeping touches and favicon', 200, 'Part 4 of `plan 11: masterplan` (`milestone 2: visual design update`): favicon, logo, section icons, empty states, totals, import stamp, stopped page. It decorates finished pages: builds on `plan 19: styling foundation` (read its "Where things stand": the app is React, `decision 26: Once the in-browser screens are done, how does the visual design update continue?`), `plan 20: spreadsheet-style tables and dashboard` and `plan 21: forms and actions`.

## Where things stand

- Shell: `frontend/src/App.tsx` (app-name link, nav from `frontend/src/nav.ts`, Quit), `frontend/index.html` (`<title>rios-de-asia-accounting</title>`, no icon), `frontend/src/pages/Stopped.tsx` (one h1 "rios-de-asia-accounting has stopped, you can close this tab").
- Empty lists: `DataTable`''s `empty` text row ("No bookings.", "No expenses.", "None yet." …); dashboard "Nothing here yet: …" (`pages/Dashboard.tsx`).
- Totals: footer rows of Expenses and Time (`<th>Total</th>`), restyled by part 2 (heavier top rule).
- Import summary: `SummaryStep` in `pages/Import.tsx` ("Import done", a list of counts, problems/warnings); TRM success `alert-success`.
- **Favicon path caveat:** Flask (`src/rios_de_asia_accounting/web/app.py`) serves only `/assets/*` as static files and answers every other GET with `index.html`. A file in `frontend/public/` lands at the bundle root (e.g. `/favicon.svg`) and would get `index.html` back. So put the icon files in `frontend/src/assets/` and link them from `index.html` (`<link rel="icon" href="/src/assets/favicon.svg">`): Vite then hashes them into `/assets/`. No server change; `/favicon.ico` requests keep getting `index.html` (harmless; browsers use the `<link>`).

## Ground rules (every task)

- No functional change: same routes, texts of existing labels, headings, messages and empty texts, numbers and formats (`decision 10: a figure that cannot be computed is shown as empty, not as zero`, `decision 15: data entry forms: how money and hours are typed`). New wording only in decorative extras (a doodle caption, a stamp), never replacing an existing text.
- Decorations are `aria-hidden="true"` (or `role="img"` + `aria-label` only for the logo), never cover or push out a number or label; readable at the narrow window width.
- Offline: inline SVG components and plain CSS only; no icon fonts, web fonts, new npm dependencies or new JavaScript behaviour (CSS animations, if any, short and under `prefers-reduced-motion: no-preference`). One light theme (`decision 28: visual design: one light ledger theme, no dark mode`); colours from the theme variables (`--ledger-rule`, `primary`, `error` …), `currentColor` in icons.
- Icons live in `frontend/src/components/icons.tsx` (small stroke icons, `viewBox="0 0 24 24"`, `className` prop), as the README "Styling conventions" section from part 1 announces; add what this part introduces to that section.
- Checks: in `frontend/`: `npm run typecheck`, `npm run lint`, `npm test`, `npm run build`; `pytest`; `nix flake check`. Look at the pages in the running app (`rios-de-asia-accounting --no-browser`), with data and empty.

## Tasks

1. **Favicon and logo** (requires part 1''s app-shell task)
   - `frontend/src/assets/favicon.svg`: a ledger motif (e.g. an open ledger book with green rules and a red margin line, or an abacus), legible at 16×16; plus `favicon-32.png` and `apple-touch-icon.png` (180×180) rendered once from the SVG with a tool at hand (e.g. `rsvg-convert` via `nix shell`) and committed. Linked from `index.html` (`rel="icon" type="image/svg+xml"`, PNG fallback, `apple-touch-icon`).
   - `Logo` in `icons.tsx` (same motif, inline SVG) next to the app-name link in the navbar; the link text "rios-de-asia-accounting" stays.
   - Done when the browser tab shows the icon in the built app served by Flask (check `/assets/…` in the page source) and the navbar shows the logo.
2. **Section icons** (requires 1, and part 1''s PageTitle task)
   - One icon per nav entry in `icons.tsx`: Bookings (calendar/bed), Expenses (receipt), Recurring (circular arrows), Blocked days (calendar with a cross), Time (clock), Rates (coins/exchange), Import (tray with arrow), Settings (gear), Dashboard (bar chart / ledger) for the home link if part 1 shows one.
   - `nav.ts` entries get an `icon`; the sheet tabs show icon + same label; `PageTitle`''s icon slot used on each section''s pages (list, form, detail). Same labels and order.
   - Done when every tab and page title carries its icon and the nav still reads the same.
3. **Friendly empty states** (requires part 2''s `DataTable` task and dashboard task)
   - `DataTable`''s empty row: above the unchanged `empty` text, a small doodle (blank ledger page, pencil) and a muted decorative caption such as "The ledger is blank", `aria-hidden`; still one row spanning all columns.
   - Dashboard "Nothing here yet: …" (text and links unchanged) on a light card with a larger doodle (empty ledger / sleeping calculator).
   - Done when every empty list and the empty dashboard show the doodle and the same text.
4. **Totals underline and import stamp** (requires part 2''s `DataTable` task, part 3''s import-forms task)
   - Accountant''s double underline under total figures: a `total` class (`border-bottom: 3px double` in ink colour, on the figure cell) in `index.css`, used on the Expenses and Time footer total cells (and dashboard totals only if a row is a sum, e.g. none; don''t invent one).
   - Import summary (`SummaryStep`): a rubber-stamp badge beside "Import done" (rotated a few degrees, outlined, ledger green, uppercase, e.g. "POSTED ✓"; `aria-hidden`); the counts as a tidy ledger list; problems/warnings unchanged. Optionally the same small stamp on the TRM "rates loaded" success alert. The stamp is always shown: it says the import was posted, not that anything balanced, so no "balanced" claim.
   - Done when the summary shows the stamp with all its counts and links unchanged, and totals are double underlined.
5. **Stopped page** (requires 1)
   - `pages/Stopped.tsx` on part 1''s paper card: the same h1 text, the logo, a "books closed" doodle (closed ledger with a ribbon), and a muted decorative line (e.g. "The books are closed for today.").
   - Done when Quit leads to the decorated page with the same sentence.', 'The last step of the bookkeeping app''s new look adds the small, playful touches that make it feel like a well-kept ledger: a browser-tab icon and a little logo, a tiny picture for each section of the app, friendly drawings where a list is still empty, a double line under totals like an accountant draws, an ink-stamp on the import result and a nicer goodbye page after quitting. None of it changes what the app does or what any figure or message says; it only decorates screens that the earlier design steps have already finished.', '2026-10-24T00:15:56Z', 60);
INSERT INTO plan (id, milestone_id, subject, priority, body, intro, created_at, created_by_task) VALUES (23, 4, 'masterplan', 1000, 'The masterplan of `milestone 4: first round of improvements`. **Its own tasks are not implementation work: each of them writes the plan for one part below** (`pm plan add 4 …`, with the priority given here); that plan''s split then creates the implementation tasks.

## Where things stand

- Everything is in whole COP today: `expenses.amount`, `recurring_expenses.amount`, settings `hourly_value_cop` / `long_term_rent_cop_per_month`, `booking_lines.amount_cop` (converted from the line''s currency with `exchange_rates`, "latest rate on or before the line date", rates typed on the Rates page or loaded from a hand-downloaded TRM CSV). `money.py`, `metrics.py`, `allocation.py` and the `booking_totals` view all compute in COP; inputs follow `decision 15: data entry forms: how money and hours are typed` (whole pesos).
- The Airbnb CSV (`airbnb_.csv` is a real sample) has lines in COP and USD; payouts in USD/EUR are ignored.
- Product and architecture specs say "no network access" (`airbnb-bookkeeping-spec.md`, `architecture-spec.md` "Where rates come from"). The owner now asks for fetched rates, so that rule changes for exchange rates only (the bundle still needs no CDN or web fonts).
- Screens (`frontend/src/pages/*`, nav in `frontend/src/nav.ts`): Bookings, Expenses, Recurring, Blocked days, Time, Rates, Import, Settings, plus a Quit button in `App.tsx`. Forms live on separate `/…/new` and `/…/:id/edit` routes in a `FormSlip`; lists are `DataTable` sheets with a "New …" `Toolbar` action.

## Part 1: remove blocked days (plan priority 900)

The owner doesn''t need them. Remove completely:
- a migration dropping `blocked_days` (backup before migrating happens already);
- `BlockedDay`, `Inputs.blocked_days`, the `available = False` step in `allocation.allocate` (every day is available), the start-date rule (`decision 21: the per-day view starts on the first day any input is spread over` loses "blocked day"; record a superseding decision);
- repo functions, `web/api/blocked.py`, the booking-delete check that mentions blocked days, `pages/Blocked.tsx`, routes, nav entry, `BlockedIcon`, tests, specs and README.
- Done when nothing in code, tests or docs refers to blocked days and all checks pass.

## Part 2: USD inside, exchange rates fetched automatically (plan priority 850)

What the owner asked: the whole tool runs on USD; whenever an expense or income is added, the rate of its reference date is fetched and the amount converted to USD if needed. Reference dates:
- Airbnb income: the booking''s first day (check-in), for every line of the booking (not the line''s own date as today);
- an expense: its date; a generated monthly expense: the 1st of its month (already its date, `decision 9: monthly expenses generated from templates are dated the 1st and come back if deleted`);
- settings amounts (long-term rent benchmark, hourly value if it stays): the plan decides (e.g. stored in USD, typed in any currency at today''s rate).

The plan has to settle and record (`pm decision record`):
- **storage:** amounts in USD cents (integers); every converted entry keeps its original amount, currency, rate and rate date so it can be checked and recomputed; `money.py`, `metrics.py`, `allocation.py`, `booking_totals`, dashboard JSON and tests switch from COP to USD;
- **the rate source:** free, no API key, historical daily rates for COP and EUR against USD (candidates to verify: the official TRM API on datos.gov.co, which `importer/trm_csv.py` already parses, plus ECB rates via Frankfurter for EUR; or one multi-currency API). Fetched rates are cached in `exchange_rates` (rebased on USD) so each date is fetched once;
- **when fetching fails** (offline, no rate for a date): what saving an expense and an import do, and what the screen says;
- **existing data:** a migration converting the current COP books to USD (rates for past dates have to be fetched, so it may be a one-off command rather than a plain SQL migration);
- **expense entry:** a currency choice (USD / COP / EUR) next to the amount, replacing whole-peso input (supersedes `decision 15: data entry forms: how money and hours are typed` for money);
- **what goes:** the Rates page, the manual rate API, the TRM CSV import (CLI `import-rates`, Import page section) and "bookings lacking a rate" notices, unless the plan keeps one of them as an offline fallback;
- specs and README updated (the "no network access" rule, the Exchange rates section).

The plan-writing task needs web access to check the rate APIs.

## Part 3: display currency (plan priority 500)

- A currency switch visible on every screen (USD, COP, EUR; default USD). On change, today''s rate is fetched once and every amount on every screen (dashboard, charts, lists, totals) is converted with that one rate; stored books stay USD.
- The chosen currency and the rate fetched with it are kept (the existing `currency` setting) so a reload shows the same figures until the owner switches again; the screen says which rate and date are used.
- Settle: whether conversion happens on the server (API returns amounts in the display currency) or in the client; number formats per currency (pesos without decimals, USD/EUR with two).
- Builds on part 2: its plan task requires part 2''s plan task.

## Part 4: add expenses inline in the sheet (plan priority 400)

- Expenses and Recurring: the "New expense" / "New recurring expense" button becomes a "+" button; pressing it opens an entry row inside the `DataTable` sheet itself (one input per column, Save/Cancel at the row end) instead of the separate `/new` page with a `FormSlip`.
- The date field of a new expense is pre-filled with today''s date; a new recurring expense''s start month with this month.
- Field errors appear in the row; the `/expenses/new` and `/recurring/new` routes go. Editing existing rows keeps its page unless the plan finds the inline row reusable for it at no extra cost.
- Uses the currency choice from part 2, so its plan task requires part 2''s plan task; README styling conventions get the new pattern.

## Part 5: hand-entered bookings, the Time page and the Quit button (plan priority 400)

The owner doesn''t understand these; each has a question for the owner, and the plan follows the answers:
- `decision 29: Hand-entered bookings: remove the ''New booking'' button so that all income comes from the Airbnb CSV?` (the owner expects all income to come from the CSV);
- `decision 30: Time page: remove the log of your own hosting hours, or keep it and explain it?` (removal also drops the time log table, the profit-per-hour and own-time metrics, the hourly-value setting, and the "time entry" in `decision 21: the per-day view starts on the first day any input is spread over`);
- `decision 31: Quit button: remove it, or keep it with a clearer name?`.
- Its plan task waits for all three decisions. Removals include API, routes, nav, tests, specs and README.

## Order

- Part 1 before part 2, so the USD migration doesn''t carry blocked days along. Parts 3 and 4 after part 2''s plan. Part 5 is independent and runs once the owner has answered.
- All work runs in the `main` work tree.', 'This round of improvements comes from the owner''s first real use of the bookkeeping app. Its biggest change: the books are kept in US dollars, with each amount converted automatically at the exchange rate of its own date and shown in dollars, pesos or euros as the owner picks. It also takes away screens that confused more than they helped (blocked days, typed-in exchange rates, and, depending on the owner''s answers, typed-in bookings, the hours log and the quit button), and lets new expenses be typed straight into the spreadsheet-like table.', '2026-10-24T03:15:59Z', NULL);
INSERT INTO plan (id, milestone_id, subject, priority, body, intro, created_at, created_by_task) VALUES (24, 4, 'remove blocked days', 900, 'Part 1 of `plan 23: masterplan`. Blocked days go completely; afterwards nothing in code, tests or docs refers to them and all checks pass (pytest, ruff, frontend typecheck/build).

Rules this plan follows:
- `decision 32: the per-day view starts on the first day any input is spread over, without blocked days` (supersedes `decision 21: the per-day view starts on the first day any input is spread over`).
- Every day is available: available nights of a period = its number of days. `Day.available` goes; `metrics.py` counts days instead of summing the flag (period metrics, break-even, rolling window). The dashboard row "Available nights" stays.
- The database is backed up before migrating already; the migration just drops the table.

## Task 1: backend removal

- New migration `storage/migrations/0002_drop_blocked_days.sql`: `DROP TABLE blocked_days;` (`0001_init.sql` stays untouched).
- `model.py`: drop `BlockedDay`, `Inputs.blocked_days`, `Day.available`.
- `allocation.py`: drop blocked days from the default start and the `available` steps; update the docstrings.
- `metrics.py`: available nights = number of selected days (see above).
- `storage/repo.py`: drop the blocked-days section (`_blocked`, `set/get/list/delete_blocked_day`) and `blocked_days=` in the inputs loader.
- `web/api/blocked.py` and its registration in `web/api/__init__.py` go.
- Tests: delete `tests/test_api_blocked.py`; remove blocked-day cases from `test_allocation.py`, `test_repo_other.py`, `test_schema.py`, `test_metrics.py` (days built with `available=`, `test_rolling_window_without_available_nights` goes or is rewritten), `test_e2e.py` (the 2026-10-15 blocked day; expected figures such as `available_nights` change, recompute them). Add a schema check that `blocked_days` is gone after migrating.
- Done when `rg -i blocked src tests` only finds the unrelated "blocked by expenses" wording (or nothing) and pytest + ruff pass.

## Task 2: frontend, specs and README (requires task 1)

- `frontend/src/pages/Blocked.tsx` goes; its routes in `App.tsx`, the nav entry in `nav.ts`, `BlockedIcon` in `components/icons.tsx`.
- Rebuild the bundle in `src/rios_de_asia_accounting/web/dist` the way the project does it.
- `airbnb-bookkeeping-spec.md`: the blocked-days input, the `blocked_days` table, "available = false", the CRUD list; occupancy/RevPAR read "÷ nights in the period".
- `architecture-spec.md`: the `/blocked-days` route list, `model.py`/`allocation.py` lines, the `/api/blocked-days` endpoints; the booking delete line says "refused while it has expenses" instead of "blocked by expenses" so a search for "blocked" comes back clean.
- `README.md`: `BlockedIcon` in the section icons list, any other mention.
- Done when `rg -i blocked` (outside `tasks.sql`, caches and the old migration) finds nothing and the frontend builds.', 'The bookkeeping tool lets the owner mark single days as unavailable (cleaning buffers, own use, repairs), which lowers the count of nights the apartment could have been rented. The owner doesn''t use or need this, so the feature goes completely: its stored data, its screen and its effect on the figures. From then on every day counts as available, which keeps occupancy and revenue-per-night figures simple.', '2026-10-24T03:19:55Z', 126);
INSERT INTO plan (id, milestone_id, subject, priority, body, intro, created_at, created_by_task) VALUES (25, 4, 'USD inside, exchange rates fetched automatically', 850, 'Part 2 of `plan 23: masterplan`. Afterwards the books run on USD cents, rates are fetched and cached automatically, the existing COP books are converted, and nothing refers to typed rates, the Rates page or the TRM CSV import. All checks pass (pytest, ruff, frontend typecheck/lint/test/build, `nix flake check`).

Rules (binding):
- `decision 34: money is stored in US cents, and every converted entry keeps what was typed`
- `decision 35: exchange rates: TRM from datos.gov.co for COP, ECB via Frankfurter for EUR, cached per day` (endpoints and response formats are in it)
- `decision 36: reference date of a conversion: check-in for Airbnb income, the entry''s own date for expenses`
- `decision 37: when no exchange rate can be fetched, entries are saved and wait for their rate`
- `decision 38: existing peso books are converted by the app itself after the migration`
- `decision 39: money entry: an amount with a currency choice (USD, COP, EUR)` (supersedes `decision 15: data entry forms: how money and hours are typed` for money)
- `decision 40: the Rates page, typed rates and the TRM file import go; no offline fallback`
- `decision 41: settings amounts are stored in USD and typed in any currency at the rate of the day they are saved`
- Hand-entered bookings stay (`decision 29: Hand-entered bookings: remove the ''New booking'' button so that all income comes from the Airbnb CSV?`); the time log and hourly value go in part 5 (`decision 30: Time page: remove the log of your own hosting hours, or keep it and explain it?`), so this plan doesn''t touch them beyond what decision 41 says.

## Task 1: fetch rates from the two sources (requires `task 133: remove blocked days from the frontend, specs and README`)

- New module (e.g. `src/rios_de_asia_accounting/rates.py`): `fetch_cop(start, end)` (datos.gov.co SODA) and `fetch_eur(start, end)` (Frankfurter v2, `providers=ECB`), each returning the rates received as (date, currency units per USD × 1 000 000) plus the coverage date reached (COP: latest `vigenciahasta`; EUR: min(end, yesterday)). Stdlib `urllib`, 10 s timeout, User-Agent; one `RateUnavailable` error for network, HTTP and format problems.
- Pure parsing split from HTTP so it is testable with recorded responses (small JSON fixtures in `tests/fixtures/`, taken from the real endpoints); no test touches the network.
- No database or caller changes yet. Done when the parsers are covered by a few tests and one ad-hoc run against the real endpoints (not committed) returns sensible rates for 2021-12-31 and today.

## Task 2: the backend runs on USD (requires task 1; opus)

- Migration `storage/migrations/0003_usd.sql` per decisions 34 and 38: expenses `amount` = USD cents (NULL while waiting) + `original_minor`, `currency`, `rate`, `rate_date`; recurring templates `amount_minor` + `currency`; booking lines drop `amount_cop`, add `amount_usd`, `service_fee_usd`, `gross_usd`, `rate_date` (rate reset to NULL); `exchange_rates` emptied and rebased (currency units per USD × 1 000 000) plus a coverage table; `booking_totals` sums the USD columns and exposes `waiting` instead of `needs_rate`; settings `long_term_rent_cop_per_month` → `long_term_rent_usd` / `long_term_rent_entered`. Old values move into the original columns as COP. SQLite table rebuilds where `ALTER` can''t do it.
- `money.py`: `to_usd(original_minor, rate)` replaces `to_cop`/`COP_RATE`. `model.py`: the new fields; `Day` and metrics docstrings say USD cents.
- Rate cache and conversion: `rate_on(conn, currency, day)` (cache, coverage, fetch on miss, provisional after coverage) and `convert_waiting(conn, today)` (all waiting or provisional expenses, lines and settings; one range fetch per currency). Called on app start after migrating and generating recurring expenses, before the dashboard is built, after an Airbnb import, after saving an entry, and by new `POST /api/rates/fetch`.
- Reference dates per decision 36: booking lines use the booking''s check-in (import and Manual line); changing check-in, an expense''s date/amount/currency re-converts.
- Recurring generation copies the template''s amount and currency and converts at the 1st of the month.
- Allocation and metrics skip waiting entries (amount NULL); `long_term_rent_usd` replaces the COP setting in `metrics.py`.
- API: money inputs take `amount` + `currency` with the parse rules of decision 39 (in `web/forms.py`); outputs are USD cents plus the original fields; a warning notice when a save leaves an entry waiting; a `waiting` count where `needing_rate` was. Settings API per decision 41.
- Removals (decision 40, backend side): `web/api/rates.py` CRUD, `/api/import/rates`, CLI `import-rates`, `importer/trm_csv.py`, `tests/fixtures/trm_sample.csv`, `tests/test_trm.py`, `tests/test_api_rates.py`, repo `set/upsert/delete_exchange_rate`, `recompute_lines`.
- Tests updated to USD cents (fetcher monkeypatched); a schema test for the migrated columns; `test_e2e.py` recomputed with fixed fixture rates.
- Verify the migration and conversion on a copy of the owner''s database if one exists (decision 38), never the original; report the converted totals in the task note.
- Done when pytest and ruff pass and `rg -i "amount_cop|_cop\b|needs_rate|trm_csv|import-rates"` in `src tests` finds nothing.

## Task 3: the screens run on USD (requires task 2)

- `format.ts` mirrors the new `forms.py` money parse/format (USD cents shown as 1.234,56); `formatRate` goes; `format.test.ts` updated.
- An amount + currency select input (in `components/inputs.tsx`) used by the expense, recurring, hand-entered booking and settings forms; it defaults to the API''s default currency (decision 39).
- Lists and booking detail show USD and, for non-USD entries, the original amount with rate and rate date on hover; dashboard and charts treat money as cents.
- The waiting notice with a "Fetch rates now" button (`POST /api/rates/fetch`) on dashboard, bookings and expenses; the old "needs exchange rate" texts and links to `/rates` go.
- Removals (decision 40): `pages/Rates.tsx`, its routes in `App.tsx`, the nav entry and `RatesIcon` if unused, the "Exchange rates (TRM)" section of `pages/Import.tsx`.
- Rebuild the bundle the way the project does it. Done when typecheck, lint, test and build pass and `rg -i "rates\"|/rates|needs.rate|TRM" frontend/src` only finds the fetch call.

## Task 4: specs and README (requires task 3)

- `airbnb-bookkeeping-spec.md` and `architecture-spec.md`: USD cents storage with originals, the two rate sources and endpoints, caching and coverage, reference dates, waiting entries, the migration, money entry with currency; the "no network access" rule becomes "network only to fetch exchange rates; no CDN or web fonts"; the "Where rates come from" / Exchange rates sections rewritten; Rates page, typed rates, TRM CSV import and `import-rates` removed.
- `README.md`: the Exchange rates section (what is fetched from where, what happens offline), CLI list without `import-rates`.
- Done when the docs describe the code as it is and `rg -i "import-rates|trm.csv|whole pesos|no network"` outside `tasks.sql` finds nothing stale.', 'The bookkeeping tool keeps its books in Colombian pesos and relies on exchange rates typed in by hand, which the owner found confusing. From now on everything is kept in US dollars: when an expense is typed or Airbnb income is imported in pesos or euros, the app fetches that day''s official rate by itself and converts the amount, keeping what was typed so every conversion can be checked. The page for typing rates goes away, and the books kept so far are converted once.', '2026-10-24T03:47:36Z', 127);
INSERT INTO plan (id, milestone_id, subject, priority, body, intro, created_at, created_by_task) VALUES (26, 4, 'add expenses inline in the sheet', 400, 'Part 4 of `plan 23: masterplan`. Afterwards Expenses and Recurring add new entries in a row of the `DataTable` sheet; the `/expenses/new` and `/recurring/new` routes and the `ExpenseNew` / `RecurringNew` components are gone; README''s styling conventions describe the entry row. All frontend checks pass (typecheck, lint, test, build) and `nix flake check`.

Rules (binding):
- `decision 43: editing an expense or recurring template stays on its own page; only new entries are typed inline`: `ExpenseForm` / `RecurringForm` stay for editing only (drop their "new" branches).
- `decision 39: money entry: an amount with a currency choice (USD, COP, EUR)`: the amount cell uses the amount + currency input that `task 137: the screens run on USD with a currency choice and the waiting notice` adds to `components/inputs.tsx`, defaulting to the API''s default currency.
- `decision 37: when no exchange rate can be fetched, entries are saved and wait for their rate`: a save that leaves the entry waiting shows the API''s warning notice like any other save.

## Where things stand (before task 137)

- `frontend/src/pages/Expenses.tsx` holds `ExpenseList`, `ExpenseForm`, `RecurringList`, `RecurringForm` and the New/Edit wrappers; `App.tsx` routes `/expenses/new`, `/recurring/new`. Nothing else links to those routes.
- `ExpenseList` puts the "New expense" link in its `Toolbar` `action`; `RecurringList` has a plain `btn-primary` link above the sheet.
- `DataTable` (`components/DataTable.tsx`) renders the letter row, header, numbered rows, empty row and `footer`. Lists come from the API sorted ascending (expenses by date, templates by start month), so the entry row belongs at the bottom, like the next empty spreadsheet row, above the footer.
- `useSave` always navigates after success.

## Task 1: the sheet entry row and inline new expenses (requires task 137)

- `DataTable` gets an optional `entry?: ReactNode` rendered as the last body row (after the empty-state row too); a `SheetEntryRow` helper in `DataTable.tsx` adds the gutter cell (a "+" mark instead of a number, `aria-hidden`) and a class so `index.css` can style it (inputs `input-sm`/`select-sm`, filling their cell, a light highlight for the row being typed).
- `useSave`: `redirectTo` optional; without it the save stays on the page, and the caller gets an `onSaved` callback (close the row) and can reset errors.
- `ExpenseList`: the Toolbar `action` becomes a "+" button (`btn btn-primary btn-sm btn-square`, `aria-label="Add expense"`, `title` too) that opens the entry row; disabled while the row is open.
- The row has one input per column: Date (pre-filled with today''s **local** date, not `toISOString()` which is UTC), Category, Description, Amount (+ currency), and in the Source column Save (`btn-primary btn-sm`) and Cancel (`btn-ghost btn-sm`). Booking (per_booking) and useful life (capex) show inside the Category cell, under the select, only for those categories. Enter submits (the row is a `<form>` via the `form` attribute on its inputs, since a form can''t wrap a `tr`); Escape cancels.
- Field errors under each input in its cell (a small `text-error` line, same warning mark as `Field`; extract it from `Field.tsx` so both share it); errors for `""` show in `FormError` above the sheet.
- After a successful save: the row closes, the list and totals refresh (query invalidation), notices show. If the new expense falls outside the current filter, it simply doesn''t appear; no extra handling.
- Remove `/expenses/new`, `ExpenseNew` and the "new" branch of `ExpenseForm`.
- Done when an expense can be added, rejected with in-row errors, and cancelled in the running app (check once by hand), and the frontend checks pass.

## Task 2: inline new recurring expenses and README (requires task 1)

- `RecurringList`: the link becomes the same "+" button (`aria-label="Add recurring expense"`), above the sheet on the right; it opens a `SheetEntryRow` with Description, Category, Amount per month (+ currency), Start month (pre-filled with this local month), Until (empty = open) and Save/Cancel in the last cell (or a cell of their own if Until gets too cramped).
- Same error, save and close behaviour as task 1; after saving stay on the list (the template''s detail page is one click away).
- Remove `/recurring/new`, `RecurringNew` and the "new" branch of `RecurringForm`.
- README "Styling conventions": a bullet for the entry row (`entry` + `SheetEntryRow`, "+" button as the Toolbar `action` or above the sheet, in-cell errors, today''s date default) and the Buttons bullet no longer speaks of a "New …" link for Expenses (Bookings keeps its link per `decision 29: Hand-entered bookings: remove the ''New booking'' button so that all income comes from the Airbnb CSV?`).
- Done when a template can be added inline in the running app, `rg "recurring/new|expenses/new|ExpenseNew|RecurringNew" frontend README.md` finds nothing, and the frontend checks and `nix flake check` pass.', 'Adding an expense today means pressing a ''New expense'' button and filling a form on a separate page. The owner wants it to feel like a spreadsheet: a small plus button opens an empty row at the bottom of the expense table, typed in place, with today''s date already filled in. Monthly recurring expenses get the same treatment, starting at the current month.', '2026-10-24T03:49:23Z', 129);
INSERT INTO plan (id, milestone_id, subject, priority, body, intro, created_at, created_by_task) VALUES (27, 4, 'hand-entered bookings, the Time page and the Quit button', 400, 'Part 5 of `plan 23: masterplan`, following the owner''s answers:
- `decision 29: Hand-entered bookings: remove the ''New booking'' button so that all income comes from the Airbnb CSV?` → keep it, relabelled "Add a stay booked outside Airbnb", with a one-line hint on the Bookings page. Backend unchanged.
- `decision 30: Time page: remove the log of your own hosting hours, or keep it and explain it?` → remove the Time page, the time log, the own-time dashboard rows and the hourly-value setting.
- `decision 31: Quit button: remove it, or keep it with a clearer name?` → remove it and the "stopped" page; the app stops with Ctrl-C / SIGTERM. The owner added: "this is a server app now. it never stops. we need a different mechanism for the backup."

Rules (binding):
- `decision 44: the per-day view starts on the first day any input is spread over, without blocked days or own time` (supersedes decision 32)
- `decision 45: backups while the app runs: at start, then every hour when something changed, plus at stop`
- `decision 19: backups: which files are pruned, how many are kept, and what a failed backup does` still holds; `decision 6: own time is stored in whole minutes` becomes moot.

Order with `plan 25: USD inside, exchange rates fetched automatically` (same work tree, overlapping files: metrics, settings, cli, App.tsx, Settings.tsx, specs, README): this plan''s tasks run **before** the matching part 2 tasks, so part 2 converts less. The split adds: `task 136: the backend runs on USD cents with automatic rate conversion` requires tasks 1 and 2; `task 137: the screens run on USD with a currency choice and the waiting notice` requires task 3; `task 138: describe USD books and fetched exchange rates in specs and README` requires task 4. If one of those has already started, the matching task here requires it instead. Task 1''s migration takes the next free number; tell task 136 (its body names `0003_usd.sql`) by `pm task set 136 --body -` if it is still open.

## Task 1: remove the time log from the backend

- Migration (next free number): `DROP TABLE time_log` (and its index); delete the `hourly_value_cop` settings row.
- `model.py`: `TimeEntry`, `Inputs.time_log`, `Settings.hourly_value_cop`, `Day.minutes` go. `allocation.py`: the time-log loop and the start-date term (decision 44). `metrics.py`: `minutes`, `profit_per_hour`, `own_time_value`, `profit_after_own_time` go; dashboard JSON (`web/api/dashboard.py`) loses those rows.
- `storage/repo.py`: time-entry functions, `_INT_SETTINGS` entry, any booking-delete check mentioning time entries. `web/api/timelog.py` and its registration; settings API without `hourly_value_cop`; `web/forms.py` hours parse/format if nothing else uses them.
- Tests: `test_api_timelog.py` goes; metrics, allocation, settings, schema, repo and `test_e2e.py` updated.
- Done when pytest and ruff pass and `rg -i "time_log|timeentry|hourly|minutes|per_hour|own_time" src tests` finds nothing but unrelated hits.

## Task 2: backups while the app runs; the quit endpoint goes

- `cli.serve`: a daemon thread per decision 45: backup right after start, then hourly, skipped when nothing was written since the last; backup at stop stays (Ctrl-C, SIGTERM). Failures to stderr, the app keeps running.
- The last result (time, file, or error) is kept where the Flask app can read it (e.g. `app.config`), and `GET /api/settings` returns it as `last_backup` (null before the first attempt).
- Remove `POST /api/quit` (`web/api/system.py`), the `shutdown` parameter of `create_app` and `SHUTDOWN`, the `pthread_kill` plumbing; the docstring says Ctrl-C / SIGTERM.
- Tests: quit tests in `test_backup.py` and `test_api_foundation.py` go; one test of the backup loop with a short interval or an injected clock (no real hour waits); `test_e2e.py` takes its backup with `backup_on_exit` (or the loop''s step) instead of `/api/quit`.
- Done when pytest and ruff pass and `rg -i quit src tests` finds nothing.

## Task 3: the screens: no Time page, no Quit, clearer "add a stay" (requires tasks 1 and 2)

- Remove `pages/Time.tsx`, its routes in `App.tsx`, the nav entry and `TimeIcon` if unused, the "minutes" kind and own-time rows in `Dashboard.tsx`, the hourly-value field in `Settings.tsx`, hour helpers in `format.ts` and their tests if unused.
- Remove the Quit button, its mutation and error in `App.tsx`, and `pages/Stopped.tsx` (with its doodle asset if nothing else uses it).
- `Bookings.tsx`: the "New booking" link reads "Add a stay booked outside Airbnb"; one line on the page: Airbnb stays come in through the CSV import (link to Import), this is only for stays booked elsewhere. The form title for a new one matches.
- `Settings.tsx`: a read-only "Last backup" line from `last_backup` (date/time and file, or the error in the error style).
- Rebuild the bundle the way the project does it. Done when typecheck, lint, test and build pass and `rg -i "quit|stopped|/time|hourly" frontend/src` finds nothing.

## Task 4: specs and README (requires task 3)

- `airbnb-bookkeeping-spec.md`, `architecture-spec.md`: no time log, own-time metrics, hourly value or `/api/quit`; the Quit paragraph goes; backups per decision 45 (at start, hourly when changed, at stop, timer optional); start-date rule per decision 44; hand-entered stays described as "stays booked outside Airbnb".
- `README.md`: intro without "profit per hour you put in"; "Run and quit" becomes "Run" (stop with Ctrl-C or `systemctl stop`); Backup section per decision 45 and where the last backup shows; Restore step 1 "stop the app"; Bookings button name.
- Done when the docs describe the code and `rg -i "quit|time log|hourly|per hour|own time" *.md` finds nothing stale.', 'The owner didn''t understand three things on the screens: the button for adding a booking by hand, the page for logging their own working hours, and the button that stops the program. Stays booked outside Airbnb still need a way in, so that button stays with a clearer name and a short hint; the hours log and the stop button go. Because the app now runs as a server that is never stopped, it also has to back up its books by itself while it runs instead of when it closes.', '2026-10-24T03:51:12Z', 130);
INSERT INTO plan (id, milestone_id, subject, priority, body, intro, created_at, created_by_task) VALUES (28, 4, 'display currency', 500, 'Part 3 of `plan 23: masterplan`. Afterwards a USD / COP / EUR switch sits in the page header; choosing COP or EUR fetches today''s rate once (reusing the rate fetchers and cache of `plan 25: USD inside, exchange rates fetched automatically`), keeps currency and rate in settings, and every money figure on every screen is shown in that currency. All checks pass (pytest, ruff, frontend typecheck/lint/test/build, `nix flake check`).

Rules (binding):
- `decision 46: display currency: amounts are converted in the browser, the server keeps answering in USD`
- `decision 47: display currency: number formats per currency`
- `decision 48: display currency: kept in settings with the rate fetched when it was chosen, switched and shown in the page header`
- Unchanged: books in USD cents (`decision 34: money is stored in US cents, and every converted entry keeps what was typed`); money entry keeps its own currency select (`decision 39: money entry: an amount with a currency choice (USD, COP, EUR)`); hover texts and edit forms keep showing what was typed.

## Where things stand

- `Settings.currency` (`model.py`) defaults to `"COP"` and is saved by `repo.save_settings` but used nowhere.
- `conversion.rate_on(conn, currency, day)` fetches on a cache miss and returns `(rate, rate_date)` or None; USD needs no fetch (`USD_RATE`).
- Frontend money display: `format.ts` (`formatMoney`, `showMoney`, `formatAmount`), `components/AmountCell.tsx`, and direct calls in `pages/Dashboard.tsx` (tables, `LineChart`/`BarChart` formatters, "USD unless stated" / "(USD)" headings), `pages/Bookings.tsx` (net payout column, line "USD" column, detail totals), `pages/Expenses.tsx` (amount columns, totals), `pages/Settings.tsx` (rent shown in USD). Header and nav in `App.tsx`.

## Task 1: the display currency on the server (requires `task 136: the backend runs on USD cents with automatic rate conversion`)

- Migration `storage/migrations/0005_display_currency.sql`: settings `currency` set to `USD` (the old COP value never had a rate); `Settings.currency` default `"USD"`, new `Settings.display_rate: dict | None` (`{rate, rate_date}`) loaded/saved as JSON by `repo`.
- New `web/api/display.py`: `GET /api/display` → `{currency, rate, rate_date, currencies}` (USD: rate 1 000 000, rate_date null); `PUT /api/display {currency}` → validates against `CURRENCIES`, USD needs no rate, else `rate_on(conn, currency, today())`; stores currency and rate; None → refusal with the warning notice of decision 48 and nothing saved. Response uses the usual `ok(..., [notice])` shape.
- `/api/settings` stays as it is (the display choice isn''t on the Settings form).
- A couple of tests (fetcher monkeypatched like the other conversion tests): switch to COP stores the rate; failed fetch leaves USD; the migration sets USD.
- Done when pytest and ruff pass.

## Task 2: every screen shows the display currency (requires task 1 and `task 137: the screens run on USD with a currency choice and the waiting notice`)

- `format.ts`: `toDisplay(cents, rate)` → minor units of the display currency (`round(cents × rate / 1 000 000)`, half away from zero) and a formatter for it per decision 47; unit tests in `format.test.ts`.
- A display context/hook (e.g. `useDisplay()` with TanStack Query key `["display"]`) giving `{currency, rate, rate_date, money(cents|null)}`; `showMoney`/`AmountCell` and every direct `formatMoney` call that shows a USD figure go through it. Hover texts (`conversionTitle`), the booking line "Original" and "Rate" columns and form inputs stay as they are.
- Header in `App.tsx`: a small `select` (USD / COP / EUR) next to the nav, plus "1 USD = 4.123,45 COP · rate of 2026-10-23" (hidden for USD). Changing it calls `PUT /api/display`, shows notices, invalidates `["display"]`; on refusal the select returns to the stored value.
- Headings and labels that say USD say the display currency: "Amount (…)", "Net payout (…)", "… unless stated", "ADR and RevPAR (…)", the booking-line "USD" column becomes the display currency, Settings'' "rent … USD" line.
- Dashboard charts: convert the series values before passing them to `LineChart`/`BarChart`, so ticks come out round in the display currency.
- Rebuild the bundle the way the project does it. Check once in the running app: switch to COP and EUR (with network), figures change everywhere and survive a reload; switch back to USD.
- Done when typecheck, lint, test and build pass and `rg "formatMoney\(" frontend/src` only finds the display helper (or its tests).

## Task 3: specs and README (requires task 2)

- `airbnb-bookkeeping-spec.md` and `architecture-spec.md`: the display currency (header switch, rate fetched once on switching and kept, conversion in the client, number formats), `GET/PUT /api/display`, the `currency` / `display_rate` settings keys.
- `README.md`: where to switch the currency and what the rate line means; the styling conventions say money is shown through the display helper.
- Done when the docs describe the code and nothing says figures are always shown in USD.', 'The books are kept in US dollars, but the owner also wants to read every figure in Colombian pesos or euros. A small switch at the top of every screen picks the currency; when it changes, the app fetches that day''s exchange rate once and shows all amounts, totals and charts converted with it. The books themselves stay in dollars, and the screen always says which rate and date the figures use.', '2026-10-24T13:59:54Z', 128);

INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (1, 1, 'write the masterplan of milestone 1: first version build', 'masterplan', 'done', NULL, '2026-10-23, plan 1 body and intro (no files)', 'Write `plan 1: masterplan`, the masterplan of `milestone 1: first version build`: expand on everything that needs to be done to achieve it,
divided into parts, with an intro in plain English (`pm plan edit 1 --intro "…" --body -`). State in the masterplan that its own tasks are not implementation work: each of them writes the
plan for one part.', '2026-10-23T19:11:39Z', '2026-10-23T19:15:34Z', NULL, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (2, 1, 'create tasks for plan 1: masterplan', 'split', 'done', 1000, '2026-10-23, tasks 3–11 (one plan-writing task per masterplan part, chained in order; no human decision needed now, the architecture approval is raised by part 1''s work task)', 'Split `plan 1: masterplan` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-23T19:15:31Z', '2026-10-23T19:19:40Z', 1, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (3, 1, 'write the plan for part 1: architecture spec', 'plan', 'done', 1000, '2026-10-23, plan 2: architecture spec', 'Write the plan for part 1 of `plan 1: masterplan` (see its section "1. Architecture spec"); suggested plan priority 950.

- The plan has one work task (`--model opus`) that writes `architecture-spec.md` from `airbnb-bookkeeping-spec.md`, checked against the real sample `airbnb_.csv`.
- That work task must settle, with one recommendation each: tech stack and UI style, Nix packaging (flake package, dev shell, NixOS / home-manager module), code layout, test approach, DB location and migrations, and the Airbnb CSV mapping including how USD reservations (and EUR payouts) become integer COP.
- After writing the spec, that work task raises one human decision "approve the architecture" (`pm decision add`) and makes every still-open task of `plan 1: masterplan` wait for it (`pm task-pending-decision <task> <decision>`), so no other part is planned against an unapproved architecture. Spell this out in the work task''s body.
- **Ordering:** the other masterplan tasks have priority 1000 and would otherwise run before that work task. So once the plan''s split creates the work task, it must be required by `task 4: write the plan for part 2: project skeleton and Nix packaging` (`pm task requires 4 <work task id>`); tasks 5–11 already chain behind task 4. Say this in the plan body so its split does it.
- Done when the plan exists as described.', '2026-10-23T19:19:29Z', '2026-10-23T19:20:04Z', 2, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (4, 1, 'write the plan for part 2: project skeleton and Nix packaging', 'plan', 'done', 1000, '2026-10-23, plan 3: project skeleton and Nix packaging', 'Write the plan for part 2 of `plan 1: masterplan` (section "2. Project skeleton and Nix packaging"); suggested plan priority 920.

- Base it on the approved `architecture-spec.md`.
- Work tasks: source tree, build, test runner, linter/formatter; `flake.nix` keeps the existing dev shell (`pm`, git), adds the toolchain, an app package (`nix build`) and a runnable app (`nix run`); a trivial app that starts and a trivial test that passes.
- Done when the plan exists; its tasks are split afterwards.', '2026-10-23T19:19:29Z', '2026-10-23T19:30:55Z', 2, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (5, 1, 'write the plan for part 3: database schema and storage', 'plan', 'done', 1000, '2026-10-23, plan 4: database schema and storage; decisions 5, 6', 'Write the plan for part 3 of `plan 1: masterplan` (section "3. Database schema and storage"); suggested plan priority 900.

- Base it on `architecture-spec.md` (incl. its currency handling) and `airbnb-bookkeeping-spec.md`.
- Covers: SQLite schema (`bookings`, `expenses`, `recurring_expenses`, `blocked_days`, `time_log`, `settings`, plus currency fields), migrations from an empty DB, default DB path outside Dropbox and overridable for tests, the spec''s constraints, settings defaults.
- Its first tasks require the skeleton tasks of part 2 (`--requires` on their ids, see `pm plan list` / `pm show`).', '2026-10-23T19:19:29Z', '2026-10-23T19:32:24Z', 2, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (6, 1, 'write the plan for part 4: daily allocation engine', 'plan', 'done', 1000, '2026-10-23, plan 5: daily allocation engine; decisions 7, 8, 9', 'Write the plan for part 4 of `plan 1: masterplan` (section "4. Daily allocation engine"); suggested plan priority 650.

- Covers: the per-day `days` view, all allocation rules from the spec, idempotent generation of monthly expenses from recurring ones, an integer rounding rule so per-day amounts sum exactly, thorough unit tests (month lengths, leap years, stays across months, future bookings).
- Tasks require the schema tasks of part 3.
- Consider `--model opus` for the allocation core (subtle rules).', '2026-10-23T19:19:30Z', '2026-10-23T19:36:43Z', 2, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (7, 1, 'write the plan for part 5: metrics', 'plan', 'done', 1000, '2026-10-23, plan 6: metrics; decisions 10-13', 'Write the plan for part 5 of `plan 1: masterplan` (section "5. Metrics"); suggested plan priority 600.

- Covers: metrics for any date range (occupancy, ADR, RevPAR, profit, variable cost per night, break-even occupancy, vs. long-term rental, profit per hour and after own time, remaining capex book value), the standard ranges, rolling 90-day series, expense breakdown by category, defined division-by-zero behaviour, hand-checked unit tests.
- Tasks require the allocation engine tasks of part 4.', '2026-10-23T19:19:30Z', '2026-10-23T19:43:03Z', 2, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (8, 1, 'write the plan for part 6: Airbnb CSV import', 'plan', 'done', 1000, '2026-10-23, plan 7: Airbnb CSV import; decision 14', 'Write the plan for part 6 of `plan 1: masterplan` (section "6. Airbnb CSV import"); suggested plan priority 700.

- Follow the CSV mapping in `architecture-spec.md`, checked against `airbnb_.csv` (BOM, `MM/DD/YYYY`, several rows per reservation, COP/USD/EUR).
- Covers: create or update bookings deduplicated by confirmation code, handling of payout and other rows as the spec says, an import summary (new, updated, skipped, problems), tests against `airbnb_.csv` or a trimmed fixture.
- Tasks require the schema tasks of part 3 (not the engine or metrics).', '2026-10-23T19:19:30Z', '2026-10-23T19:44:48Z', 2, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (9, 1, 'write the plan for part 7: data entry screens', 'plan', 'done', 1000, '2026-10-23, plan 8: data entry screens; decisions 15, 16, 17', 'Write the plan for part 7 of `plan 1: masterplan` (section "7. Data entry screens"); suggested plan priority 450.

- Covers: create, list, edit, delete for bookings, expenses, recurring expenses, blocked days, time log; a settings screen; the CSV import reachable from the UI; validation matching the schema rules (e.g. capex needs a useful life).
- Tasks require the schema tasks of part 3, and the import screen requires the import tasks of part 6.', '2026-10-23T19:19:30Z', '2026-10-23T19:46:36Z', 2, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (10, 1, 'write the plan for part 8: dashboard and charts', 'plan', 'done', 1000, '2026-10-23, plan 9: dashboard and charts, decision 18', 'Write the plan for part 8 of `plan 1: masterplan` (section "8. Dashboard and charts"); suggested plan priority 400.

- Covers: metrics for the standard ranges side by side plus a custom range, a chart of rolling 90-day RevPAR, ADR and occupancy, expense breakdown by category for a chosen range; plain, readable presentation.
- Tasks require the metrics tasks of part 5 and, where they share UI scaffolding, the screens of part 7.', '2026-10-23T19:19:30Z', '2026-10-23T19:47:47Z', 2, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (11, 1, 'write the plan for part 9: backup, install and final check', 'plan', 'done', 1000, '2026-10-23, plan 10: backup, install and final check; decision 19', 'Write the plan for part 9 of `plan 1: masterplan` (section "9. Backup, install and final check"); suggested plan priority 300.

- Covers: `sqlite3 … ".backup …"` into a Dropbox folder as `books-YYYY-MM-DD.db`, keeping the last N, on app exit and via a daily systemd user timer shipped as a NixOS / home-manager module in the flake; restore and install/run/import/backup docs in the README; an end-to-end check (fresh DB, import `airbnb_.csv`, a few expenses, dashboard numbers verified by hand for one month).
- The end-to-end check requires the tasks of parts 6, 7 and 8.', '2026-10-23T19:19:30Z', '2026-10-23T19:49:20Z', 2, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (12, 2, 'create tasks for plan 2: architecture spec', 'split', 'done', 1000, '2026-10-23, tasks 13', 'Split `plan 2: architecture spec` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-23T19:20:02Z', '2026-10-23T19:21:42Z', 3, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (13, 2, 'write architecture-spec.md and ask for its approval', 'work', 'done', NULL, '2026-10-23, architecture-spec.md', 'Write `architecture-spec.md` at the repo root and get the owner''s approval of it. Nothing else in `plan 1: masterplan` may be planned or built before that approval.

Inputs: `airbnb-bookkeeping-spec.md` (the product idea), `airbnb_.csv` (a real Airbnb transaction-history export), the existing `flake.nix`.

The document must be short and readable for the owner: **one recommended option per question**, alternatives only where the choice really matters. It must settle:

- **Tech stack and UI style:** language, libraries; desktop GUI, TUI or local web server on localhost; how charts are drawn.
- **Nix packaging:** flake package (`nix build`), `nix run`, dev shell (keep `pm` and git, add the toolchain), NixOS / home-manager module for the backup timer.
- **Code layout:** source tree and module boundaries (storage, allocation engine, metrics, import, UI).
- **Test approach:** test runner, unit tests for allocation and metrics, fixture for the CSV import.
- **DB location and migrations:** default path outside Dropbox (e.g. under `$XDG_DATA_HOME`), override for tests, how schema migrations run.
- **Airbnb CSV mapping**, checked against `airbnb_.csv`:
  - columns (`Date, Arriving by date, Type, Confirmation code, Booking date, Start date, End date, Nights, Guest, Listing, Details, Reference code, Currency, Amount, Paid out, Service fee, Fast pay fee, Cleaning fee, Gross earnings, Airbnb remitted tax, Earnings year`), UTF-8 BOM, dates `MM/DD/YYYY`;
  - which row types become bookings, which are ignored or reported (payouts, adjustments, …), and what happens with several rows per confirmation code;
  - **currencies:** reservations are in COP and USD, payouts in EUR, the product spec stores integer COP. Say how a non-COP amount becomes COP (recommended: keep original currency and amount plus an exchange rate and the derived integer COP), where the rate comes from, and whether EUR payouts are used at all.

Then:

1. `git add architecture-spec.md`.
2. Raise one human decision "approve the architecture" with `pm decision add` (plain-English intro; body points to `architecture-spec.md` and lists its main recommendations; option "approve" first, i.e. recommended).
3. For every still-open task of `plan 1: masterplan` (at least tasks 4–11 as far as still open; check with `pm show p1`): `pm task-pending-decision <task> <decision>`.
4. Record lasting choices that are not part of the owner''s approval with `pm decision record`, if any.

Done when `architecture-spec.md` is staged, the decision exists, and the open masterplan tasks are pending on it.', '2026-10-23T19:21:39Z', '2026-10-23T19:24:06Z', 12, 0, 'opus', 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (14, 3, 'create tasks for plan 3: project skeleton and Nix packaging', 'split', 'done', 1000, '2026-10-23, tasks 17, 18', 'Split `plan 3: project skeleton and Nix packaging` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-23T19:30:52Z', '2026-10-23T19:41:40Z', 4, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (15, 4, 'create tasks for plan 4: database schema and storage', 'split', 'done', 1000, '2026-10-23, tasks 19 20 21 22', 'Split `plan 4: database schema and storage` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-23T19:32:15Z', '2026-10-23T19:42:16Z', 5, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (16, 5, 'create tasks for plan 5: daily allocation engine', 'split', 'done', 1000, '2026-10-23, tasks 24, 25, 26', 'Split `plan 5: daily allocation engine` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-23T19:36:41Z', '2026-10-23T19:42:58Z', 6, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (17, 3, 'Python project skeleton', 'work', 'done', NULL, '2026-10-23, pyproject.toml, src/airbnb_books/, tests/test_web.py, flake.nix, .gitignore', 'Builds the empty app frame from `architecture-spec.md` (`decision 3: approve the architecture`): Python 3, Flask + Jinja2 + waitress, pytest, ruff. No DB, no config paths, no real pages yet.

- `pyproject.toml` (setuptools build backend, `src/` layout):
  - package `airbnb_books`, dependencies `flask`, `jinja2`, `waitress`
  - console script `airbnb-books = airbnb_books.cli:main`
  - pytest: `testpaths = ["tests"]`, `pythonpath = ["src"]` (so tests import the package without installing it)
  - ruff: line length 100, rules `E,F,I,UP,B`, ruff format
- `src/airbnb_books/__init__.py` (with `__version__`), `cli.py`, `web/__init__.py`, `web/app.py`, `web/templates/index.html`:
  - `web/app.py`: `create_app()` factory, one route `/` rendering a placeholder page showing "airbnb-books" and the version
  - `cli.py`: `argparse` with subcommand `serve` (default when none given): waitress on `127.0.0.1`, a free port unless `--port`, prints the URL, opens the browser unless `--no-browser`; Ctrl-C stops cleanly. No `backup` / `import` / `migrate` yet.
- `tests/test_web.py`: Flask test client, `GET /` → 200 and contains "airbnb-books".
- `flake.nix` dev shell: keep `pm`, the pm dashboard and git; add `python3.withPackages` (flask, jinja2, waitress, pytest), `ruff`, `sqlite`.
- `.gitignore`: `__pycache__/`, `*.egg-info/`, `.pytest_cache/`, `.ruff_cache/`, `result`.

Done when, inside `nix develop`: `pytest` passes, `ruff check` and `ruff format --check` are clean, and `PYTHONPATH=src python -m airbnb_books.cli --no-browser` serves the page on localhost (check with `curl`, then stop it by PID).', '2026-10-23T19:41:36Z', '2026-10-23T19:50:02Z', 14, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (18, 3, 'Nix package, app and flake checks', 'work', 'done', NULL, '2026-10-23, flake.nix', 'Packages the skeleton from `task 17: Python project skeleton` with Nix so it can be built, run and checked with the owner''s Nix setup.

- `flake.nix`, for all listed systems:
  - `packages.default` = `python3Packages.buildPythonApplication` from `pyproject.toml` (`pyproject = true`, `build-system = [ setuptools ]`, dependencies from nixpkgs, `nativeCheckInputs = [ pytestCheckHook ]` so the tests run in the build)
  - `apps.default` runs `bin/airbnb-books`
  - `checks.default` = the package; plus a ruff check derivation running `ruff check` and `ruff format --check` over the source, so `nix flake check` runs tests and lint
  - keep the existing `devShells.default` unchanged
- Out of scope: NixOS / home-manager module and backup (a later part of the masterplan).

Done when `nix build` succeeds (tests run in it), `nix flake check` passes, and `nix run . -- --no-browser` serves the page on localhost (check with `curl`, then stop it by PID).', '2026-10-23T19:41:36Z', '2026-10-23T19:50:29Z', 14, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (19, 4, 'Paths, connection and migrations runner', 'work', 'done', NULL, '2026-10-23, config.py, storage/db.py, storage/migrations/0001_init.sql, cli.py, pyproject.toml, tests/test_storage.py', 'Part 1 of `plan 4: database schema and storage`: where the database file lives, how it is opened, and how it is created/upgraded. Follows `architecture-spec.md` sections 3, 5, 6, 7 (`decision 3: approve the architecture`). Builds on the skeleton of `task 17: Python project skeleton`.

- `src/airbnb_books/config.py`:
  - DB path: `--db`, else env `AIRBNB_BOOKS_DB`, else `$XDG_DATA_HOME/airbnb-books/books.db` (`~/.local/share/airbnb-books/books.db` when unset); creates the parent directory.
  - Refuses, with a clear error, a DB path inside any directory named `Dropbox` (the live DB must not be synced; only backups go there).
  - Backup dir: `--backup-dir`, else env `AIRBNB_BOOKS_BACKUP_DIR`, else `~/Dropbox/airbnb-books` (only resolved here; the backup itself comes later).
- `src/airbnb_books/storage/db.py`:
  - `connect(path)`: `PRAGMA foreign_keys = ON`, `row_factory = sqlite3.Row`, dates as ISO text (no implicit converters).
  - `migrate(conn, before_migrate=None)`: applies the numbered files `storage/migrations/NNNN_*.sql` above `PRAGMA user_version`, in order, each in one transaction that also sets `user_version`. Calls `before_migrate(path)` once, before the first one, only when the DB already existed (user_version > 0) and something is pending; the backup step will pass a hook here.
  - Migration files are package data in `pyproject.toml` so `nix build` ships them.
- Placeholder `storage/migrations/0001_init.sql` with one trivial `STRICT` table, so the runner is testable; the next task replaces it with the real schema.
- `cli.py`: global `--db`; new subcommand `migrate`; `serve` migrates before starting.
- Only `storage/` contains SQL.
- Tests `tests/test_storage.py` (all with `tmp_path`, never the real DB):
  - new DB gets all migrations; second run applies nothing;
  - a failing migration rolls back and leaves `user_version` unchanged;
  - hook called only for an existing DB with pending migrations;
  - path resolution order (flag > env > XDG > home default); Dropbox refusal.
- Done when `pytest`, `ruff check`, `ruff format --check` pass and `airbnb-books --db /tmp/x.db migrate` (or `PYTHONPATH=src python -m airbnb_books.cli …`) creates the file; delete `/tmp/x.db` afterwards.', '2026-10-23T19:42:16Z', '2026-10-23T19:51:07Z', 15, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (20, 4, 'Initial database schema', 'work', 'done', NULL, '2026-10-23, src/airbnb_books/storage/migrations/0001_init.sql, tests/test_schema.py', 'Part 2 of `plan 4: database schema and storage`: replace the placeholder `src/airbnb_books/storage/migrations/0001_init.sql` with the real schema. The full column list is in the plan body (section "Schema"); read it with `pm show p4`.

Ground rules (from the plan):
- All tables `STRICT`; money `INTEGER` whole COP; foreign amounts `INTEGER` minor units; rates `INTEGER` COP per unit in hundredths (4123.45 → 412345); dates ISO `TEXT` with `CHECK (date(x) IS x)`; months `YYYY-MM`; check-out exclusive.
- Own time in whole minutes (`decision 6: own time is stored in whole minutes`).
- Booking totals are not stored; the view `booking_totals` derives them from `booking_lines`, hand-entered stays get one `Manual` line (`decision 5: booking money totals are derived from booking lines, not stored`).
- Unique `(recurring_expense_id, date)` on `expenses`: generated monthly rows are dated the 1st and a deleted one is recreated (`decision 9: monthly expenses generated from templates are dated the 1st and come back if deleted`), so this key is what makes generation idempotent.

Contents:
- Tables `bookings`, `booking_lines`, `exchange_rates`, `expenses`, `recurring_expenses`, `blocked_days`, `time_log`, `settings` with the constraints of the plan (categories/reasons/types as `CHECK … IN (…)`, `ON DELETE` behaviours, uniques).
- View `booking_totals`: per booking `net_payout`, `cohost_cost` (positive), `gross`, `airbnb_fee`, `needs_rate`, `nights`.
- Indexes on `booking_lines(booking_id)`, `expenses(date)`, `time_log(date)`.

Tests (raw SQL, `tmp_path`), one per constraint: bad date, `check_out <= check_in`, duplicate Airbnb code, capex without useful life, per-booking expense without booking, unknown category/reason/type, float or text in a money column, deleting a booking with expenses fails, its lines cascade, duplicate line rejected, duplicate recurring month rejected. `booking_totals` on a small hand-checked example: a COP line, a USD line with rate, a co-host line, a line without rate → `needs_rate`.

Done when the tests, `ruff check` and `ruff format --check` pass.', '2026-10-23T19:42:16Z', '2026-10-23T19:52:17Z', 15, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (21, 4, 'Model and repository: bookings, lines, exchange rates', 'work', 'done', NULL, '2026-10-23, src/airbnb_books/model.py, money.py, storage/repo.py, tests/test_repo_bookings.py', 'Part 3 of `plan 4: database schema and storage`: the Python side for stays and currency conversion, so no code outside `storage/` writes SQL.

- `src/airbnb_books/model.py`: dataclasses `Booking` (incl. the totals from the `booking_totals` view and `needs_rate`), `BookingLine`, `ExchangeRate`.
- `src/airbnb_books/money.py`: `to_cop(amount_minor, rate) -> int` = amount_minor × rate / 10 000, rounded half away from zero, integer arithmetic only (no floats).
- `src/airbnb_books/storage/repo.py`:
  - bookings: create / get / list (by date range, by listing) / update / delete; find by Airbnb code;
  - a hand-entered booking is created together with its `Manual` line (amount in COP, rate 100); editing its amount edits that line;
  - add lines for the import, ignoring duplicates (the unique dedup key) and returning whether the line was new;
  - exchange rates CRUD; `rate_for(currency, date)` = latest rate on or before that date;
  - `recompute_lines()`: fills or updates `rate` / `amount_cop` of every non-COP line from `exchange_rates`; call it after any rate change.
- Tests (`tmp_path`): CRUD round trips, totals, rate lookup on/before the date, recompute after adding and after changing a rate, `to_cop` rounding incl. negatives and exact halves.
- Done when `pytest`, `ruff check`, `ruff format --check` pass.', '2026-10-23T19:42:16Z', '2026-10-23T19:53:16Z', 15, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (22, 4, 'Repository: expenses, recurring expenses, blocked days, time log, settings', 'work', 'done', NULL, '2026-10-23, src/airbnb_books/model.py, storage/repo.py, tests/test_repo_other.py', 'Part 4 of `plan 4: database schema and storage`: the remaining tables in Python, plus one loader that hands the allocation engine everything it needs.

- `src/airbnb_books/model.py`: `Expense`, `RecurringExpense`, `BlockedDay`, `TimeEntry` (minutes, `decision 6: own time is stored in whole minutes`), `Settings` with typed fields and defaults: `hourly_value_cop` 0, `long_term_rent_cop_per_month` 0, `currency` "COP", `per_booking_allocation` "check_in" (or "spread"), `property_listings` [] , `backup_keep` 30.
- `src/airbnb_books/storage/repo.py`:
  - CRUD for each; list by date range;
  - `insert_generated_expense(...)`: inserts unless `(recurring_expense_id, date)` exists (for generating monthly rows, see `decision 9: monthly expenses generated from templates are dated the 1st and come back if deleted`; the generation itself is a later part);
  - `load_settings()` / `save_settings()`: defaults in code for missing keys, `property_listings` stored as JSON;
  - `load_inputs(conn)`: bookings with totals and co-host cost, expenses, blocked days, time log, settings, all as dataclasses.
- Constraint violations (`sqlite3.IntegrityError`) surface as one `ValidationError` with a readable message, for the screens later.
- Tests (`tmp_path`): CRUD round trips, settings defaults and round trip, generated-expense dedup, a constraint violation becomes `ValidationError`, `load_inputs` on a small DB.
- Done when `pytest`, `ruff check`, `ruff format --check` pass.', '2026-10-23T19:42:16Z', '2026-10-23T19:54:28Z', 15, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (23, 6, 'create tasks for plan 6: metrics', 'split', 'done', 1000, '2026-10-23, tasks 27, 28', 'Split `plan 6: metrics` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-23T19:42:49Z', '2026-10-23T19:43:18Z', 7, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (24, 5, 'Day model, split helper and income/occupancy allocation', 'work', 'done', NULL, '2026-10-23, src/airbnb_books/model.py (Day), src/airbnb_books/allocation.py (split, calendar helpers, allocate: income/occupancy/availability/minutes), tests/test_allocation.py', 'First step of `plan 5: daily allocation engine`: the per-day data type and the income/occupancy half of the engine. Rules are in the plan body ("Rules"); binding: `decision 7: the per-day view ends today; nothing after today is counted`, `decision 6: own time is stored in whole minutes`.

**What**
- `model.py`: `Day` dataclass: `date, available, occupied, income, cost_fixed, cost_per_night, cost_per_booking, cost_maintenance, cost_capex, cost_tax, minutes` (ints/bools), property `profit` = income − all cost columns.
- `allocation.py` (pure, no clock, no DB):
  - `split(amount, n) -> list[int]`: each day `amount // n`, the first `amount % n` days one more; sums exactly, works for negatives.
  - calendar helpers: days in month, inclusive date range, months between.
  - `allocate(inputs, today, start=None) -> list[Day]`: one `Day` per date from `start` (default: earliest date of any booking, expense, blocked day or time entry) to `today` inclusive. Bookings: `net_payout` split over `[check_in, check_out)`, full span, only days ≤ today kept; those days `occupied`; overlapping bookings add income, occupied once. `available` = not blocked, or occupied (booking wins). `minutes` summed from the time log. Cost columns stay 0 (next task).
- Inputs: whatever `load_inputs(conn)` returns (from `task 22: Repository: expenses, recurring expenses, blocked days, time log, settings`).

**Tests** (`tests/test_allocation.py`)
- `split` sums exactly for many (amount, n), incl. negative and `amount < n`.
- Stay across a month end and a year end; stay running past today (only past nights, no future rows); future booking (nothing); overlapping bookings; blocked + booked same day; default start; empty inputs → empty list.

**Done when** `pytest`, `ruff check` and `ruff format --check` pass.', '2026-10-23T19:42:51Z', '2026-10-23T19:59:48Z', 16, 0, 'opus', 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (25, 5, 'Allocation cost rules: fixed, per-night, per-booking, co-host, capex, maintenance, tax', 'work', 'done', NULL, '2026-10-23, src/airbnb_books/allocation.py (cost rules: fixed, per-night, per-booking, co-host, capex, maintenance, tax; default start from expense spans, decision 21), tests/test_allocation.py', 'Second step of `plan 5: daily allocation engine`: fill the cost columns of `Day` in `allocate` (`allocation.py`). Rules in the plan body; binding: `decision 8: a per-night expense is spread over the occupied nights of its month`, `decision 7: the per-day view ends today; nothing after today is counted`.

**What** (every item split over its full span with `split`, only days ≤ today kept)
- `fixed` → `cost_fixed`: over all days of the expense''s calendar month (28–31), whatever day it is dated.
- `per_night` → `cost_per_night`: over the occupied nights of the expense''s month (future booked nights count in the split); none → over all days of the month.
- `per_booking` (expense with `booking_id`) and the booking''s co-host cost → `cost_per_booking`: setting `per_booking_allocation` = `check_in` → whole amount on the check-in day; `spread` → split over the booking''s nights. The expense''s own date is ignored.
- `capex` → `cost_capex`: over `useful_life_days` days from the purchase date (also when it starts before `start`: only the days in range are kept).
- `maintenance`, `tax` → whole amount on their date.

**Tests** (hand-checked numbers, `tests/test_allocation.py`)
- Fixed in Feb of a leap year (29 days) and a non-leap year, 30- and 31-day months, a fixed expense dated mid-month covers its whole month.
- Per-night over the month''s occupied nights and the no-occupancy fallback.
- Per-booking on check-in vs spread, a booking across months; co-host cost in both modes.
- Capex across a leap day, total after its full life equals the amount; capex starting before `start`.
- Maintenance and tax on their date.
- Each test also checks that each column sums (with `today` after the full span) to the input total.

**Done when** `pytest`, `ruff check` and `ruff format --check` pass.', '2026-10-23T19:42:51Z', '2026-10-23T20:01:06Z', 16, 0, 'opus', 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (26, 5, 'Recurring expense generation and load_days entry point', 'work', 'done', NULL, '2026-10-23, src/airbnb_books/recurring.py, cli.py, tests/test_recurring.py', 'Last step of `plan 5: daily allocation engine`: monthly expenses from recurring templates, and the single call the metrics and web layers use. Binding: `decision 9: monthly expenses generated from templates are dated the 1st and come back if deleted`.

**What**
- `recurring.py`:
  - pure `due_expenses(templates, today) -> list[Expense]`: one per template and month from `start_month` to `min(end_month, month of today)`, dated `YYYY-MM-01`, amount/category/description copied, `recurring_expense_id` set.
  - `generate_recurring(conn, today) -> int` (rows created) via `repo.insert_generated_expense` (no-op when `(recurring_expense_id, date)` exists, so edited rows stay and deleted ones come back).
  - `load_days(conn, today, start=None) -> list[Day]` = `generate_recurring`, `load_inputs`, `allocate`.
- `cli.py` `serve`: call `generate_recurring(conn, date.today())` after migrating.

**Tests**
- Months from start to end; open end stops at today''s month; template starting in the future → nothing; December → January.
- `generate_recurring` twice creates rows once; an edited generated row is kept; a deleted one is recreated.
- `load_days` on a small temp DB (a booking, a recurring fixed cost, a capex) gives hand-checked totals.

**Done when** `pytest`, `ruff check` and `ruff format --check` pass.', '2026-10-23T19:42:51Z', '2026-10-23T20:02:05Z', 16, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (27, 6, 'Metrics: date ranges and per-range summary', 'work', 'done', NULL, '2026-10-23, src/airbnb_books/metrics.py, tests/test_metrics.py', 'Part of `plan 6: metrics`; read the plan''s "Rules" section, it is the spec for this task.

- Builds on `task 24: Day model, split helper and income/occupancy allocation` (`Day`, `split`); `Day` objects are built by hand in tests, so the cost rules of `task 25` are not needed.
- `src/airbnb_books/metrics.py` (pure: no DB, no clock):
  - `DateRange(start, end)` (inclusive), `standard_ranges(today, first_day)` (all-time, last 30 days, last 90 days, current month), `month_range(year, month)`, `custom(start, end)`; ranges are clipped to the days that exist.
  - `Metrics` dataclass and `summarize(days, rng, settings) -> Metrics`: nights, income, each cost column, total cost, profit, minutes, occupancy, ADR, RevPAR, variable cost per night, break-even occupancy (exact `Fraction`, `decision 11: break-even occupancy treats fixed, maintenance, capex and tax costs as fixed`), long-term rental benchmark and profit vs. it (`decision 12: the long-term rental benchmark is spread over the days of each month`), profit per hour, own-time value, profit after own time.
  - Money is `int` COP, rounded half away from zero with integer arithmetic (reuse `money.py` if it fits); ratios are `float`; undefined → `None` (`decision 10: a figure that cannot be computed is shown as empty, not as zero`).
- `tests/test_metrics.py`, small hand-checked data: 10-day example (occupancy/ADR/RevPAR/profit); break-even computed, ADR ≤ variable cost → None, no occupancy → None; benchmark over a full month = monthly figure, and across Feb/Mar of a leap year; profit per hour and after own time with and without minutes; empty range; range entirely before the first day; last 30 days with fewer than 30 days of data; current month on the 1st.
- Done when `pytest`, `ruff check` and `ruff format --check` pass.', '2026-10-23T19:43:18Z', '2026-10-23T20:03:09Z', 23, 0, 'opus', 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (28, 6, 'Metrics: rolling 90-day series, expense breakdown, capex book value', 'work', 'done', NULL, '2026-10-23, src/airbnb_books/metrics.py, tests/test_metrics.py', 'Part of `plan 6: metrics`; read the plan''s "Rules" section, it is the spec for this task. Adds to `src/airbnb_books/metrics.py` from the previous metrics task.

- `rolling_90(days) -> list[RollingPoint(date, revpar, adr, occupancy)]` per `decision 13: the rolling 90-day chart starts once 90 days of history exist`; linear time with running sums, not 90 × days; undefined values None.
- `expense_breakdown(days, rng) -> list[(category, amount, share)]`: the six cost columns in fixed order (co-host is inside per-booking), share of total cost as float, None when the total is 0.
- `capex_book_value(expenses, as_of) -> int`: Σ over capex expenses of amount − the part of `split(amount, useful_life_days)` on days ≤ as_of; purchases after as_of not counted; 0 after full life.
- Tests in `tests/test_metrics.py`: rolling on 89 days → empty; on 90 → one point equal to `summarize` over those days; on 200 days a few points each equal `summarize` of their window; a window with no available nights → None values; breakdown sums to total cost and shares sum to 1, all-zero → None shares; capex book value before, during (hand-checked, incl. a leap day), after the useful life, and with two purchases.
- Done when `pytest`, `ruff check` and `ruff format --check` pass.', '2026-10-23T19:43:18Z', '2026-10-23T20:04:07Z', 23, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (29, 7, 'create tasks for plan 7: Airbnb CSV import', 'split', 'done', 1000, '2026-10-23, tasks 31, 32, 33, 34', 'Split `plan 7: Airbnb CSV import` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-23T19:44:20Z', '2026-10-23T19:45:04Z', 8, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (30, 7, 'create tasks for plan 7: Airbnb CSV import', 'split', 'dropped', 1000, 'duplicate of task 29: create tasks for plan 7: Airbnb CSV import, which already split the plan into tasks 31-34 with their prerequisites; nothing missing', 'Split `plan 7: Airbnb CSV import` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-23T19:44:28Z', '2026-10-23T19:45:22Z', 8, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (31, 7, 'Airbnb CSV test fixture and parser', 'work', 'done', NULL, '2026-10-23, src/airbnb_books/money.py, src/airbnb_books/importer/airbnb_csv.py, tests/fixtures/airbnb_sample.csv, tests/test_import.py', 'Part 1 of `plan 7: Airbnb CSV import`: read Airbnb''s earnings CSV into typed rows, without touching the database. Rules: section 6 of `architecture-spec.md` and the plan''s "Rules" list.

- `tests/fixtures/airbnb_sample.csv`: a trimmed copy of `airbnb_.csv` (repo root), keeping the BOM and the original header, with one example of each case:
  - the monthly rows of one long stay, a `Co-Host payout`, an `Adjustment` (incl. `-0.01`), a `Resolution Adjustment` and a `Resolution Payout`, `Payout` rows (EUR and USD), COP and USD reservations, an amount with a thousands comma, at least two listings.
  - Replace guest names and the owner''s name/IBAN in `Details` with fake ones.
- `src/airbnb_books/money.py` (created by `task 21: Model and repository: bookings, lines, exchange rates`): add `parse_minor(text) -> int`: strip thousands commas, parse with `Decimal`, return hundredths exactly; raise `ValueError` on junk or more than 2 decimals.
- `src/airbnb_books/importer/airbnb_csv.py`: `parse(file) -> ParsedFile`, pure (no DB):
  - open with `utf-8-sig`, columns by header name; a missing required column (`Date, Type, Confirmation code, Start date, End date, Nights, Listing, Guest, Currency, Amount, Service fee, Cleaning fee, Gross earnings, Paid out`) is a file error (exception with a readable message);
  - dates `MM/DD/YYYY` → `datetime.date`; `End date` is the exclusive check-out; `End − Start ≠ Nights` is a problem;
  - amounts in minor units for every currency (COP included); empty fee columns → 0, empty `Gross earnings` → `None`;
  - types `Reservation`, `Adjustment`, `Resolution Adjustment`, `Resolution Payout`, `Co-Host payout` → rows; `Payout` → only counted; anything else → problem;
  - result: typed rows (type, code, date, start, end, nights, listing, guest, currency, amount, service fee, cleaning fee, gross), payout count, listings found with row counts, problems (CSV line number + message). A row with a problem is not in the rows.
- Tests (`tests/test_import.py`): the fixture parses with the expected counts; BOM handled; comma amounts; negative and empty fields; missing column; unknown type; bad date; bad amount; nights mismatch; `parse_minor` cases.
- Done when `pytest`, `ruff check`, `ruff format --check` pass.', '2026-10-23T19:45:00Z', '2026-10-23T19:55:41Z', 29, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (32, 7, 'Airbnb import plan and apply', 'work', 'done', NULL, '2026-10-23, src/airbnb_books/importer/airbnb_csv.py, tests/test_import.py', 'Part 2 of `plan 7: Airbnb CSV import`: turn parsed rows into bookings and booking lines, showing first what an import would do, then doing it. Rules: section 6 of `architecture-spec.md`, the plan''s "Rules", `decision 14: Airbnb import: which rows set a booking''s dates, listing and guest name`, `decision 5: booking money totals are derived from booking lines, not stored`.

- `src/airbnb_books/importer/airbnb_csv.py`:
  - `plan_import(conn, parsed, listings=None) -> ImportPlan` (reads only):
    - `listings=None` uses the setting `property_listings`; an empty setting and no `listings` → plan with `needs_listing_choice=True`, the listings found, nothing to import;
    - rows of other listings are skipped, counted per listing;
    - one booking per confirmation code; a line is known when its key (booking, type, date, currency, amount) exists;
    - new bookings; updated bookings (new lines, or dates/listing/guest name differing from the latest-dated `Reservation` row, any type when there is none, per `decision 14`), each with what changed; skipped (payout rows, known lines, other listings); problems from the parse; warnings: overlapping stays among imported listings (existing + new), lines with no rate on or before their date.
  - `apply_import(conn, plan)`: one transaction, only through `storage/repo.py` (no SQL in the importer; add small repo helpers there if missing, e.g. listing a booking''s line keys); saves a given listing choice to `property_listings`; COP lines get rate 100; then `repo.recompute_lines()`; returns a summary (new, updated, skipped, problems, warnings, bookings needing a rate). `guests` and `notes` are never written.
- Tests on a temp DB with `tests/fixtures/airbnb_sample.csv`:
  - first import creates the expected bookings and lines; totals of the long stay and of a USD stay with a rate checked by hand; the co-host line is stored with type `Co-Host payout`;
  - second import of the same file → nothing new or updated;
  - a file with one extra row for a known code → one updated booking;
  - a row of another listing is skipped and counted;
  - empty setting → nothing imported until listings are given, then saved to the setting;
  - `guests` / `notes` edited by the user survive a re-import;
  - a USD stay without a rate is flagged, then filled after adding a rate.
- Done when `pytest`, `ruff check`, `ruff format --check` pass.', '2026-10-23T19:45:00Z', '2026-10-23T19:57:29Z', 29, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (33, 7, 'Command line Airbnb import', 'work', 'done', NULL, '2026-10-23, src/airbnb_books/cli.py, tests/test_cli_import.py', 'Part 3 of `plan 7: Airbnb CSV import`: let the owner run the import from the terminal before the import screen exists.

- `src/airbnb_books/cli.py`: subcommand `airbnb-books import <csv> [--listing NAME …] [--dry-run]` (uses the global `--db`):
  - migrates, parses, plans (`--listing` given → those listings; else the setting);
  - prints a readable summary: counts (new, updated, skipped by reason and listing, problems, warnings, bookings needing a rate) plus every problem and warning line;
  - applies unless `--dry-run`; when listings still need choosing, prints the listings found and how to pass `--listing`, exits with code 2 and changes nothing.
- Tests (`tests/test_cli_import.py`, temp DB, the fixture): dry run changes nothing; a real run imports; exit code 2 without listings. One test imports the real `airbnb_.csv` from the repo root with all its listings (skipped when the file is absent) and asserts there are no problems.
- Done when `pytest`, `ruff check`, `ruff format --check` pass and `airbnb-books --db /tmp/x.db import airbnb_.csv --listing …` works in the dev shell (`nix develop`).', '2026-10-23T19:45:00Z', '2026-10-23T19:58:08Z', 29, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (34, 7, 'Exchange-rate (TRM) import', 'work', 'done', NULL, '2026-10-23, importer/trm_csv.py, storage/repo.py, cli.py, tests/test_trm.py, tests/fixtures/trm_sample.csv', 'Part 4 of `plan 7: Airbnb CSV import`: load the official Colombian peso/dollar rate history so stays paid in dollars get a value in pesos.

- The owner downloads the TRM history by hand from datos.gov.co ("Tasa de Cambio Representativa del Mercado – Histórico", CSV export). Look up its real column names, date format and number format there (web access) and note them in a comment in the parser.
- `src/airbnb_books/importer/trm_csv.py`:
  - parse → (date, COP per USD in hundredths, via `money.parse_minor` or equivalent exact parsing) using each row''s start-of-validity date; problems with CSV line numbers;
  - apply: upsert into `exchange_rates` for `USD` through `storage/repo.py`, then `repo.recompute_lines()`; summary: rates added, rates changed, lines recomputed, bookings still needing a rate.
- `src/airbnb_books/cli.py`: `airbnb-books import-rates <csv> [--currency USD]`, prints the summary.
- Fixture `tests/fixtures/trm_sample.csv`: a few weeks in the real format. Tests: parse; re-import changes nothing; a changed rate recomputes a booking''s COP amount; a bad row is a problem with its line number.
- Done when `pytest`, `ruff check`, `ruff format --check` pass.', '2026-10-23T19:45:01Z', '2026-10-23T20:10:08Z', 29, 1, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (35, 8, 'create tasks for plan 8: data entry screens', 'split', 'done', 1000, '2026-10-23, tasks 36, 37, 38, 39, 40, 41', 'Split `plan 8: data entry screens` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-23T19:46:33Z', '2026-10-23T19:47:27Z', 9, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (36, 8, 'Web frame: layout, form helpers, app on a real DB', 'work', 'done', NULL, '2026-10-23, web/app.py, web/forms.py, web/templates/{base,stub,index}.html, cli.py, tests/test_web.py', 'First task of `plan 8: data entry screens`; read the plan''s "Ground rules" first. Builds the frame every data entry screen uses.

- `create_app(db_path)` in `web/`: one database connection per request (opened lazily, closed on teardown); `serve` passes the resolved DB path.
- `base.html`: navigation (Bookings, Expenses, Recurring, Blocked days, Time, Rates, Import, Settings), flash messages, minimal CSS inline in the template, no CDN, no JavaScript framework. `/` stays the placeholder until the dashboard part. Nav links may point to stub pages ("coming soon") that later tasks replace, so every link renders.
- `web/forms.py`, per `decision 15: data entry forms: how money and hours are typed`:
  - parse/format money (whole pesos, `.`/`,`/space thousands separators, no decimals; shown as `1.234.567`), hours (`1.5`, `1,5`, `1:30` → minutes), exchange rates (up to 2 decimals after a dot), dates (`YYYY-MM-DD`) and months (`YYYY-MM`)
  - a small helper that turns a POST into parsed values + one error per field
  - mapping of the repo''s `ValidationError` to a form error (never a 500)
  - booking picker options: newest first, label `check-in – check-out · guest name · listing`
- Origin check: a POST whose `Origin` (or, if missing, `Referer`) names another host than the request''s is rejected with 403.
- `tests/test_web.py`: fixture creating the app on a migrated `tmp_path` DB (later tasks reuse it).
- Tests: parsing/formatting tables (`1.234.567`, `1,234,567`, `1234567` ok; `12,5` → error for money; `1.5`, `1,5`, `1:30` → 90 min; bad input → error), foreign Origin → 403, same-origin and missing Origin pass, every nav link renders.

Done when `pytest`, `ruff check`, `ruff format --check` pass and `airbnb-books --db /tmp/x.db --no-browser` serves the pages (checked with `curl`, stopped by PID).', '2026-10-23T19:47:15Z', '2026-10-23T20:05:36Z', 35, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (37, 8, 'Booking screens', 'work', 'done', NULL, '2026-10-23, web/bookings.py, web/app_db.py, web/app.py, templates/booking*.html, tests/test_web.py', 'Part of `plan 8: data entry screens`; see its "Ground rules" and the "Bookings" bullet. Uses the frame and `web/forms.py` from `task 36: Web frame: layout, form helpers, app on a real DB`; only calls `repo`, never SQL.

- List: newest first, filter by date range and listing, a "needs exchange rate" mark per booking.
- Detail page: totals (net payout, gross, Airbnb fee, co-host cost, nights) and the booking''s lines read-only.
- New (hand-entered stay): check-in, check-out (> check-in), net payout in COP (≥ 0, stored as one `Manual` line by the repo), optional confirmation code (unique), listing (preset when the property has exactly one listing in settings), guest name, guests (> 0 or empty), notes.
- Edit per `decision 17: bookings from the Airbnb import: dates, listing and guest name are read-only in the edit form`: imported bookings only accept guests and notes; hand-entered ones every field including the amount.
- Saving a booking that overlaps another shows a warning flash, not an error.
- Delete: refused with a readable message while expenses point to it; for imported bookings the confirmation text says a re-import brings it back.
- Tests in `tests/test_web.py`: hand-entered booking created with its `Manual` line and correct net payout; edited amount changes the line; check-out ≤ check-in rejected; duplicate code rejected; imported booking (lines added through `repo` in the test) only accepts guests/notes; overlap warns; delete refused while an expense points to it; delete works otherwise.

Done when `pytest`, `ruff check`, `ruff format --check` pass and the pages work against a running `airbnb-books --db /tmp/x.db --no-browser` (checked with `curl`, stopped by PID).', '2026-10-23T19:47:15Z', '2026-10-23T20:06:58Z', 35, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (38, 8, 'Expense and recurring expense screens', 'work', 'done', NULL, '2026-10-23, web/expenses.py, web/app.py, templates/expense*.html, templates/recurring*.html, tests/test_web.py', 'Part of `plan 8: data entry screens`; see its "Ground rules" and the "Expenses" and "Recurring expenses" bullets. Uses the frame from `task 36: Web frame: layout, form helpers, app on a real DB`; only calls `repo` and `recurring`.

- Expenses: list filtered by date range and category, generated rows marked with (a link to) their template. Fields: date, amount (> 0), category, booking (picker; required for `per_booking`, hidden otherwise), useful life in days (required and > 0 for `capex`, hint "3 years ≈ 1095"; hidden otherwise), description. Hidden fields are ignored server-side for other categories (a tiny inline script or CSS may hide them; the form must still work without it).
- Recurring expenses: list; fields description, amount (> 0), category (`fixed`, `per_night`, `maintenance`, `tax`), start month, end month (empty or ≥ start). After every save, `generate_recurring(conn, today)` runs so due months appear at once.
- Template edits per `decision 16: changing a recurring expense template only affects months not yet generated`; the template''s page lists its generated expenses with links; deleting a template keeps them.
- Tests: capex without useful life rejected; per-booking without booking rejected; booking/useful life ignored for other categories; filter by category and dates; new template generates its due months; editing a template leaves generated rows unchanged; end month before start rejected; create/edit/delete for both.

Done when `pytest`, `ruff check`, `ruff format --check` pass and the pages work against a running `airbnb-books --db /tmp/x.db --no-browser` (checked with `curl`, stopped by PID).', '2026-10-23T19:47:15Z', '2026-10-23T20:08:19Z', 35, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (39, 8, 'Blocked days and time log screens', 'work', 'done', NULL, '2026-10-23, web/blocked.py, web/timelog.py, 5 templates, web/app.py, tests/test_web.py', 'Part of `plan 8: data entry screens`; see its "Ground rules" and the "Blocked days" and "Time log" bullets. Uses the frame from `task 36: Web frame: layout, form helpers, app on a real DB`; only calls `repo`.

- Blocked days: list (newest first, date filter); add a range in one form (from, to ≥ from, reason `buffer`/`owner`/`maintenance`/`other`, note); days already blocked are skipped and reported in the flash; a blocked day inside a booking gives a warning. Edit reason/note of one day, delete one day.
- Time log (stored in minutes per `decision 6: own time is stored in whole minutes`): list with hours per entry and the total for the current filter; fields date, hours (> 0, typed per `decision 15: data entry forms: how money and hours are typed`), optional booking (picker), description.
- Tests: a range of 5 days with 2 already blocked adds 3 and reports 2; blocked day inside a booking warns; hours `1:30` stored as 90 minutes and shown as 1.5 h; zero hours rejected; total for a filter; edit and delete for both.

Done when `pytest`, `ruff check`, `ruff format --check` pass and the pages work against a running `airbnb-books --db /tmp/x.db --no-browser` (checked with `curl`, stopped by PID).', '2026-10-23T19:47:15Z', '2026-10-23T20:11:44Z', 35, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (40, 8, 'Settings and exchange-rate screens', 'work', 'done', NULL, '2026-10-23, web/settings.py, web/forms.py, web/app.py, templates settings/rates/rate_form, tests/test_web.py', 'Part of `plan 8: data entry screens`; see its "Ground rules" and the "Settings" and "Exchange rates" bullets. Uses the frame from `task 36: Web frame: layout, form helpers, app on a real DB`; only calls `repo`.

- Settings: hourly value of own time (COP, ≥ 0), long-term rental benchmark per month (COP, ≥ 0), per-booking allocation (`check_in` / `spread`), listings of this property (checkboxes of all listings found in bookings, plus a text field for another name; saved as the `property_listings` list), backups to keep (≥ 1); currency shown as COP, not editable. Defaults are shown on an empty DB.
- Exchange rates: list by currency and date; fields date, currency (3 letters, upper-cased, default USD), COP per unit (> 0, up to 2 decimals). Create, edit, delete; after any change call `repo.recompute_lines()` (unless the repo already does) and the flash says how many bookings still need a rate.
- Tests: settings round trip and defaults on an empty DB; negative value rejected; listing choice saved as the `property_listings` list; adding a rate fills the COP amount of a booking that needed one (booking with a USD line created through `repo`); changing the rate recomputes it; invalid currency rejected.

Done when `pytest`, `ruff check`, `ruff format --check` pass and the pages work against a running `airbnb-books --db /tmp/x.db --no-browser` (checked with `curl`, stopped by PID).', '2026-10-23T19:47:15Z', '2026-10-23T20:12:47Z', 35, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (41, 8, 'Import screen', 'work', 'done', NULL, '2026-10-23, web/importing.py, web/app.py, templates import/import_preview/import_summary, tests/test_web.py', 'Part of `plan 8: data entry screens`; see its "Ground rules" and the "Import" bullet. Uses the frame from `task 36: Web frame: layout, form helpers, app on a real DB` and the import code of `plan 7: Airbnb CSV import` (`importer`), never SQL.

- Upload the Airbnb CSV → preview of the import plan: new bookings, updated ones with what changed, skipped rows per reason and listing, problems with CSV line numbers, warnings → an "Import" button applies it, then shows the summary.
- When no property listings are chosen yet, the preview shows the listings found as checkboxes; the choice is sent with the apply and saved to settings.
- The uploaded file is kept in a temp directory under a random token between preview and apply (token validated, no path from the user); apply re-parses and re-plans the file; the file is deleted after apply.
- A second upload field loads the TRM exchange-rate CSV and shows its summary.
- Tests with `tests/fixtures/airbnb_sample.csv`: upload on an empty DB asks for listings and imports nothing; choosing listings then applying creates the bookings; uploading the same file again previews nothing new; a broken file shows the file error; the temp file is gone after apply; the TRM fixture upload shows its summary.

Done when `pytest`, `ruff check`, `ruff format --check` pass and the page works against a running `airbnb-books --db /tmp/x.db --no-browser` (checked with `curl -F`, stopped by PID).', '2026-10-23T19:47:16Z', '2026-10-23T20:14:19Z', 35, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (42, 9, 'create tasks for plan 9: dashboard and charts', 'split', 'done', 1000, '2026-10-23, tasks 43, 45, 44', 'Split `plan 9: dashboard and charts` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-23T19:47:43Z', '2026-10-23T19:48:28Z', 10, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (43, 9, 'SVG chart module', 'work', 'done', NULL, '2026-10-23, src/airbnb_books/web/charts.py, tests/test_charts.py', 'Part of `plan 9: dashboard and charts`. Our own small chart drawer, used by the dashboard: inline SVG, no JavaScript, no chart library, no CDN (`architecture-spec.md`, `decision 3: approve the architecture`).

**What**
- New `web/charts.py` with pure functions returning `markupsafe.Markup` SVG strings:
  - `line_chart(series, *, y_format, y_min=None, y_max=None, width, height)`, `series = [(label, [(date, value|None), …])]`
  - `bar_chart(items, *, value_format)`, `items = [(label, value)]` (horizontal bars)
- Fixed size via `viewBox` (scales to page width); a few y gridlines labelled at round values; x labels at month starts; a legend; a fixed small palette, each series also with its own line dash (print and colour-blind friendly); `<title>` elements so hovering shows the value.
- A `None` value breaks the line: one `<polyline>`/`<path>` per run of non-None values.
- Labels are escaped. Empty input or all values None → `None` (the template shows its own text) or an empty-state SVG; pick one and document it in the docstring.

**Tests** in `tests/test_charts.py`
- output parses as XML (`xml.etree`)
- a None in the middle gives two segments
- y labels at round values for a sample range (e.g. 0–1 234 567)
- a label containing `<&>` is escaped
- bar widths proportional to values
- zero values and empty inputs don''t divide by zero

**Done when** `pytest`, `ruff check` and `ruff format --check` pass.', '2026-10-23T19:48:11Z', '2026-10-23T20:15:12Z', 42, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (44, 9, 'Dashboard: rolling chart and expense breakdown', 'work', 'done', NULL, '2026-10-23, src/airbnb_books/web/dashboard.py, web/templates/index.html, tests/test_web.py', 'Part of `plan 9: dashboard and charts` (read its Layout section). Adds the charts and the capex row to the dashboard built by `task 45: Dashboard: metrics table and period form`, using `web/charts.py` and `metrics.rolling_90`, `metrics.expense_breakdown`, `metrics.capex_book_value`.

**What**
- Rolling chart: two stacked line charts sharing the date axis: money (ADR and RevPAR, COP) and occupancy (0–100 %); one point per day from `metrics.rolling_90`; `None` breaks the line. Fewer than 90 days of history → the text "the 90-day chart starts once 90 days of history exist" and no chart (`decision 13: the rolling 90-day chart starts once 90 days of history exist`).
- Expense breakdown for the custom range if set, else the chosen month (`decision 18: dashboard layout: which periods are shown and which period the cost breakdown uses`): horizontal bar chart plus a small table (category, amount, share %), the six categories in `metrics.expense_breakdown`''s order; all zero → "no costs in this period".
- Last row of the metrics table: remaining capex book value at each period''s end.

**Tests** in `tests/test_web.py`: under 90 days → the message and no chart; 120 days of data → two `<svg>` line charts containing the series labels; the breakdown follows the custom range when given, else the chosen month; the capex row matches `capex_book_value` at the period end.

**Done when** `pytest`, `ruff check` and `ruff format --check` pass and the dashboard works in the browser on a DB with `airbnb_.csv` imported (`airbnb-books --db /tmp/x.db --no-browser`, checked with `curl`, stopped by PID).', '2026-10-23T19:48:11Z', '2026-10-23T20:17:47Z', 42, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (45, 9, 'Dashboard: metrics table and period form', 'work', 'done', 410, '2026-10-23, src/airbnb_books/web/dashboard.py, web/templates/index.html, web/app.py, tests/test_web.py', 'Part of `plan 9: dashboard and charts` (read its Layout section; layout per `decision 18: dashboard layout: which periods are shown and which period the cost breakdown uses`). Replaces the placeholder route `/` from `task 36: Web frame: layout, form helpers, app on a real DB`. The page only calls `recurring.load_days`, `metrics` and `repo`, never SQL.

**What**
- `today`: `date.today()` in the route, overridable through the app config in tests; passed to `load_days` and `metrics`.
- Period form (one GET form at the top): month input (`?month=YYYY-MM`, default last month), from/to date inputs (`?from=…&to=…`), Apply, Reset link. Invalid input (bad date, from > to) → that column left out and one message, status 200, never a 500.
- Metrics table, one column per period: all-time, last 90 days, last 30 days, this month, chosen month, custom (only when set). Headers show the period''s dates.
- Rows: available nights, occupied nights, occupancy %, ADR, RevPAR, income, total cost, profit, variable cost per night, break-even occupancy %, long-term rental benchmark, profit vs. long-term rental, hours, profit per hour, profit after own time. (The capex book value row comes in `task 44: Dashboard: rolling chart and expense breakdown`.)
- Formatting: money with the `web/forms.py` formatter (thousands dots, "COP" in the header, not per cell); ratios `57.3 %` (one decimal, break-even above 100 % shown as is); hours one decimal; `None` as a dash (`decision 10: a figure that cannot be computed is shown as empty, not as zero`); negative profit with minus sign and red text.
- Notices above everything: "N bookings need an exchange rate" linking to the rates screen (`task 40: Settings and exchange-rate screens`); an empty DB shows "nothing here yet: import the Airbnb CSV or add a booking" with links instead of the table.

**Tests** in `tests/test_web.py`, temp DB with a booking, a fixed expense and a time entry (hand-checked numbers): all standard columns present; `?month=` and `?from/to` add/change columns; invalid custom range → message and 200; a booking with a USD line without a rate → the notice; empty DB → empty state; None shown as a dash.

**Done when** `pytest`, `ruff check` and `ruff format --check` pass and `/` renders in the browser (`airbnb-books --db /tmp/x.db --no-browser`, checked with `curl`, stopped by PID).', '2026-10-23T19:48:24Z', '2026-10-23T20:17:00Z', 42, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (46, 10, 'create tasks for plan 10: backup, install and final check', 'split', 'done', 1000, '2026-10-23, tasks 47, 48, 49, 50, 51', 'Split `plan 10: backup, install and final check` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-23T19:49:14Z', '2026-10-23T19:50:04Z', 11, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (47, 10, 'Backup module and backup command', 'work', 'done', NULL, '2026-10-23, src/airbnb_books/backup.py, src/airbnb_books/cli.py, tests/test_backup.py (decision 19: backups: which files are pruned, how many are kept, and what a failed backup does)', 'Daily and on-demand copies of the live SQLite database into the backup folder (Dropbox by default). Rules: `decision 19: backups: which files are pruned, how many are kept, and what a failed backup does`.

- `backup.py`: `backup(db_path, backup_dir, keep, today)` → path written.
  - Uses `sqlite3.Connection.backup` (online backup, safe while the app runs) into a temp file inside `backup_dir`, then renames it to `books-YYYY-MM-DD.db` (same day overwrites).
  - Creates `backup_dir` if missing.
  - Then prunes: only files matching `books-YYYY-MM-DD.db`, newest `keep` kept, oldest deleted. Any other file is left alone. A failed backup deletes nothing.
- `cli.py`: subcommand `backup [--backup-dir] [--keep]` (backup dir and DB path resolved by `config.py`, `task 19: Paths, connection and migrations runner`). Keep = flag, else setting `backup_keep` (`task 22: Repository: expenses, recurring expenses, blocked days, time log, settings`), else 30. On failure: message on stderr, non-zero exit.
- `serve` and `migrate` pass the backup as `before_migrate` to `storage/db.migrate`; a failed backup there aborts the migration.
- `tests/test_backup.py`: the backup is a readable copy with the same rows; same-day overwrite; pruning keeps N and leaves foreign files alone; keep precedence (flag > setting > 30); migration hook called only for an existing (non-new) DB; failure → non-zero exit.

Done when the tests pass and `airbnb-books backup --backup-dir <tmp>` on a temp DB writes today''s file.', '2026-10-23T19:50:00Z', '2026-10-23T20:18:59Z', 46, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (48, 10, 'Backup on exit and Quit button', 'work', 'done', NULL, '2026-10-23, src/airbnb_books/cli.py, src/airbnb_books/web/app.py, src/airbnb_books/web/templates/base.html, src/airbnb_books/web/templates/stopped.html, tests/test_backup.py', 'The app takes a backup whenever it stops, and gets a Quit button so the owner has a clean way to close it.

- `serve` takes a backup (`backup.py` from `task 47: Backup module and backup command`) when the server stops: Ctrl-C, SIGTERM, or the **Quit** button in the page header (layout from `task 36: Web frame: layout, form helpers, app on a real DB`).
- POST `/quit`: renders "airbnb-books has stopped, you can close this tab", then stops waitress cleanly (after the response is sent).
- A failed backup at exit is printed to stderr; the app still exits (`decision 19: backups: which files are pruned, how many are kept, and what a failed backup does`).
- Tests: `/quit` with the test client triggers the shutdown callback (inject it, don''t kill the test process); the exit path calls the backup exactly once, even if several stop signals arrive.

Done when the tests pass and, by hand: start with `--no-browser` on a temp DB and backup dir, `curl -X POST` the `/quit` URL, the process ends and today''s backup file exists.', '2026-10-23T19:50:00Z', '2026-10-23T20:23:18Z', 46, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (49, 10, 'NixOS and home-manager backup module', 'work', 'done', NULL, '2026-10-23, nix/module.nix, flake.nix', 'A Nix module that installs a daily systemd timer running `airbnb-books backup`, so backups happen even when the app isn''t opened.

- `nix/module.nix`, exposed in `flake.nix` as `homeManagerModules.default` and `nixosModules.default` (NixOS: `systemd.user` units, for all users). One file serves both.
- Options `services.airbnb-books-backup`: `enable`; `package` (default: this flake''s package from `task 18: Nix package, app and flake checks`); `backupDir`; `keep` (default 30); `dbPath` (default null = app default); `onCalendar` (default `"daily"`).
- `airbnb-books-backup.service`: oneshot, runs `airbnb-books backup --backup-dir … --keep …`, plus `--db …` when `dbPath` is set (command from `task 47: Backup module and backup command`).
- `airbnb-books-backup.timer`: `OnCalendar` from the option, `Persistent = true`, wanted by `timers.target`.
- A flake check that evaluates the NixOS module in a minimal `nixosSystem` and asserts the generated unit''s `ExecStart` and timer settings (no VM test). Don''t add home-manager as a flake input just for a check.

Done when `nix flake check` passes.', '2026-10-23T19:50:00Z', '2026-10-23T20:23:58Z', 46, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (50, 10, 'README for the owner', 'work', 'done', NULL, '2026-10-23, README.md', 'A short `README.md` for the owner: how to install, use, back up and restore the app.

Contents:
- What the app is (one paragraph).
- Install: `nix run`; or the flake as an input with the package and the backup module (`task 49: NixOS and home-manager backup module`), with a home-manager example.
- Run and quit (the Quit button, `task 48: Backup on exit and Quit button`).
- Import the Airbnb CSV: where to download it on Airbnb, the listings question on the first import, re-imports are safe (`task 41: Import screen`, `task 33: Command line Airbnb import`).
- Exchange rates: the TRM file from datos.gov.co, or typing one in (`task 34: Exchange-rate (TRM) import`).
- Backup: on exit, daily timer, where files go, how many are kept, `airbnb-books backup` by hand.
- **Restore**: close the app, copy `books-YYYY-MM-DD.db` over the live DB path, start the app.
- Where the DB lives and how to override it (flag / env var).

Done when every command in the README has been tried once in the dev shell against a temp DB and works as written.', '2026-10-23T19:50:00Z', '2026-10-23T20:24:34Z', 46, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (51, 10, 'End-to-end check with real data', 'work', 'done', NULL, '2026-10-23, tests/test_e2e.py. Real app on a fresh temp DB with airbnb_.csv (listings Large 4 bed + Master bedroom), checked October 2026 (today 10-23, HMECDBYSMK USD with co-host, HMNDSJTM25 crossing into November, fixed/per-night/capex/maintenance costs, a blocked day, 4 h logged): nights, occupancy, income, every cost category, profit, ADR, RevPAR, variable cost, break-even, benchmark, profit per hour all match an independent recomputation from the CSV exactly; Quit wrote the backup, restore per README showed the same dashboard. One bug: typed exchange rates are stored 100x too big (follow-up task 52: Rates page stores typed exchange rates at the wrong scale); rates were loaded via the TRM import instead.', 'Final run-through of the whole app, checking one month''s numbers independently of the app''s code.

- In the real app on a fresh temp DB: import `airbnb_.csv` (repo root) through the import screen, choose the listings, add the USD rates needed for one chosen month, add a few expenses (a recurring fixed cost, a per-night cost, a capex item with a useful life, a maintenance cost) and a time log entry; open the dashboard.
- Pick one month with several stays (one crossing a month boundary). Recompute its figures independently from the CSV rows and the expenses (a short throwaway script or by hand, not by calling the app''s code): nights, occupancy, income, costs by category, profit, ADR, RevPAR, profit per hour. They must match the dashboard exactly (integer COP).
- Then: Quit, check the backup file, restore it per the README (`task 50: README for the owner`) and see the same dashboard.
- Make it repeatable: `tests/test_e2e.py` does the same on `tests/fixtures/airbnb_sample.csv` (fake guest names; no real names in the repo) and asserts the hand-checked numbers for one month.
- Every mismatch or bug found becomes a follow-up task in the plan it belongs to; don''t fix it here.

Done when `tests/test_e2e.py` passes; the done note names the month checked and the result.', '2026-10-23T19:50:00Z', '2026-10-23T20:30:10Z', 46, 0, 'opus', 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (52, 10, 'Rates page stores typed exchange rates at the wrong scale', 'work', 'done', NULL, '2026-10-23, src/airbnb_books/web/forms.py, tests/test_web.py, tests/test_e2e.py', 'Found in `task 51: End-to-end check with real data`. Belongs to the Rates screen of `plan 8: data entry screens` (closed, hence here).

**Bug:** a rate typed on the Rates page is stored 100× too big, so every USD booking converted with it gets 100× its income (and co-host cost).

- Storage and conversion use **hundredths of COP per unit**: `exchange_rates.rate` 4123.45 → `412345` (architecture-spec.md section 6; `money.to_cop` divides `amount_minor * rate` by 10 000; the TRM import stores `parse_minor(value)`, also hundredths).
- `web/forms.py` `parse_rate` multiplies by `money.RATE_SCALE` (10 000) instead of 100, and `format_rate` divides by 10 000. Typing `3850.25` stores `38502500`; a TRM-imported `3209.78` (`320978`) is shown on the Rates page as `32.10`.
- Seen in the real app: October 2026 income 421.175.464 instead of 4.353.251.

**Fix:**
- `parse_rate` → hundredths (`int(Decimal(cleaned) * 100)`), `format_rate` → divide by 100. Don''t use `RATE_SCALE` there (it is the scale of minor units × rate, not of a rate).
- `tests/test_web.py`: `test_rates_dates_months` and `test_rates_create_recompute_edit_delete` assert the wrong values (`41005000`, `40_005_000`); correct them, and assert that a typed rate and a TRM-imported rate of the same value give the same COP for a line.
- `tests/test_e2e.py` loads its rates through a TRM file because of this bug (comment in `_enter_everything`); switch it to typing the two rates on `/rates/new` (2026-10-08 3850.25 and 2026-10-09 3900.00); the asserted numbers must stay the same.
- No migration needed: the app has not been used with typed rates yet.

Done when a rate typed on the Rates page gives the same COP as the TRM import of that rate, the Rates page shows TRM rates as typed (`3209.78`), and `pytest` passes.', '2026-10-23T20:30:02Z', '2026-10-23T20:31:04Z', 51, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (53, 1, 'post-milestone cleanup of milestone 1: first version build', 'cleanup', 'done', NULL, '2026-10-23, src/airbnb_books/web/app.py, removed stub.html; README and decisions checked, no pending decisions, no other milestones', 'After `milestone 1: first version build`, for the whole project:
* rewrite top-level .md files to reflect the current state of the project
* remove files that have become redundant
* suggest entirely new files, if necessary
* delete code that isn''t actually used
* check pending decisions if they are still relevant and really pending
* check other milestones if their contents are up-to-date; raise a decision for each change they need', '2026-10-23T20:31:04Z', '2026-10-23T20:31:35Z', NULL, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (54, NULL, 'Rename the app from airbnb-books to rios-de-asia-accounting', 'exec', 'done', NULL, '2026-10-23, src/rios_de_asia_accounting (renamed from airbnb_books), flake.nix, nix/module.nix, pyproject.toml, README.md, architecture-spec.md, tests', 'The human wants the app, its command and everything derived from the name to match the repo:
**`rios-de-asia-accounting`**. This replaces the name `airbnb-books` fixed by
`decision 3: approve the architecture` (only the name; the rest of that decision stands).
Record the new name with `pm decision record` so later tasks don''t bring the old one back.

## What to rename

- **Command / package:** `airbnb-books` → `rios-de-asia-accounting` (`flake.nix` pname, `meta.mainProgram`,
  `pyproject.toml` project name and console script, argparse `prog`).
- **Python package:** `src/airbnb_books/` → `src/rios_de_asia_accounting/`, all imports, tests.
- **Nix module:** `services.airbnb-books-backup` → `services.rios-de-asia-accounting-backup`, unit names
  likewise (`nix/module.nix`, the `backup-module` check in `flake.nix`).
- **Paths:** data dir `$XDG_DATA_HOME/rios-de-asia-accounting/books.db`, default backup dir
  `~/Dropbox/rios-de-asia-accounting`. Backup file names `books-YYYY-MM-DD.db` and `books.db` stay.
- **Env vars:** `AIRBNB_BOOKS_DB` → `RIOS_DE_ASIA_ACCOUNTING_DB`, `AIRBNB_BOOKS_BACKUP_DIR` →
  `RIOS_DE_ASIA_ACCOUNTING_BACKUP_DIR`.
- **User-visible text:** page title/header, startup and error messages, `README.md`, `architecture-spec.md`.
- Leave `airbnb-bookkeeping-spec.md` (the original product spec) and words that mean Airbnb itself
  (the CSV importer, "Airbnb fee", etc.) alone.

## Notes

- No compatibility with the old paths or env vars: no real data exists under the old names yet.
- Done when `grep -rI "airbnb.books\|AIRBNB_BOOKS"` (excluding `tasks.sql`, `.git`, `airbnb-bookkeeping-spec.md`)
  finds nothing, `nix flake check` passes and `nix run . -- --no-browser --port 8002` serves the app.', '2026-10-23T21:28:25Z', '2026-10-23T21:29:28Z', NULL, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (55, 11, 'write the masterplan of milestone 2: visual design update', 'masterplan', 'done', NULL, '2026-10-23, plan 11 body and intro, decision 23', 'Write `plan 11: masterplan`, the masterplan of `milestone 2: visual design update`: expand on everything that needs to be done to achieve it,
divided into parts, with an intro in plain English (`pm plan edit 11 --intro "…" --body -`). State in the masterplan that its own tasks are not implementation work: each of them writes the
plan for one part.', '2026-10-23T22:34:21Z', '2026-10-23T22:35:37Z', NULL, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (56, 11, 'create tasks for plan 11: masterplan', 'split', 'done', 1000, '2026-10-23, tasks 57 (part 1 plan, waits for decision 23), 58, 59 (parts 2, 3 plans, after 57), 60 (part 4 plan, after 58 and 59)', 'Split `plan 11: masterplan` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-23T22:35:34Z', '2026-10-23T22:36:14Z', 55, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (57, 11, 'write the plan for part 1: styling foundation', 'plan', 'done', 1000, '2026-10-24, plan 19: styling foundation; decision recorded (light ledger theme only); consequences of decisions 23 and 26', 'Write the plan for part 1 of `plan 11: masterplan` (see its body): **Styling foundation**, `pm plan add 2 "styling foundation" --priority 350 --intro "…"`.

- Covers: the CSS toolchain exactly as answered in `decision 23: How do Tailwind CSS and daisyUI get into an app that promised no build step and no network?`; a `web/static/` folder served by Flask and in `pyproject.toml` package data; Nix package, dev shell and (if the answer asks for it) a flake check updated.
- A custom daisyUI "ledger" theme (paper background, ledger green/blue rules, red ink for negatives, tabular/monospace figures); decide light only vs. optional dark mode and record it with `pm decision record`.
- `base.html` rebuilt: inline `<style>` replaced, nav as navbar or sheet tabs with the active page highlighted, Quit button, flash messages as alerts (categories `warning`/`error` kept), main area as a "sheet of paper" card.
- Shared conventions for parts 2–4 (components/classes for tables, forms, buttons, hints, errors; Jinja macros or a README section), so the later plans can point at them.
- Keep the masterplan''s ground rules in the plan body (no functional change, offline, checks).
- Waits for the human''s answer to `decision 23`.', '2026-10-23T22:36:11Z', '2026-10-24T00:12:22Z', 56, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (58, 11, 'write the plan for part 2: spreadsheet-style tables and dashboard', 'plan', 'done', 1000, '2026-10-23, plan 20: spreadsheet-style tables and dashboard (no files; its split task 106 was already running, so it could not be made to require task 102)', 'Write the plan for part 2 of `plan 11: masterplan` (see its body): **Spreadsheet-style tables and dashboard**, `pm plan add 2 "spreadsheet-style tables and dashboard" --priority 300 --intro "…"`.

- Covers: every list table (bookings, expenses, blocked days, time log, rates, recurring expenses, import preview/summary, booking detail lines) and the dashboard metric table in spreadsheet style (grid lines, column-header row, optional A/B/C letters and row-number gutter, zebra rows, right-aligned tabular numbers, red negatives via a class instead of the inline style in `index.html`).
- Dashboard period form as a compact "formula bar" toolbar; headings and the exchange-rate warning restyled; `web/charts.py` colours/fonts/grid aligned with the theme only.
- Build on the conventions from part 1''s plan (`styling foundation`); its implementation tasks `--requires` the part 1 implementation tasks they need (look them up with `pm plan list` / `pm show`).
- Keep the ground rules: no functional change (`decision 10`, `decision 18` formats and structure), tests keep passing, offline.', '2026-10-23T22:36:12Z', '2026-10-24T00:13:56Z', 56, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (59, 11, 'write the plan for part 3: forms and actions', 'plan', 'done', 1000, '2026-10-24, plan 21: forms and actions (no files changed)', 'Write the plan for part 3 of `plan 11: masterplan` (see its body): **Forms and actions**, `pm plan add 2 "forms and actions" --priority 300 --intro "…"`.

- Covers: every form (booking, expense, blocked days, time entry, rate, recurring expense, settings, CSV import upload) with daisyUI inputs, selects, labels, hints and errors; field names, order and validation unchanged (`decision 15: data entry forms: how money and hours are typed`).
- Buttons: primary Save/Apply, secondary Cancel/Reset links, danger Delete with the confirm dialogs kept; a "journal entry slip" feel for form cards.
- Build on the conventions from part 1''s plan (`styling foundation`); its implementation tasks `--requires` the part 1 implementation tasks they need.
- Keep the ground rules: no functional change, tests keep passing, offline, no new JavaScript.', '2026-10-23T22:36:12Z', '2026-10-24T00:14:55Z', 56, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (60, 11, 'write the plan for part 4: playful bookkeeping touches and favicon', 'plan', 'done', 1000, '2026-10-24, plan 22: playful bookkeeping touches and favicon (priority 200); split task 117 requires task 111 (part 3''s split)', 'Write the plan for part 4 of `plan 11: masterplan` (see its body): **Playful bookkeeping touches and favicon**, `pm plan add 2 "playful bookkeeping touches and favicon" --priority 200 --intro "…"`.

- Covers: favicon (ledger/abacus/calculator motif as SVG plus PNG/ICO fallback in `web/static/`, linked from `base.html`); app title/logo in the navbar; inline-SVG section icons; friendly empty states; a styled "stopped" page after Quit; double underline under totals; a "balanced ✓" / rubber-stamp look on the import summary.
- Only decorative wording may change; existing messages and labels stay.
- It decorates finished pages: its implementation tasks `--requires` the implementation tasks of parts 2 and 3 (`spreadsheet-style tables and dashboard`, `forms and actions`) that touch the same templates.
- Keep the ground rules: no functional change, offline (inline SVG / plain CSS only), readability first.', '2026-10-23T22:36:12Z', '2026-10-24T00:16:03Z', 56, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (61, 12, 'write the masterplan of milestone 3: add a proper client-side framework', 'masterplan', 'done', NULL, '2026-10-23, plan 12 body and intro; decision 24 recorded, decision 25 raised', 'Write `plan 12: masterplan`, the masterplan of `milestone 3: add a proper client-side framework`: expand on everything that needs to be done to achieve it,
divided into parts, with an intro in plain English (`pm plan edit 12 --intro "…" --body -`). State in the masterplan that its own tasks are not implementation work: each of them writes the
plan for one part.', '2026-10-23T22:40:12Z', '2026-10-23T22:42:16Z', NULL, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (62, 12, 'create tasks for plan 12: masterplan', 'split', 'done', 1000, '2026-10-23, tasks 63-68', 'Split `plan 12: masterplan` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-23T22:42:13Z', '2026-10-23T22:43:11Z', 61, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (63, 12, 'write the plan for part 1: architecture and client toolchain', 'plan', 'done', 1000, '2026-10-23, plan 14: architecture and client toolchain added (priority 850); no files changed', 'Write the plan for part 1 of `plan 12: masterplan` ("Architecture and client toolchain"): `pm plan add 3 "architecture and client toolchain" --priority 850 --intro "…"` with the full body.

- Scope as in the masterplan''s part 1: rewrite `architecture-spec.md` sections 1–3 for React + Vite + Flask JSON API (keep DB, migrations, backups, import), `frontend/` skeleton (Vite, React 19, TS, React Router, TanStack Query, Tailwind + daisyUI, Biome, Vitest, `package-lock.json`), app shell with today''s nav (`NAV` in `web/app.py`) and Quit, API client helper, Flask serving the bundle with `index.html` fallback, dev workflow with Vite proxy (README), Nix frontend derivation (`buildNpmPackage` + `importNpmLock`) copied into the Python package, dev shell `nodejs`, flake checks for lint/typecheck.
- Binding: `decision 24: client-side framework: React with TypeScript, built by Vite, on top of a JSON API from the existing Python server`; the masterplan''s ground rules (offline, same URLs, same-origin guard).
- Waits for `decision 25: In which order do the visual design update and the new client-side framework happen, and does the design work move onto the new screens?`: the answer decides whether the shell gets the default daisyUI look or the ledger theme of `plan 11: masterplan`.
- Split into tasks that each fit one worker run (e.g. spec rewrite; frontend skeleton + shell; Flask serving + dev workflow; Nix packaging).', '2026-10-23T22:43:05Z', '2026-10-23T22:45:51Z', 62, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (64, 12, 'write the plan for part 2: JSON API', 'plan', 'done', 1000, '2026-10-23, plan 13: JSON API added (priority 800); no files changed', 'Write the plan for part 2 of `plan 12: masterplan` ("JSON API"): `pm plan add 3 "JSON API" --priority 800 --intro "…"` with the full body.

- Scope as in the masterplan''s part 2: endpoints under `/api` for every current screen and action (dashboard incl. chart series and rate warnings, bookings with lines and overlap warning, expenses, recurring templates, blocked days, time log, rates, settings, CSV import upload → preview → listing choice → confirm, TRM rates import, quit).
- One error shape (`422` with per-field messages from the `web/forms.py` parsers) and one shape for warnings/notices (today''s flash messages); money and minutes as integers; a short API section in `architecture-spec.md` the TS types mirror.
- Reuse the logic of the current route modules (`web/bookings.py`, `web/expenses.py`, …); HTML routes stay until part 6; API tests with Flask''s test client, one or two per resource.
- Binding: `decision 24: client-side framework: React with TypeScript, built by Vite, on top of a JSON API from the existing Python server`, `decision 15: data entry forms: how money and hours are typed`, `decision 10: a figure that cannot be computed is shown as empty, not as zero` (null, not 0, in JSON).
- Independent of part 1 and of `decision 25`; split by resource so tasks fit one worker run (a shared foundation task first: blueprint, error/notice shape, same-origin guard).', '2026-10-23T22:43:05Z', '2026-10-23T22:44:33Z', 62, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (65, 12, 'write the plan for part 3: data screens', 'plan', 'done', 1000, '2026-10-23, plan 15: data screens (no files)', 'Write the plan for part 3 of `plan 12: masterplan` ("Data screens"): `pm plan add 3 "data screens" --priority 500 --intro "…"` with the full body.

- Scope as in the masterplan''s part 3: React lists and forms for bookings (detail lines, read-only fields of imported bookings per `decision 17: bookings from the Airbnb import: dates, listing and guest name are read-only in the edit form`), expenses (category toggle), recurring templates, blocked days, time log, rates, settings.
- Shared components: table, form field with error/hint, money/hours/date inputs per `decision 15: data entry forms: how money and hours are typed`, confirm-before-delete, notices; after save navigate as today''s redirects do.
- Server stays authoritative: send typed strings, show the API''s per-field errors.
- Build on the plans of parts 1 and 2 (written by the tasks this one requires): the plan''s tasks say which of their implementation tasks they need, so the split can `--requires` them.
- Waits for `decision 25: In which order do the visual design update and the new client-side framework happen, and does the design work move onto the new screens?` (default daisyUI look vs. full ledger look of `plan 11: masterplan`).', '2026-10-23T22:43:05Z', '2026-10-23T22:47:18Z', 62, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (66, 12, 'write the plan for part 4: dashboard and charts', 'plan', 'done', 1000, '2026-10-23, plan 16: dashboard and charts; task 75 body: also returns the effective period choices (form)', 'Write the plan for part 4 of `plan 12: masterplan` ("Dashboard and charts"): `pm plan add 3 "dashboard and charts" --priority 490 --intro "…"` with the full body.

- Scope as in the masterplan''s part 4: period controls (month, from, to, Apply, Reset) in URL query params per `decision 18: dashboard layout: which periods are shown and which period the cost breakdown uses`; metric table with empty cells per `decision 10: a figure that cannot be computed is shown as empty, not as zero`; rate warning.
- Charts: rolling 90-day line chart and expense breakdown bar chart as React SVG components from API data, porting `web/charts.py` (same series and ticks, `decision 13: the rolling 90-day chart starts once 90 days of history exist`); no chart library unless the plan argues for one.
- Build on the plans of parts 1 and 2 (written by the tasks this one requires); the plan''s tasks name which of their implementation tasks they need.
- Waits for `decision 25: In which order do the visual design update and the new client-side framework happen, and does the design work move onto the new screens?`.', '2026-10-23T22:43:05Z', '2026-10-23T22:48:43Z', 62, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (67, 12, 'write the plan for part 5: import flow', 'plan', 'done', 1000, '2026-10-23, plan 17: import flow added (priority 480, 2 tasks after split); decision 26 raised, task 57 waits for it; decision 25 consequences recorded; no files', 'Write the plan for part 5 of `plan 12: masterplan` ("Import flow"): `pm plan add 3 "import flow" --priority 480 --intro "…"` with the full body.

- Scope as in the masterplan''s part 5: Airbnb CSV upload, preview (new / updated / skipped / problems), first-import listing choice, confirm, summary; TRM rates CSV upload; counts of bookings lacking a rate. Same behaviour as today''s import pages.
- Build on the plans of parts 1 and 2 (written by the tasks this one requires); the plan''s tasks name which of their implementation tasks they need.
- Waits for `decision 25: In which order do the visual design update and the new client-side framework happen, and does the design work move onto the new screens?`.
- Of the plan-writing tasks waiting for `decision 25`, whichever finishes last (pm show tells) records its consequences with `pm decision consequences 25 "…"`: what happens to `plan 11: masterplan` and its tasks, and to `decision 23: How do Tailwind CSS and daisyUI get into an app that promised no build step and no network?`. If the answer means milestone 2 changes, raise a decision for the human rather than editing it.', '2026-10-23T22:43:05Z', '2026-10-23T22:50:13Z', 62, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (68, 12, 'write the plan for part 6: retire the server-rendered pages', 'plan', 'done', 1000, '2026-10-23, plan 18: retire the server-rendered pages (priority 400)', 'Write the plan for part 6 of `plan 12: masterplan` ("Retire the server-rendered pages"): `pm plan add 3 "retire the server-rendered pages" --priority 400 --intro "…"` with the full body.

- Scope as in the masterplan''s part 6: delete Jinja templates, HTML routes, `web/charts.py` if fully ported, unused Jinja filters; update `pyproject.toml` package data; reduce `tests/test_web.py`/`tests/test_e2e.py` to API tests; README (run, develop, build) and `architecture-spec.md` final; an end-to-end check with the real `airbnb_.csv` through the running app.
- Its tasks `--requires` the implementation tasks of parts 3–5 (data screens, dashboard and charts, import flow), whose plans the required tasks wrote.', '2026-10-23T22:43:05Z', '2026-10-23T22:51:29Z', 62, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (69, 13, 'create tasks for plan 13: JSON API', 'split', 'done', 1000, '2026-10-23, tasks 70-76', 'Split `plan 13: JSON API` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-23T22:44:30Z', '2026-10-23T22:45:19Z', 64, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (70, 13, 'JSON API foundation: /api blueprint, helpers, JSON errors, quit', 'work', 'done', NULL, '2026-10-23, web/api/{__init__,common,system}.py, web/app.py, architecture-spec.md, tests/test_api_foundation.py', 'First step of `plan 13: JSON API`; fixes the conventions every other API task uses (read the plan''s "Conventions" section, it is binding).

What:
- New package `src/rios_de_asia_accounting/web/api/` with one Flask blueprint at `/api`, registered in `create_app` (`web/app.py`).
- Helpers in the package (e.g. `api/common.py`):
  - read the JSON body (object of strings, arrays for multi-value fields) into `web/forms.py` `Form(data, lists)` so the existing parsers and messages apply;
  - `ok(data, notices)` → `200 {"data": …, "notices": [{"level", "text"}]}`;
  - `invalid(form)` → `422 {"errors": {field: message}}`, repo `ValidationError` under key `""`;
  - a notice helper (`info` / `warning` / `error`).
- JSON error handlers for paths under `/api`: 404, 403, 405 (and 400 for a body that is not a JSON object) as `{"error": "<text>"}`, not HTML pages. HTML routes keep their pages.
- Same-origin guard in `web/app.py`: from POST only to every non-GET method (PUT, DELETE, PATCH), for HTML and API alike.
- `POST /api/quit`: like `/quit`, shuts the server down after the response; returns `ok(None, [])`.
- A "JSON API" section in `architecture-spec.md`: the conventions from the plan (input, output values, reads, writes, notices, errors) and the first endpoint line (`POST /api/quit`). Later tasks add one line per endpoint (method, path, request, response).
- One test file `tests/test_api_foundation.py`: 404 JSON shape under `/api` and a cross-origin PUT/DELETE → 403. Sparse (AGENTS.md).

Done when: the blueprint and helpers exist, HTML pages unchanged, `pytest`, `ruff check src tests`, `ruff format --check src tests` green.', '2026-10-23T22:44:54Z', '2026-10-23T22:53:57Z', 69, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (71, 13, 'JSON API: bookings', 'work', 'done', NULL, '2026-10-23, web/api/bookings.py, web/bookings.py, web/api/__init__.py, architecture-spec.md, tests/test_api_bookings.py', 'Part of `plan 13: JSON API`: bookings under `/api`, module `web/api/bookings.py`, next to `web/bookings.py`.

- `GET /api/bookings?from=&to=&listing=`: list with today''s filters, money as integer pesos, `null` where a total cannot be computed (`decision 10: a figure that cannot be computed is shown as empty, not as zero`).
- `GET /api/bookings/<id>`: detail with booking lines, derived totals and an `imported` flag (has Airbnb lines).
- `GET /api/bookings/options`: listing names.
- `POST /api/bookings`, `PUT /api/bookings/<id>`: create/update with today''s fields and messages; imported bookings accept only guests and notes (`decision 17: bookings from the Airbnb import: dates, listing and guest name are read-only in the edit form`); overlap warning as a `warning` notice; "Booking saved." etc. as `info`.
- `DELETE /api/bookings/<id>`: blocked when expenses point at it → 422 with today''s text under key `""`.
- Test file `tests/test_api_bookings.py`.

Follow the "Conventions" of `plan 13: JSON API` and the helpers from `task 70: JSON API foundation: /api blueprint, helpers, JSON errors, quit` (`ok`, `invalid`, JSON body → `Form`). Reuse the parsers and helpers the HTML routes use; move logic out of HTML view functions into plain functions where both need it, with no behaviour change for the HTML pages. Add one line per endpoint (method, path, request, response) to the "JSON API" section of `architecture-spec.md`. Tests sparse: one happy path and one 422 or notice. Checks: `pytest`, `ruff check src tests`, `ruff format --check src tests`.', '2026-10-23T22:45:16Z', '2026-10-23T22:59:42Z', 69, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (72, 13, 'JSON API: expenses and recurring templates', 'work', 'done', NULL, '2026-10-23, web/api/expenses.py, web/expenses.py, web/api/__init__.py, architecture-spec.md, tests/test_api_expenses.py', 'Part of `plan 13: JSON API`: expenses and recurring expense templates under `/api`, module `web/api/expenses.py`, next to `web/expenses.py`.

- `GET /api/expenses` with today''s filters (incl. category), `GET /api/expenses/<id>`, `GET /api/expenses/options` (categories, booking choices from `booking_options`), `POST`, `PUT /<id>`, `DELETE /<id>`.
- `GET /api/recurring`, `GET /api/recurring/<id>`, `POST`, `PUT /<id>`, `DELETE /<id>` with today''s notices ("… N expense(s) generated", "the expenses it generated are kept").
- Money as integer pesos, months as `YYYY-MM`.
- Test file `tests/test_api_expenses.py`.

Follow the "Conventions" of `plan 13: JSON API` and the helpers from `task 70: JSON API foundation: /api blueprint, helpers, JSON errors, quit` (`ok`, `invalid`, JSON body → `Form`). Reuse the parsers and helpers the HTML routes use; move logic out of HTML view functions into plain functions where both need it, with no behaviour change for the HTML pages. Add one line per endpoint (method, path, request, response) to the "JSON API" section of `architecture-spec.md`. Tests sparse: one happy path and one 422 or notice. Checks: `pytest`, `ruff check src tests`, `ruff format --check src tests`.', '2026-10-23T22:45:16Z', '2026-10-23T23:00:19Z', 69, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (73, 13, 'JSON API: blocked days and time log', 'work', 'done', NULL, '2026-10-23, web/api/blocked.py, web/api/timelog.py, web/blocked.py, web/api/__init__.py, architecture-spec.md, tests/test_api_blocked.py, tests/test_api_timelog.py', 'Part of `plan 13: JSON API`: blocked days and time entries under `/api`, modules `web/api/blocked.py` and `web/api/timelog.py`, next to `web/blocked.py` and `web/timelog.py`.

- Blocked days: `GET /api/blocked-days`, `POST` (day ranges as today, the inside-a-booking notice), `PUT /api/blocked-days/<day>`, `DELETE /api/blocked-days/<day>`.
- Time entries: `GET /api/time`, `POST`, `PUT /api/time/<id>`, `DELETE /api/time/<id>`; minutes as integers in output, input hours as typed (`decision 15: data entry forms: how money and hours are typed`).
- Test files `tests/test_api_blocked.py`, `tests/test_api_timelog.py` (one test each is enough).

Follow the "Conventions" of `plan 13: JSON API` and the helpers from `task 70: JSON API foundation: /api blueprint, helpers, JSON errors, quit` (`ok`, `invalid`, JSON body → `Form`). Reuse the parsers and helpers the HTML routes use; move logic out of HTML view functions into plain functions where both need it, with no behaviour change for the HTML pages. Add one line per endpoint (method, path, request, response) to the "JSON API" section of `architecture-spec.md`. Tests sparse: one happy path and one 422 or notice. Checks: `pytest`, `ruff check src tests`, `ruff format --check src tests`.', '2026-10-23T22:45:16Z', '2026-10-23T23:00:59Z', 69, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (74, 13, 'JSON API: exchange rates and settings', 'work', 'done', NULL, '2026-10-23, web/api/rates.py, web/api/settings.py, web/settings.py (read_settings), architecture-spec.md, tests/test_api_rates.py, tests/test_api_settings.py', 'Part of `plan 13: JSON API`: exchange rates and settings under `/api`, module(s) in `web/api/` next to `web/settings.py`.

- Rates: `GET /api/rates`, `POST`, `PUT /api/rates/<day>/<currency>`, `DELETE /api/rates/<day>/<currency>`; rate as the stored integer (COP × 100); the "N bookings still need a rate" notice (`_needs_rate_message`) on writes.
- Settings: `GET /api/settings`, `PUT /api/settings`; listings as an array of strings.
- Test files `tests/test_api_rates.py`, `tests/test_api_settings.py` (one test each is enough).

Follow the "Conventions" of `plan 13: JSON API` and the helpers from `task 70: JSON API foundation: /api blueprint, helpers, JSON errors, quit` (`ok`, `invalid`, JSON body → `Form`). Reuse the parsers and helpers the HTML routes use; move logic out of HTML view functions into plain functions where both need it, with no behaviour change for the HTML pages. Add one line per endpoint (method, path, request, response) to the "JSON API" section of `architecture-spec.md`. Tests sparse: one happy path and one 422 or notice. Checks: `pytest`, `ruff check src tests`, `ruff format --check src tests`.', '2026-10-23T22:45:16Z', '2026-10-23T23:01:51Z', 69, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (75, 13, 'JSON API: dashboard', 'work', 'done', NULL, '2026-10-23, web/api/dashboard.py, web/dashboard.py (build_dashboard), architecture-spec.md, tests/test_api_dashboard.py', 'Part of `plan 13: JSON API`: the dashboard as data, module `web/api/dashboard.py`, next to `web/dashboard.py`.

- `GET /api/dashboard?month=&from=&to=`: today''s parameter handling and messages (as `error` notices in the response), per `decision 18: dashboard layout: which periods are shown and which period the cost breakdown uses`.
- Returns: column heads (label, start, end); metric rows (key, label, kind: `int`/`pct`/`money`/`minutes`, one value per column, `null` where uncomputable per `decision 10: a figure that cannot be computed is shown as empty, not as zero`), incl. remaining capex book value; count of bookings needing a rate; an `empty` flag; the rolling 90-day series as raw daily points (`date`, `adr`, `revpar`, `occupancy`; empty list before 90 days of history, `decision 13: the rolling 90-day chart starts once 90 days of history exist`); the expense breakdown (range, items with key, label, amount, share).
- Ratios as plain numbers (0.42). No chart geometry (ticks, scales): the client does that later.
- Move the period handling and table building out of the HTML view into a plain function both use; the HTML dashboard stays unchanged.
- Also returns `form`: the effective period choices for the controls, as today''s view fills them: `month` (`YYYY-MM`, default last month; the raw text when it was invalid), `from` and `to` as given. Needed by `plan 16: dashboard and charts` so the client never computes "last month" itself.
- Test file `tests/test_api_dashboard.py`.

Follow the "Conventions" of `plan 13: JSON API` and the helpers from `task 70: JSON API foundation: /api blueprint, helpers, JSON errors, quit` (`ok`, `invalid`, JSON body → `Form`). Reuse the parsers and helpers the HTML routes use; move logic out of HTML view functions into plain functions where both need it, with no behaviour change for the HTML pages. Add one line per endpoint (method, path, request, response) to the "JSON API" section of `architecture-spec.md`. Tests sparse: one happy path and one 422 or notice. Checks: `pytest`, `ruff check src tests`, `ruff format --check src tests`.', '2026-10-23T22:45:16Z', '2026-10-23T23:02:59Z', 69, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (76, 13, 'JSON API: Airbnb and exchange-rate import', 'work', 'done', NULL, '2026-10-23, web/api/importing.py, web/importing.py (shared upload/apply functions), architecture-spec.md, tests/test_api_import.py', 'Part of `plan 13: JSON API`: the CSV imports under `/api`, module `web/api/importing.py`, next to `web/importing.py`.

- `POST /api/import/airbnb` (multipart upload) → token + preview: new / updated / skipped / problems, whether a listing choice is needed and which listings the file has.
- `POST /api/import/airbnb/apply` (`token`, `listings`, `other_listing`) → summary; missing listing choice → 422 with the preview again.
- `DELETE /api/import/airbnb/<token>` → notice "Import cancelled; nothing was changed."
- `POST /api/import/rates` (multipart file + currency) → summary and problems, or 422.
- Same temp-file and token handling as `web/importing.py`: shared (moved into plain functions), not copied; HTML import pages unchanged.
- Test file `tests/test_api_import.py` (use a fixture from `tests/fixtures`).

Follow the "Conventions" of `plan 13: JSON API` and the helpers from `task 70: JSON API foundation: /api blueprint, helpers, JSON errors, quit` (`ok`, `invalid`, JSON body → `Form`). Reuse the parsers and helpers the HTML routes use; move logic out of HTML view functions into plain functions where both need it, with no behaviour change for the HTML pages. Add one line per endpoint (method, path, request, response) to the "JSON API" section of `architecture-spec.md`. Tests sparse: one happy path and one 422 or notice. Checks: `pytest`, `ruff check src tests`, `ruff format --check src tests`.', '2026-10-23T22:45:16Z', '2026-10-23T23:03:57Z', 69, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (77, 14, 'create tasks for plan 14: architecture and client toolchain', 'split', 'done', 1000, '2026-10-23, tasks 79 80 81 82', 'Split `plan 14: architecture and client toolchain` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-23T22:45:41Z', '2026-10-23T22:46:31Z', 63, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (78, 14, 'create tasks for plan 14: architecture and client toolchain', 'split', 'dropped', 1000, 'duplicate of task 77 (queued by an immediate body edit before any split ran)', 'Split `plan 14: architecture and client toolchain` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-23T22:45:48Z', '2026-10-23T22:45:51Z', 63, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (79, 14, 'Rewrite architecture-spec.md sections 1-3 for React + Vite + Flask JSON API', 'work', 'done', NULL, '2026-10-23, architecture-spec.md', 'Rewrite the stack part of `architecture-spec.md` so it describes the new architecture of milestone 3 (see `plan 14: architecture and client toolchain`, "Choices this plan makes").

- **Section 1 (tech stack and UI)**: per `decision 24: client-side framework: React with TypeScript, built by Vite, on top of a JSON API from the existing Python server`: React 19 + TS (strict) SPA, React Router (today''s URLs: `/` and the `NAV` paths of `web/app.py`, plus a not-found page), TanStack Query, Tailwind v4 + daisyUI 5 with plain daisyUI defaults (`decision 25`: no custom theme yet, only daisyUI component classes), Biome, Vitest for pure helpers; Flask stays the authoritative backend with a JSON API under `/api` (point to the "JSON API" section `plan 13: JSON API` adds); offline (no CDN, no network fonts); same-origin guard for writes; Quit button → `POST /api/quit` → "stopped" screen.
- **Section 2 (Nix packaging)**: `frontend` derivation with `buildNpmPackage` + `importNpmLock` from `package-lock.json`, its `dist` copied into `src/rios_de_asia_accounting/web/dist` before the Python build; dev shell adds `nodejs`; check `frontend-lint` (`biome check`, `tsc --noEmit`, `vitest run`) next to the existing ones.
- **Section 3 (code layout)**: add `frontend/` (`package.json`, `package-lock.json`, `vite.config.ts`, `tsconfig.json`, `biome.json`, `src/` with `main.tsx`, `api.ts`, pages); `web/dist/` built, git-ignored, package data; Flask serving: `/assets/…` from `web/dist`, a 404 handler giving `index.html` for unmatched non-`/api` GETs, plain 404 "frontend not built" without a bundle; dev workflow (Vite dev server on 5173 proxying `/api` to the server on 8080, rewriting `Origin`).
- Sections 4–7: keep; only where they name Jinja, HTML templates or `charts.py`, mark those as "until part 6" (they go when the HTML routes are deleted).
- Docs only, no code. Checks: none beyond reading the result; `pytest` still green.

Done when: sections 1–3 describe the new architecture with the choices above and nothing in 4–7 contradicts it.', '2026-10-23T22:46:24Z', '2026-10-23T22:52:05Z', 77, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (80, 14, 'Frontend skeleton and app shell in frontend/', 'work', 'done', NULL, '2026-10-23, frontend/ (package.json, lock, vite/ts/biome config, src/), flake.nix, .gitignore', 'Create the client project and the empty app frame (`plan 14: architecture and client toolchain`, "Choices this plan makes"; stack from `decision 24: client-side framework: React with TypeScript, built by Vite, on top of a JSON API from the existing Python server`).

- `frontend/` at the repo root: `package.json` + `package-lock.json` (commit both), Vite, React 19, TypeScript strict, React Router, TanStack Query, Tailwind v4 + daisyUI 5, Biome, Vitest. Scripts: `dev`, `build`, `typecheck` (`tsc --noEmit`), `lint` (`biome check`), `test` (`vitest run`).
- `vite.config.ts`: `build.outDir` = `../src/rios_de_asia_accounting/web/dist` (emptyOutDir). The `/api` proxy is the next task, leave it out or as a stub.
- Styling: plain daisyUI defaults, one built-in light theme, no custom theme, only daisyUI component classes (`decision 25`). No CDN, no network fonts.
- `src/main.tsx`: `QueryClient` + `QueryClientProvider`, router.
- Shell: header with today''s nav (labels and paths from `NAV` in `src/rios_de_asia_accounting/web/app.py`: `/`, `/bookings`, `/expenses`, `/recurring`, `/blocked-days`, `/time`, `/rates`, `/import`, `/settings`), active entry highlighted; a placeholder page per route; a not-found page.
- Quit button in the header → `POST /api/quit` → a "stopped" screen with the text of `templates/stopped.html`. (`/api/quit` comes from `task 70: JSON API foundation: /api blueprint, helpers, JSON errors, quit`; not needed to build this.)
- `src/api.ts`: `fetch` with relative URLs, JSON in/out, types for the `plan 13: JSON API` shapes (`{data, notices}`, `Notice {level, text}`, `422 {errors: {field: message}}`, `{error}`), an `ApiError` with status, field errors and text. One Vitest test of the error parsing (422 and `{error}`).
- `flake.nix`: add `nodejs` to the dev shell, only that line (packaging is a later task).

Checks: in `frontend/` `npm run build`, `npm run typecheck`, `npm run lint`, `npm test`; `pytest`, `ruff check/format --check src tests`. Don''t commit `node_modules/` or the built `dist/` (add them to `.gitignore` if not there yet).

Done when: `npm run dev` shows the shell with the nav and placeholders, all checks green.', '2026-10-23T22:46:24Z', '2026-10-23T22:53:10Z', 77, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (81, 14, 'Flask serves the built frontend; Vite dev proxy; README Develop section', 'work', 'done', NULL, '2026-10-23, web/app.py, frontend/vite.config.ts, package.json, pyproject.toml, README.md, tests/test_frontend_serving.py', 'Serve the bundle from Flask and set up the two-terminal dev workflow (`plan 14: architecture and client toolchain`, "Flask serving" and "Seeing new screens before part 6").

- `src/rios_de_asia_accounting/web/app.py`: assets at `/assets/…` from `web/dist/assets`; a 404 handler (not a catch-all route) that, for a `GET` not under `/api`, returns `web/dist/index.html`; without a built bundle it answers a short plain-text 404 "frontend not built". `/api` 404s keep the JSON shape from `task 70: JSON API foundation: /api blueprint, helpers, JSON errors, quit` — merge with its 404 handling, don''t shadow it. Existing Jinja routes keep working unchanged.
- `.gitignore`: `src/rios_de_asia_accounting/web/dist/`, `frontend/node_modules/` (if not already there).
- `pyproject.toml`: package data `web/dist/**/*`.
- `frontend/vite.config.ts`: dev server on 5173 proxies `/api` to `http://127.0.0.1:8080`, rewriting the `Origin` header to the target (`changeOrigin` plus a `configure` hook on `proxyReq`) so the same-origin guard passes. Never weaken the guard.
- README section "Develop": terminal 1 `rios-de-asia-accounting --no-browser --port 8080`, terminal 2 `cd frontend && npm install && npm run dev` → http://localhost:5173; `npm run build` to serve the bundle from Flask itself.
- One test (e.g. `tests/test_frontend_serving.py`): no bundle → unknown GET path gives plain 404; unknown `/api/...` stays a JSON 404.

Checks: `pytest`, `ruff check/format --check src tests`; in `frontend/` `npm run build`, `npm run typecheck`, `npm run lint`, `npm test`. Verify by hand: dev server shows the shell, Quit through the proxy stops the server and shows the stopped screen; after `npm run build`, the Flask server serves `/assets/…` and an unmatched path gives the app.

Done when: both work, checks green.', '2026-10-23T22:46:24Z', '2026-10-23T22:55:39Z', 77, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (82, 14, 'Nix packaging of the frontend bundle and frontend-lint check', 'work', 'done', NULL, '2026-10-23, flake.nix', 'Build the frontend in Nix and ship it inside the Python package (`plan 14: architecture and client toolchain`; `decision 24: client-side framework: React with TypeScript, built by Vite, on top of a JSON API from the existing Python server`: built by Nix, not committed).

- `flake.nix`: a `frontend` derivation with `buildNpmPackage` + `importNpmLock` (offline, from `frontend/package-lock.json`, no `npmDepsHash` churn), output the Vite `dist`; the Python package copies it into `src/rios_de_asia_accounting/web/dist` before its build (e.g. `preBuild`), so the wheel contains it via the package data set up by `task 81: Flask serves the built frontend; Vite dev proxy; README Develop section`.
- Note: `vite.config.ts` builds into `../src/rios_de_asia_accounting/web/dist`; inside the derivation override the out dir (e.g. `vite build --outDir dist`) or copy from there.
- Biome ships platform-specific optional binary packages (`@biomejs/cli-linux-x64` …), which may not resolve under `importNpmLock`. Fallback: use `pkgs.biome` for the lint check, pinned/checked to the lock''s version.
- New check `frontend-lint`: `biome check`, `tsc --noEmit`, `vitest run`.

Checks: `nix build`, `nix run` (app opens; until part 6 removes the Jinja pages, check that an unmatched path, e.g. `/app-check`, gets the shell and `/assets/…` load), `nix flake check` green; `pytest`, `ruff check/format --check src tests`.

Done when: all of the above green and the installed package contains `web/dist/index.html`.', '2026-10-23T22:46:24Z', '2026-10-23T22:58:26Z', 77, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (83, 15, 'create tasks for plan 15: data screens', 'split', 'done', 1000, '2026-10-23, tasks 84, 85, 86, 87', 'Split `plan 15: data screens` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-23T22:47:12Z', '2026-10-23T22:47:53Z', 65, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (84, 15, 'Form kit (format.ts, shared components, notices, useSave) and time log screens', 'work', 'done', NULL, '2026-10-23, frontend/src/format.ts, format.test.ts, useSave.ts, components/*, pages/Time.tsx, App.tsx', 'First screens of `plan 15: data screens`, and the shared pieces every later screen uses. Follow the plan''s "Choices" section; binding: `decision 24: client-side framework: React with TypeScript, built by Vite, on top of a JSON API from the existing Python server` (server authoritative, no client parsing), `decision 15: data entry forms: how money and hours are typed`, `decision 10: a figure that cannot be computed is shown as empty, not as zero`, `decision 25: In which order do the visual design update and the new client-side framework happen, and does the design work move onto the new screens?` (plain daisyUI default classes only).

What:
- `frontend/src/format.ts`: TS ports of `format_money`, `format_hours`, `format_rate` from `src/rios_de_asia_accounting/web/forms.py` (identical output), plus display helpers (money with dot thousands, `null` → dash). Vitest tests for these — the only tests of the plan.
- `frontend/src/components/`: `DataTable`, `Field`, `MoneyInput`, `HoursInput`, `RateInput` (text + `inputMode`, no parsing), `DateInput`, `Select`, `ConfirmDelete` (daisyUI modal, today''s texts), `Notices`.
- Notices context in the app shell: keeps the last write''s `notices`, shows them as daisyUI alerts above the page after navigation, dismissable.
- `useSave` hook: TanStack Query mutation; success → push notices, invalidate the resource''s queries, navigate; `422` → return `errors` to the form (field errors next to fields, `""` above the form; typed text stays); other errors → error notice.
- Form state: plain `Record<string, string>` (+ `string[]` for multi-value), sent as JSON strings.
- Time log screens at `/time`, `/time/new`, `/time/:id/edit` with delete, replacing the shell''s placeholder: same fields, hint texts, notices and redirects (save/delete → `/time`) as the Jinja pages (`web/app.py`, `templates/`). TS types mirror the "JSON API" section of `architecture-spec.md`.

Gaps in the API (missing field/option): add a follow-up task to `plan 13: JSON API`, no client workaround.

Done when: in `frontend/` `npm run build`, `npm run typecheck`, `npm run lint`, `npm test` pass; with the server (`--no-browser --port 8080`) on a copy of the real database and `npm run dev`, the time log list, create, edit with an error (e.g. hours `abc`) and delete work like today (ad-hoc headless screenshots fine).', '2026-10-23T22:47:34Z', '2026-10-23T23:06:17Z', 83, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (85, 15, 'Booking screens: list with filters, detail, new/edit, delete', 'work', 'done', NULL, '2026-10-23, frontend/src/pages/Bookings.tsx, components/inputs.tsx, App.tsx', 'Booking screens of `plan 15: data screens`, built with the form kit of `task 84: Form kit (format.ts, shared components, notices, useSave) and time log screens` on the endpoints of `task 71: JSON API: bookings`. Binding: `decision 17: bookings from the Airbnb import: dates, listing and guest name are read-only in the edit form`, `decision 10: a figure that cannot be computed is shown as empty, not as zero`, plain daisyUI classes (`decision 25`).

What (same fields, texts and navigation as the Jinja pages in `web/app.py` / `templates/`):
- `/bookings`: list with filters `from`, `to`, `listing` in the URL query.
- `/bookings/:id`: fields, derived totals, lines table (amount, COP or "needs rate"), needs-rate warning linking to `/rates`.
- `/bookings/new`, `/bookings/:id/edit`: imported bookings show dates, listing, guest name and amount read-only, only guests and notes editable, with today''s hint; listing suggestions from `GET /api/bookings/options`; overlap warning shown as a notice. Create/edit → detail page.
- Delete with `ConfirmDelete` (imported: "It was imported from Airbnb; a re-import brings it back."); success → list; blocked delete (expenses point at it) → stays on detail with the error, as today.

API gaps: follow-up task in `plan 13: JSON API`, no client workaround.

Done when: `npm run build`, `npm run typecheck`, `npm run lint`, `npm test` pass in `frontend/`; via `npm run dev` against the server on a copy of the real database: list with filters, create, edit with an error, edit of an imported booking, delete and a blocked delete behave like today.', '2026-10-23T22:47:50Z', '2026-10-23T23:07:25Z', 83, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (86, 15, 'Expense and recurring template screens', 'work', 'done', NULL, '2026-10-23, frontend/src/pages/Expenses.tsx, App.tsx (routes; also moved the booking/time routes out of the header and restored their nav links), components/inputs.tsx (MonthInput)', 'Expense and recurring-template screens of `plan 15: data screens`, built with the form kit of `task 84: Form kit (format.ts, shared components, notices, useSave) and time log screens` on the endpoints of `task 72: JSON API: expenses and recurring templates`. Binding: `decision 16: changing a recurring expense template only affects months not yet generated`, plain daisyUI classes (`decision 25`).

What (same fields, texts and navigation as the Jinja pages in `web/app.py` / `templates/`):
- `/expenses`: list with today''s filters (incl. category) in the URL query.
- `/expenses/new`, `/expenses/:id/edit`: category select; booking field shown only for `per_booking`, useful life only for `capex` (cosmetic, the server ignores the rest); booking choices and categories from `GET /api/expenses/options`; hint and link to the template when the expense was generated from one. Save/delete → `/expenses`.
- `/recurring`, `/recurring/new`, `/recurring/:id`: the template''s own page has its form plus the list of expenses it generated, each linked to its edit page. Save → own page with the "… N expense(s) generated" notice; delete → list with today''s notice (generated expenses are kept).

API gaps: follow-up task in `plan 13: JSON API`, no client workaround.

Done when: `npm run build`, `npm run typecheck`, `npm run lint`, `npm test` pass in `frontend/`; via `npm run dev` against the server on a copy of the real database: list, create, edit with an error and delete work like today for both expenses and templates.', '2026-10-23T22:47:50Z', '2026-10-23T23:11:07Z', 83, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (87, 15, 'Blocked days, exchange rate and settings screens', 'work', 'done', NULL, '2026-10-23, frontend/src/pages/Blocked.tsx, Rates.tsx, Settings.tsx, App.tsx', 'Remaining data screens of `plan 15: data screens`, built with the form kit of `task 84: Form kit (format.ts, shared components, notices, useSave) and time log screens` on the endpoints of `task 73: JSON API: blocked days and time log` and `task 74: JSON API: exchange rates and settings`. Binding: `decision 15: data entry forms: how money and hours are typed` (rates up to 2 decimals), plain daisyUI classes (`decision 25`).

What (same fields, texts and navigation as the Jinja pages in `web/app.py` / `templates/`):
- `/blocked-days`, `/blocked-days/new`, `/blocked-days/:day`: new as a from/to range with reason and note, hint "Days that are already blocked are skipped.", today''s notices (incl. inside-a-booking); edit by day; delete. Save/delete → list.
- `/rates`, `/rates/new`, `/rates/:day/:currency`: list, new, edit, delete; the "N bookings still need a rate" notice. Save/delete → list.
- `/settings`: money fields, allocation select, listing checkboxes plus "another listing" (multi-value field as `string[]`), backups to keep, currency shown as COP. Save → settings.

API gaps: follow-up task in `plan 13: JSON API`, no client workaround.

Done when: `npm run build`, `npm run typecheck`, `npm run lint`, `npm test` pass in `frontend/`; via `npm run dev` against the server on a copy of the real database: list, create, edit with an error and delete work like today for blocked days and rates; settings save and show an error like today.', '2026-10-23T22:47:50Z', '2026-10-23T23:12:10Z', 83, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (88, 16, 'create tasks for plan 16: dashboard and charts', 'split', 'done', 1000, '2026-10-23, tasks 89, 90', 'Split `plan 16: dashboard and charts` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-23T22:48:37Z', '2026-10-23T22:49:14Z', 66, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (89, 16, 'Dashboard screen without charts', 'work', 'done', NULL, '2026-10-23, frontend/src/pages/Dashboard.tsx, frontend/src/App.tsx', 'Part of `plan 16: dashboard and charts`: the React dashboard at `/`, built into the app shell of `task 80: Frontend skeleton and app shell in frontend/`, reading `GET /api/dashboard` from `task 75: JSON API: dashboard`. The Jinja page (`web/dashboard.py`, `templates/index.html`) is the reference and stays.

- TS types for the dashboard response, mirroring the "JSON API" section of `architecture-spec.md`.
- Period controls: Month (`type="month"`), From, To (`type="date"`), Apply, Reset, bound to `useSearchParams` (`?month=&from=&to=`, bookmarkable, `decision 18: dashboard layout: which periods are shown and which period the cost breakdown uses`). Inputs start from the response''s `form`; Apply writes non-empty values; Reset goes to `/`. The TanStack Query key includes the query string.
- Notices with level `error` (bad parameters) show under the form, not as global notices.
- Rate warning "N booking(s) need(s) an exchange rate" as a warning alert linking to `/rates`; empty state "Nothing here yet: import the Airbnb CSV or add a booking." linking to `/import` and `/bookings/new`.
- Metric table: header cell "COP unless stated"; each column its label with "start – end" as a hint. Values: `pct` → x*100, 1 decimal + " %"; `minutes` → hours, 1 decimal; `money` truncated like `int(value)`, dot thousands, negatives with "−" and `text-error`; `int` as is; `null` → "–" (`decision 10: a figure that cannot be computed is shown as empty, not as zero`). Use `frontend/src/format.ts` from `task 84: Form kit (format.ts, shared components, notices, useSave) and time log screens`; no second money formatter.
- "Last 90 days, day by day" section: texts as today ("The 90-day chart starts once 90 days of history exist." for an empty series, "Nothing to chart." for all-null), with placeholders where the two line charts go.
- "Expense breakdown" with the range as a hint: "No costs in this period." when all amounts are 0, else a Category / COP / Share table (share `null` → "–"); placeholder for the bar chart.
- Plain daisyUI default classes, no custom theme (`decision 25: In which order do the visual design update and the new client-side framework happen, and does the design work move onto the new screens?`).
- A field missing from the API: follow-up task in `plan 13: JSON API`, no client workaround.

Checks in `frontend/`: `npm run build`, `npm run typecheck`, `npm run lint`, `npm test`. Verify with the server (`--no-browser --port 8080`) and the Vite dev server on a copy of the real database: same numbers and texts as the Jinja page for the default view, `?month=…`, `?from=…&to=…` and an invalid range.

Done when: the dashboard minus charts matches the Jinja page for those URLs and the checks are green.', '2026-10-23T22:49:12Z', '2026-10-23T23:13:05Z', 88, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (90, 16, 'Dashboard charts: chartMath, LineChart, BarChart', 'work', 'done', NULL, '2026-10-23, frontend/src/charts/{chartMath.ts,chartMath.test.ts,LineChart.tsx,BarChart.tsx}, frontend/src/pages/Dashboard.tsx', 'Part of `plan 16: dashboard and charts`: port `web/charts.py` to React SVG in `frontend/src/charts/` and put the charts into the dashboard in place of the placeholders left by the previous task of this plan. No chart library: same look, ticks and labels as today.

- `chartMath.ts`, pure helpers: `niceTicks(lo, hi, target=5)`; the y-range logic of `line_chart` (`y_min`/`y_max`, ticks clipped to the range); month-start x labels, first day labelled when it is not a 1st, thinned by `stride = ceil(n*48/plotWidth)`; splitting a series into runs at `null` (gaps, `decision 10: a figure that cannot be computed is shown as empty, not as zero`).
- Dates: day arithmetic on `YYYY-MM-DD` strings via UTC; month labels from a fixed English list ("Jan 2026"), not the locale.
- `LineChart` (series, yFormat, yMin, yMax, width, height) and `BarChart` (items, valueFormat, width=600): same layout constants, Okabe-Ito palette and dash patterns as `web/charts.py`, `<title>` tooltips on points and bars, legend under the plot, `viewBox` with `width="100%"`.
- Dashboard: "ADR and RevPAR (COP)" (800×280, yMin 0, money labels via `format.ts`), "Occupancy" (800×220, 0..1, labels x*100 with 0 decimals + " %"), and the expense breakdown bar chart above its table.
- Vitest only for `chartMath.ts`: a few cases whose expected values come from running the Python functions in `web/charts.py`.

Checks in `frontend/`: `npm run build`, `npm run typecheck`, `npm run lint`, `npm test`. Verify with the server (`--no-browser --port 8080`) and the Vite dev server on a copy of the real database; compare chart shapes, ticks and labels with the Jinja page at `http://127.0.0.1:8080/` for the default view, `?month=…` and `?from=…&to=…` (ad-hoc headless screenshots are fine).

Done when: the charts match the Jinja page for those URLs and the checks are green.', '2026-10-23T22:49:12Z', '2026-10-23T23:14:01Z', 88, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (91, 17, 'create tasks for plan 17: import flow', 'split', 'done', 1000, '2026-10-23, tasks 92, 93', 'Split `plan 17: import flow` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-23T22:49:54Z', '2026-10-23T22:50:26Z', 67, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (92, 17, 'Import screen: Airbnb import flow in React', 'work', 'done', NULL, '2026-10-23, frontend/src/api.ts, frontend/src/App.tsx, frontend/src/pages/Import.tsx', 'The `/import` route in `frontend/` with the Airbnb part of today''s Jinja import pages (`web/importing.py`, `templates/import.html`, `import_preview.html`, `import_summary.html` are the reference: same steps, texts, counts, links). Spec: `plan 17: import flow`.

What:
- `postFile(path, FormData)` in `frontend/src/api.ts` next to the JSON helpers: no `Content-Type` header (browser sets the multipart boundary), same `ApiError` handling, same-origin.
- TS types for the Airbnb import responses, mirroring the "JSON API" section of `architecture-spec.md`.
- `/import` replaces the shell''s placeholder; one route, steps in component state (upload → preview → summary); reload goes back to upload.
- Upload: "You see what would change before anything is written.", file input (`.csv,text/csv`), Preview; no file → "choose the Airbnb CSV file"; API file errors above the form.
- Preview with listing choice: today''s paragraph, one checkbox per listing with row count (server order), "Another listing name"; 422 "choose at least one listing" shown above the form, preview kept.
- Preview otherwise: "Listings imported: …", new bookings table, updated bookings table (`field: old → new` or "new lines only"), skipped counts (payout rows, already imported lines, other listings per listing), problems ("line N: message") and warnings. Changes come from the server (`decision 14: Airbnb import: which rows set a booking''s dates, listing and guest name`); nothing decided on the client (`decision 24: client-side framework: React with TypeScript, built by Vite, on top of a JSON API from the existing Python server`).
- Import → summary: counts, "N booking(s) need an exchange rate (rates)" linking `/rates`, skipped, problems, warnings, link to `/bookings`; then invalidate all TanStack queries.
- Cancel → `DELETE` → upload forms + notice "Import cancelled; nothing was changed." (notices context from `task 84: Form kit (format.ts, shared components, notices, useSave) and time log screens`).
- "The uploaded file is gone; upload it again" on apply → upload form with that error.
- Plain daisyUI default classes only (`decision 25: In which order do the visual design update and the new client-side framework happen, and does the design work move onto the new screens?`).

Not here: the exchange-rate section (next task), deleting the Jinja pages (part 6). API gaps → follow-up task in `plan 13: JSON API`, no client workaround.

Done when: in `frontend/` `npm run build`, `npm run typecheck`, `npm run lint`, `npm test` are green; with the server (`--no-browser --port 8080`) on a **copy** of the real database plus the Vite dev server: upload `airbnb_.csv` (preview counts equal the Jinja page''s), Cancel, upload again and Import, re-import (all skipped), non-CSV file (error); once on an empty database for the listing choice. Ad-hoc headless screenshots are fine.', '2026-10-23T22:50:21Z', '2026-10-23T23:16:33Z', 91, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (93, 17, 'Import screen: exchange-rate (TRM) import in React', 'work', 'done', NULL, '2026-10-23, frontend/src/pages/Import.tsx', 'The exchange-rate (TRM) section on the `/import` page in `frontend/`, below the Airbnb part, matching today''s Jinja import page (`templates/import.html`, `web/importing.py`). Spec: `plan 17: import flow`.

What:
- Hint "CSV from datos.gov.co with the columns VALOR and VIGENCIADESDE.", file input, Currency (default `USD`, typed text kept after an error), "Load rates" button; upload via `postFile` in `frontend/src/api.ts`.
- TS type for the rates import response, mirroring the "JSON API" section of `architecture-spec.md`.
- Field errors from the API through the `Field` component.
- Success: "USD rates: N added, N changed; N line(s) recomputed; N booking(s) still need an exchange rate." plus the problem list; then invalidate all TanStack queries.
- Plain daisyUI default classes only.

API gaps → follow-up task in `plan 13: JSON API`, no client workaround.

Done when: in `frontend/` `npm run build`, `npm run typecheck`, `npm run lint`, `npm test` are green; with the server (`--no-browser --port 8080`) on a **copy** of the real database plus the Vite dev server, loading a TRM fixture from `tests/fixtures` shows the same counts as the Jinja page, and a bad currency shows the field error with the typed text kept.', '2026-10-23T22:50:21Z', '2026-10-23T23:17:17Z', 91, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (94, 18, 'create tasks for plan 18: retire the server-rendered pages', 'split', 'done', 1000, '2026-10-23, tasks 97, 98, 95, 96', 'Split `plan 18: retire the server-rendered pages` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-23T22:51:21Z', '2026-10-23T22:52:29Z', 68, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (95, 18, 'README and architecture spec describe the final app', 'work', 'done', NULL, '2026-10-23, README.md, architecture-spec.md', 'Bring the docs in line with the app after the server-rendered pages are gone (`plan 18: retire the server-rendered pages`).

- `README.md`: sections Install, Run and quit, Import, Exchange rates kept, but checked against the React screens (names of buttons, menu entries, URLs). Keep "Develop" (from `task 81: Flask serves the built frontend; Vite dev proxy; README Develop section`); add a "Build" section: `nix build`, `npm run build` for a local bundle, and which checks run where (pytest/ruff vs. `npm run …` vs. `nix flake check`).
- `architecture-spec.md`: remove every "until part 6" mark and every mention of Jinja, `charts.py` or HTML routes; check the "JSON API" section against the actual endpoints under `web/api/` and fix differences in the spec (not the code).
- Code differences you find that look like bugs: follow-up task, not a fix here.

Checks: `pytest`, `ruff check src tests`, `ruff format --check src tests`.

Done when both documents describe the app as it is.', '2026-10-23T22:52:01Z', '2026-10-23T23:21:38Z', 94, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (96, 18, 'End-to-end check of the built app with the real Airbnb export', 'work', 'done', NULL, '2026-10-23, no files; built app (nix build) ran on fresh DB with airbnb_.csv via headless Chrome: import with listing choice (11 new, 13 lines, same as pre-deletion CLI import), rate, expense, time, blocked day, recurring (2 generated), settings, bookings detail reload, Quit + backup all OK; dashboard tables for default, ?month=, and custom range identical to the pre-deletion app (e06ad1c); charts render; / /bookings/1 /rates/.. give index.html, unknown /api 404 JSON. No findings, no follow-up tasks. Not covered: TRM file import (no file available; typed a rate instead).', 'Manual run-through of the finished app with the real export, to confirm nothing was lost in milestone 3 (`plan 18: retire the server-rendered pages`). No code fixes here.

- `nix build`, run the built app with `--no-browser --port …` on a fresh database in a temp dir (point XDG_DATA_HOME there; don''t touch the real database or the Dropbox backups).
- Through a headless browser (ad-hoc screenshots fine): import `airbnb_.csv` with the listing choice; load a TRM file or type a rate; add an expense, a recurring template, a blocked day, a time entry; edit settings; dashboard for a month and a custom range, both charts; reload bookmark-style URLs (`/bookings/<id>`, `/?month=…`); Quit.
- Compare dashboard numbers with the pre-deletion app (checkout of the commit before `task 98: Delete the server-rendered pages, templates and charts.py`, in a separate git worktree) on the same file and inputs.
- Anything wrong: a follow-up task in the plan it belongs to (`plan 13: JSON API`, `plan 15: data screens`, `plan 16: dashboard and charts`, `plan 17: import flow`, or this plan), with what, where, done when.
- Delete temp dirs, screenshots and worktrees afterwards.

Done when every screen worked or has a follow-up task, and the findings are in the task''s done note.', '2026-10-23T22:52:01Z', '2026-10-23T23:25:02Z', 94, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (97, 18, 'End-to-end test through the JSON API', 'work', 'done', 410, '2026-10-23, tests/test_e2e.py', 'Rewrite `tests/test_e2e.py` so it drives the app through `/api` instead of scraping HTML, before the HTML pages are deleted (`plan 18: retire the server-rendered pages`).

- Same scenario, same hand-computed October 2026 numbers; the docstring stays the reference and is not changed.
- Steps via the JSON API: Airbnb import with the listing choice, exchange rates, expenses, time entries, dashboard JSON values, `POST /api/quit`, then backup and restore.
- Assertions on the numbers stay the same (compare JSON values, not formatted strings, unless the API returns formatted ones). Per `decision 10: a figure that cannot be computed is shown as empty, not as zero`, uncomputable ratios are `null`.
- Don''t touch the HTML routes or other tests; this only needs the JSON API.

Checks: `pytest`, `ruff check src tests`, `ruff format --check src tests`.

Done when the rewritten e2e test passes and uses no HTML route.', '2026-10-23T22:52:21Z', '2026-10-23T23:17:56Z', 94, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (98, 18, 'Delete the server-rendered pages, templates and charts.py', 'work', 'done', 410, '2026-10-23, web/app.py, web/api/{bookings,expenses,blocked,timelog,settings,rates,importing,dashboard,common}.py (helpers moved in), deleted web/templates/, web/{dashboard,bookings,expenses,blocked,timelog,settings,importing,charts}.py, tests/test_web.py -> tests/test_forms.py, deleted tests/test_charts.py, ported 4 rules to tests/test_api_{bookings,expenses,rates}.py, tests/test_backup.py quit via /api/quit, pyproject.toml, flake.nix, frontend/src/nav.ts', 'Remove the Jinja side of the Flask app so it is only the JSON API plus the built React bundle (`decision 24: client-side framework: React with TypeScript, built by Vite, on top of a JSON API from the existing Python server`). No functional change: every URL of today must open the React screen via the index.html fallback. Details in `plan 18: retire the server-rendered pages`, sections "What goes, what stays" and "Tests".

**Delete**
- `web/templates/` (all templates incl. `stopped.html`).
- HTML view functions and their `register(app)` calls in `web/dashboard.py`, `bookings.py`, `expenses.py`, `blocked.py`, `timelog.py`, `settings.py`, `importing.py`; `POST /quit` (keep `POST /api/quit`).
- In `web/app.py`: Jinja filters `money`, `rate`, `hours`, the `nav` context processor, `NAV` if nothing reads it, `app.secret_key`/`flash` if unused.
- `web/charts.py` and `tests/test_charts.py` (first check nothing in `web/api/` imports it).

**Move**
- Helpers the API still uses from those modules (`_overlaps`, `_needs_rate_message`, dashboard period handling, import token/temp-file handling, `booking_options`, …) go next to their API module or into one plain helper module in `web/`. No module may remain that only existed for deleted pages. Drop the leading underscore where they become cross-module. No behaviour change.

**Keep**: `web/forms.py`, `web/app_db.py`, the same-origin guard, bundle serving and fallback.

**Packaging**: `pyproject.toml` package data without `web/templates/*.html` (keep `web/dist/**/*` and migrations); drop the explicit `jinja2` dependency from `pyproject.toml` and `flake.nix`.

**Tests** (AGENTS.md: sparse)
- `tests/test_web.py`: keep parser/helper tests (`parse_money`, `parse_hours`, `format_*`, `Form`, `booking_options`, one connection per request); rename to `tests/test_forms.py` if only those remain; delete HTML route tests.
- Before deleting a route test, check its rule is covered by a `tests/test_api_<resource>.py` test; port only uncovered ones as API tests (likely: typed rate equals TRM-imported rate, expense fields ignored for other categories, recurring edit keeps generated rows).

**Verify** with a built bundle: `GET /`, `/bookings/<id>`, `/rates/<day>/<currency>` answer 200 with `index.html`; unknown `/api/...` stays a JSON 404; `/assets/...` load.

Checks: `pytest`, `ruff check src tests`, `ruff format --check src tests`; in `frontend/`: `npm run build`, `npm run typecheck`, `npm run lint`, `npm test`; `nix flake check`.

Done when no template, HTML route or `charts.py` is left and all checks are green.', '2026-10-23T22:52:21Z', '2026-10-23T23:20:49Z', 94, 0, 'opus', 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (99, 14, 'Make the Flask tests independent of a built frontend bundle', 'work', 'done', NULL, '2026-10-23, tests/conftest.py, flake.nix', '- Problem: with a built bundle in `src/rios_de_asia_accounting/web/dist/` (after `npm run build`), three tests in `tests/test_web.py` fail (`test_booking_delete`, `test_blocked_validation_edit_delete`, `test_rates_create_recompute_edit_delete`): they expect a 404 for a deleted item, but the app now answers the frontend shell. The Nix build works around it by removing the bundle before the tests run.
- Do: in `tests/conftest.py` (or the app fixture) point `rios_de_asia_accounting.web.app.DIST` at a nonexistent directory, so tests never depend on a bundle.
- Done when: `pytest` is green with and without a built bundle; then the `postBuild` removal in `flake.nix` can go.', '2026-10-23T22:58:17Z', '2026-10-23T22:58:55Z', 82, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (100, 18, 'Drop the unused placeholder routes from the React shell', 'work', 'done', NULL, '2026-10-23, frontend/src/App.tsx, frontend/src/pages/Placeholder.tsx (deleted)', 'Every nav entry now has a real screen, so the "not built yet" fallback in the React shell is dead code.

- `frontend/src/App.tsx`: remove the `IMPLEMENTED` list, the `NAV.filter(...)` block that adds `<Placeholder>` routes, and the `Placeholder` import.
- Delete `frontend/src/pages/Placeholder.tsx` if nothing else imports it.
- No functional change: every nav URL already matches an explicit `<Route>`.

Done when: `npm run build`, `npm run typecheck`, `npm run lint` and `npm test` in `frontend/` are green and no `Placeholder` is left.', '2026-10-23T23:20:49Z', '2026-10-23T23:25:19Z', 98, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (101, 12, 'post-milestone cleanup of milestone 3: add a proper client-side framework', 'cleanup', 'done', NULL, '2026-10-23, frontend/src/App.tsx, frontend/src/pages/Placeholder.tsx (deleted), architecture-spec.md', 'After `milestone 3: add a proper client-side framework`, for the whole project:
* rewrite top-level .md files to reflect the current state of the project
* remove files that have become redundant
* suggest entirely new files, if necessary
* delete code that isn''t actually used
* check pending decisions if they are still relevant and really pending
* check other milestones if their contents are up-to-date; raise a decision for each change they need', '2026-10-23T23:25:20Z', '2026-10-23T23:25:48Z', NULL, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (102, 19, 'create tasks for plan 19: styling foundation', 'split', 'done', 1000, '2026-10-23, tasks 103, 104, 105; decision 28 recorded', 'Split `plan 19: styling foundation` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-24T00:12:11Z', '2026-10-24T00:12:41Z', 57, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (103, 19, 'ledger theme and shared number classes', 'work', 'done', NULL, '2026-10-23, frontend/src/index.css, frontend/index.html', 'Part of `plan 19: styling foundation`; follow the plan''s ground rules (no functional change, offline, no new npm deps, light only: `decision 28: visual design: one light ledger theme, no dark mode`).

Files: `frontend/src/index.css`, `frontend/index.html`.

- Replace `themes: light --default` with a custom daisyUI 5 theme `ledger` (`@plugin "daisyui/theme" { name: "ledger"; default: true; color-scheme: light; … }`):
  - warm off-white paper `base-100`, slightly darker `base-200`/`base-300` for chrome and header rows, dark ink `base-content`
  - ledger green `primary`, ledger blue `secondary`/`info`, clear red ink `error`, readable `warning`, plus matching `*-content` colours
  - small `--radius-*` (paper, not bubbly)
- `data-theme="ledger"` on `<html>` in `index.html`.
- Shared classes in `index.css` (`@utility` or `@layer components`):
  - `num`: tabular-nums, right-aligned, monospace system font stack
  - `neg`: red ink, `color: var(--color-error)`
  - CSS variables for rule colours (e.g. `--ledger-rule-green`, `--ledger-rule-blue`) for later grid lines and underlines
- Contrast: body text and `error` on `base-100` at least WCAG AA (check the ratios with a quick ad-hoc calculation).
- Don''t apply `num`/`neg` to pages yet; that is later work.

Done when: `npm run typecheck`, `npm run lint`, `npm test`, `npm run build` (in `frontend/`), `pytest` and `nix flake check` pass, and every page renders in the new colours with nothing else changed (look at it via `rios-de-asia-accounting --no-browser`).', '2026-10-24T00:12:39Z', '2026-10-24T00:16:50Z', 102, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (104, 19, 'app shell: sheet tabs, paper card, notices', 'work', 'done', NULL, '2026-10-23, frontend/src/App.tsx, components/Notices.tsx, pages/Stopped.tsx', 'Part of `plan 19: styling foundation`; follow the plan''s ground rules (no functional change, offline, no new npm deps, icons as inline SVG).

Files: `frontend/src/App.tsx`, `frontend/src/components/Notices.tsx`, `frontend/src/pages/Stopped.tsx`.

- Nav as spreadsheet sheet tabs along the top: daisyUI `tabs` with `tabs-lift` (or `tabs-border`), `NavLink` active → `tab-active`. Same entries from `nav.ts`, same order and paths; the app name link to `/` stays. Wraps or scrolls horizontally on narrow windows.
- Quit: small outlined button on the right, still disabled while pending; its error alert kept.
- Notices: daisyUI `alert` with `alert-warning`/`alert-error` from the notice level and a small inline-SVG icon per level; Dismiss kept.
- `<main>` as a sheet of paper: centred card (`card bg-base-100 shadow`, max width) on a `base-200` desk background, visually attached to the active tab.
- `Stopped.tsx` on the same paper card, same texts.

Done when: all checks in the plan pass (`npm run typecheck`, `lint`, `test`, `build`, `pytest`, `nix flake check`) and every page, a notice and the stopped page look right in the running app; routes and texts unchanged.', '2026-10-24T00:12:39Z', '2026-10-24T00:17:38Z', 102, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (105, 19, 'PageTitle/SectionTitle components and README styling conventions', 'work', 'done', NULL, '2026-10-23, frontend/src/components/Titles.tsx, frontend/src/pages/*.tsx, README.md', 'Part of `plan 19: styling foundation`; follow the plan''s ground rules (no functional change, same texts).

- New small components `PageTitle` (h1, optional slot/prop for a section icon added later) and `SectionTitle` (h2), e.g. in `frontend/src/components/Titles.tsx`.
- Replace every `<h1 className="text-2xl font-bold …">` and `<h2 className="text-xl font-bold …">` in `frontend/src/pages/*.tsx` (Blocked, Bookings, Dashboard, Expenses, Import, NotFound, Rates, Settings, Stopped, Time) with them; keep texts and the spacing that mattered (e.g. headings without bottom margin).
- README section "Styling conventions" for the later design work:
  - numbers: `num`, negatives `neg`
  - tables only via `DataTable` (pages add no table classes)
  - forms via `Field` + `inputs.tsx`; form actions in one `flex gap-2 mt-4` row
  - buttons: `btn btn-primary` Save/Apply, `btn btn-ghost` or `btn-soft` Cancel/Reset links, `btn btn-error` Delete via `ConfirmDelete`
  - errors: page-level `alert alert-error`, field-level `text-error` under the field (in `Field`); hints via `Field`''s `hint`; muted notes `opacity-70`
  - headings via `PageTitle`/`SectionTitle`
  - icons: inline SVG components in `frontend/src/components/icons.tsx` (created later)
- Bring existing pages in line with these conventions only where it''s a pure class change.

Done when: no page uses the old heading classes, the README section exists, and all checks in the plan pass.', '2026-10-24T00:12:39Z', '2026-10-24T00:18:31Z', 102, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (106, 20, 'create tasks for plan 20: spreadsheet-style tables and dashboard', 'split', 'done', 1000, '2026-10-23, tasks 107, 108, 109, 110', 'Split `plan 20: spreadsheet-style tables and dashboard` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-24T00:13:47Z', '2026-10-24T00:14:28Z', 58, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (107, 20, 'sheet table style and DataTable spreadsheet frame', 'work', 'done', NULL, '2026-10-23, frontend/src/index.css, components/DataTable.tsx, pages/Expenses.tsx, pages/Time.tsx, pages/Bookings.tsx, README.md (not checked visually in the running app)', 'Part of `plan 20: spreadsheet-style tables and dashboard`; follow its ground rules (no functional change: same columns, texts, links, formats; offline; no new npm deps; light only, `decision 28: visual design: one light ledger theme, no dark mode`). Uses part 1''s `num`/`neg` classes, `--ledger-rule` variables and README "Styling conventions" section.

Files: `frontend/src/index.css`, `frontend/src/components/DataTable.tsx`, `pages/Expenses.tsx`, `pages/Time.tsx`, `pages/Bookings.tsx` (detail lines), `README.md`.

- `sheet` component class in `index.css`, on top of daisyUI `table`:
  - thin grid lines on every cell in the ledger rule colour
  - header cells like spreadsheet column headers (`base-200`, small, semibold)
  - zebra rows, compact padding, row hover highlight
  - footer (totals) rows with a heavier top rule
- `DataTable`:
  - uses `table sheet`, wrapped in `overflow-x-auto`
  - numeric columns get `num` instead of `text-right`
  - decorative letter row (A, B, C … one per column) above the real header, and a row-number gutter (1, 2, 3 …) on the left; both `aria-hidden`, muted, never replacing a real header or value
  - the empty-state row keeps its text and spans all columns (plus the gutter)
- Footer rows need a gutter cell too: export a small helper (e.g. `SheetFooterRow` or a gutter cell) and use it in the Expenses and Time footers; their total cells get `num`.
- Optional `negative?: (row) => boolean` on `Column` that adds `neg`; use it for the booking detail lines (`Amount`, `COP` below zero). Only the colour changes.
- README "Styling conventions": add the `sheet` class, the gutter/letter frame, the footer helper and `negative`.

Done when every `DataTable` page (bookings, booking detail lines, expenses list/recurring/generated, blocked days, time log, rates) shows the sheet look with the same columns, texts and links, with data and empty; `npm run typecheck`, `npm run lint`, `npm test`, `npm run build` (in `frontend/`), `pytest` and `nix flake check` pass; checked in the running app (`rios-de-asia-accounting --no-browser`).', '2026-10-24T00:14:11Z', '2026-10-24T00:19:41Z', 106, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (108, 20, 'import preview and booking detail tables on the sheet style', 'work', 'done', NULL, '2026-10-23, frontend/src/pages/Import.tsx, pages/Bookings.tsx, index.css, README.md (not checked visually in the running app)', 'Part of `plan 20: spreadsheet-style tables and dashboard`; follow its ground rules (no functional change, same texts and columns; offline; no new npm deps). Builds on the `sheet` class and `DataTable` frame from `task 107: sheet table style and DataTable spreadsheet frame` (see README "Styling conventions").

Files: `frontend/src/pages/Import.tsx`, `frontend/src/pages/Bookings.tsx` (`BookingDetail`).

- Import preview: the two hand-built tables (new bookings, changed bookings) use the sheet style: via `DataTable` where that fits without changing any text, else `table sheet` plus the same `aria-hidden` letter row and row-number gutter by hand. Money/number cells `num`. The import summary stays a list.
- Booking detail key/value table: a two-column sheet, the labels as a header column (`th`, `base-200`), money values `num`.

Done when no table in `frontend/src/pages/` other than the dashboard''s uses plain `className="table"`; `npm run typecheck`, `npm run lint`, `npm test`, `npm run build` (in `frontend/`), `pytest` and `nix flake check` pass; import preview and a booking detail checked in the running app (`rios-de-asia-accounting --no-browser`).', '2026-10-24T00:14:27Z', '2026-10-24T00:20:28Z', 106, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (109, 20, 'dashboard: metric tables as sheets, formula-bar period form, headings and warning', 'work', 'done', NULL, '2026-10-23, frontend/src/pages/Dashboard.tsx, components/Notices.tsx, components/inputs.tsx (not checked visually in the running app)', 'Part of `plan 20: spreadsheet-style tables and dashboard`; follow its ground rules. Same numbers, texts, URL parameters and layout (`decision 18: dashboard layout: which periods are shown and which period the cost breakdown uses`, `decision 10: a figure that cannot be computed is shown as empty, not as zero`). Builds on the `sheet` class from `task 107: sheet table style and DataTable spreadsheet frame` and part 1''s `PageTitle`/`SectionTitle` and alert style.

File: `frontend/src/pages/Dashboard.tsx` (plus `index.css` only if a small class is needed).

- Metric table and expense breakdown table on `table sheet`:
  - period columns as column headers (label + muted date range)
  - metric labels as a frozen first column (`sticky left-0` with a background) so wide tables scroll under it; table in `overflow-x-auto`
  - values `num`; negatives `neg` instead of `text-error`, same `cell()` text with the `−` sign
- `PeriodForm` as a compact "formula bar": one bordered `base-200` strip, `input-sm` inputs, short inline labels Month/From/To, a decorative `fx`-like marker (`aria-hidden`), Apply `btn btn-primary btn-sm`, Reset `btn btn-ghost btn-sm` link to `/`; same input names and submit behaviour; error lines below the strip as `text-error`; wraps on narrow windows.
- Headings via `PageTitle`/`SectionTitle` (if not already), chart sub-headings (`h3`) in the same style one size smaller; the date range after "Expense breakdown" muted.
- The "N booking(s) need(s) an exchange rate" warning as the same alert style as the app''s notices (warning icon), still a link to `/rates` with the same text. "Nothing here yet" unchanged.

Done when the dashboard reads like one sheet with a toolbar on top and every number is where it was (compare before/after with data and with an empty database); `npm run typecheck`, `npm run lint`, `npm test`, `npm run build` (in `frontend/`), `pytest` and `nix flake check` pass; checked in the running app (`rios-de-asia-accounting --no-browser`).', '2026-10-24T00:14:27Z', '2026-10-24T00:21:14Z', 106, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (110, 20, 'charts in the ledger theme colours', 'work', 'done', NULL, '2026-10-23, frontend/src/index.css, charts/chartMath.ts, charts/LineChart.tsx, charts/BarChart.tsx (not checked visually in the running app)', 'Part of `plan 20: spreadsheet-style tables and dashboard`; follow its ground rules (same data, series, sizes, labels, `<title>` tooltips; no new npm deps). Uses the `ledger` theme colours and `--ledger-rule` variables from `task 103: ledger theme and shared number classes`.

Files: `frontend/src/charts/chartMath.ts`, `LineChart.tsx`, `BarChart.tsx` (`chartMath.test.ts` only if it asserts literal colours).

- Series colours from the theme: ledger green, ledger blue, then two more clearly distinguishable inks; no red for a series (red means negative). Keep `DASHES` so series differ without colour.
- Bars in ledger green.
- Grid lines (the hard-coded `GRID`) in the ledger rule colour, axis text (`TEXT`) in the base content colour.
- `fontFamily="sans-serif"` → the app''s system stack or `inherit`; tick labels with tabular figures.
- Colours via CSS variables through `style` or Tailwind `stroke-*`/`fill-*` classes: SVG presentation attributes don''t resolve `var()`. The theme stays the single source of colour.

Done when the charts match the theme in the running app (`rios-de-asia-accounting --no-browser`, with data) and `npm run typecheck`, `npm run lint`, `npm test`, `npm run build` (in `frontend/`), `pytest` and `nix flake check` pass.', '2026-10-24T00:14:27Z', '2026-10-24T00:21:52Z', 106, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (111, 21, 'create tasks for plan 21: forms and actions', 'split', 'done', 1000, '2026-10-23, tasks 112, 113, 114, 115, 116', 'Split `plan 21: forms and actions` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-24T00:14:53Z', '2026-10-24T00:15:54Z', 59, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (112, 21, 'form building blocks: FormSlip, Field, FormActions, FormError, ConfirmDelete', 'work', 'done', NULL, '2026-10-23, FormSlip.tsx FormActions.tsx FormError.tsx Field.tsx inputs.tsx ConfirmDelete.tsx index.css README.md', 'Part of `plan 21: forms and actions`; follow its ground rules (no functional change, same texts, offline, no new npm deps, inline SVG only, light only: `decision 28: visual design: one light ledger theme, no dark mode`; inputs stay plain text: `decision 15: data entry forms: how money and hours are typed`). Uses part 1''s theme, `num`, `--ledger-rule` variables and README "Styling conventions" (`plan 19: styling foundation`).

Files: `frontend/src/components/` (new `FormSlip.tsx`, `FormActions.tsx`, `FormError.tsx` or one `forms.tsx`; `Field.tsx`, `inputs.tsx`, `ConfirmDelete.tsx`), `frontend/src/index.css` if a class is needed, `README.md`.

- `FormSlip`: the "journal entry slip" around a form
  - paper `base-100` card, thin border, `max-w-lg`
  - header strip (`base-200`, ruled bottom line) with a small-caps label passed in (e.g. "Entry") and an optional decorative entry-number/date slot, `aria-hidden`
  - red vertical margin rule on the left like ledger paper (CSS, error colour at low opacity or a `--ledger-rule` variable)
  - children are the form
- `Field`: daisyUI 5 `fieldset` + `label` styling; controls full width inside the slip; hint as a muted line; error as `text-error` with a small inline-SVG warning mark, still right under its field.
- `inputs.tsx`: `MoneyInput`, `HoursInput`, `RateInput` get `num` (tabular, right-aligned). Nothing else about the inputs changes.
- Read-only values (Airbnb bookings, `decision 17: bookings from the Airbnb import: dates, listing and guest name are read-only in the edit form`): if they are text today, a small "inked" class for them; if they are inputs today, leave them.
- `FormActions`: row `flex flex-wrap gap-2 mt-4` with a ruled top border like the slip''s foot; primary first, then secondary.
- `FormError`: page-level `alert alert-error` with an icon (reuse the error icon from the app''s notices if `Notices.tsx` has one); same props as the Expenses `FormError` (`message?`, renders nothing when empty).
- Button roles: submit `btn btn-primary`; Cancel/Back/Reset `btn btn-ghost` (or `btn-soft`); Delete trigger `btn btn-error btn-outline btn-sm` under a thin rule ("void entry" area).
- `ConfirmDelete`: dialog as a small slip (`modal-box` with the same header strip, question, muted detail), Delete `btn-error`, Cancel `btn-ghost`; same texts, same `pending`/`disabled` handling, still `showModal()`.
- README "Styling conventions": add `FormSlip`, `FormActions`, `FormError`, the button roles (and say `Toolbar` comes with the filter-bar task).
- Don''t move pages onto the new components yet (except what `Field`/`inputs`/`ConfirmDelete` change by themselves); the next tasks do that.

Done when the components exist, `ConfirmDelete` is restyled, the README is updated; `npm run typecheck`, `npm run lint`, `npm test`, `npm run build` (in `frontend/`), `pytest` and `nix flake check` pass; forms still work in the running app (`rios-de-asia-accounting --no-browser`).', '2026-10-24T00:15:51Z', '2026-10-24T00:22:52Z', 111, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (113, 21, 'booking and expense forms on the entry slip', 'work', 'done', NULL, '2026-10-23, pages/Bookings.tsx pages/Expenses.tsx', 'Part of `plan 21: forms and actions`; follow its ground rules (no functional change: same fields, labels, hints, order, conditions, read-only rules, errors, button labels, links, pending handling). Uses the components from `task 112: form building blocks: FormSlip, Field, FormActions, FormError, ConfirmDelete`.

Files: `frontend/src/pages/Bookings.tsx`, `frontend/src/pages/Expenses.tsx`.

- Booking form, expense form, recurring expense form: wrap in `FormSlip` (label e.g. "Booking", "Expense", "Recurring expense"), actions via `FormActions` (Save `btn-primary`, Cancel `btn-ghost`), Delete via the restyled `ConfirmDelete` in the "void entry" area.
- Page-level errors via `FormError`; remove the local `FormError` from Expenses and replace the repeated `<div role="alert" className="alert alert-error mb-4">` in these two pages.
- Two-column grid for paired fields (Check-in/Check-out, Date/Amount) only where they are already side by side; stacks on narrow windows.
- Airbnb bookings keep their read-only fields (`decision 17: bookings from the Airbnb import: dates, listing and guest name are read-only in the edit form`), shown in the "inked" style where they are text.
- Expense form: category-dependent Booking / Useful life fields show exactly when they do today.
- Booking detail: Edit `btn-primary`, Back `btn-ghost`, in a `FormActions`-style row.
- Leave the list filter bars alone (a later task turns them into a toolbar).

Done when these forms show the slip with the same fields, conditions and errors (checked empty, filled and with server errors in the running app, `rios-de-asia-accounting --no-browser`), and `npm run typecheck`, `npm run lint`, `npm test`, `npm run build`, `pytest`, `nix flake check` pass.', '2026-10-24T00:15:51Z', '2026-10-24T00:23:41Z', 111, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (114, 21, 'blocked days, time, rate and settings forms on the entry slip', 'work', 'done', NULL, '2026-10-23, pages/Blocked.tsx Time.tsx Rates.tsx Settings.tsx', 'Part of `plan 21: forms and actions`; follow its ground rules (no functional change). Same treatment as `task 113: booking and expense forms on the entry slip`, with the components from `task 112: form building blocks: FormSlip, Field, FormActions, FormError, ConfirmDelete`.

Files: `frontend/src/pages/Blocked.tsx`, `Time.tsx`, `Rates.tsx`, `Settings.tsx`.

- Each entry form in `FormSlip` (label e.g. "Blocked days", "Time entry", "Exchange rate", "Settings"), actions via `FormActions`, Delete via `ConfirmDelete` in the "void entry" area, page-level errors via `FormError` instead of the repeated `alert alert-error` divs.
- Settings: listing checkboxes as daisyUI `checkbox` rows inside the slip''s fieldset; same names, labels and order.
- Leave the list filter bars alone (a later task turns them into a toolbar).

Done when these forms show the slip with the same fields and errors (checked empty, filled and with server errors in `rios-de-asia-accounting --no-browser`), and `npm run typecheck`, `npm run lint`, `npm test`, `npm run build`, `pytest`, `nix flake check` pass.', '2026-10-24T00:15:51Z', '2026-10-24T00:24:21Z', 111, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (115, 21, 'import forms on the entry slip', 'work', 'done', NULL, '2026-10-23, pages/Import.tsx', 'Part of `plan 21: forms and actions`; follow its ground rules (no functional change). Uses the components from `task 112: form building blocks: FormSlip, Field, FormActions, FormError, ConfirmDelete`.

File: `frontend/src/pages/Import.tsx`.

- Airbnb CSV upload and TRM upload each as a `FormSlip`: styled daisyUI `file-input`, Currency as a short input, Upload / "Load rates" `btn-primary` in `FormActions`.
- Preview form: listing checkboxes and "Another listing name" inside a slip, Import (`btn-primary`) / Cancel (`btn-ghost`) via `FormActions`. Don''t touch the preview tables (`plan 20: spreadsheet-style tables and dashboard` restyles them).
- Replace the local `Alert` with `FormError` (same texts).
- The success message stays `alert-success` (a later part adds a stamp).

Done when the import screens look like slips with the same fields, texts and flow (upload a CSV, preview, import, cancel; a wrong file for the error), and `npm run typecheck`, `npm run lint`, `npm test`, `npm run build`, `pytest`, `nix flake check` pass.', '2026-10-24T00:15:51Z', '2026-10-24T00:25:04Z', 111, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (116, 21, 'list filter bars as a compact Toolbar strip', 'work', 'done', NULL, '2026-10-23, frontend/src/components/Toolbar.tsx, inputs.tsx, pages/{Dashboard,Bookings,Expenses,Blocked,Time,Rates}.tsx, README.md; not checked visually in the running app', 'Part of `plan 21: forms and actions`; follow its ground rules (no functional change: same filter fields, names, URL parameters, labels, links). Builds on `task 112: form building blocks: FormSlip, Field, FormActions, FormError, ConfirmDelete` and on the dashboard''s "formula bar" from `task 109: dashboard: metric tables as sheets, formula-bar period form, headings and warning`.

Files: new `frontend/src/components/Toolbar.tsx` (or reuse what task 109 made), `pages/Bookings.tsx`, `Expenses.tsx`, `Blocked.tsx`, `Time.tsx`, `Rates.tsx`, `README.md`.

- A shared `Toolbar` strip with the formula-bar look: `base-200`, bordered, `input-sm`/`select-sm` controls with short labels, Filter `btn-sm btn-secondary` (or `btn-soft`), the "New …" link `btn-sm btn-primary` pushed to the right; wraps on narrow windows.
- If task 109 left the formula bar as inline classes in `Dashboard.tsx`, extract them into `Toolbar` and use it there too (same look, same form behaviour).
- Replace the `flex flex-wrap items-end gap-2` filter bars on the five list pages; filter errors stay below the strip.
- README "Styling conventions": add `Toolbar`.

Done when all five list pages and the dashboard use the same strip with the same filters and links, and `npm run typecheck`, `npm run lint`, `npm test`, `npm run build`, `pytest`, `nix flake check` pass; checked in the running app.', '2026-10-24T00:15:51Z', '2026-10-24T00:26:08Z', 111, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (117, 22, 'create tasks for plan 22: playful bookkeeping touches and favicon', 'split', 'done', 1000, '2026-10-24, tasks 118-122', 'Split `plan 22: playful bookkeeping touches and favicon` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-24T00:15:56Z', '2026-10-24T00:16:50Z', 60, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (118, 22, 'favicon and navbar logo', 'work', 'done', NULL, '2026-10-23, frontend/src/assets/{favicon.svg,favicon-32.png,apple-touch-icon.png}, frontend/index.html, frontend/src/components/icons.tsx, frontend/src/App.tsx, README.md', 'Part of `plan 22: playful bookkeeping touches and favicon`; follow its ground rules (no functional change, offline, inline SVG, `currentColor`, theme colours, one light theme per `decision 28: visual design: one light ledger theme, no dark mode`).

Files: `frontend/src/assets/favicon.svg`, `frontend/src/assets/favicon-32.png`, `frontend/src/assets/apple-touch-icon.png`, `frontend/index.html`, `frontend/src/components/icons.tsx` (create it if part 1 hasn''t), `frontend/src/App.tsx`, `README.md`.

- Favicon: a ledger motif (e.g. an open ledger book with green rules and a red margin line, or an abacus), legible at 16×16, as `frontend/src/assets/favicon.svg`.
- PNGs rendered once from the SVG with a tool at hand (e.g. `nix shell nixpkgs#librsvg -c rsvg-convert -w 32 -h 32 …`) and committed: `favicon-32.png` (32×32) and `apple-touch-icon.png` (180×180).
- **Path caveat:** Flask serves only `/assets/*` as files and answers every other GET with `index.html`, so don''t use `frontend/public/` (that lands at `/favicon.svg` and gets HTML back). Link the files from `index.html` as `/src/assets/…`; Vite hashes them into `/assets/`. No server change.
  - `<link rel="icon" type="image/svg+xml" href="/src/assets/favicon.svg">`, a PNG fallback `<link rel="icon" type="image/png" sizes="32x32" …>`, and `<link rel="apple-touch-icon" …>`. Title unchanged.
- `Logo` component in `icons.tsx` (same motif, inline SVG, `className` prop, `role="img"` + `aria-label`, or `aria-hidden` if the link text already names it) placed before the app-name link text in the navbar; the text "rios-de-asia-accounting" stays.
- README "Styling conventions": mention the favicon files, the `src/assets` path reason, and `Logo`.

Done when the browser tab shows the icon in the built app served by Flask (`rios-de-asia-accounting --no-browser`; the page source links `/assets/…` and those URLs return the images, not HTML), the navbar shows the logo next to the unchanged name, and `npm run typecheck`, `npm run lint`, `npm test`, `npm run build` (in `frontend/`), `pytest` and `nix flake check` pass.', '2026-10-24T00:16:43Z', '2026-10-24T00:30:32Z', 117, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (119, 22, 'section icons on sheet tabs and page titles', 'work', 'done', NULL, '2026-10-23, frontend/src/components/icons.tsx, nav.ts, App.tsx, Titles.tsx, pages/{Bookings,Expenses,Time,Rates,Blocked,Import,Settings}.tsx, README.md', 'Part of `plan 22: playful bookkeeping touches and favicon`; follow its ground rules (decorative icons `aria-hidden`, inline SVG, `currentColor`, no new dependencies, no functional change).

Files: `frontend/src/components/icons.tsx`, `frontend/src/nav.ts`, `frontend/src/App.tsx`, the section pages in `frontend/src/pages/`, `README.md`.

- One small stroke icon per nav entry in `icons.tsx` (`viewBox="0 0 24 24"`, `className` prop): Bookings (calendar/bed), Expenses (receipt), Recurring (circular arrows), Blocked days (calendar with a cross), Time (clock), Rates (coins/exchange), Import (tray with arrow), Settings (gear); Dashboard (bar chart/ledger) only if the shell shows a home tab.
- `nav.ts` entries get an `icon` field; the sheet tabs render icon + the same label, in the same order and paths.
- `PageTitle`''s icon slot (from `task 105: PageTitle/SectionTitle components and README styling conventions`) filled on each section''s pages: list, form and detail pages use their section''s icon.
- README "Styling conventions": list the section icons and how to use them with `nav.ts` and `PageTitle`.

Done when every tab and page title carries its icon, the nav reads the same (labels, order, links), it still fits/wraps at narrow width, and `npm run typecheck`, `npm run lint`, `npm test`, `npm run build`, `pytest`, `nix flake check` pass; checked in the running app.', '2026-10-24T00:16:44Z', '2026-10-24T00:31:28Z', 117, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (120, 22, 'friendly empty states: doodles in empty tables and on the empty dashboard', 'work', 'done', NULL, '2026-10-23, frontend/src/components/icons.tsx, DataTable.tsx, pages/Dashboard.tsx, README.md', 'Part of `plan 22: playful bookkeeping touches and favicon`; follow its ground rules (existing texts unchanged, decorations `aria-hidden`, inline SVG with `currentColor` and theme colours, no new dependencies).

Files: `frontend/src/components/icons.tsx` (doodles), `frontend/src/components/DataTable.tsx`, `frontend/src/pages/Dashboard.tsx`, `README.md`.

- `DataTable`''s empty row: above the unchanged `empty` text ("No bookings.", "No expenses.", "None yet." …), a small doodle (blank ledger page, pencil) and a muted decorative caption such as "The ledger is blank", both `aria-hidden`. Still one row spanning all columns (plus the row-number gutter from `task 107: sheet table style and DataTable spreadsheet frame`).
- Dashboard "Nothing here yet: …" (text and links unchanged) on a light card (`base-200`/paper look) with a larger doodle (empty ledger or sleeping calculator).
- Doodles as components in `icons.tsx`; README "Styling conventions" mentions them.

Done when every empty list (bookings, expenses list/recurring/generated, blocked days, time, rates, booking detail lines if they can be empty) and the empty dashboard show the doodle with the same text, checked in the running app with an empty database (e.g. a fresh data dir via `XDG_DATA_HOME`), and `npm run typecheck`, `npm run lint`, `npm test`, `npm run build`, `pytest`, `nix flake check` pass.', '2026-10-24T00:16:44Z', '2026-10-24T00:32:08Z', 117, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (121, 22, 'double underline under totals and POSTED stamp on the import summary', 'work', 'done', NULL, '2026-10-23, frontend/src/index.css, pages/{Expenses,Time,Import}.tsx, README.md', 'Part of `plan 22: playful bookkeeping touches and favicon`; follow its ground rules (same numbers, texts, counts and links; decorations `aria-hidden`; theme colours; CSS only, no new JavaScript behaviour).

Files: `frontend/src/index.css`, `frontend/src/pages/Expenses.tsx`, `frontend/src/pages/Time.tsx`, `frontend/src/pages/Import.tsx`, `README.md`.

- Accountant''s double underline: a `total` class in `index.css` (`border-bottom: 3px double` in the ink colour, on the figure cell), used on the total figure cells of the Expenses and Time footer rows (`<th>Total</th>` rows). Dashboard: only where a row is a sum; none is today, so don''t invent one.
- Import summary (`SummaryStep` in `pages/Import.tsx`):
  - a rubber-stamp badge beside "Import done": outlined, ledger green, uppercase, rotated a few degrees, e.g. "POSTED ✓", `aria-hidden`. Always shown; it says the import was posted, never that anything balanced.
  - the counts as a tidy ledger list (label left, count right with `num`, thin rules); problems/warnings unchanged.
  - optionally the same small stamp on the TRM "rates loaded" `alert-success`.
- README "Styling conventions": the `total` class and the stamp class.

Done when the import summary shows the stamp with all its counts and links unchanged (import a sample Airbnb CSV and a TRM file in the running app), the Expenses and Time totals are double underlined, and `npm run typecheck`, `npm run lint`, `npm test`, `npm run build`, `pytest`, `nix flake check` pass.', '2026-10-24T00:16:44Z', '2026-10-24T00:32:50Z', 117, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (122, 22, 'stopped page: logo and books-closed doodle', 'work', 'done', NULL, '2026-10-23, frontend/src/pages/Stopped.tsx, frontend/src/components/icons.tsx', 'Part of `plan 22: playful bookkeeping touches and favicon`; follow its ground rules (same h1 text, decorations `aria-hidden`, inline SVG, no new dependencies).

Files: `frontend/src/pages/Stopped.tsx`, `frontend/src/components/icons.tsx`.

- On part 1''s paper card: the `Logo` from `task 118: favicon and navbar logo`, the unchanged h1 "rios-de-asia-accounting has stopped, you can close this tab", a "books closed" doodle (closed ledger with a ribbon bookmark) in `icons.tsx`, and a muted decorative line such as "The books are closed for today." (`aria-hidden`).

Done when Quit leads to the decorated page with the same sentence (check in the running app; the server stops, so the page must render without further requests), and `npm run typecheck`, `npm run lint`, `npm test`, `npm run build`, `pytest`, `nix flake check` pass.', '2026-10-24T00:16:44Z', '2026-10-24T00:33:24Z', 117, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (123, 11, 'post-milestone cleanup of milestone 2: visual design update', 'cleanup', 'done', NULL, '2026-10-23, architecture-spec.md', 'After `milestone 2: visual design update`, for the whole project:
* rewrite top-level .md files to reflect the current state of the project
* remove files that have become redundant
* suggest entirely new files, if necessary
* delete code that isn''t actually used
* check pending decisions if they are still relevant and really pending
* check other milestones if their contents are up-to-date; raise a decision for each change they need', '2026-10-24T00:33:25Z', '2026-10-24T00:33:48Z', NULL, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (124, 23, 'write the masterplan of milestone 4: first round of improvements', 'masterplan', 'done', NULL, '2026-10-23, plan 23 body and intro; decisions 29-31 raised', 'Write `plan 23: masterplan`, the masterplan of `milestone 4: first round of improvements`: expand on everything that needs to be done to achieve it,
divided into parts, with an intro in plain English (`pm plan edit 23 --intro "…" --body -`). State in the masterplan that its own tasks are not implementation work: each of them writes the
plan for one part.', '2026-10-24T03:15:59Z', '2026-10-24T03:18:30Z', NULL, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (125, 23, 'create tasks for plan 23: masterplan', 'split', 'done', 1000, '2026-10-23, tasks 126-130', 'Split `plan 23: masterplan` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-24T03:18:26Z', '2026-10-24T03:19:07Z', 124, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (126, 23, 'write the plan for part 1: remove blocked days', 'plan', 'done', 1000, '2026-10-23, plan 24: remove blocked days, decision 32', 'Write the plan for part 1 of `plan 23: masterplan` (read that part): `pm plan add 4 "remove blocked days" --priority 900 --intro "…"`.

- Covers: migration dropping `blocked_days`, the model/allocation/repo/API/frontend/test/spec/README removals, and a superseding decision for `decision 21: the per-day view starts on the first day any input is spread over` (start date no longer counts blocked days).
- Done when the plan exists with the masterplan''s priority (900).', '2026-10-24T03:19:04Z', '2026-10-24T03:19:58Z', 125, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (127, 23, 'write the plan for part 2: USD inside, exchange rates fetched automatically', 'plan', 'done', 990, '2026-10-24, plan 25 (decisions 34-41); no files changed', 'Write the plan for part 2 of `plan 23: masterplan` (read that part in full): `pm plan add 4 "USD inside, exchange rates fetched automatically" --priority 850 --intro "…"`.

- Needs web access: verify a free, keyless source of historical daily COP and EUR rates against USD (candidates: the TRM API on datos.gov.co, Frankfurter/ECB, a multi-currency API) — check the real endpoints and response formats, write them into the plan.
- Record (`pm decision record`) each choice the part lists: storage in USD cents with original amount/currency/rate/rate date; the rate source and caching in `exchange_rates`; behaviour when fetching fails; converting existing COP data; currency choice at expense entry (superseding `decision 15: data entry forms: how money and hours are typed` for money); which of Rates page / manual rate API / TRM CSV import / "lacking a rate" notices go; settings amounts.
- Raise a decision for the owner only where the choice really is theirs.
- The plan''s first implementation task must require the last implementation task of part 1''s plan (`plan … remove blocked days`), so the USD migration runs after blocked days are gone.
- Done when the plan exists with priority 850 and the decisions above are recorded.', '2026-10-24T03:19:04Z', '2026-10-24T03:47:40Z', 125, 1, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (128, 23, 'write the plan for part 3: display currency', 'plan', 'done', 980, '2026-10-24, plan 28: display currency; decisions 46, 47, 48', 'Write the plan for part 3 of `plan 23: masterplan` (read that part): `pm plan add 4 "display currency" --priority 500 --intro "…"`.

- Builds on part 2''s plan (`USD inside, exchange rates fetched automatically`): reuse its rate source and fetch code; its implementation tasks require part 2''s implementation tasks they build on.
- Record (`pm decision record`): conversion on server or client; number formats per currency; how the chosen currency and its rate/date are kept in settings and shown.
- Done when the plan exists with priority 500.', '2026-10-24T03:19:04Z', '2026-10-24T13:59:56Z', 125, 1, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (129, 23, 'write the plan for part 4: add expenses inline in the sheet', 'plan', 'done', 970, '2026-10-23, plan 26: add expenses inline in the sheet (priority 400), decision 43 recorded; no files changed', 'Write the plan for part 4 of `plan 23: masterplan` (read that part): `pm plan add 4 "add expenses inline in the sheet" --priority 400 --intro "…"`.

- "+" button opening an entry row inside the `DataTable` sheet on Expenses and Recurring; date pre-filled with today, start month with this month; field errors in the row; `/expenses/new` and `/recurring/new` go; README styling conventions updated.
- Uses part 2''s currency choice next to the amount: its implementation tasks require the part 2 task that adds currency entry.
- Decide (and record) whether editing existing rows also goes inline, only if it costs nothing extra.
- Done when the plan exists with priority 400.', '2026-10-24T03:19:05Z', '2026-10-24T03:49:27Z', 125, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (130, 23, 'write the plan for part 5: hand-entered bookings, the Time page and the Quit button', 'plan', 'done', 960, '2026-10-24, plan 27; decisions 44, 45; consequences of decisions 29, 30, 31', 'Write the plan for part 5 of `plan 23: masterplan` (read that part): `pm plan add 4 "hand-entered bookings, the Time page and the Quit button" --priority 400 --intro "…"`.

- Follow the owner''s answers to `decision 29: Hand-entered bookings: remove the ''New booking'' button so that all income comes from the Airbnb CSV?`, `decision 30: Time page: remove the log of your own hosting hours, or keep it and explain it?` and `decision 31: Quit button: remove it, or keep it with a clearer name?`; write their consequences (`pm decision consequences`).
- Removals include API, routes, nav, tests, specs and README; if the Time page goes, also the time log table (migration), own-time metrics, the hourly-value setting, and a superseding decision for `decision 21: the per-day view starts on the first day any input is spread over`.
- If part 2''s plan already exists, have tasks that touch money code (metrics, settings) require the matching part 2 tasks or run before them, to avoid conflicting edits.
- Done when the plan exists with priority 400.', '2026-10-24T03:19:05Z', '2026-10-24T03:51:24Z', 125, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (131, 24, 'create tasks for plan 24: remove blocked days', 'split', 'done', 1000, '2026-10-23, tasks 132, 133', 'Split `plan 24: remove blocked days` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-24T03:19:55Z', '2026-10-24T03:20:28Z', 126, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (132, 24, 'remove blocked days from the backend', 'work', 'done', NULL, '2026-10-24, migration 0002, model.py, allocation.py, metrics.py, storage/repo.py, web/api, tests', 'Blocked days go from database, model, figures, storage, API and tests. Every day now counts as available.
Follows `decision 32: the per-day view starts on the first day any input is spread over, without blocked days`.

- New migration `src/rios_de_asia_accounting/storage/migrations/0002_drop_blocked_days.sql`: `DROP TABLE blocked_days;`. Leave `0001_init.sql` as it is. The database is already backed up before migrating, so nothing else is needed.
- `model.py`: drop `BlockedDay`, `Inputs.blocked_days` and `Day.available`.
- `allocation.py`: take blocked days out of the default start and drop the `available` steps; update the docstrings.
- `metrics.py`: available nights of a period = number of selected days (period metrics, break-even, rolling window). The dashboard row "Available nights" stays.
- `storage/repo.py`: drop the blocked-days section (`_blocked`, `set/get/list/delete_blocked_day`) and `blocked_days=` in the inputs loader.
- Delete `web/api/blocked.py` and its registration in `web/api/__init__.py`.
- Tests:
  - delete `tests/test_api_blocked.py`
  - remove blocked-day cases from `test_allocation.py`, `test_repo_other.py`, `test_schema.py`
  - `test_metrics.py`: stop building days with `available=`; drop or rewrite `test_rolling_window_without_available_nights`
  - `test_e2e.py`: drop the 2026-10-15 blocked day and recompute the expected figures that change (e.g. `available_nights`)
  - add a schema check that `blocked_days` is gone after migrating
- Done when `rg -i blocked src tests` finds only the old migration (or the unrelated "blocked by expenses" wording) and pytest + ruff pass.', '2026-10-24T03:20:21Z', '2026-10-24T03:21:09Z', 131, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (133, 24, 'remove blocked days from the frontend, specs and README', 'work', 'done', NULL, '2026-10-24, frontend Blocked page/routes/nav/icon, README, both specs', 'After the backend no longer knows blocked days, remove the screen and every mention in the docs.

- Frontend: delete `frontend/src/pages/Blocked.tsx`; remove its routes in `App.tsx`, the nav entry in `nav.ts` and `BlockedIcon` in `components/icons.tsx`.
- Rebuild the bundle in `src/rios_de_asia_accounting/web/dist` the way the project does it (see README), and stage it.
- `airbnb-bookkeeping-spec.md`: remove the blocked-days input, the `blocked_days` table, "available = false" and the CRUD list entry; occupancy/RevPAR read "÷ nights in the period".
- `architecture-spec.md`: remove the `/blocked-days` route, the `model.py`/`allocation.py` mentions and the `/api/blocked-days` endpoints; reword the booking delete line to "refused while it has expenses" instead of "blocked by expenses".
- `README.md`: drop `BlockedIcon` from the section icons list and any other mention.
- Done when `rg -i blocked` (outside `tasks.sql`, caches, `node_modules` and `0001_init.sql`) finds nothing and frontend typecheck, lint, tests and build pass.', '2026-10-24T03:20:28Z', '2026-10-24T03:21:34Z', 131, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (134, 25, 'create tasks for plan 25: USD inside, exchange rates fetched automatically', 'split', 'done', 1000, '2026-10-23, tasks 135, 136, 137, 138; no new decisions needed (decisions 34-41 cover the plan)', 'Split `plan 25: USD inside, exchange rates fetched automatically` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-24T03:47:36Z', '2026-10-24T03:48:25Z', 127, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (135, 25, 'fetch exchange rates from datos.gov.co and Frankfurter', 'work', 'done', NULL, '2026-10-23, src/rios_de_asia_accounting/rates.py, tests/test_rates.py, tests/fixtures/rates_cop.json, tests/fixtures/rates_eur.json. Ad-hoc real run: 2021-12-31 COP 3981.16 (rate 3981160000, coverage 2022-01-03), EUR 0.88292 (882920); 2026-10-23 COP 3185.01 (3185010000, coverage 2026-10-23), EUR 0.89342 (893420, coverage 2026-10-22). COP rows are dated by vigenciadesde; fetch_cop coverage is None when nothing was received.', 'First step of `plan 25: USD inside, exchange rates fetched automatically`: a small module that fetches daily rates from the two public sources, with nothing wired to the database or the app yet.

Rules: `decision 35: exchange rates: TRM from datos.gov.co for COP, ECB via Frankfurter for EUR, cached per day` (endpoints, query parameters and response formats are in it), `decision 34: money is stored in US cents, and every converted entry keeps what was typed` (rate scale).

- New module `src/rios_de_asia_accounting/rates.py`:
  - `fetch_cop(start, end)`: datos.gov.co SODA dataset `32sa-8pi3`, `$where=vigenciahasta >= start AND vigenciadesde <= end`, `$order=vigenciadesde`, `$limit=50000`.
  - `fetch_eur(start, end)`: Frankfurter v2 `/v2/rates?base=USD&quotes=EUR&from=…&to=…&providers=ECB`.
  - Each returns the rates received as (date, currency units per USD × 1 000 000, integer, no float drift: parse the decimal string) plus the coverage date reached (COP: latest `vigenciahasta`; EUR: min(end, yesterday)).
  - Stdlib `urllib`, 10 s timeout, a User-Agent naming the app; one `RateUnavailable` exception for network, HTTP and format errors.
- Parsing is pure functions, separate from HTTP, tested with small recorded JSON fixtures in `tests/fixtures/` taken from the real endpoints. No test touches the network. Keep tests few.
- No database, migration or caller changes (that is the next task).

Done when: the parser tests and ruff pass, and one ad-hoc run against the real endpoints (script not committed) returns sensible rates for 2021-12-31 and today; put the values in the task note.', '2026-10-24T03:48:23Z', '2026-10-24T03:52:12Z', 134, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (136, 25, 'the backend runs on USD cents with automatic rate conversion', 'work', 'done', NULL, '2026-10-23, storage/migrations/0004_usd.sql, conversion.py (new), money.py, model.py, rates.py, allocation.py, metrics.py, recurring.py, storage/repo.py, importer/airbnb_csv.py, cli.py, web/forms.py, web/api/{common,expenses,bookings,settings,dashboard,importing,rates}.py; removed importer/trm_csv.py, tests/test_trm.py, tests/test_api_rates.py, tests/fixtures/trm_sample.csv; tests updated (conftest fixes rates at 4000 COP / 0.8 EUR per USD, e2e recomputed by hand). pytest 298 passed, ruff clean.

Owner''s data: $XDG_DATA_HOME/rios-de-asia-accounting/books.db exists but is empty (schema v1, no rows); a copy migrated cleanly (v1 -> v4, 0 waiting). To exercise decision 38 for real, a v3 copy filled with peso data (4 expenses, 3 bookings incl. a 2021-12-31 and a future check-in, a COP template, rent 3.000.000) was migrated and converted against the live endpoints: 8 waiting entries -> 0 with one COP range fetch (1146 rates, 2021-12-21..2026-10-23, coverage 2026-10-23); 398.116 COP on 2021-12-31 = 100,00 USD at 3981.16; rent 3.000.000 COP = 941,91 USD at 3185.01; the future check-in is provisional at the 2026-10-23 rate.

The done grep still finds, by necessity: the immutable migrations 0001/0003, ALTER ... DROP COLUMN amount_cop in 0004 and its migration test, and fetch_cop/parse_cop from `task 135: fetch exchange rates from datos.gov.co and Frankfurter`.

API for `task 137: the screens run on USD with a currency choice and the waiting notice`:
- money inputs: expenses, recurring and hand-entered bookings take `amount` + `currency` (USD/COP/EUR; bookings no longer `net_payout`); settings take `long_term_rent` + `long_term_rent_currency`.
- `/api/{expenses,recurring,bookings,settings}/options` add `currencies` and `default_currency`.
- expense JSON: `amount` (US cents or null), `original_minor`, `currency`, `rate` (units per USD x 1e6), `rate_date`, `waiting`; recurring: `amount_minor`, `currency`; booking: `waiting` instead of `needs_rate`, detail `manual_amount` (minor) + `manual_currency`, lines `amount_usd`, `rate`, `rate_date`; settings: `long_term_rent_usd`, `long_term_rent_entered` {original_minor, currency, date, rate, rate_date}.
- dashboard `waiting` replaces `needing_rate`; import summary `waiting` (lines); `GET /api/rates/waiting` -> {waiting}; `POST /api/rates/fetch` -> data {waiting} + notice. Saves that leave an entry waiting answer with a warning notice.', 'Second step of `plan 25: USD inside, exchange rates fetched automatically`: the database, domain code and JSON API switch from whole pesos to US cents, using the fetcher from the previous task, and typed rates / the TRM CSV import go. The frontend follows in the next task (it may be visibly broken in between; the backend checks must pass).

Rules (binding): `decision 34: money is stored in US cents, and every converted entry keeps what was typed`, `decision 35: exchange rates: TRM from datos.gov.co for COP, ECB via Frankfurter for EUR, cached per day`, `decision 36: reference date of a conversion: check-in for Airbnb income, the entry''s own date for expenses`, `decision 37: when no exchange rate can be fetched, entries are saved and wait for their rate`, `decision 38: existing peso books are converted by the app itself after the migration`, `decision 39: money entry: an amount with a currency choice (USD, COP, EUR)`, `decision 40: the Rates page, typed rates and the TRM file import go; no offline fallback`, `decision 41: settings amounts are stored in USD and typed in any currency at the rate of the day they are saved`.

- **Migration** `storage/migrations/0004_usd.sql` (decisions 34, 38): expenses `amount` = USD cents (NULL while waiting) + `original_minor`, `currency`, `rate`, `rate_date`; recurring templates `amount_minor` + `currency`; booking lines drop `amount_cop`, add `amount_usd`, `service_fee_usd`, `gross_usd`, `rate_date` (rate reset to NULL); `exchange_rates` emptied and rebased (currency units per USD × 1 000 000) plus a coverage table; `booking_totals` view sums the USD columns and exposes `waiting` instead of `needs_rate`; settings `long_term_rent_cop_per_month` → `long_term_rent_usd` / `long_term_rent_entered`. Old values move into the original columns as COP (whole pesos × 100). Table rebuilds where `ALTER` can''t do it.
- **money.py**: `to_usd(original_minor, rate)` (round half away from zero) replaces `to_cop`/`COP_RATE`. **model.py**: the new fields; `Day` and metrics docstrings say USD cents.
- **Rate cache and conversion**: `rate_on(conn, currency, day)` (cache, coverage, fetch on miss, provisional after coverage) and `convert_waiting(conn, today)` (all waiting or provisional expenses, lines and settings; one range fetch per currency). Called on app start after migrating and generating recurring expenses, before the dashboard is built, after an Airbnb import, after saving an entry, and by new `POST /api/rates/fetch`. Rate errors are logged on stderr, never crash a request.
- **Reference dates** (decision 36): all booking lines use the booking''s check-in (import and Manual line); changing check-in, or an expense''s date/amount/currency, re-converts.
- **Recurring generation** copies the template''s amount and currency and converts at the 1st of the month.
- **Allocation and metrics** skip waiting entries (amount NULL); `long_term_rent_usd` replaces the COP setting in `metrics.py`.
- **API**: money inputs take `amount` + `currency`, parsed in `web/forms.py` per decision 39; outputs are USD cents plus the original fields; the default currency (last saved expense''s, else USD) is exposed for the forms; a warning notice when a save leaves an entry waiting; a `waiting` count where `needing_rate` was; import summary says how many lines wait. Settings API per decision 41.
- **Removals** (decision 40): `web/api/rates.py` CRUD, `/api/import/rates`, CLI `import-rates`, `importer/trm_csv.py`, `tests/fixtures/trm_sample.csv`, `tests/test_trm.py`, `tests/test_api_rates.py`, repo `set/upsert/delete_exchange_rate`, `recompute_lines`.
- **Tests**: updated to USD cents with the fetcher monkeypatched; one schema test for the migrated columns; `test_e2e.py` recomputed with fixed fixture rates. Stay sparse.
- **Owner''s data**: if `$XDG_DATA_HOME/rios-de-asia-accounting/books.db` exists, run migration + conversion on a copy (never the original) and put the converted totals in the task note.

Done when pytest and ruff pass and `rg -i "amount_cop|_cop\b|needs_rate|trm_csv|import-rates" src tests` finds nothing.


The time log and `hourly_value_cop` are already gone (`task 143: remove the time log from the backend`, migration 0003), and the quit endpoint too (`task 144: back up the books while the app runs and remove the quit endpoint`).', '2026-10-24T03:48:23Z', '2026-10-24T04:07:39Z', 134, 0, 'opus', 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (137, 25, 'the screens run on USD with a currency choice and the waiting notice', 'work', 'done', NULL, '2026-10-23, frontend/src: format.ts, components/{inputs,AmountCell,WaitingNotice}, pages/{Expenses,Bookings,Settings,Dashboard,Import}, App, nav, icons; Rates page removed', 'Third step of `plan 25: USD inside, exchange rates fetched automatically`: the React frontend follows the backend''s switch to US cents. Rules: `decision 39: money entry: an amount with a currency choice (USD, COP, EUR)`, `decision 37: when no exchange rate can be fetched, entries are saved and wait for their rate`, `decision 40: the Rates page, typed rates and the TRM file import go; no offline fallback`, `decision 41: settings amounts are stored in USD and typed in any currency at the rate of the day they are saved`.

- `frontend/src/format.ts` mirrors the new money parse/format of `web/forms.py` (USD cents shown as 1.234,56); `formatRate` goes; `format.test.ts` updated.
- An amount + currency select input in `components/inputs.tsx`, used by the expense, recurring, hand-entered booking and settings forms; defaults to the default currency the API provides.
- Lists and booking detail show USD and, for non-USD entries, the original amount (e.g. `4.500.000 COP`) with rate and rate date on hover; dashboard and charts treat money as cents. Settings show what was typed plus the USD value with its rate date.
- One waiting notice ("N entries wait for an exchange rate and are left out of the figures") with a "Fetch rates now" button (`POST /api/rates/fetch`) on dashboard, bookings and expenses; save warnings from the API are shown; the old "needs exchange rate" texts and links to `/rates` go.
- Removals: `pages/Rates.tsx`, its routes in `App.tsx`, the nav entry and `RatesIcon` if unused, the "Exchange rates (TRM)" section of `pages/Import.tsx`.
- Rebuild the bundle the way the project does it (see README / `nix flake check`).

Done when typecheck, lint, test and build pass, `nix flake check` passes, and `rg -i "rates\"|/rates|needs.rate|TRM" frontend/src` only finds the fetch call.', '2026-10-24T03:48:23Z', '2026-10-24T04:10:07Z', 134, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (138, 25, 'describe USD books and fetched exchange rates in specs and README', 'work', 'done', NULL, '2026-10-23, README.md, airbnb-bookkeeping-spec.md, architecture-spec.md', 'Last step of `plan 25: USD inside, exchange rates fetched automatically`: the documents catch up with the code. Rules: decisions 34–41 of that plan (see `pm show p25`).

- `airbnb-bookkeeping-spec.md` and `architecture-spec.md`: storage in USD cents with the originals kept, the two rate sources and their endpoints, caching and coverage, reference dates, entries waiting for a rate, the migration of the peso books, money entry with a currency choice. The "no network access" rule becomes "network only to fetch exchange rates; no CDN or web fonts". Rewrite the "Where rates come from" / Exchange rates sections; remove the Rates page, typed rates, TRM CSV import and `import-rates`.
- `README.md`: the Exchange rates section (what is fetched from where, what happens offline), the CLI list without `import-rates`.

Done when the docs describe the code as it is and `rg -i "import-rates|trm.csv|whole pesos|no network" --glob ''!tasks.sql''` finds nothing stale.', '2026-10-24T03:48:23Z', '2026-10-24T04:15:52Z', 134, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (139, 26, 'create tasks for plan 26: add expenses inline in the sheet', 'split', 'done', 1000, '2026-10-23, tasks 140, 141', 'Split `plan 26: add expenses inline in the sheet` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-24T03:49:23Z', '2026-10-24T03:49:57Z', 129, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (140, 26, 'add new expenses in an entry row of the sheet', 'work', 'done', NULL, '2026-10-23, frontend/src: DataTable.tsx, FieldError.tsx, Field.tsx, inputs.tsx, useSave.ts, index.css, App.tsx, pages/Expenses.tsx', 'Part of `plan 26: add expenses inline in the sheet` (see its "Task 1" section for the full list). Instead of the "New expense" page, a "+" button opens an empty row at the bottom of the Expenses sheet, typed in place.

Rules: `decision 43: editing an expense or recurring template stays on its own page; only new entries are typed inline`, `decision 39: money entry: an amount with a currency choice (USD, COP, EUR)` (use the amount + currency input from `task 137: the screens run on USD with a currency choice and the waiting notice`, default currency from the API), `decision 37: when no exchange rate can be fetched, entries are saved and wait for their rate` (a waiting save shows the API''s warning notice).

What to do (`frontend/src`):
- `components/DataTable.tsx`: optional `entry?: ReactNode`, rendered as the last body row (after the empty-state row, above the footer); a `SheetEntryRow` helper adds the gutter cell ("+" mark, `aria-hidden`) and a class styled in `index.css` (`input-sm`/`select-sm` filling the cell, light highlight).
- `useSave`: `redirectTo` optional; without it stay on the page, call an `onSaved` callback, allow resetting errors.
- `pages/Expenses.tsx` `ExpenseList`: Toolbar `action` becomes a "+" button (`btn btn-primary btn-sm btn-square`, `aria-label` and `title` "Add expense"), disabled while the row is open.
- Row inputs per column: Date (today''s local date, not `toISOString()`), Category (with booking for per_booking / useful life for capex under the select, only for those), Description, Amount + currency, Save/Cancel in the Source column. Inputs use the `form` attribute so Enter submits; Escape cancels.
- Field errors under each input (small `text-error` line with the warning mark extracted from `Field.tsx` and shared); `""` errors in `FormError` above the sheet.
- After save: row closes, list and totals refresh via query invalidation, notices show.
- Remove the `/expenses/new` route in `App.tsx`, `ExpenseNew`, and the "new" branch of `ExpenseForm`.

Done when an expense can be added, rejected with in-row errors, and cancelled in the running app (check once by hand), and frontend typecheck, lint, test and build pass.', '2026-10-24T03:49:57Z', '2026-10-24T04:11:16Z', 139, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (141, 26, 'add new recurring expenses in an entry row and describe it in the README', 'work', 'done', NULL, '2026-10-23, frontend/src/pages/Expenses.tsx, frontend/src/App.tsx, README.md', 'Part of `plan 26: add expenses inline in the sheet` (see its "Task 2" section). Recurring monthly expenses get the same "+" button and entry row as expenses, using the `entry` / `SheetEntryRow` / `useSave` pieces the previous task added.

Rules: `decision 43: editing an expense or recurring template stays on its own page; only new entries are typed inline`, `decision 39: money entry: an amount with a currency choice (USD, COP, EUR)`, `decision 37: when no exchange rate can be fetched, entries are saved and wait for their rate`.

What to do:
- `frontend/src/pages/Expenses.tsx` `RecurringList`: the "New" link becomes a "+" button (`btn btn-primary btn-sm btn-square`, `aria-label`/`title` "Add recurring expense") above the sheet on the right, opening a `SheetEntryRow` with Description, Category, Amount per month + currency, Start month (this local month), Until (empty = open), Save/Cancel in the last cell (or their own cell if cramped).
- Same in-cell errors, save, refresh and close behaviour as for expenses; stay on the list after saving.
- Remove the `/recurring/new` route, `RecurringNew` and the "new" branch of `RecurringForm`.
- README "Styling conventions": add a bullet on the entry row (`entry` + `SheetEntryRow`, "+" button as Toolbar `action` or above the sheet, in-cell errors, today''s date default); the Buttons bullet no longer mentions a "New …" link for Expenses (Bookings keeps its link per `decision 29: Hand-entered bookings: remove the ''New booking'' button so that all income comes from the Airbnb CSV?`).

Done when a template can be added inline in the running app, `rg "recurring/new|expenses/new|ExpenseNew|RecurringNew" frontend README.md` finds nothing, and frontend typecheck, lint, test, build and `nix flake check` pass.', '2026-10-24T03:49:57Z', '2026-10-24T04:12:03Z', 139, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (142, 27, 'create tasks for plan 27: hand-entered bookings, the Time page and the Quit button', 'split', 'done', 1000, '2026-10-23, tasks 143, 144, 145, 146; 136 requires 143+144 (migration renamed 0004_usd.sql), 137 requires 145, 138 requires 146; no new decisions', 'Split `plan 27: hand-entered bookings, the Time page and the Quit button` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-24T03:51:12Z', '2026-10-24T03:51:57Z', 130, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (143, 27, 'remove the time log from the backend', 'work', 'done', NULL, '2026-10-23, migration 0003_drop_time_log.sql, model, allocation, metrics, repo, web api (timelog removed, dashboard, settings), forms, tests', 'First step of `plan 27: hand-entered bookings, the Time page and the Quit button`: the log of the owner''s own hosting hours and everything computed from it leave the backend, per `decision 30: Time page: remove the log of your own hosting hours, or keep it and explain it?`. The frontend follows in a later task (it may be visibly broken in between; the backend checks must pass).

Rules: `decision 44: the per-day view starts on the first day any input is spread over, without blocked days or own time`; `decision 6: own time is stored in whole minutes` becomes moot.

- **Migration** `storage/migrations/0003_drop_time_log.sql` (0003 is the next free number): `DROP TABLE time_log` and its index; delete the `hourly_value_cop` settings row.
- **model.py**: `TimeEntry`, `Inputs.time_log`, `Settings.hourly_value_cop`, `Day.minutes` go.
- **allocation.py**: the time-log loop and the time-entry term of the default start date (decision 44).
- **metrics.py**: `minutes`, `profit_per_hour`, `own_time_value`, `profit_after_own_time` go; the dashboard JSON (`web/api/dashboard.py`) loses those rows.
- **storage/repo.py**: time-entry functions, the `_INT_SETTINGS` entry, any booking-delete check mentioning time entries.
- **web**: `web/api/timelog.py` and its registration; settings API without `hourly_value_cop`; the hours parse/format helpers in `web/forms.py` if nothing else uses them.
- **Tests**: `test_api_timelog.py` goes; metrics, allocation, settings, schema, repo and `test_e2e.py` updated. Stay sparse.

Done when pytest and ruff pass and `rg -i "time_log|timeentry|hourly|minutes|per_hour|own_time" src tests` finds nothing but unrelated hits.', '2026-10-24T03:51:37Z', '2026-10-24T03:53:09Z', 142, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (144, 27, 'back up the books while the app runs and remove the quit endpoint', 'work', 'done', NULL, '2026-10-23, cli.py (backup thread), web/app.py, web/api/settings.py, web/api/system.py removed, test_backup, test_api_foundation, test_e2e', 'Second step of `plan 27: hand-entered bookings, the Time page and the Quit button`. The app is a server that never stops (`decision 31: Quit button: remove it, or keep it with a clearer name?`), so backups can no longer rely on quitting.

Rules: `decision 45: backups while the app runs: at start, then every hour when something changed, plus at stop`; `decision 19: backups: which files are pruned, how many are kept, and what a failed backup does` still holds.

- **cli.serve**: a daemon thread: one backup right after start, then every hour, skipped when nothing was written since the last one (`PRAGMA data_version` on the thread''s own connection, or the db / -wal modification time). Each writes today''s `books-YYYY-MM-DD.db` (same-day overwrite, pruning per decision 19). The backup at stop (Ctrl-C, SIGTERM) stays. Failures go to stderr; the app keeps running.
- **Last result**: kept where the Flask app can read it (e.g. `app.config`); `GET /api/settings` returns it as `last_backup` (time and file, or the error; null before the first attempt).
- **Removals**: `POST /api/quit` (`web/api/system.py`), the `shutdown` parameter of `create_app`, `SHUTDOWN`, the `pthread_kill` plumbing. The serve docstring says to stop with Ctrl-C / SIGTERM.
- **Tests**: the quit tests in `test_backup.py` and `test_api_foundation.py` go; one test of the backup loop with a short interval or an injected clock (no real hour waits); `test_e2e.py` takes its backup with `backup_on_exit` (or the loop''s step) instead of `/api/quit`.

Done when pytest and ruff pass and `rg -i quit src tests` finds nothing.', '2026-10-24T03:51:37Z', '2026-10-24T03:53:52Z', 142, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (145, 27, 'remove the Time page and the Quit button, rename the add-a-stay button, show the last backup', 'work', 'done', NULL, '2026-10-23, frontend/src App.tsx nav.ts format.ts format.test.ts components/icons.tsx pages/{Bookings,Dashboard,Settings}.tsx; Time.tsx and Stopped.tsx removed', 'Third step of `plan 27: hand-entered bookings, the Time page and the Quit button`: the screens follow `task 143: remove the time log from the backend` and `task 144: back up the books while the app runs and remove the quit endpoint`.

Rules: `decision 29: Hand-entered bookings: remove the ''New booking'' button so that all income comes from the Airbnb CSV?` (keep, relabel, hint), `decision 30: Time page: remove the log of your own hosting hours, or keep it and explain it?`, `decision 31: Quit button: remove it, or keep it with a clearer name?`, `decision 45: backups while the app runs: at start, then every hour when something changed, plus at stop`.

- **Time page**: remove `pages/Time.tsx`, its routes in `App.tsx`, the nav entry and `TimeIcon` if unused, the "minutes" kind and own-time rows in `Dashboard.tsx`, the hourly-value field in `Settings.tsx`, the hour helpers in `format.ts` and their tests if unused.
- **Quit**: remove the Quit button, its mutation and error in `App.tsx`, and `pages/Stopped.tsx` (with its doodle asset if nothing else uses it).
- **Bookings.tsx**: the "New booking" link reads "Add a stay booked outside Airbnb"; one line on the page: Airbnb stays come in through the CSV import (link to Import), this is only for stays booked elsewhere. The form title for a new one matches.
- **Settings.tsx**: a read-only "Last backup" line from `last_backup` in `GET /api/settings` (date/time and file, or the error in the error style; nothing yet → say so).
- Rebuild the bundle the way the project does it.

Done when frontend typecheck, lint, test and build pass and `rg -i "quit|stopped|/time|hourly" frontend/src` finds nothing.', '2026-10-24T03:51:48Z', '2026-10-24T04:08:24Z', 142, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (146, 27, 'describe the removed time log and quit, running backups and outside stays in specs and README', 'work', 'done', NULL, '2026-10-23, README.md, airbnb-bookkeeping-spec.md, architecture-spec.md', 'Last step of `plan 27: hand-entered bookings, the Time page and the Quit button`: the docs follow the code after `task 143: remove the time log from the backend`, `task 144: back up the books while the app runs and remove the quit endpoint` and the screens task before this one.

Rules: `decision 44: the per-day view starts on the first day any input is spread over, without blocked days or own time`, `decision 45: backups while the app runs: at start, then every hour when something changed, plus at stop`, `decision 29: Hand-entered bookings: remove the ''New booking'' button so that all income comes from the Airbnb CSV?`.

- `airbnb-bookkeeping-spec.md`, `architecture-spec.md`: no time log, own-time metrics, hourly value or `/api/quit`; the Quit paragraph goes; backups per decision 45 (at start, hourly when changed, at stop; the systemd timer stays optional); the start-date rule per decision 44; hand-entered stays described as "stays booked outside Airbnb".
- `README.md`: the intro without "profit per hour you put in"; "Run and quit" becomes "Run" (stop with Ctrl-C or `systemctl stop`); the Backup section per decision 45 and where the last backup shows (Settings page); Restore step 1 "stop the app"; the Bookings button name "Add a stay booked outside Airbnb".

Done when the docs describe the code and `rg -i "quit|time log|hourly|per hour|own time" *.md` finds nothing stale.', '2026-10-24T03:51:48Z', '2026-10-24T04:12:41Z', 142, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (147, NULL, 'Fix inline-form layout on Expenses and Recurring; move CSV import onto the Bookings page', 'exec', 'done', NULL, '2026-10-24, frontend/src/components/inputs.tsx, index.css, pages/Expenses.tsx, pages/Bookings.tsx, components/AirbnbImport.tsx (was pages/Import.tsx), nav.ts, App.tsx, components/icons.tsx, README.md, architecture-spec.md', 'Three UI fixes the human reported from screenshots, plus removing a page.

**1. Expenses: new-expense row overflows its cells**
- When adding an expense, the inline row''s amount cell (column D, `Amount (USD)`) holds the `AmountInput` (`frontend/src/components/inputs.tsx`): a tiny empty amount box plus a wide currency select.
- The currency select spills into column E and runs under the Save/Cancel buttons; the amount box itself is a few pixels wide, so you can''t see what you type.
- Done when: the amount box is wide enough to read a typical amount, the currency select is compact (it only shows USD/COP/EUR), both stay inside their cell, and Save/Cancel don''t overlap anything.

**2. Recurring: same row, different breakage**
- On the Recurring page''s new-template row, the `Amount / month` cell (column C) also shows a near-zero-width amount box and a currency select that pokes into the `From` column.
- The `Until` cell stacks the date input above Save/Cancel, so the row is twice as tall as needed and the buttons sit under the wrong column.
- Done when: amount + currency fit in their cell like on Expenses, and the action buttons sit cleanly (own column or aligned at row end) without the row growing tall.
- Best fix is likely in `AmountInput` / shared CSS (`frontend/src/index.css`) so both pages benefit; check the edit forms too, not only the "new" rows.

**3. Remove the Import page; add "Import CSV" on Bookings**
- Drop `/import` from `frontend/src/nav.ts` and `frontend/src/App.tsx`, and delete `frontend/src/pages/Import.tsx` (and `ImportIcon` if unused afterwards).
- Add an "Import CSV" button to the Bookings page toolbar (`frontend/src/pages/Bookings.tsx`) that offers the same Airbnb CSV upload and shows the same result/feedback the Import page did; refresh the bookings list after a successful import.
- Backend import endpoint stays as is.
- Update README / specs where they mention the Import page.

Verify each fix by looking at the running app (screenshot at a normal desktop width), not only by type-checking.', '2026-10-24T12:51:37Z', '2026-10-24T12:53:51Z', NULL, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (148, 28, 'create tasks for plan 28: display currency', 'split', 'done', 1000, '2026-10-24, tasks 149, 150, 151', 'Split `plan 28: display currency` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-24T13:59:54Z', '2026-10-24T14:00:26Z', 128, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (149, 28, 'the display currency on the server: settings, migration and /api/display', 'work', 'open', NULL, NULL, 'Server side of `plan 28: display currency`. Rules: `decision 46: display currency: amounts are converted in the browser, the server keeps answering in USD`, `decision 48: display currency: kept in settings with the rate fetched when it was chosen, switched and shown in the page header`.

- Migration `storage/migrations/0005_display_currency.sql`: settings `currency` set to `USD` (the old `COP` value never had a rate).
- `model.py`: `Settings.currency` default `"USD"`; new `Settings.display_rate: dict | None` (`{rate, rate_date}`, rate = currency units per USD × 1 000 000), loaded/saved as JSON by `repo`.
- New `web/api/display.py`:
  - `GET /api/display` → `{currency, rate, rate_date, currencies}`; USD: rate 1 000 000, rate_date null.
  - `PUT /api/display {currency}`: validate against `CURRENCIES`; USD needs no rate; else `conversion.rate_on(conn, currency, today())`; store currency and rate. Choosing the same currency again refreshes the rate.
  - No rate: refusal with the warning notice of decision 48 ("No COP rate could be fetched (no connection?); figures stay in USD.") and nothing saved. Usual `ok(..., [notice])` response shape.
- `/api/settings` stays as it is; every other endpoint keeps answering in USD cents.
- A few tests (fetcher monkeypatched like the other conversion tests): switching to COP stores the rate; a failed fetch leaves USD; the migration sets USD.
- Done when pytest and ruff pass.', '2026-10-24T14:00:15Z', NULL, 148, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (150, 28, 'every screen shows the display currency, switched in the page header', 'work', 'open', NULL, NULL, 'Client side of `plan 28: display currency`. Rules: `decision 46: display currency: amounts are converted in the browser, the server keeps answering in USD`, `decision 47: display currency: number formats per currency`, `decision 48: display currency: kept in settings with the rate fetched when it was chosen, switched and shown in the page header`. The API from `task 149: the display currency on the server: settings, migration and /api/display` is in place.

- `format.ts`: `toDisplay(cents, rate)` → minor units of the display currency (`round(cents × rate / 1 000 000)`, half away from zero) and a formatter per decision 47 (COP whole pesos 1.234.567; USD/EUR 1.234,56; code, never a symbol; no abbreviations). Unit tests in `format.test.ts`.
- A display hook/context (e.g. `useDisplay()`, TanStack Query key `["display"]`) giving `{currency, rate, rate_date, money(cents|null)}`. `showMoney`, `AmountCell` and every direct `formatMoney` call showing a USD figure go through it (Dashboard tables, Bookings net payout / line amounts / detail totals, Expenses amounts and totals, Settings rent).
- Stay as typed: hover texts (`conversionTitle`), booking line "Original" and "Rate" columns, form inputs.
- Totals: convert the server''s USD total, don''t sum converted rows.
- Header in `App.tsx`: small `select` (USD / COP / EUR) next to the nav, plus "1 USD = 4.123,45 COP · rate of 2026-10-23" (hidden for USD). Changing it calls `PUT /api/display`, shows notices, invalidates `["display"]`; on refusal the select goes back to the stored value.
- Labels that say USD say the display currency: "Amount (…)", "Net payout (…)", "… unless stated", "ADR and RevPAR (…)", the booking-line "USD" column, Settings'' "rent … USD" line.
- Dashboard charts: convert series values before passing them to `LineChart`/`BarChart`, so ticks are round in the display currency.
- Rebuild the bundle the way the project does it. Check once in the running app: switch to COP and EUR (needs network), figures change everywhere and survive a reload; switch back to USD.
- Done when frontend typecheck, lint, test and build pass, `nix flake check` passes, and `rg "formatMoney\(" frontend/src` only finds the display helper (or its tests).', '2026-10-24T14:00:23Z', NULL, 148, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (151, 28, 'specs and README describe the display currency', 'work', 'open', NULL, NULL, 'Docs for `plan 28: display currency`, after `task 150: every screen shows the display currency, switched in the page header`.

- `airbnb-bookkeeping-spec.md` and `architecture-spec.md`: the display currency (header switch, rate fetched once on switching and kept until the next switch, conversion in the client, number formats per `decision 47: display currency: number formats per currency`), `GET/PUT /api/display`, the `currency` / `display_rate` settings keys.
- `README.md`: where to switch the currency and what the rate line in the header means; the styling conventions say money is shown through the display helper.
- Done when the docs describe the code and nothing says figures are always shown in USD.', '2026-10-24T14:00:26Z', NULL, 148, 0, NULL, 'main');

INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (1, 'Sign off the masterplan of milestone 1: first version build', 'answered', '["approve"]', '', 'This is the overall roadmap for building the first working version of a small, private bookkeeping app for one Airbnb apartment. The app turns every booking and every cost into amounts per calendar day, so it can answer whether hosting pays off, whether prices are set well, and how things are trending. The roadmap splits the build into parts, starting with a short architecture document the owner approves before anything else is built, and ending with a check against the real Airbnb export.

Approving lets the work described here go ahead.', 'approve', NULL, '2026-10-23T19:15:40Z', '2026-10-23T19:19:03Z', NULL, 'masterplan', 'rule', NULL, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (2, 'Sign off plan 2: architecture spec', 'answered', '["approve"]', '', 'Before any code is written, the owner needs a short document that fixes the big technical choices for the bookkeeping app: what it is built with, what the screen looks like, how it is installed, where the data file lives, and how the Airbnb export is read, including how bookings paid in dollars become pesos. Writing this down first, and having the owner approve it, means every later piece is built on choices the owner has agreed to, instead of being reworked afterwards.

Approving lets the work described here go ahead.', 'approve', NULL, '2026-10-23T19:20:03Z', '2026-10-23T19:21:23Z', NULL, 'plan', 'rule', NULL, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (3, 'approve the architecture', 'answered', '["approve", "request changes (say which)"]', 'Read `architecture-spec.md` at the repo root. Main recommendations:

- **Stack/UI:** Python 3 + Flask/Jinja2/waitress, a local web server on 127.0.0.1 opened in the browser; plain HTML forms, charts as server-drawn inline SVG; pytest, ruff.
- **Nix:** `nix build` (tests run in the check phase), `nix run`, dev shell keeps `pm` + git and adds Python, pytest, ruff, sqlite; home-manager and NixOS modules for a daily backup timer.
- **Layout:** only `storage/` talks SQL; `allocation` and `metrics` are pure functions; the per-day view is computed in Python on demand with an exact integer rounding rule.
- **DB:** `$XDG_DATA_HOME/airbnb-books/books.db`, override with `--db` / `AIRBNB_BOOKS_DB`; migrations as numbered SQL files tracked by `PRAGMA user_version`; backups via SQLite''s online backup API into `~/Dropbox/airbnb-books`, keep 30.
- **CSV import:** one booking per confirmation code, its rows kept as booking lines (long stays have one row per month); adjustments and resolution rows fold into the booking; co-host payouts become a per-booking cost; `Payout` rows (EUR/USD transfers) ignored to avoid counting income twice; thousands commas in amounts handled.
- **Listings (please check):** the export has 7 listings (rooms and apartments, overlapping in time). Recommended: a setting "listings of this property"; the first import asks which to keep, others are skipped.
- **Currencies:** each line keeps original currency and amount, the rate used and the derived integer COP; rates (COP per USD) are loaded by the user, from a hand-downloaded TRM CSV of datos.gov.co or typed in; latest rate on or before the row''s date; missing rates are flagged, rate changes recompute.', 'Before anything is built, the owner should agree on how the bookkeeping app will be made: which programming language and screen style it uses, how it is installed, where its data lives, and how it reads Airbnb''s export file. Approving lets the build start on this basis; asking for changes means the design document is revised first. One point needs particular attention: the Airbnb export contains several rooms and apartments, while the app was meant for a single property.', 'approve', NULL, '2026-10-23T19:23:57Z', '2026-10-23T19:30:24Z', 13, NULL, 'rule', NULL, '2026-10-23, task 11: Approving architecture-spec.md fixed the stack and layout every part plan builds on: Python 3 + Flask/Jinja2/waitress local web app named airbnb-books, pytest + ruff, flake package/app/checks and a shared NixOS/home-manager backup module (nix/module.nix, services.airbnb-books-backup), DB at $XDG_DATA_HOME/airbnb-books/books.db with numbered SQL migrations and a backup before migrating, backups via Connection.backup as books-YYYY-MM-DD.db in ~/Dropbox/airbnb-books keeping 30. Schema additions beyond the product spec: booking_lines, exchange_rates, bookings.listing/guest_name, settings property_listings/backup_keep; booking money totals derived from lines; co-host payouts are per-booking costs; Payout rows ignored; USD lines converted with the latest rate on or before the line date. Plans 3-10 (parts 2-9) were written against it; no longer holds: the product spec''s single integer net_payout per booking and storing per-day rows in a table (days is computed on demand).');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (4, 'Sign off plan 3: project skeleton and Nix packaging', 'answered', '["approve"]', '', 'Before any bookkeeping feature is written, the app needs an empty but working frame: a place for the code, a way to run its tests and check its style, and a way to install and start it with the owner''s Nix setup. This part builds that frame with a tiny app that only starts and shows one page, and one test that passes. Every later part then just adds its own code and tests to it, instead of each one fighting with tooling.

Approving lets the work described here go ahead.', 'approve', NULL, '2026-10-23T19:30:54Z', '2026-10-23T19:31:35Z', NULL, 'plan', 'rule', NULL, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (5, 'booking money totals are derived from booking lines, not stored', 'answered', '[]', 'Architecture section 7 makes the totals sums over booking lines; storing them as well would need re-syncing after every rate change or re-import. A view is cheap at this data size. See `plan 4: database schema and storage`.', 'Each stay''s income figures (what the guest paid, Airbnb''s fee and what the owner received) can either be saved alongside the stay or be added up whenever needed from the individual payment records Airbnb sends. Adding them up each time means there is only one place the numbers live, so a corrected exchange rate or a late adjustment changes the totals automatically.', 'derive totals with a database view over booking lines; hand-entered stays get one manual line', NULL, '2026-10-23T19:32:22Z', '2026-10-23T19:32:22Z', 5, NULL, 'rule', 5, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (6, 'own time is stored in whole minutes', 'answered', '[]', 'Keeps the no-floats convention of the product spec; minutes are fine-grained enough. Metrics divide by minutes/60 at display time. See `plan 4: database schema and storage`.', 'The owner logs the hours spent on hosting so the app can show profit per hour. Hours with fractions would need decimal numbers, which the app avoids everywhere for exactness, so the time is kept as whole minutes and shown as hours.', 'time_log stores integer minutes; screens show and accept hours', NULL, '2026-10-23T19:32:22Z', '2026-10-23T19:32:22Z', 5, NULL, 'rule', 5, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (7, 'the per-day view ends today; nothing after today is counted', 'answered', '[]', 'The product spec counts booking income only on or before today; doing the same for all costs keeps profit consistent (no future costs against no future income) and makes every split independent of the range shown. Upcoming bookings are a ''Later'' feature.', 'The app turns every payment and cost into amounts per calendar day, and must decide what to do with days that have not happened yet, such as the later nights of a booked stay or a monthly bill for the rest of the month. The choice is to show only days up to and including today, so every figure is something that has actually happened, while still splitting each amount over its full period so later days get their share when they arrive.', 'days run from a start date to today inclusive; each amount is split over its full span (including future days) and only the days up to today are kept', NULL, '2026-10-23T19:36:18Z', '2026-10-23T19:36:18Z', 6, NULL, 'rule', 6, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (8, 'a per-night expense is spread over the occupied nights of its month', 'answered', '[]', 'Expense rows hold a paid amount, not a rate per night; spreading it over the month''s occupied nights keeps the exact total and puts it on the nights that caused it. The fallback keeps sums exact. Same rule for per_night rows generated from recurring templates.', 'Some costs grow with guest nights, such as consumables or extra electricity, but are paid as one bill. The app has to decide how such a bill becomes amounts per day: it is shared out over the nights guests stayed in the bill''s month, and if nobody stayed that month, over every day of the month so the cost never disappears.', 'per_night expense dated in month M: split over the occupied nights of M (booked nights after today count in the split); no occupied night in M: split over all days of M like a fixed cost', NULL, '2026-10-23T19:36:18Z', '2026-10-23T19:36:18Z', 6, NULL, 'rule', 6, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (9, 'monthly expenses generated from templates are dated the 1st and come back if deleted', 'answered', '[]', 'Needs no extra schema beyond the unique (recurring_expense_id, date) key of plan 4. Remembering deletions would need a new table for little gain; the screens of part 7 must say this next to the delete button of a generated expense.', 'Regular monthly bills such as internet or the building fee are entered once as a template, and the app creates one cost entry per month from it automatically. The choice is how those entries behave: each is dated the first of its month and can be edited freely, but deleting one only lasts until the next start, because the app recreates missing months; to stop a bill, the template gets an end month, and to skip one month its amount is set to zero.', 'one expense per template and month from start_month to min(end_month, today''s month), dated YYYY-MM-01, created when missing on every app start and before the dashboard is built; edits to generated rows are kept, deleted rows are recreated', NULL, '2026-10-23T19:36:18Z', '2026-10-23T19:36:18Z', 6, NULL, 'rule', 6, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (10, 'a figure that cannot be computed is shown as empty, not as zero', 'answered', '[]', 'A zero ADR or occupancy would be read as ''priced at nothing'' or ''empty''; None keeps ''no data'' distinct and makes charts leave a gap instead of dropping to the axis.', 'Some figures have no meaningful value for a period, for example the average price per night when nobody stayed, or profit per hour when no hours were logged. The app has to show something in that case, and a zero would look like a real result.', 'every ratio whose divisor is zero (no occupied nights, no available nights, no logged hours, break-even with nightly price not above the variable cost) is None and the screens show it as a dash; sums (income, costs, profit) are 0 for an empty period', NULL, '2026-10-23T19:42:21Z', '2026-10-23T19:42:21Z', 7, NULL, 'rule', 7, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (11, 'break-even occupancy treats fixed, maintenance, capex and tax costs as fixed', 'answered', '[]', 'Everything that is not per night or per booking is incurred whether guests come or not; leaving maintenance, capex or tax out would understate the break-even point.', 'Break-even occupancy says what share of the available nights must be booked to cover the costs that do not depend on guests. The product description only says ''fixed costs'', so it has to be settled which kinds of cost count as such.', 'fixed costs = fixed + maintenance + capex + tax of the range; break-even occupancy = (those ÷ available nights) ÷ (ADR − variable cost per night), where variable cost = per-night + per-booking (incl. co-host); None when ADR ≤ variable cost or no occupied or available nights; values above 100% are shown as they are', NULL, '2026-10-23T19:42:21Z', '2026-10-23T19:42:21Z', 7, NULL, 'rule', 7, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (12, 'the long-term rental benchmark is spread over the days of each month', 'answered', '[]', 'Same rule as fixed monthly costs, so a month''s benchmark and its fixed costs line up day for day and a full month gives exactly the monthly figure.', 'The owner can enter what the place would earn per month as a long-term rental, to compare it with hosting. For a period that is not whole months, the monthly figure has to be turned into an amount for that exact period.', 'the monthly benchmark is split over the days of each calendar month with the same exact rounding as fixed costs; the benchmark for a range is the sum of its days; profit vs. long-term rental = profit − that sum', NULL, '2026-10-23T19:42:22Z', '2026-10-23T19:42:22Z', 7, NULL, 'rule', 7, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (13, 'the rolling 90-day chart starts once 90 days of history exist', 'answered', '[]', 'Every point then covers the same length of time, which is what makes the series comparable.', 'The trend chart shows, for each day, the average nightly price, revenue per available night and occupancy over the 90 days up to that day. For the first days of the records a full 90-day window does not exist yet, and a shorter one would make early points jumpy and not comparable.', 'one point per day from the 90th day of the per-day view to today, each over the 90 days ending that day; less than 90 days of history → an empty series (the dashboard says so); undefined values are None (a gap)', NULL, '2026-10-23T19:42:22Z', '2026-10-23T19:42:22Z', 7, NULL, 'rule', 7, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (14, 'Airbnb import: which rows set a booking''s dates, listing and guest name', 'answered', '[]', 'In airbnb_.csv all rows of a code agree on dates and listing, but an altered reservation would produce a newer Reservation row with new dates; taking the latest one follows Airbnb''s current state. Resolution rows can be the only rows of a code inside an export window, so they may create the booking. guests and notes are only ever entered by the owner (architecture-spec.md section 6).', 'One stay can appear in the Airbnb file several times: once a month for long stays, plus corrections and reimbursements, and a stay can be changed after it was first booked. The app has to decide which of these rows gives the stay''s dates, listing and guest name, and what a repeated import may overwrite. The chosen rule keeps the newest information from Airbnb while never touching what the owner typed in by hand.', 'dates, listing and guest name come from the latest-dated Reservation row of the code (any row type when there is none); a re-import updates them when they differ and reports the change; guests and notes are never changed by an import', NULL, '2026-10-23T19:44:26Z', '2026-10-23T19:44:26Z', 8, NULL, 'rule', 8, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (15, 'data entry forms: how money and hours are typed', 'answered', '[]', 'Pesos have no cents in practice, so any dot or comma in a peso amount can only be a thousands separator: no ambiguity. Hours follow `decision 6: own time is stored in whole minutes`; rounding to the nearest minute. Rates follow the hundredths storage of `plan 4: database schema and storage`.', 'The owner types amounts of money and hours worked into the app''s forms. Colombian and English habits differ on whether a dot or a comma separates thousands, and hours can be written as a decimal or as hours and minutes. This fixes what the forms accept, so they never misread an amount.', 'money in whole pesos: digits with optional dot, comma or space thousands separators, no decimals; shown as 1.234.567; hours as decimal (1.5 or 1,5) or h:mm (1:30), stored as whole minutes; exchange rates with up to 2 decimals after a dot', NULL, '2026-10-23T19:46:02Z', '2026-10-23T19:46:02Z', 9, NULL, 'rule', 9, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (16, 'changing a recurring expense template only affects months not yet generated', 'answered', '[]', 'Fits `decision 9: monthly expenses generated from templates are dated the 1st and come back if deleted` (edits to generated rows are kept). A price change usually starts at a date, so rewriting past months would be wrong more often than right; a typo is fixed by editing the few generated rows.', 'Regular monthly costs such as rent or internet are entered once as a template, and the app creates one cost entry per month from it. When the owner later changes the template (say, the rent goes up), the app must decide whether the months already created change too. The answer: only future months change; past months are corrected one by one, so history is never rewritten by accident.', 'editing a template changes only the months generated after the edit; already generated expenses stay as they are and are edited individually (the template''s page lists them with links); deleting a template keeps its generated expenses', NULL, '2026-10-23T19:46:02Z', '2026-10-23T19:46:02Z', 9, NULL, 'rule', 9, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (17, 'bookings from the Airbnb import: dates, listing and guest name are read-only in the edit form', 'answered', '[]', 'Follows `decision 14: Airbnb import: which rows set a booking''s dates, listing and guest name`: a re-import resets dates, listing and guest name, and never touches guests and notes.', 'Stays loaded from the Airbnb export get their dates, listing and guest name from that file, and loading a newer export updates them. If the owner could also change those fields by hand, the next import would silently undo the change. So for imported stays the form shows these fields but only lets the owner change the guest count and notes; stays typed in by hand stay fully editable.', 'bookings with Airbnb lines: only guests and notes are editable, money lines are shown read-only; hand-entered bookings: every field, including the amount, is editable', NULL, '2026-10-23T19:46:02Z', '2026-10-23T19:46:02Z', 9, NULL, 'rule', 9, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (18, 'dashboard layout: which periods are shown and which period the cost breakdown uses', 'answered', '[]', 'Columns per period keep the comparison side by side, as the product spec asks. Last month as default for the chosen month gives a full closed month next to the running one. The breakdown needs one period; tying it to the custom range (or chosen month) avoids a third set of date fields. URL query parameters (GET form) need no state and no JavaScript.', 'The dashboard compares figures over several periods at once and shows how costs split by kind. Someone has to pick which periods appear by default and which period the cost split refers to, so that the page stays readable without extra clicks.', 'one table with a column per period: all-time, last 90 days, last 30 days, this month, a chosen month (default: last month) and a custom range (default: none, column hidden until set); rows are the metrics; the expense breakdown uses the custom range when set, else the chosen month; period choices are in the page''s URL so a view can be bookmarked', NULL, '2026-10-23T19:47:18Z', '2026-10-23T19:47:18Z', 10, NULL, 'rule', 10, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (19, 'backups: which files are pruned, how many are kept, and what a failed backup does', 'answered', '[]', 'Other files the owner keeps in the folder must be safe. Writing to a temp file and renaming means Dropbox never syncs a half-written backup and an older same-day file is only replaced by a complete one. A migration without a fresh backup is the one case where losing data is likely, so it must not go ahead.', 'The app copies its database into a Dropbox folder every day and when it closes, and deletes old copies so only the most recent ones remain. This choice fixes which copies may be deleted, where the number to keep comes from, and what happens when a copy cannot be made, so that no backup is ever lost by accident and a failing backup is noticed.', 'pruning deletes only files named books-YYYY-MM-DD.db in the backup folder, oldest first, keeping the newest N; N = --keep, else the backup_keep setting, else 30; a backup is written to a temporary file and renamed into place; a failed backup on exit or by the timer is reported (stderr / non-zero exit, so systemd shows it) but never deletes anything and never stops the app from closing; a failed backup before a migration stops the migration', NULL, '2026-10-23T19:48:49Z', '2026-10-23T19:48:49Z', 11, NULL, 'rule', 11, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (20, 'Grant task 34: Exchange-rate (TRM) import web access (WebSearch, WebFetch)', 'answered', '["approve"]', '', 'The next piece of work needs to look things up on the internet: search the web and read web pages. Approving allows that for this piece of work only.', 'approve', NULL, '2026-10-23T19:58:13Z', '2026-10-23T20:07:29Z', NULL, 'web', 'rule', NULL, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (21, 'the per-day view starts on the first day any input is spread over', 'answered', '[]', 'The plan''s rule said ''earliest date of any expense''; read literally, a fixed cost dated mid-month in the oldest month would lose part of its amount in the all-time totals. Using the start of each expense''s span keeps every amount whole in the view.', 'The daily view of the books begins on the earliest day for which the app has something to show. A monthly cost such as rent is spread over every day of its month, even when it was entered with a date in the middle of the month. If the view began on that entered date, the first days of the month, and their share of the cost, would be cut off.', 'default start = earliest check-in, blocked day, time entry, or first day an expense is spread over (the 1st of the month for fixed and per-night costs, the check-in day or first night for per-booking costs)', NULL, '2026-10-23T20:01:03Z', '2026-10-23T20:01:03Z', 25, NULL, 'rule', 25, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (22, 'App renamed from airbnb-books to rios-de-asia-accounting', 'answered', '[]', 'Replaces only the name fixed by `decision 3: approve the architecture`; the rest stands. Command, Python package rios_de_asia_accounting, Nix module services.rios-de-asia-accounting-backup, data dir $XDG_DATA_HOME/rios-de-asia-accounting, backup dir ~/Dropbox/rios-de-asia-accounting, env vars RIOS_DE_ASIA_ACCOUNTING_DB and RIOS_DE_ASIA_ACCOUNTING_BACKUP_DIR. No compatibility with old names. Later work must not reintroduce airbnb-books.', 'The bookkeeping app was first given a working name that did not match the project''s own name. The human asked for everything derived from the name to follow the project name instead, so the program, its folders, settings and the backup service all use one consistent name.', 'rios-de-asia-accounting', NULL, '2026-10-23T21:28:47Z', '2026-10-23T21:28:47Z', 54, NULL, 'rule', 54, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (23, 'How do Tailwind CSS and daisyUI get into an app that promised no build step and no network?', 'answered', '["generate with the Tailwind CLI and daisyUI plugin in the dev shell, commit the generated CSS, a flake check keeps it up to date", "generate the CSS during the Nix package build, not committed", "no generator: vendored prebuilt daisyUI CSS plus hand-written CSS"]', 'Amends `decision 3: approve the architecture` (architecture-spec.md: ''no JavaScript framework, no build step, no CDN, no network access''). Options:
1. Generate the CSS with the Tailwind standalone CLI (nixpkgs tailwindcss_4, in the dev shell) plus the vendored daisyUI plugin files (daisyui.mjs, daisyui-theme.mjs, committed). The generated, minified CSS is committed under web/static/ and shipped as package data; a flake check fails when it is out of date. Runtime stays build-free and offline; changing styles means re-running one command.
2. Same tools, but the CSS is generated inside the Nix package build and never committed; running from the source tree needs that command first.
3. No generator: vendor daisyUI''s prebuilt full CSS file (components only, no Tailwind utility classes) plus a small hand-written CSS file. Simplest tooling, larger file, fewer layout utilities.', 'The new look uses two styling toolkits, Tailwind CSS and daisyUI, which normally run a small generator to produce the finished stylesheet. The approved architecture promised that the app needs no build step and never goes online, so the stylesheet has to come from somewhere that keeps the app working offline. The choice is between generating the stylesheet once and storing the result with the code, generating it every time the app is packaged, or skipping the generator and using daisyUI''s ready-made stylesheet only. The answer decides how the app is packaged and how much effort it takes to change a style later.', 'revisit the current code, it should be no problem now', NULL, '2026-10-23T22:35:11Z', '2026-10-24T00:10:56Z', 55, NULL, 'rule', NULL, '2026-10-24, task 57: Moot after `milestone 3: add a proper client-side framework`: Vite builds Tailwind 4 + daisyUI 5 from the npm devDependencies (frontend/src/index.css) and Nix builds the bundle offline (flake.nix packages.frontend, check frontend-lint), per `decision 24: client-side framework: React with TypeScript, built by Vite, on top of a JSON API from the existing Python server`. `plan 19: styling foundation` therefore has no toolchain task: no committed generated CSS, no vendored daisyUI files, no web/static/ folder, no pyproject package-data or dev-shell change. Static assets (the favicon of part 4) go into frontend/public/. The architecture-spec rule ''no build step'' no longer holds; ''no CDN, no network, no web fonts'' still does.');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (24, 'client-side framework: React with TypeScript, built by Vite, on top of a JSON API from the existing Python server', 'answered', '[]', 'Milestone 3: add a proper client-side framework asks for a proper client-side framework (''your choice'', build steps allowed), replacing the UI part of decision 3: approve the architecture (server-rendered Jinja, no JS, no build step). Considered: React (largest ecosystem, best known to people and agents, rich form/table libraries), Svelte 5 (smaller, less boilerplate, smaller ecosystem), Vue. React chosen for maintainability and library availability. Keeping Python: allocation, metrics, import, backup and their tests are correct and tested; rewriting them in TS gains nothing. Tailwind + daisyUI because milestone 2: visual design update already settled on them. Not committing the bundle: Vite needs node anyway for development; Nix builds it reproducibly offline from package-lock.json. Still local only: 127.0.0.1, no CDN, no network at runtime.', 'The app''s screens move from pages assembled on the server to a modern in-browser application, as the owner asked. The choice is React, the most widely used toolkit for this, written in TypeScript so mistakes in data shapes show up before the app runs, and bundled by Vite. The existing Python server keeps all bookkeeping rules, the database and the backups, and now only answers the browser''s data requests; everything still runs on the owner''s own computer, without internet.', 'React 19 + TypeScript + Vite single-page app in frontend/ (React Router for URLs, TanStack Query for server data, Tailwind CSS + daisyUI for styling, Biome for lint/format, Vitest only for pure helpers); Flask stays as the backend, serves a JSON API under /api and the built bundle; the bundle is built by Nix (buildNpmPackage with importNpmLock) and not committed; the dev shell adds nodejs; server-side parsing and validation stay authoritative', NULL, '2026-10-23T22:41:36Z', '2026-10-23T22:41:36Z', 61, NULL, 'rule', 61, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (25, 'In which order do the visual design update and the new client-side framework happen, and does the design work move onto the new screens?', 'answered', '["framework first: the new screens use Tailwind + daisyUI with the default look; the visual design update follows on the new screens (hold milestone 2, its plans get revised)", "visual design first on the current pages; the new screens re-create that look", "merge: the new screens are built with the full visual design right away; the visual design milestone is dropped"]', 'milestone 2: visual design update (plan 11: masterplan, tasks 57-60) restyles the Jinja templates with Tailwind/daisyUI; milestone 3: add a proper client-side framework replaces those templates with a React app (decision 24 if that is the recorded id: see pm decision list). Both milestones are open at queue index 0. Option 1 needs the human to put milestone 2 on hold until milestone 3 is implemented (or give it a later queue index); its plans 57-60 are then revised to target the React components, and decision 23: How do Tailwind CSS and daisyUI get into an app that promised no build step and no network? becomes irrelevant (Vite builds the CSS). Option 2: milestone 2 runs as planned, milestone 3 re-creates the theme, tables and forms in React (theme CSS reusable, markup redone). Option 3: milestone 3''s screen plans include the ledger theme, spreadsheet tables, playful touches and favicon; milestone 2 is closed by dropping its open tasks.', 'Two pieces of work are waiting: giving the app a friendlier look, and rebuilding its screens as a modern in-browser application. The look was planned for the current screens, which the rebuild throws away, so doing it first means styling every screen twice. The choice is whether the rebuild comes first and the new look is then applied to the new screens, whether the look comes first and is carried over, or whether the rebuild takes over the new look entirely. The answer decides which work runs first and whether the design plans are rewritten.', 'the visual design update is waiting on a decision. i will not answer the decision before the client-side framework milestone is completely done.', NULL, '2026-10-23T22:41:43Z', '2026-10-23T22:43:14Z', 61, NULL, 'rule', NULL, '2026-10-23, task 67: The design update waits until `milestone 3: add a proper client-side framework` is completely done. So every screen plan of milestone 3 (`plan 14: architecture and client toolchain`, `plan 15: data screens`, `plan 16: dashboard and charts`, `plan 17: import flow`) uses plain daisyUI default classes with one built-in light theme: no custom theme, no ledger look, no spreadsheet styling, no favicon. `plan 11: masterplan` and its tasks 57-60 are not edited: they stay blocked, since task 57 waits on `decision 23: How do Tailwind CSS and daisyUI get into an app that promised no build step and no network?`. What no longer holds once milestone 3 is done: plan 11 targets Jinja templates that part 6 deletes, and decision 23 is moot because Vite builds the CSS (`decision 24: client-side framework: React with TypeScript, built by Vite, on top of a JSON API from the existing Python server`). Whether milestone 2 is rewritten for the React screens or dropped is left to the human in `decision 26: Once the in-browser screens are done, how does the visual design update continue?`, which task 57 now also waits for.');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (26, 'Once the in-browser screens are done, how does the visual design update continue?', 'answered', '["rewrite the visual design update for the new screens: same goals (ledger theme, spreadsheet tables, playful touches, favicon) applied to the React components; the stylesheet question is dropped", "drop the visual design update; the plain default look stays"]', 'Context: `decision 25: In which order do the visual design update and the new client-side framework happen, and does the design work move onto the new screens?` was answered with: no design decision before `milestone 3: add a proper client-side framework` is completely done. `plan 11: masterplan` (tasks 57-60) targets the Jinja templates, which part 6 of `plan 12: masterplan` deletes; `decision 23: How do Tailwind CSS and daisyUI get into an app that promised no build step and no network?` is moot after milestone 3 (Vite + the Tailwind/daisyUI npm packages build the CSS, see `decision 24: client-side framework: React with TypeScript, built by Vite, on top of a JSON API from the existing Python server`). Option 1 means: the human puts milestone 2 on hold or behind milestone 3, marks decision 23 irrelevant, and `plan 11: masterplan` is revised (parts target `frontend/src` components and a custom daisyUI theme). Meant to be answered after milestone 3 is done.', 'A friendlier look for the app was planned for the current server-built pages, but those pages are being replaced by new screens that run in the browser, and the look was put off until that rebuild is finished. The old design plans would style pages that will no longer exist, and they include a question about how to produce the stylesheet that the new build tools already answer. The choice is whether to rewrite the design work for the new screens or to drop it. The answer decides whether the design plans are rewritten or closed.', 'the client-side rework is complete, now we can do the visual design', NULL, '2026-10-23T22:50:03Z', '2026-10-24T00:10:37Z', 67, NULL, 'rule', NULL, '2026-10-24, task 57: The visual design update targets the React screens. `plan 19: styling foundation` (part 1) maps the masterplan''s Jinja targets onto frontend/src: base.html → App.tsx, Notices.tsx, pages/Stopped.tsx; web/static/ → frontend/public/; tables → components/DataTable.tsx and the dashboard table; forms → components/Field.tsx, inputs.tsx, ConfirmDelete.tsx; charts → frontend/src/charts/. tests/test_web.py no longer exists; the checks are npm typecheck/lint/test/build, pytest and nix flake check. Tasks 58-60 (plans for parts 2-4) should read plan 19''s ''Where things stand'' section instead of the masterplan''s file names. `plan 11: masterplan`''s body was not edited.');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (27, 'visual design: one light ledger theme, no dark mode', 'answered', '[]', 'The masterplan left dark mode optional for part 1. The paper/ruled-line/red-ink motif depends on a light background; a dark variant would need its own rule and ink colours and a second visual check of every page and chart, for a single-user local app. Can be added later as a second daisyUI theme without touching components, since they use theme colours (base-*, primary, error) and the num/neg classes. See `plan 19: styling foundation`.', 'The app''s new look could come in a light version only, or in a light and a dark version that follows the computer''s setting. A ledger look is about paper, ruled lines and red ink, which only reads naturally on a light background, and a second colour scheme doubles the checking for every screen. So the app gets one light theme.', 'one custom light daisyUI theme ''ledger'' (default, color-scheme light); no dark theme, no prefers-color-scheme switch', NULL, '2026-10-24T00:12:22Z', '2026-10-24T00:12:22Z', 57, NULL, 'rule', 57, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (28, 'visual design: one light ledger theme, no dark mode', 'answered', '[]', 'Masterplan ground rule (`plan 19: styling foundation`, readability first): one theme keeps contrast checks to one palette, and the paper/ledger look only makes sense light. The app is a local single-user tool, so following the OS dark-mode setting is not needed.', 'The bookkeeping app''s new look imitates paper ledgers: off-white paper, green and blue ruling, red ink for losses. A dark variant would need a second, separately checked colour scheme and would weaken the paper metaphor. So the app gets just one light colour scheme.', 'one custom light daisyUI theme named ledger, set as the default; no dark theme and no theme switcher; color-scheme: light', NULL, '2026-10-24T00:12:24Z', '2026-10-24T00:12:24Z', 102, NULL, 'rule', 102, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (29, 'Hand-entered bookings: remove the ''New booking'' button so that all income comes from the Airbnb CSV?', 'answered', '["remove it: income only from the Airbnb CSV; bookings already typed in by hand stay visible and can be deleted, but no new ones can be added", "keep it, relabelled ''Add a stay booked outside Airbnb'', with a one-line hint on the bookings page", "remove it and also delete every booking that was typed in by hand"]', 'What the button does now: it creates a booking with dates, guests, notes and one hand-typed amount in pesos (stored as one line of type ''Manual''); its edit form allows changing everything (`decision 17: bookings from the Airbnb import: dates, listing and guest name are read-only in the edit form`). Airbnb stays never need it: the import creates and updates them by confirmation code. You are right if every guest books through Airbnb.', 'Today a stay can be typed in by hand, with a total amount, besides the stays that come in from Airbnb''s export file. That is only useful for guests who booked outside Airbnb (directly, friends, another platform); Airbnb stays always come from the file. The answer decides whether the app keeps a way to record such outside stays or takes income from the Airbnb file only.', 'keep it, relabelled ''Add a stay booked outside Airbnb'', with a one-line hint on the bookings page', NULL, '2026-10-24T03:17:56Z', '2026-10-24T03:43:55Z', 124, NULL, 'once', NULL, '2026-10-24, task 130: `plan 27: hand-entered bookings, the Time page and the Quit button` keeps hand-entered bookings and their backend as they are; on the Bookings page the ''New booking'' link reads ''Add a stay booked outside Airbnb'' with a one-line hint that Airbnb stays come in through the CSV import; specs and README call them stays booked outside Airbnb. Part 2 converts their lines at check-in like Airbnb lines.');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (30, 'Time page: remove the log of your own hosting hours, or keep it and explain it?', 'answered', '["remove it: the Time page, the logged hours, the three dashboard rows and the hourly-value setting go", "keep it: rename the tab ''My hours'', add a short explanation on the page and next to the dashboard rows"]', 'Used by: the dashboard rows ''Profit per hour'', ''Own time value'', ''Profit after own time'' and the ''Hourly value of own time'' setting. Without logged hours those rows are empty dashes (`decision 10: a figure that cannot be computed is shown as empty, not as zero`).', 'The Time page lets you record the hours you spend on hosting yourself (cleaning, messaging guests, check-ins). The dashboard uses them to show profit per hour of your work and profit after paying yourself an hourly rate set in Settings. The answer decides whether this own-time accounting stays (with a clear explanation on the page) or disappears from the app.', 'remove it: the Time page, the logged hours, the three dashboard rows and the hourly-value setting go', NULL, '2026-10-24T03:17:56Z', '2026-10-24T03:43:29Z', 124, NULL, 'once', NULL, '2026-10-24, task 130: `plan 27: hand-entered bookings, the Time page and the Quit button` drops the time_log table (migration), TimeEntry, the time API, the Time page, nav entry and hour helpers, the own-time metrics (hours, profit per hour, own-time value, profit after own time) and the hourly_value_cop setting; `decision 44: the per-day view starts on the first day any input is spread over, without blocked days or own time` supersedes decision 32; `decision 6: own time is stored in whole minutes` is moot. These run before `plan 25: USD inside, exchange rates fetched automatically` converts settings and metrics to USD.');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (31, 'Quit button: remove it, or keep it with a clearer name?', 'answered', '["keep it, renamed ''Stop app'', with a hover hint: stops the program on this computer and takes a backup; the browser tab can then be closed", "remove it: stop the program with Ctrl-C in its terminal; the page after stopping goes too"]', 'Backups also happen daily by the timer (if enabled) and whenever the program stops for any reason, so removing the button loses no backups. Without it, the program is stopped from the terminal (Ctrl-C) or by logging out; if the app is started from a desktop launcher without a terminal, the button is the only easy way.', 'The app is a small program running on your own computer; the browser only shows it, so closing the browser tab leaves the program running. The Quit button stops that program and takes a backup of the books, the same as pressing Ctrl-C in the terminal where it was started. The answer decides whether the button stays with a name that says this, or goes away.', 'remove it: stop the program with Ctrl-C in its terminal; the page after stopping goes too

this is a server app now. it never stops. we need a different mechanism for the backup.', NULL, '2026-10-24T03:17:56Z', '2026-10-24T03:43:16Z', 124, NULL, 'once', NULL, '2026-10-24, task 130: `plan 27: hand-entered bookings, the Time page and the Quit button` removes the Quit button, the stopped page, POST /api/quit and the shutdown plumbing; the app stops with Ctrl-C or SIGTERM. Since the app runs as a server that never stops, backups no longer rely on exit: `decision 45: backups while the app runs: at start, then every hour when something changed, plus at stop`, with the last backup shown on the Settings page.');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (32, 'the per-day view starts on the first day any input is spread over, without blocked days', 'answered', '[]', 'Blocked days are removed completely (`plan 23: masterplan`, part 1), so they drop out of the start-date rule; everything else in decision 21 stays. With no blocked days every day is available: available nights in a period = the days of the period. If the Time page goes too (`decision 30: Time page: remove the log of your own hosting hours, or keep it and explain it?`), ''time entry'' drops out in the same way.', 'The day-by-day breakdown of the books has to begin somewhere: by default it starts on the earliest day that anything (a stay, an expense, an hour of own work) touches. Days the owner marked as unavailable used to count too, but that feature is being removed, so they no longer play a part in where the breakdown starts.', 'default start = earliest check-in, time entry, or first day an expense is spread over (the 1st of the month for fixed and per-night costs, the check-in day or first night for per-booking costs); supersedes `decision 21: the per-day view starts on the first day any input is spread over`', NULL, '2026-10-24T03:19:41Z', '2026-10-24T03:19:41Z', 126, NULL, 'rule', 126, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (33, 'Grant task 127: write the plan for part 2: USD inside, exchange rates fetched automatically web access (WebSearch, WebFetch)', 'answered', '["approve"]', '', 'The next piece of work needs to look things up on the internet: search the web and read web pages. Approving allows that for this piece of work only.', 'approve', NULL, '2026-10-24T03:20:05Z', '2026-10-24T03:42:27Z', NULL, 'web', 'rule', NULL, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (34, 'money is stored in US cents, and every converted entry keeps what was typed', 'answered', '[]', '- Expenses: `amount` (USD cents, NULL while waiting for a rate) plus `original_minor`, `currency`, `rate`, `rate_date`.
- Recurring templates keep their amount in their own currency (`amount_minor` + `currency`), unconverted; each generated expense is converted on its own date.
- Booking lines: `amount_cop` goes; per line `amount_usd`, `service_fee_usd`, `gross_usd` (computed in Python, so the `booking_totals` view only sums) plus `rate` and `rate_date`. `decision 5: booking money totals are derived from booking lines, not stored` still holds.
- One rate scale (x 1 000 000) fits both COP (3185.01 per USD, 2 decimals) and EUR (0.88292 per USD, 5 decimals) as integers; integer arithmetic only, as today.
- `money.py`, `metrics.py`, `allocation.py`, dashboard JSON and tests work in USD cents; metrics stay integer and unit-agnostic.', 'The books switch from Colombian pesos to US dollars as their single internal currency. Every amount is kept in whole US cents, and anything that was entered or imported in pesos or euros also keeps its original amount, currency, the exchange rate used and the date of that rate, so each conversion can be checked and redone.', 'amounts in USD cents (INTEGER); each converted entry stores original amount (minor units), currency, rate (currency units per USD x 1 000 000) and rate date; usd = original_minor x 1 000 000 / rate, rounded half away from zero; USD entries use rate 1 000 000 and need no fetch', NULL, '2026-10-24T03:46:31Z', '2026-10-24T03:46:31Z', 127, NULL, 'rule', 127, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (35, 'exchange rates: TRM from datos.gov.co for COP, ECB via Frankfurter for EUR, cached per day', 'answered', '[]', 'Checked 2026-10-24:
- **COP** `GET https://www.datos.gov.co/resource/32sa-8pi3.json` with `$where=vigenciahasta >= ''A'' AND vigenciadesde <= ''B''`, `$order=vigenciadesde`, `$limit=50000` (default page size is 1000). Answer: `[{"valor":"3185.01","unidad":"COP","vigenciadesde":"2026-10-23T00:00:00.000","vigenciahasta":"2026-10-23T00:00:00.000"}]`. A rate is valid from vigenciadesde to vigenciahasta (a Friday rate covers the weekend); the next day''s rate is published the afternoon before. No key needed (an optional app token only lifts throttling).
- **EUR** `GET https://api.frankfurter.dev/v2/rates?base=USD&quotes=EUR&from=A&to=B&providers=ECB`. Answer: `[{"date":"2022-01-03","base":"USD","quote":"EUR","rate":0.88067}]`, ECB working days only; a date with no data gives `[]`. v1 (`/v1/A..B`) is deprecated (Deprecation header, successor v2), so v2 is used. Without `providers=ECB` v2 blends sources and returns weekend values; ECB keeps it one official source. The ECB does not publish COP; Frankfurter''s BANREP COP copy misses some dates, so COP comes from datos.gov.co directly.
- Not chosen: fawazahmed0 currency-api (history only from 2024-03; the books start 2021); keyed APIs.
- **Rate for a day d:** latest cached rate dated on or before d, if d is within the currency''s coverage. Coverage (new table, e.g. `rate_coverage(currency, through)`): COP = latest vigenciahasta received; EUR = min(requested end, yesterday). A miss fetches the range [d - 10 days, d] (or one range spanning all pending dates), stores every rate received and moves coverage forward, so each date is fetched once.
- **Dates after coverage** (future check-ins, today''s EUR rate before the ECB publishes): converted provisionally with the latest known rate (rate_date < reference date) and re-converted automatically once coverage reaches the date.
- HTTP: stdlib `urllib`, 10 s timeout, a User-Agent naming the app; no new dependency. Tests never use the network (recorded JSON fixtures, fetcher injected or monkeypatched).
- This replaces the spec rule ''no network access'' for exchange rates only; the bundle still needs no CDN or web fonts.', 'To turn pesos and euros into dollars the app needs the exchange rate of each day, and it now fetches them itself instead of having them typed in. Pesos use Colombia''s official daily rate, published by the government as open data; euros use the European Central Bank''s daily rate. Both are free and need no account, and each rate is fetched once and then kept in the books.', 'COP: datos.gov.co dataset 32sa-8pi3 (official TRM, SODA JSON API); EUR: Frankfurter v2 with providers=ECB; both keyless; fetched by date range with Python''s urllib, cached in exchange_rates (rebased: currency units per USD x 1 000 000) with a per-currency coverage date', NULL, '2026-10-24T03:46:31Z', '2026-10-24T03:46:31Z', 127, NULL, 'rule', 127, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (36, 'reference date of a conversion: check-in for Airbnb income, the entry''s own date for expenses', 'answered', '[]', '- Replaces ''latest rate on or before the line date'' from the architecture spec: an Airbnb booking''s lines all use the check-in, so a booking''s total is converted at one rate.
- Hand-entered bookings stay (`decision 29: Hand-entered bookings: remove the ''New booking'' button so that all income comes from the Airbnb CSV?`, answered ''keep it''); their Manual line is converted like an Airbnb line.
- A check-in in the future is converted provisionally (see `decision 35: exchange rates: TRM from datos.gov.co for COP, ECB via Frankfurter for EUR, cached per day`).', 'An amount in pesos or euros becomes a different dollar amount depending on which day''s exchange rate is used, so each kind of entry needs a fixed day whose rate applies. Income from a stay uses the first day of the stay, an expense uses its own date, and a monthly expense uses the first of its month.', 'every line of a booking (Airbnb or hand-entered) uses the booking''s check-in; an expense its date; a generated monthly expense the 1st of its month (its date per decision 9); changing that date, the amount or the currency re-converts the entry', NULL, '2026-10-24T03:46:31Z', '2026-10-24T03:46:31Z', 127, NULL, 'rule', 127, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (37, 'when no exchange rate can be fetched, entries are saved and wait for their rate', 'answered', '[]', '- Save of a single entry: tries to fetch at once (10 s timeout); on failure it is saved anyway, and the response carries a warning notice like ''Saved. No COP rate for 2026-10-23 yet (no connection?); this expense is left out of the figures until the rate is fetched.''
- Import: lines are stored, conversion is tried once with one range request per currency; the summary says how many lines wait.
- One notice on the dashboard, bookings and expenses screens while anything waits: ''N entries wait for an exchange rate and are left out of the figures'', with a ''Fetch rates now'' button (`POST /api/rates/fetch`). It replaces today''s ''needs exchange rate'' notices and their links to the Rates page.
- Only network, HTTP and response-format errors count as ''no rate''; they are logged on stderr, never crash a request.', 'The app runs on the owner''s computer and may be offline, or a rate service may be down, exactly when an expense is typed or a file imported. Instead of refusing the entry, the app saves it with what was typed, leaves it out of the dollar figures for now, says so on screen, and converts it as soon as a rate can be fetched.', 'saving and importing never fail for lack of a rate: the entry is stored with its original amount and USD NULL (''waiting for a rate''); waiting entries are left out of figures; a warning says so; conversion is retried on app start, before the dashboard is built, after each save and import, and by a ''Fetch rates now'' button', NULL, '2026-10-24T03:46:46Z', '2026-10-24T03:46:46Z', 127, NULL, 'rule', 127, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (38, 'existing peso books are converted by the app itself after the migration', 'answered', '[]', '- Expenses: old `amount` (whole COP) becomes `original_minor = amount * 100`, `currency = ''COP''`. Recurring templates likewise (`amount_minor`, `currency`). Booking lines keep `amount_minor`/`currency`; `rate`, `amount_cop` go. Settings: see `decision on settings amounts` recorded with it.
- Old `exchange_rates` rows (COP per USD in hundredths, typed or from the TRM CSV) are dropped; the TRM is refetched, which is the same source.
- The backup before migrating already exists (`decision 19: backups: which files are pruned, how many are kept, and what a failed backup does`).
- Offline on first start: the books show the waiting notice until a fetch succeeds; nothing is lost.
- The worker checks the result on a copy of the owner''s database when one exists (`$XDG_DATA_HOME/rios-de-asia-accounting/books.db`), never on the original.', 'The books kept so far are in pesos and have to become dollars, which needs the historical rate of every past date involved. A database upgrade marks every existing amount as ''in pesos, waiting for a rate'', and the app then fetches the rates it needs in two requests and converts everything, the same way it handles any entry that waits for a rate.', 'a plain SQL migration keeps every old amount as the original (COP, or the line''s own currency) with USD NULL and drops the old rates; the regular ''convert waiting entries'' step fetches and converts on the next start; no one-off command', NULL, '2026-10-24T03:46:46Z', '2026-10-24T03:46:46Z', 127, NULL, 'rule', 127, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (39, 'money entry: an amount with a currency choice (USD, COP, EUR)', 'answered', '[]', '- Supersedes `decision 15: data entry forms: how money and hours are typed` for money and exchange rates (rates are no longer typed). Its hours rule stays as long as the time log exists: decimal (1.5 or 1,5) or h:mm (1:30), stored as whole minutes.
- The API takes `amount` + `currency` and parses server-side (still authoritative per `decision 24: client-side framework: React with TypeScript, built by Vite, on top of a JSON API from the existing Python server`); `format.ts` mirrors `forms.py`.
- Examples: COP ''1.234.567'' = 1 234 567 pesos; USD ''1,234.50'' and ''1.234,50'' = 1234.50; USD ''1.234'' = 1234.00.
- Lists show the USD amount; non-USD entries also show the original (''4.500.000 COP''), with rate and rate date on hover. Per-currency display formats are left to `plan 23: masterplan` part 3 (display currency).', 'Until now every amount was typed in whole pesos. Now each money field gets a small currency choice next to it (US dollars, pesos or euros), so a bill can be typed exactly as it was paid and the app converts it. Pesos are still typed without cents, dollars and euros with up to two decimals.', 'amount field + currency select (USD / COP / EUR) on expenses, recurring templates, hand-entered bookings and settings; COP: whole pesos as before; USD/EUR: up to 2 decimals, the last . or , followed by 1-2 digits at the end is the decimal mark, other . , and spaces are thousands separators; the select defaults to the currency of the most recently saved expense, USD when there is none; until the display-currency part, figures show in USD as 1.234,56; hours unchanged', NULL, '2026-10-24T03:47:07Z', '2026-10-24T03:47:07Z', 127, NULL, 'rule', 127, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (40, 'the Rates page, typed rates and the TRM file import go; no offline fallback', 'answered', '[]', '- Why no fallback: the owner asked for automatic rates; offline periods are handled by entries waiting for their rate (`decision : when no exchange rate can be fetched, entries are saved and wait for their rate`). If a source disappears for good, swapping the fetcher is a small code change.
- The SODA JSON parsing replaces `trm_csv.py` (same fields, lower-case names, ISO timestamps).', 'Exchange rates used to be typed in by hand or loaded from a downloaded file, which is what the confusing Rates page was for. Since the app now fetches rates itself, that page, the file import for rates and the ''this stay needs an exchange rate'' warnings go; a single notice about entries still waiting for a rate replaces them.', 'remove the Rates page and nav entry, /api/rates CRUD, the TRM CSV import (CLI import-rates, Import page section, /api/import/rates, importer/trm_csv.py and its fixture/tests) and the ''needs exchange rate'' notices; add POST /api/rates/fetch for the retry button; no manual rate entry as fallback', NULL, '2026-10-24T03:47:07Z', '2026-10-24T03:47:07Z', 127, NULL, 'rule', 127, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (41, 'settings amounts are stored in USD and typed in any currency at the rate of the day they are saved', 'answered', '[]', '- The settings form shows what was typed (amount and currency) and the USD value with its rate date.
- `long_term_rent_cop_per_month` goes. `decision 30: Time page: remove the log of your own hosting hours, or keep it and explain it?` removes `hourly_value_cop`; if that removal has not run yet when the USD switch is done, `hourly_value_cop` gets the same treatment (`hourly_value_usd`, `hourly_value_entered`).
- The `currency` setting stays for the display currency part.', 'Settings hold one benchmark amount, the monthly rent the apartment would earn as a long-term rental, which the dashboard compares with the Airbnb result. It is typed with a currency choice like any other amount, converted with that day''s rate, and stored in dollars together with what was typed.', 'long-term rent: settings key long_term_rent_usd (cents) plus long_term_rent_entered (JSON: original_minor, currency, rate, rate_date), converted at the save day''s rate; the migration turns the old peso value into a waiting entry converted at the rate of the day of the first start; the hourly value goes with the time log (decision 30), else it is handled the same way', NULL, '2026-10-24T03:47:07Z', '2026-10-24T03:47:07Z', 127, NULL, 'rule', 127, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (42, 'Grant task 128: write the plan for part 3: display currency web access (WebSearch, WebFetch)', 'answered', '["approve"]', '', 'The next piece of work needs to look things up on the internet: search the web and read web pages. Approving allows that for this piece of work only.', 'approve', NULL, '2026-10-24T03:47:51Z', '2026-10-24T13:58:28Z', NULL, 'web', 'rule', NULL, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (43, 'editing an expense or recurring template stays on its own page; only new entries are typed inline', 'answered', '[]', 'The inline row would only come for free if editing were just the same inputs. It isn''t: the expense edit page has the delete dialog and the ''generated from a recurring expense'' note, and the recurring page shows decision 16''s explanation plus its generated expenses. Moving those into the table means a second interaction design (row actions, delete confirmation inside the sheet, an expandable detail), which is the extra cost the masterplan rules out. Revisit if the owner asks for inline editing.', 'The owner wants new expenses typed straight into a row of the expense table instead of on a separate page. Changing an existing entry could work the same way, but its page also offers deleting, explains where a generated expense came from, and for a recurring expense lists the months already created. Keeping editing on that page means none of this has to be rebuilt inside the table.', 'only the new-entry row is inline; existing rows keep linking to their edit page (expenses) and detail page (recurring templates), unchanged', NULL, '2026-10-24T03:49:03Z', '2026-10-24T03:49:03Z', 129, NULL, 'rule', 129, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (44, 'the per-day view starts on the first day any input is spread over, without blocked days or own time', 'answered', '[]', 'The Time page and the time log go (`decision 30: Time page: remove the log of your own hosting hours, or keep it and explain it?`), so ''time entry'' drops out of the rule of `decision 32: the per-day view starts on the first day any input is spread over, without blocked days`; everything else stays.', 'The day-by-day breakdown of the books starts by default on the earliest day that anything touches. The log of the owner''s own working hours is being removed, so hours of work no longer play a part in where the breakdown starts; stays and expenses still do.', 'default start = earliest check-in, or first day an expense is spread over (the 1st of the month for fixed and per-night costs, the check-in day or first night for per-booking costs)', NULL, '2026-10-24T03:50:47Z', '2026-10-24T03:50:47Z', 130, NULL, 'rule', 130, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (45, 'backups while the app runs: at start, then every hour when something changed, plus at stop', 'answered', '[]', 'The owner: ''this is a server app now. it never stops. we need a different mechanism for the backup.'' Backing up only at exit (and with the Quit button gone, `decision 31: Quit button: remove it, or keep it with a clearer name?`) would mean no backups at all unless the systemd timer module is enabled. An in-process thread needs no setup. One file per day keeps the naming and pruning of `decision 19: backups: which files are pruned, how many are kept, and what a failed backup does` unchanged; hourly overwriting of today''s file bounds data loss to an hour, and skipping unchanged hours keeps Dropbox quiet. The failure is shown on screen because nobody reads a server''s stderr.', 'The app used to copy its database to the backup folder when the owner closed it. It now runs as a server that is never closed, so it has to make its copies by itself while it runs. It copies the books when it starts and then once an hour if anything was changed, so at most an hour of work can be lost, and it shows on the Settings page when the last copy was made or why it failed.', 'serve starts a background thread: a backup right after start, then every hour, skipped when nothing was written since the last one (PRAGMA data_version on the thread''s own connection, or the db/-wal modification time); each writes today''s books-YYYY-MM-DD.db (same-day overwrite, pruning as decision 19); still one at stop (Ctrl-C, SIGTERM); a failure goes to stderr and is shown on the Settings page (last backup time and file, or the last error), never stops the app; the optional systemd timer module stays', NULL, '2026-10-24T03:50:47Z', '2026-10-24T03:50:47Z', 130, NULL, 'rule', 130, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (46, 'display currency: amounts are converted in the browser, the server keeps answering in USD', 'answered', '[]', '- Every money value the API sends (lists, totals, dashboard JSON, booking lines, settings) stays USD cents; only a new display endpoint knows the display currency and its rate.
- The client converts with one function: display minor units = round(usd_cents × rate / 1 000 000) (rate as stored by `decision 35: exchange rates: TRM from datos.gov.co for COP, ECB via Frankfurter for EUR, cached per day`: currency units per USD × 1 000 000; COP minor units are centavos, shown as whole pesos).
- Totals are converted from the server''s USD total, not summed from converted rows; a peso of rounding difference between a column and its total is accepted.
- Charts get converted series, so their axis ticks are round numbers in the display currency.
- Why: server-side conversion would touch every endpoint, the dashboard builder and their tests; client-side is one helper in `format.ts` plus a context, and the API stays what the books are.
- Not converted: what was typed (original amounts, rates and rate dates in hover texts and edit forms) stays in its own currency.', 'The owner wants to look at all figures in US dollars, Colombian pesos or euros, while the books themselves stay in dollars. The conversion can happen either where the data is served or in the screen that shows it. Doing it in the screen keeps every data answer unchanged and puts the conversion in one place.', 'the API keeps returning USD cents; the client multiplies by the one display rate when it formats money, and converts chart series before plotting', NULL, '2026-10-24T13:59:30Z', '2026-10-24T13:59:30Z', 128, NULL, 'rule', 128, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (47, 'display currency: number formats per currency', 'answered', '[]', '- Same marks as money entry in `decision 39: money entry: an amount with a currency choice (USD, COP, EUR)`, so a figure shown can be typed back as is; the existing `formatAmount(minor, currency)` already does this.
- No $ or € symbols: $ is ambiguous (USD vs COP). Column headings and dashboard labels carry the code, e.g. "Amount (COP)", "ADR and RevPAR (EUR)", "COP unless stated".
- Pesos round to whole pesos (half away from zero) when shown; nothing is abbreviated (no "4,2 M"), chart axes included.', 'Once figures can be shown in dollars, pesos or euros, each needs a fixed way of being written. Pesos have no cents worth showing, while dollars and euros do, and the symbol $ means both dollars and pesos in Colombia. This settles how numbers and currency names appear.', 'COP whole pesos (1.234.567), USD and EUR with two decimals (1.234,56); . groups thousands and , marks decimals for all three; the currency is named by its code (USD, COP, EUR), never a symbol', NULL, '2026-10-24T13:59:31Z', '2026-10-24T13:59:31Z', 128, NULL, 'rule', 128, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (48, 'display currency: kept in settings with the rate fetched when it was chosen, switched and shown in the page header', 'answered', '[]', '- Settings key `currency` (already exists, default `COP` from before the USD books) becomes the display currency, default and migrated value `USD`; new key `display_rate`: JSON `{rate, rate_date}` (currency units per USD × 1 000 000, the date the rate is for). USD: rate 1 000 000, no fetch, no rate line.
- `GET /api/display` → `{currency, rate, rate_date, currencies}`; `PUT /api/display {currency}` fetches today''s rate with the existing cache and fetchers (`conversion.rate_on(conn, currency, today)`, which uses the latest rate on or before today, e.g. yesterday''s ECB rate in the morning) and stores both. No rate at all: 422-style refusal with a warning notice (''No COP rate could be fetched (no connection?); figures stay in USD.'') and nothing changes.
- The rate stays until the owner switches again (choosing the same currency again refreshes it); it is not refreshed on start. The header line always shows the rate and its date, so an old rate is visible as such.
- The switch lives in the header on every screen, not on the Settings page, since it is a viewing choice.
- Builds on `decision 37: when no exchange rate can be fetched, entries are saved and wait for their rate` only in spirit: the books never depend on the display rate.', 'The owner picks the currency figures are shown in, and the app fetches the day''s exchange rate once at that moment. That choice and its rate have to survive a page reload, be visible on every screen, and behave sensibly when there is no connection. This settles where they are kept, where the switch sits and what it says.', 'settings ''currency'' (USD default) plus ''display_rate'' {rate, rate_date}; a USD/COP/EUR select in the header next to the navigation with ''1 USD = 4.123,45 COP · rate of 2026-10-23'' beside it; switching fetches today''s rate, and if none can be had the switch stays where it was with a warning', NULL, '2026-10-24T13:59:31Z', '2026-10-24T13:59:31Z', 128, NULL, 'rule', 128, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (49, 'editing expenses and recurring templates happens inline in the sheet, like adding', 'answered', '[]', 'The owner asked for it directly (2026-10-24): ''i can add expenses or recurring expenses, but i want to edit them too. Make sure that adding and editing follow the inline (spreadsheet-inspired) style.'' This revisits decision 43 as it invited.', 'The owner wants to change existing expenses and monthly recurring expenses right in the table, the same way new ones are typed in, instead of on a separate page. Adding and editing should look and behave the same: a row of the spreadsheet turns into inputs, Enter saves, Escape cancels.', 'existing rows are edited in place: the row turns into the same entry inputs as the new-entry row; the separate expense edit page goes away', NULL, '2026-10-24T14:00:21Z', '2026-10-24T14:00:21Z', NULL, NULL, 'rule', NULL, '');

INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (1, 1, '2026-10-23T19:14:37Z', '2026-10-23T19:15:40Z', 'done', NULL, 0, 'cd3d42740dd5ea9c8707207210ebd4e93c9b80c8', NULL, 'claude-opus-5-5', '0b74794a-06e2-4f40-8b9d-b839a74c0101', NULL, 6, 12, 5937, 151146, 39344, 0.46376920000000005, 39881, 60, 1445179);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (2, 2, '2026-10-23T19:19:04Z', '2026-10-23T19:19:45Z', 'done', NULL, 0, 'c3af31b31bf19a0c813d5df39657354d2953594e', NULL, 'claude-opus-5-5', 'a4465501-56c2-4e5c-ada6-af51d0d966e0', NULL, 6, 12, 4235, 176178, 25654, 0.32521560000000005, 37524, 60, 1445179);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (3, 3, '2026-10-23T19:19:43Z', '2026-10-23T19:20:09Z', 'done', NULL, 0, 'c3af31b31bf19a0c813d5df39657354d2953594e', 'main', 'claude-opus-5-5', '01926aa8-ee58-49d7-91fc-650df71b6aec', NULL, 5, 10, 2222, 133821, 21726, 0.2450522, 34030, 60, 1445179);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (4, 4, '2026-10-23T19:20:09Z', '2026-10-23T19:20:33Z', 'blocked', NULL, 0, '6a3272656efbeb1bea37f1fc625c67460287cf82', 'main', 'claude-opus-5-5', '84de8f30-0785-4cd1-aef7-2d3866387edf', NULL, 8, 18, 1805, 241242, 24471, 0.2801884, 36595, 60, 1445179);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (5, 12, '2026-10-23T19:21:24Z', '2026-10-23T19:21:47Z', 'done', NULL, 0, '654e8a9c2e37d79153b5e55867d5c3b03396d2b6', NULL, 'claude-opus-5-5', '84937f15-3aa1-4610-bc16-56d19b29a803', NULL, 4, 8, 1712, 96033, 18932, 0.20493460000000002, 31072, 60, 1445179);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (6, 13, '2026-10-23T19:21:42Z', '2026-10-23T19:24:17Z', 'done', NULL, 0, '654e8a9c2e37d79153b5e55867d5c3b03396d2b6', 'main', 'claude-opus-5-5', 'fdbad895-093f-464b-9810-8678ba0124a4', NULL, 12, 24, 13704, 500149, 45430, 0.73764580000000013, 57973, 60, 1445179);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (7, 4, '2026-10-23T19:30:27Z', '2026-10-23T19:31:01Z', 'done', NULL, 0, '0766499f96e5ec1095e40bd31fac6b92b64ec68f', 'main', 'claude-opus-5-5', '869dd62e-2f9b-49dc-b80d-1f809d81f989', NULL, 5, 10, 2761, 142842, 26526, 0.2960364, 38881, 60, 1445179);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (8, 5, '2026-10-23T19:31:01Z', '2026-10-23T19:32:33Z', 'done', NULL, 0, '0b54e9390ae721fdc3a528419ebceb7f0a4c7cc1', 'main', 'claude-opus-5-5', 'd772841c-911f-47dd-91bf-deee0dd412b6', NULL, 10, 16, 8834, 289545, 36949, 0.530245, 48826, 60, 1445179);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (9, 6, '2026-10-23T19:35:06Z', '2026-10-23T19:36:53Z', 'done', NULL, 0, 'd28c4c716bb75498d9928ba2cf2c00cebbafe1bf', 'main', 'claude-opus-5-5', '2949abf9-e80f-4898-9528-6a9ed7e06b29', NULL, 8, 16, 8563, 312392, 43878, 0.5848264, 56408, 60, 1460586);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (10, 7, '2026-10-23T19:41:23Z', '2026-10-23T19:43:14Z', 'done', NULL, 0, '8e1b463123b617d25b65d9c12fceae8d0d7586ca', 'main', 'claude-opus-5-5', 'ad4f49e5-a5fe-4efc-b9fd-ae1814d81664', NULL, 10, 20, 6892, 373344, 35669, 0.4979408, 48201, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (11, 14, '2026-10-23T19:41:23Z', '2026-10-23T19:41:44Z', 'done', NULL, 0, '8e1b463123b617d25b65d9c12fceae8d0d7586ca', NULL, 'claude-opus-5-5', '7f9419d8-f86c-4ed0-b810-59070d227c1a', NULL, 4, 8, 2241, 96301, 19679, 0.2215442, 31832, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (12, 15, '2026-10-23T19:41:44Z', '2026-10-23T19:42:21Z', 'done', NULL, 0, '3a2623f7867eb0c18873799205de4e255470d830', NULL, 'claude-opus-5-5', 'c47d5de1-9425-4e8b-a177-ecaec82f9d8a', NULL, 4, 8, 4104, 109688, 27639, 0.3251616, 39925, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (13, 16, '2026-10-23T19:42:21Z', '2026-10-23T19:43:02Z', 'done', NULL, 0, '5f7f1a734c53ffaef29527306d43434131a15c4f', NULL, 'claude-opus-5-5', '5d7ed1a3-5407-4a3c-b7cb-49ee38acc8db', NULL, 5, 10, 2909, 146295, 26485, 0.299359, 38697, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (14, 23, '2026-10-23T19:43:02Z', '2026-10-23T19:43:22Z', 'done', NULL, 0, 'b6312108c4c568ec4b005c4754a5e0ff0112592f', NULL, 'claude-opus-5-5', '2540e656-fb3d-49bb-839c-1a0f564d1d08', NULL, 3, 6, 1959, 70347, 23424, 0.24066539999999997, 35591, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (15, 8, '2026-10-23T19:43:14Z', '2026-10-23T19:44:57Z', 'done', NULL, 0, 'b6312108c4c568ec4b005c4754a5e0ff0112592f', 'main', 'claude-opus-5-5', '7ce03cb8-59ca-47ac-ae04-21190ab50146', NULL, 11, 22, 10641, 434769, 41000, 0.6278618, 53570, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (16, 29, '2026-10-23T19:44:22Z', '2026-10-23T19:45:10Z', 'done', NULL, 0, '0d7c14b00e7235476057dea7716f6ac435e04a83', NULL, 'claude-opus-5-5', '9b85e8b5-34a4-4b8c-b492-f4c3900299dd', NULL, 6, 12, 4389, 205373, 35840, 0.4156226, 48222, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (17, 9, '2026-10-23T19:44:57Z', '2026-10-23T19:46:45Z', 'done', NULL, 0, '0d7c14b00e7235476057dea7716f6ac435e04a83', 'main', 'claude-opus-5-5', '3bf62a14-25f5-4b7f-8e82-1f53f2650eea', NULL, 8, 16, 8840, 322352, 45798, 0.6077184000000001, 58377, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (18, 30, '2026-10-23T19:45:10Z', '2026-10-23T19:45:27Z', 'done', NULL, 0, 'a464701117b5d7059b03c81d06513ea37c81384d', NULL, 'claude-opus-5-5', 'fb2fc270-84a3-452e-b977-298ffb385526', NULL, 4, 8, 717, 113661, 28172, 0.2624802, 40268, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (19, 35, '2026-10-23T19:46:36Z', '2026-10-23T19:47:31Z', 'done', NULL, 0, 'a8fa68692dc46c04958671f49c502ab49c9ee357', NULL, 'claude-opus-5-5', '871c309e-4819-4b09-914a-7751cc7d2271', NULL, 10, 20, 5831, 345005, 32128, 0.44272499999999992, 44391, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (20, 10, '2026-10-23T19:46:45Z', '2026-10-23T19:47:55Z', 'done', NULL, 0, 'a8fa68692dc46c04958671f49c502ab49c9ee357', 'main', 'claude-opus-5-5', 'b680badb-d1d7-4dfb-86b9-824d30f2f5f9', NULL, 10, 20, 4693, 405832, 41885, 0.5101864, 54385, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (21, 42, '2026-10-23T19:47:43Z', '2026-10-23T19:48:33Z', 'done', NULL, 0, '0acf1aed2824d3f41eb0046b0a673c0fd6f12c47', NULL, 'claude-opus-5-5', 'a324808b-955c-4092-a048-bdd5c400e144', NULL, 9, 18, 5472, 292183, 29225, 0.4017486, 41517, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (22, 11, '2026-10-23T19:47:55Z', '2026-10-23T19:49:29Z', 'done', NULL, 0, '0acf1aed2824d3f41eb0046b0a673c0fd6f12c47', 'main', 'claude-opus-5-5', '839d4b95-bc9d-4592-9a4c-9e3cd56419c2', NULL, 9, 18, 6398, 312355, 35957, 0.478159, 48533, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (23, 46, '2026-10-23T19:49:15Z', '2026-10-23T19:50:10Z', 'done', NULL, 0, '122cf5bcf3c236ae4bb40ab8ac5bc02a09bf8132', NULL, 'claude-opus-5-5', 'af3db05b-fb4e-4d3c-940b-30ffb561f0b1', NULL, 8, 16, 4304, 251039, 29900, 0.37555179999999994, 42174, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (24, 17, '2026-10-23T19:49:30Z', '2026-10-23T19:50:06Z', 'done', NULL, 0, '122cf5bcf3c236ae4bb40ab8ac5bc02a09bf8132', 'main', 'claude-sonnet-5-5', 'cb74b131-b982-40e0-bb65-605beb46eb69', NULL, 6, 12, 2984, 143565, 31838, 0.17157250000000002, 32256, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (25, 18, '2026-10-23T19:50:06Z', '2026-10-23T19:50:33Z', 'done', NULL, 0, 'a4d6b79501457f8aa9be917248fa582833c0fa71', 'main', 'claude-sonnet-5-5', 'cb74b131-b982-40e0-bb65-605beb46eb69', 24, 4, 8, 1313, 143616, 7553, 0.2292921, 39733, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (26, 19, '2026-10-23T19:50:33Z', '2026-10-23T19:51:11Z', 'done', NULL, 0, '8c7c652bd8f328443e6dae1a404f044e38ada8f9', 'main', 'claude-sonnet-5-5', 'ea329ab3-65f7-42d9-8b83-6eac559557fc', NULL, 7, 12, 5391, 171914, 25098, 0.17151740000000001, 37566, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (27, 20, '2026-10-23T19:51:12Z', '2026-10-23T19:52:22Z', 'done', NULL, 0, '5f25811aa0f8b8ef2b2e90e9216002bcb7cf67fb', 'main', 'claude-sonnet-5-5', 'ea329ab3-65f7-42d9-8b83-6eac559557fc', 26, 7, 14, 8938, 346017, 19377, 0.3730351, 56705, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (28, 21, '2026-10-23T19:52:22Z', '2026-10-23T19:53:22Z', 'done', NULL, 0, '65ce30d95a6346c560fe850ab8e092f6f419ff01', 'main', 'claude-sonnet-5-5', 'ea329ab3-65f7-42d9-8b83-6eac559557fc', 27, 4, 8, 9355, 256109, 17181, 0.5609360000000001, 74066, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (29, 22, '2026-10-23T19:53:22Z', '2026-10-23T19:54:33Z', 'done', NULL, 0, '37947027ebf9ff1ddf9ebb2aa7fb8a9b4b4de98b', 'main', 'claude-sonnet-5-5', 'ea329ab3-65f7-42d9-8b83-6eac559557fc', 28, 5, 10, 10272, 417592, 18440, 0.77919520000000009, 92483, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (30, 31, '2026-10-23T19:54:33Z', '2026-10-23T19:55:47Z', 'done', NULL, 0, 'f4b126594782901805820eb1b09afd4868b68454', 'main', 'claude-sonnet-5-5', 'c087f18b-a96f-4e43-86d8-9f17be2f4730', NULL, 10, 20, 8819, 351317, 34511, 0.26140569999999996, 46977, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (31, 32, '2026-10-23T19:55:48Z', '2026-10-23T19:57:36Z', 'done', NULL, 0, '2b03d2bb7bda23715614146d8aedc5c9057a7fc8', 'main', 'claude-sonnet-5-5', 'c087f18b-a96f-4e43-86d8-9f17be2f4730', 30, 9, 18, 13149, 589806, 33201, 0.58471630000000008, 80278, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (32, 33, '2026-10-23T19:57:36Z', '2026-10-23T19:58:13Z', 'done', NULL, 0, 'a3391ef94edad483321b0f4a24bce9d143879f05', 'main', 'claude-sonnet-5-5', '3de9937b-e624-47c2-bb03-a53cbc801ac0', NULL, 8, 16, 3756, 250401, 27352, 0.17204010000000003, 39742, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (33, 24, '2026-10-23T19:58:43Z', '2026-10-23T19:59:57Z', 'done', NULL, 0, '3415ed77e928a722ce54a134e837e83ed2518b9d', 'main', 'claude-opus-5-5', 'ef561f6e-2bb8-4e5e-a1dc-21b94acc45ad', NULL, 8, 16, 6048, 260898, 30305, 0.4156436, 42757, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (34, 25, '2026-10-23T19:59:57Z', '2026-10-23T20:01:15Z', 'done', NULL, 0, 'f240dc736b62bbec0b90631fefa30f4ae5231169', 'main', 'claude-opus-5-5', 'ef561f6e-2bb8-4e5e-a1dc-21b94acc45ad', 33, 8, 16, 6801, 413004, 15943, 0.7618724, 58119, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (35, 26, '2026-10-23T20:01:15Z', '2026-10-23T20:02:09Z', 'done', NULL, 0, 'a5fb21139682c2ff1395ad4c21725cce4de100a4', 'main', 'claude-sonnet-5-5', '47c1893f-0e46-48ea-828a-cebebeae2ac9', NULL, 9, 18, 4154, 296711, 28518, 0.18531910000000001, 40774, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (36, 27, '2026-10-23T20:02:10Z', '2026-10-23T20:03:16Z', 'done', NULL, 0, '42dc341d3d74d8f52ac8dd9c455c6e8368baaf5a', 'main', 'claude-opus-5-5', '4ddc6886-6b33-4f93-a867-ee046d95afdb', NULL, 9, 18, 7303, 293905, 29390, 0.44003299999999995, 41960, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (37, 28, '2026-10-23T20:03:16Z', '2026-10-23T20:04:15Z', 'done', NULL, 0, '238f506d3ec5854a3edd09d85abc87625a29f0c9', 'main', 'claude-sonnet-5-5', 'cb173597-0df2-44ee-ae75-c2ba80f4ced6', NULL, 11, 22, 4519, 344533, 25498, 0.1816793, 37920, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (38, 36, '2026-10-23T20:04:15Z', '2026-10-23T20:05:41Z', 'done', NULL, 0, '9b5a7d2125c00d40d239da3202cf1ab87fbe7d16', 'main', 'claude-sonnet-5-5', '678a0120-7763-49d0-a368-abb84ad2244f', NULL, 13, 26, 10337, 520685, 38258, 0.3085225, 50666, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (39, 37, '2026-10-23T20:05:41Z', '2026-10-23T20:07:04Z', 'done', NULL, 0, 'fe6654c8ef969ef6f4e5572d2d53ac37c9cdcdda', 'main', 'claude-sonnet-5-5', '678a0120-7763-49d0-a368-abb84ad2244f', 38, 7, 14, 10974, 451576, 24609, 0.56188409999999989, 75339, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (40, 38, '2026-10-23T20:07:04Z', '2026-10-23T20:08:23Z', 'done', NULL, 0, 'b79e07602a8280619a98c1a4e99893c2238739c8', 'main', 'claude-sonnet-5-5', '678a0120-7763-49d0-a368-abb84ad2244f', 39, 7, 14, 11223, 612870, 23355, 0.82884909999999989, 98535, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (41, 34, '2026-10-23T20:08:23Z', '2026-10-23T20:10:16Z', 'done', NULL, 0, '491a961c1cddf032e58165f3aa975e65c1ad49e0', 'main', 'claude-sonnet-5-5', 'ae311a7a-1ef2-408a-a874-91b7a8b7497d', NULL, 16, 28, 11564, 555174, 41721, 0.34970570000000006, 54310, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (42, 39, '2026-10-23T20:10:16Z', '2026-10-23T20:11:51Z', 'done', NULL, 0, '669f99349856a91ec0702ea663cbf313e3b59d31', 'main', 'claude-sonnet-5-5', '41b11f89-d445-43a7-85c2-9719f2ddf251', NULL, 12, 24, 9986, 520591, 43926, 0.3276711, 56338, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (43, 40, '2026-10-23T20:11:51Z', '2026-10-23T20:12:56Z', 'done', NULL, 0, 'cb9d895746c8c718b0a0db307c0012c7653a5741', 'main', 'claude-sonnet-5-5', '41b11f89-d445-43a7-85c2-9719f2ddf251', 42, 7, 14, 8590, 473007, 21881, 0.5484238, 78349, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (44, 41, '2026-10-23T20:12:56Z', '2026-10-23T20:14:25Z', 'done', NULL, 0, '710b529cf864f99a56fafb680e38e76e0c5e8f32', 'main', 'claude-sonnet-5-5', '41b11f89-d445-43a7-85c2-9719f2ddf251', 43, 9, 18, 10796, 824945, 25441, 0.8406783000000001, 103807, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (45, 43, '2026-10-23T20:14:26Z', '2026-10-23T20:15:17Z', 'done', NULL, 0, 'e89b14444ab69cc1e36071f063c3026457bff27c', 'main', 'claude-sonnet-5-5', '4307fc5d-d4e2-4248-8092-db70125dfae2', NULL, 8, 16, 5631, 236702, 24405, 0.1776322, 36772, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (46, 45, '2026-10-23T20:15:17Z', '2026-10-23T20:17:06Z', 'done', NULL, 0, 'cc4d92f8a4f807d260efb43e91b091bd7df207b7', 'main', 'claude-sonnet-5-5', '4307fc5d-d4e2-4248-8092-db70125dfae2', 45, 19, 38, 11362, 1152199, 35985, 0.55048809999999993, 72963, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (47, 44, '2026-10-23T20:17:06Z', '2026-10-23T20:17:52Z', 'done', NULL, 0, '1d8293a730b7be0a6a0880ab4c4c0b560e9c4916', 'main', 'claude-sonnet-5-5', '4307fc5d-d4e2-4248-8092-db70125dfae2', 46, 6, 12, 4454, 480308, 12316, 0.6923469, 85227, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (48, 47, '2026-10-23T20:17:53Z', '2026-10-23T20:19:03Z', 'done', NULL, 0, '7bdbecd108ae1118b5a150903345b90a01035f95', 'main', 'claude-sonnet-5-5', '02de1d34-c631-426f-9388-30b2899550b7', NULL, 11, 22, 6224, 379005, 30164, 0.22084050000000002, 42471, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (49, 48, '2026-10-23T20:19:03Z', '2026-10-23T20:23:23Z', 'done', NULL, 0, 'b8f21ee2e781c13144ad8c466a630bb3de1e3fff', 'main', 'claude-sonnet-5-5', '02de1d34-c631-426f-9388-30b2899550b7', 48, 14, 28, 8174, 754972, 20696, 0.46091770000000004, 63362, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (50, 49, '2026-10-23T20:23:23Z', '2026-10-23T20:24:03Z', 'done', NULL, 0, '6f3017a901117fce7d1a000da1b342c2e751af1c', 'main', 'claude-sonnet-5-5', '02de1d34-c631-426f-9388-30b2899550b7', 49, 4, 8, 3095, 268742, 8551, 0.5529619, 71847, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (51, 50, '2026-10-23T20:24:03Z', '2026-10-23T20:24:37Z', 'done', NULL, 0, 'aaadff6a06fbe1b9f79c35f79be708567208aa24', 'main', 'claude-sonnet-5-5', '02de1d34-c631-426f-9388-30b2899550b7', 50, 5, 10, 2929, 389327, 11996, 0.6691886, 83612, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (52, 51, '2026-10-23T20:24:37Z', '2026-10-23T20:30:28Z', 'done', NULL, 0, 'd8d02ae237fa66f6355968b5b843107574ee38ae', 'main', 'claude-opus-5-5', 'a5149d23-d068-4127-8c42-f4f248bd236f', NULL, 44, 80, 24625, 3537707, 110129, 2.0813933999999996, 122764, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (53, 52, '2026-10-23T20:30:28Z', '2026-10-23T20:31:08Z', 'done', NULL, 0, '3f5bf4b0ce5338fa71bcc45711d88cac022a2cb4', 'main', 'claude-sonnet-5-5', '41b1d7bd-7bd6-4811-b724-eaf7146138bb', NULL, 9, 18, 2469, 264541, 23166, 0.1438441, 35520, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (54, 53, '2026-10-23T20:31:05Z', '2026-10-23T20:31:38Z', 'done', NULL, 0, 'f687ca610bde7b564b394f3bdd29833f45d72428', NULL, 'claude-sonnet-5-5', 'a3520e7f-adff-4734-9e2a-94f04fab2c7f', NULL, 12, 22, 2262, 393626, 32375, 0.1915266, 44529, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (55, 54, '2026-10-23T21:28:28Z', '2026-10-23T21:29:32Z', 'done', NULL, 0, 'a6c36b2d356c81bd699f5087a2bf4744e8dcdd7f', NULL, 'claude-sonnet-5-5', 'f0e2794a-2c7d-4ef2-9ed5-aa5a0c4bd8f5', NULL, 11, 20, 2964, 283266, 23191, 0.15077059999999998, 35543, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (56, 55, '2026-10-23T22:34:23Z', '2026-10-23T22:35:47Z', 'done', NULL, 0, 'e72d436169d610d650d95683045afb96bdeaaac0', NULL, 'claude-opus-5-5', 'fb953c8b-92dc-474a-bd50-457f00298ca1', NULL, 10, 18, 6768, 283907, 45013, 0.55231740000000007, 45017, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (57, 56, '2026-10-23T22:35:47Z', '2026-10-23T22:36:18Z', 'done', NULL, 0, '7faa97406f08108a46310f9871a10fc84dd865c2', NULL, 'claude-opus-5-5', 'bf51736c-943f-42e6-abcd-cf051af1b426', NULL, 5, 10, 3052, 144365, 26562, 0.30244899999999997, 38770, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (58, 61, '2026-10-23T22:40:12Z', '2026-10-23T22:42:26Z', 'done', NULL, 0, '8d3c79a692c087a8f89bdc7d42ef13ce6afce0e3', NULL, 'claude-opus-5-5', '01dffd4b-1034-4c1c-858b-36b5d9880892', NULL, 12, 22, 12516, 514152, 54645, 0.79039840000000017, 66516, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (59, 62, '2026-10-23T22:42:26Z', '2026-10-23T22:43:19Z', 'done', NULL, 0, '5511bc35a8fb5cf4ae213a70f0e108cadca60c1b', NULL, 'claude-opus-5-5', '5bcfcb02-50ac-4e6a-aca3-f225874ff936', NULL, 5, 10, 4538, 145023, 27335, 0.3384846, 39817, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (60, 64, '2026-10-23T22:43:14Z', '2026-10-23T22:44:43Z', 'done', NULL, 0, '5511bc35a8fb5cf4ae213a70f0e108cadca60c1b', 'main', 'claude-opus-5-5', '5e892322-f772-44cf-a313-390a1b378158', NULL, 7, 14, 5899, 241613, 38083, 0.47102259999999996, 50644, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (61, 69, '2026-10-23T22:44:31Z', '2026-10-23T22:45:26Z', 'done', NULL, 0, '07b7fee76df1be721d5c0648c64ee45ba600bb57', NULL, 'claude-opus-5-5', '5f5e5acd-1d2f-42f3-a668-df5b2d298ad6', NULL, 9, 18, 4825, 292745, 30810, 0.401601, 43021, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (62, 63, '2026-10-23T22:44:43Z', '2026-10-23T22:45:59Z', 'done', NULL, 0, '07b7fee76df1be721d5c0648c64ee45ba600bb57', 'main', 'claude-opus-5-5', 'cd930a8e-8fad-4ecb-a1ef-daedc8436d20', NULL, 8, 16, 6455, 314434, 41212, 0.5217468, 53765, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (63, 77, '2026-10-23T22:45:41Z', '2026-10-23T22:46:39Z', 'done', NULL, 0, '155278bcbccb6303070875901a3aca9ba1dd40a6', NULL, 'claude-opus-5-5', '836d605f-37b9-4d11-863d-5a43891de1f4', NULL, 5, 10, 5672, 150571, 30466, 0.38732220000000006, 42925, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (64, 65, '2026-10-23T22:46:00Z', '2026-10-23T22:47:27Z', 'done', NULL, 0, '155278bcbccb6303070875901a3aca9ba1dd40a6', 'main', 'claude-opus-5-5', 'ee555f51-39a4-412c-bdb6-61dbd2c5cc9d', NULL, 15, 28, 6832, 559635, 41703, 0.582303, 54271, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (65, 83, '2026-10-23T22:47:12Z', '2026-10-23T22:47:59Z', 'done', NULL, 0, 'afb7dba5b4554916d2f22a1d75797639f6739903', NULL, 'claude-opus-5-5', 'b0b523a3-e6f3-477c-9108-6778f889a9d4', NULL, 6, 12, 3863, 200752, 32331, 0.3761064, 44532, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (66, 66, '2026-10-23T22:47:27Z', '2026-10-23T22:48:52Z', 'done', NULL, 0, 'afb7dba5b4554916d2f22a1d75797639f6739903', 'main', 'claude-opus-5-5', 'a3ec0ab6-1493-43e0-a270-0f1abcbaddb9', NULL, 10, 20, 7763, 452157, 48319, 0.63232340000000009, 60782, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (67, 88, '2026-10-23T22:48:38Z', '2026-10-23T22:49:20Z', 'done', NULL, 0, 'aa3d0dd29506453a93b149b264707e1d1b32aaac', NULL, 'claude-opus-5-5', 'ad16137b-2b98-4053-98b7-888c31a2b73c', NULL, 9, 18, 3358, 261218, 23736, 0.3093636, 35610, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (68, 67, '2026-10-23T22:48:52Z', '2026-10-23T22:50:23Z', 'done', NULL, 0, 'aa3d0dd29506453a93b149b264707e1d1b32aaac', 'main', 'claude-opus-5-5', 'b45cb0e4-6f1a-4a27-a7f1-1a41f91ac4b0', NULL, 11, 22, 6883, 566408, 59449, 0.7266216, 71320, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (69, 91, '2026-10-23T22:49:56Z', '2026-10-23T22:50:31Z', 'done', NULL, 0, 'fd1f04c2eb8a9146a1c95f31c04d042aea00e878', NULL, 'claude-opus-5-5', '8079d8fe-b645-40ab-84d3-363baf255dcc', NULL, 5, 10, 2393, 127332, 20550, 0.23776640000000002, 32702, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (70, 68, '2026-10-23T22:50:23Z', '2026-10-23T22:51:37Z', 'done', NULL, 0, 'fd1f04c2eb8a9146a1c95f31c04d042aea00e878', 'main', 'claude-opus-5-5', '82404eb4-aabf-4849-9fe0-3743bb3aea10', NULL, 11, 22, 6948, 473000, 46618, 0.606592, 59220, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (71, 94, '2026-10-23T22:51:23Z', '2026-10-23T22:52:35Z', 'done', NULL, 0, 'a7c0f2b322431a1f436f4af0c7738dc83068f5fe', NULL, 'claude-opus-5-5', '79f4b6a7-0dfb-4548-91f9-885df33b913c', NULL, 11, 22, 6830, 401954, 34360, 0.49195880000000003, 46720, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (72, 79, '2026-10-23T22:51:37Z', '2026-10-23T22:52:11Z', 'done', NULL, 0, 'a7c0f2b322431a1f436f4af0c7738dc83068f5fe', 'main', 'claude-sonnet-5-5', 'b8654fde-9001-40ac-b4b0-185849fef2c5', NULL, 5, 10, 4424, 128141, 38696, 0.2118581, 39287, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (73, 80, '2026-10-23T22:52:11Z', '2026-10-23T22:53:17Z', 'done', NULL, 0, '1947d8645de1c70eac18e5c157e1c54e809f0a84', 'main', 'claude-sonnet-5-5', 'b8654fde-9001-40ac-b4b0-185849fef2c5', 72, 8, 16, 5238, 384468, 15146, 0.36330089999999987, 54459, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (74, 70, '2026-10-23T22:53:17Z', '2026-10-23T22:54:02Z', 'done', NULL, 0, 'c8f2451439ce9837971f5169319bcd25cb59d5d4', 'main', 'claude-sonnet-5-5', '06d358ad-a487-42fa-8af5-be4999790291', NULL, 10, 20, 5043, 324865, 27869, 0.19443249999999998, 40306, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (75, 81, '2026-10-23T22:54:02Z', '2026-10-23T22:55:49Z', 'done', NULL, 0, 'cd824565ba66fff63a7419003d7f3b9ee9ea3200', 'main', 'claude-sonnet-5-5', '5bdcff38-0782-4dc6-b0c9-eb538167a0e7', NULL, 20, 40, 7740, 709681, 30655, 0.27106810000000003, 43318, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (76, 82, '2026-10-23T22:55:49Z', '2026-10-23T22:58:32Z', 'done', NULL, 0, '8026d8d98c2280137de4a17531ad84cb2f5d0547', 'main', 'claude-sonnet-5-5', '5bdcff38-0782-4dc6-b0c9-eb538167a0e7', 75, 20, 34, 6860, 968937, 21766, 0.5236938, 64965, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (77, 99, '2026-10-23T22:58:32Z', '2026-10-23T22:58:58Z', 'done', NULL, 0, 'c3f11a844f392df0625fa2281eb6cb7f81e86a41', 'main', 'claude-sonnet-5-5', '5bdcff38-0782-4dc6-b0c9-eb538167a0e7', 76, 4, 8, 1117, 274834, 7496, 0.59234720000000007, 72066, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (78, 71, '2026-10-23T22:58:58Z', '2026-10-23T22:59:47Z', 'done', NULL, 0, '7f28145b046714cc0bebf6bb4dc62549e7efbe39', 'main', 'claude-sonnet-5-5', '34a72306-2819-43d4-ae74-d7bb8b897eb3', NULL, 8, 16, 6115, 294867, 37489, 0.2406247, 49935, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (79, 72, '2026-10-23T22:59:47Z', '2026-10-23T23:00:24Z', 'done', NULL, 0, 'ae6794f8de7021105ef96ba645285a3a795cce13', 'main', 'claude-sonnet-5-5', '34a72306-2819-43d4-ae74-d7bb8b897eb3', 78, 4, 8, 5075, 229377, 16024, 0.3784244, 65925, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (80, 73, '2026-10-23T23:00:24Z', '2026-10-23T23:01:03Z', 'done', NULL, 0, '6ce9dae76840142ac72ed5892e3cdda5539e5278', 'main', 'claude-sonnet-5-5', '34a72306-2819-43d4-ae74-d7bb8b897eb3', 79, 5, 10, 5449, 373971, 16206, 0.5351555, 82118, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (81, 74, '2026-10-23T23:01:04Z', '2026-10-23T23:01:57Z', 'done', NULL, 0, 'e2805d4a4641cf89a8ef065e43654f1dbc9e78fe', 'main', 'claude-sonnet-5-5', 'a0e76aa7-ff5b-4211-ad78-54de2de6da81', NULL, 11, 22, 5849, 386611, 31597, 0.22358310000000004, 44116, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (82, 75, '2026-10-23T23:01:57Z', '2026-10-23T23:03:04Z', 'done', NULL, 0, '3c265f195e750f706927601bb05f8e5db73b862c', 'main', 'claude-sonnet-5-5', 'a0e76aa7-ff5b-4211-ad78-54de2de6da81', 81, 9, 18, 8495, 508172, 20206, 0.44021029999999994, 64331, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (83, 76, '2026-10-23T23:03:04Z', '2026-10-23T23:04:03Z', 'done', NULL, 0, 'baae6e9ddc911cf87df04f146aea649f30c7e6e9', 'main', 'claude-sonnet-5-5', 'a0e76aa7-ff5b-4211-ad78-54de2de6da81', 82, 7, 14, 7695, 532724, 22577, 0.6607687, 86899, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (84, 84, '2026-10-23T23:04:03Z', '2026-10-23T23:06:23Z', 'done', NULL, 0, '109ba63120d8d8f6abd63601000a6ab50fb70165', 'main', 'claude-sonnet-5-5', 'fcdc245c-9954-4a23-aa65-c652ceb7cead', NULL, 21, 40, 13121, 958303, 49963, 0.4269723, 62539, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (85, 85, '2026-10-23T23:06:23Z', '2026-10-23T23:07:33Z', 'done', NULL, 0, 'd95f3f4c736b654afc120c66623f762bb6beb304', 'main', 'claude-sonnet-5-5', 'fcdc245c-9954-4a23-aa65-c652ceb7cead', 84, 6, 12, 9051, 449484, 22132, 0.6509826999999998, 84546, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (86, 86, '2026-10-23T23:07:33Z', '2026-10-23T23:11:12Z', 'done', NULL, 0, '982f9da68cd5cda34083ae897821cb6a460261aa', 'main', 'claude-sonnet-5-5', '280ed0c7-e6b9-46d2-bbe8-fddc1e1e9635', NULL, 20, 38, 12047, 873685, 45749, 0.3909105, 58184, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (87, 87, '2026-10-23T23:11:12Z', '2026-10-23T23:12:15Z', 'done', NULL, 0, '24001fc6bfe26c737e679bc1bc10ecfbfa7f5ec0', 'main', 'claude-sonnet-5-5', '280ed0c7-e6b9-46d2-bbe8-fddc1e1e9635', 86, 6, 12, 10025, 422882, 24014, 0.6295287, 82306, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (88, 89, '2026-10-23T23:12:15Z', '2026-10-23T23:13:15Z', 'done', NULL, 0, '226253f3b9da804ea56dcd7baf460c4418a4e378', 'main', 'claude-sonnet-5-5', 'f2360096-458c-4e30-88b4-3ca6dccb0200', NULL, 14, 28, 6740, 572595, 40281, 0.28583950000000008, 52819, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (89, 90, '2026-10-23T23:13:15Z', '2026-10-23T23:14:06Z', 'done', NULL, 0, '020bfe15683ff50b190b26aca3c3c71102ed35e6', 'main', 'claude-sonnet-5-5', 'f2360096-458c-4e30-88b4-3ca6dccb0200', 88, 7, 14, 7596, 450236, 19947, 0.48663910000000016, 72569, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (90, 92, '2026-10-23T23:14:06Z', '2026-10-23T23:16:38Z', 'done', NULL, 0, '363d1a7a655376495d0c4aed6c36c7c12b746cfc', 'main', 'claude-sonnet-5-5', 'a89cb2e3-813b-4a28-ae5a-96c0df71c494', NULL, 24, 48, 12099, 1291089, 56785, 0.47733489999999995, 69265, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (91, 93, '2026-10-23T23:16:38Z', '2026-10-23T23:17:20Z', 'done', NULL, 0, '4482bd8b29d1a98e208a1f3b50085657296222ed', 'main', 'claude-sonnet-5-5', 'a89cb2e3-813b-4a28-ae5a-96c0df71c494', 90, 5, 10, 3749, 375086, 11223, 0.5972455, 80253, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (92, 97, '2026-10-23T23:17:20Z', '2026-10-23T23:18:00Z', 'done', NULL, 0, '6846bc15b25ff167ff9725da0f842052e539919c', 'main', 'claude-sonnet-5-5', '7440b93a-67be-41d1-9e6b-6efb7b50d36c', NULL, 9, 18, 4008, 311217, 31957, 0.19906569999999998, 44205, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (93, 98, '2026-10-23T23:18:00Z', '2026-10-23T23:21:04Z', 'done', NULL, 0, 'e06ad1c3ed77206625fe322b4c4d6c7d09a47fc8', 'main', 'claude-opus-5-5', 'b7168dd9-85e2-4813-be3a-e26fc26c6f72', NULL, 30, 52, 14315, 1965497, 88967, 1.3913433999999998, 100838, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (94, 95, '2026-10-23T23:21:04Z', '2026-10-23T23:21:43Z', 'done', NULL, 0, '855e96e0991cc1d482acee00f67a78197d4cfaa9', 'main', 'claude-sonnet-5-5', 'c7acb24d-b9db-4cf7-87be-981a831d209b', NULL, 13, 26, 4454, 548876, 40977, 0.26338759999999994, 53425, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (95, 96, '2026-10-23T23:21:43Z', '2026-10-23T23:25:08Z', 'done', NULL, 0, '3f86a7891c5ae228876d05a5e102fdb70d06c658', 'main', 'claude-sonnet-5-5', 'c7acb24d-b9db-4cf7-87be-981a831d209b', 94, 25, 46, 11231, 1600713, 30443, 0.65763289999999985, 83891, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (96, 100, '2026-10-23T23:25:08Z', '2026-10-23T23:25:22Z', 'done', NULL, 0, '3f86a7891c5ae228876d05a5e102fdb70d06c658', 'main', 'claude-sonnet-5-5', 'b0ba9abc-3d63-4d1a-a320-e9c353632220', NULL, 6, 12, 1105, 152457, 18856, 0.10174369999999999, 31009, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (97, 101, '2026-10-23T23:25:20Z', '2026-10-23T23:25:52Z', 'done', NULL, 0, '5a093e452891ccf9e701c5a9021207fcd1d8a7e9', NULL, 'claude-sonnet-5-5', '477bf9fb-a0a5-4414-a366-b148cece6dcd', NULL, 13, 24, 3050, 425896, 33392, 0.2067056, 45712, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (98, 57, '2026-10-24T00:10:58Z', '2026-10-24T00:12:32Z', 'done', NULL, 0, '152acd7d8324a30358e4a6eeac692f391a7a1747', 'main', 'claude-opus-5-5', '1a1512e9-b04b-424f-b711-7364a47de8ff', NULL, 11, 22, 7142, 393859, 38906, 0.53294779999999986, 50779, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (99, 102, '2026-10-24T00:12:13Z', '2026-10-24T00:12:46Z', 'done', NULL, 0, '60af466d68fa04280c7173655afd9f5145df96e0', NULL, 'claude-opus-5-5', '76bf5cd6-5dda-4964-b8f3-e9fe109d32e2', NULL, 6, 12, 3429, 170307, 23907, 0.2939454, 36205, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (100, 58, '2026-10-24T00:12:32Z', '2026-10-24T00:14:03Z', 'done', NULL, 0, '60af466d68fa04280c7173655afd9f5145df96e0', 'main', 'claude-opus-5-5', '94f5837e-d1e5-474d-8f0e-31840a50b471', NULL, 12, 24, 7618, 508799, 43789, 0.60452780000000006, 55659, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (101, 106, '2026-10-24T00:13:49Z', '2026-10-24T00:14:34Z', 'done', NULL, 0, '072e8b2830e12142a69ac1b7f9949c815dec5a8c', NULL, 'claude-opus-5-5', '5bf806c8-9e01-4d20-b5e9-cfb14ba30404', NULL, 8, 16, 4290, 278646, 32829, 0.4042252, 44700, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (102, 59, '2026-10-24T00:14:03Z', '2026-10-24T00:15:02Z', 'done', NULL, 0, '072e8b2830e12142a69ac1b7f9949c815dec5a8c', 'main', 'claude-opus-5-5', '2f5a2dd8-42ee-4a9a-895a-9d355d7eaa8e', NULL, 8, 16, 5439, 302613, 40479, 0.49319860000000004, 52955, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (103, 111, '2026-10-24T00:14:55Z', '2026-10-24T00:16:01Z', 'done', NULL, 0, '9b4c33450fb744cd7278d4519a95b4495bbb33d9', NULL, 'claude-opus-5-5', 'dc4200da-c7a2-4a8b-b40a-cb830ff040a6', NULL, 8, 16, 5452, 291292, 37232, 0.4652184, 49109, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (104, 60, '2026-10-24T00:15:02Z', '2026-10-24T00:16:10Z', 'done', NULL, 0, '9b4c33450fb744cd7278d4519a95b4495bbb33d9', 'main', 'claude-opus-5-5', '857b7591-aca9-4031-9544-5ebe771ef686', NULL, 10, 20, 6113, 381991, 38142, 0.5038742, 50631, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (105, 117, '2026-10-24T00:16:01Z', '2026-10-24T00:16:54Z', 'done', NULL, 0, 'c02fc7f8355a537ee1f6a5618522bea3aec11794', NULL, 'claude-opus-5-5', '8d0c492d-23aa-4382-bb5b-76b2573cc007', NULL, 8, 16, 5596, 253515, 31780, 0.41692700000000005, 44070, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (106, 103, '2026-10-24T00:16:10Z', '2026-10-24T00:16:54Z', 'done', NULL, 0, 'c02fc7f8355a537ee1f6a5618522bea3aec11794', 'main', 'claude-sonnet-5-5', '1c5bedb7-b344-407b-9aef-31199b7b72ea', NULL, 7, 14, 2646, 192567, 20716, 0.12860870000000002, 33051, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (107, 104, '2026-10-24T00:16:54Z', '2026-10-24T00:17:42Z', 'done', NULL, 0, '8905c35fe5ae81beebf875ead37f87c4b64ebc3e', 'main', 'claude-sonnet-5-5', '1c5bedb7-b344-407b-9aef-31199b7b72ea', 106, 7, 14, 3178, 289765, 13263, 0.24244520000000006, 46350, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (108, 105, '2026-10-24T00:17:42Z', '2026-10-24T00:18:39Z', 'done', NULL, 0, '9bf69eb49f7b36b3b2731ded36abffcf79cb83cd', 'main', 'claude-sonnet-5-5', '1c5bedb7-b344-407b-9aef-31199b7b72ea', 107, 8, 14, 3051, 362872, 10483, 0.35120240000000008, 56783, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (109, 107, '2026-10-24T00:18:39Z', '2026-10-24T00:19:45Z', 'done', NULL, 0, '91ecb524a858550b8c322fd212176d7c8a0dffec', 'main', 'claude-sonnet-5-5', '4efda1a0-2a29-4188-92d1-2d3414caea86', NULL, 13, 22, 5940, 389547, 31433, 0.2241307, 43892, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (110, 108, '2026-10-24T00:19:45Z', '2026-10-24T00:20:31Z', 'done', NULL, 0, '2666077c33fea3bdf255f591a968692e937be87b', 'main', 'claude-sonnet-5-5', '4efda1a0-2a29-4188-92d1-2d3414caea86', 109, 6, 12, 4024, 296561, 10989, 0.3380068, 54668, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (111, 109, '2026-10-24T00:20:31Z', '2026-10-24T00:21:19Z', 'done', NULL, 0, '34d8160b62fe1d83c91984abf3160220f7e02120', 'main', 'claude-sonnet-5-5', '4efda1a0-2a29-4188-92d1-2d3414caea86', 110, 8, 14, 3769, 455356, 16566, 0.48752439999999997, 71453, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (112, 110, '2026-10-24T00:21:19Z', '2026-10-24T00:21:56Z', 'done', NULL, 0, '969395ab3d08c6efa9b8ba032ec027a7d580cdbc', 'main', 'claude-sonnet-5-5', '4efda1a0-2a29-4188-92d1-2d3414caea86', 111, 4, 8, 2402, 307941, 11228, 0.5872665, 82529, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (113, 112, '2026-10-24T00:21:56Z', '2026-10-24T00:22:57Z', 'done', NULL, 0, 'ecf26d52a3a6bfd356901a1477433222c0f937f3', 'main', 'claude-sonnet-5-5', '6f781775-9bdf-4899-b8c3-01bf77e7d12a', NULL, 10, 20, 4898, 349068, 30981, 0.20785079999999997, 43542, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (114, 113, '2026-10-24T00:22:57Z', '2026-10-24T00:23:48Z', 'done', NULL, 0, 'f0ad18f63679897301a35f1c96159251b40b36f5', 'main', 'claude-sonnet-5-5', '6f781775-9bdf-4899-b8c3-01bf77e7d12a', 113, 9, 18, 3928, 495793, 17620, 0.3672261, 60945, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (115, 114, '2026-10-24T00:23:48Z', '2026-10-24T00:24:24Z', 'done', NULL, 0, '28d5b6bad401e1cd75cbc1777030daf56dcc8974', 'main', 'claude-sonnet-5-5', '6f781775-9bdf-4899-b8c3-01bf77e7d12a', 114, 5, 10, 2164, 341079, 13772, 0.47808200000000006, 74668, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (116, 115, '2026-10-24T00:24:25Z', '2026-10-24T00:25:07Z', 'done', NULL, 0, 'c86d8bb068f197a717a7e6cfaa77780aa60186a6', 'main', 'claude-sonnet-5-5', '6f781775-9bdf-4899-b8c3-01bf77e7d12a', 115, 4, 8, 2703, 328230, 14660, 0.59659100000000009, 89335, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (117, 116, '2026-10-24T00:25:08Z', '2026-10-24T00:26:12Z', 'done', NULL, 0, '4f32b32c961de2c0aa87ead88655c58d242d5547', 'main', 'claude-sonnet-5-5', 'edca9023-4ebb-4f3e-8f9a-52f17ffb3b69', NULL, 15, 26, 5796, 438317, 32844, 0.2332197, 45136, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (118, 118, '2026-10-24T00:26:12Z', '2026-10-24T00:30:37Z', 'done', NULL, 0, '55bb86b961d776ac8ed77eab27ad478bb2e89c88', 'main', 'claude-sonnet-5-5', 'a8bfe631-4eea-442b-8e47-15441577e559', NULL, 14, 28, 5061, 481205, 28564, 0.21304249999999997, 41515, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (119, 119, '2026-10-24T00:30:37Z', '2026-10-24T00:31:33Z', 'done', NULL, 0, 'b6eaf247b35516e128c1ae2fca2caa33b958efd9', 'main', 'claude-sonnet-5-5', 'a8bfe631-4eea-442b-8e47-15441577e559', 118, 6, 12, 4964, 298684, 14831, 0.3518989, 56208, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (120, 120, '2026-10-24T00:31:33Z', '2026-10-24T00:32:13Z', 'done', NULL, 0, '9406eede1f218ced1b63a186d20855ba299d01c1', 'main', 'claude-sonnet-5-5', 'a8bfe631-4eea-442b-8e47-15441577e559', 119, 5, 10, 2381, 311733, 10443, 0.44867419999999997, 66587, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (121, 121, '2026-10-24T00:32:13Z', '2026-10-24T00:32:54Z', 'done', NULL, 0, 'e272e2784e1edcad17e0aeb3fd304192b7581bd8', 'main', 'claude-sonnet-5-5', 'a8bfe631-4eea-442b-8e47-15441577e559', 120, 5, 10, 2442, 364848, 11495, 0.555579, 78077, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (122, 122, '2026-10-24T00:32:55Z', '2026-10-24T00:33:28Z', 'done', NULL, 0, '164704db95478e32eeacf77fe52d0df096eb3e7d', 'main', 'claude-sonnet-5-5', 'a8bfe631-4eea-442b-8e47-15441577e559', 121, 4, 8, 1610, 329994, 8315, 0.6379544, 86309, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (123, 123, '2026-10-24T00:33:25Z', '2026-10-24T00:33:52Z', 'done', NULL, 0, '04726e6ce9ee5acb04e229c4e449640ce95bb236', NULL, 'claude-sonnet-5-5', 'f8616dbd-c0f0-4df2-8d0e-de0381157625', NULL, 14, 22, 2775, 355215, 29067, 0.17958350000000004, 41325, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (124, 124, '2026-10-24T03:16:03Z', '2026-10-24T03:18:41Z', 'done', NULL, 0, 'ec886414b9cda6f2496d8600975adab92931a028', NULL, 'claude-opus-5-5', '3bbd9f36-ab90-4935-be79-228f71e7936e', NULL, 13, 26, 12416, 581708, 70456, 0.92841360000000006, 70463, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (125, 125, '2026-10-24T03:18:41Z', '2026-10-24T03:19:13Z', 'done', NULL, 0, '608243e3192753948b5df6d87ed0cae228418c68', NULL, 'claude-opus-5-5', 'f709096f-446e-4d2f-94f6-ac48539c2221', NULL, 5, 10, 3134, 149498, 28697, 0.3221956, 41135, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (126, 126, '2026-10-24T03:19:08Z', '2026-10-24T03:20:05Z', 'done', NULL, 0, '608243e3192753948b5df6d87ed0cae228418c68', 'main', 'claude-opus-5-5', 'a9d7a3f2-c263-4e00-927b-2b0b1fe8588d', NULL, 10, 18, 4255, 298734, 30309, 0.38739080000000004, 42722, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (127, 131, '2026-10-24T03:19:55Z', '2026-10-24T03:20:37Z', 'done', NULL, 0, '36076d40da0557bd663cd08d15aef8d8fe0e15ff', NULL, 'claude-opus-5-5', '59dfad59-4f0d-4289-b3b8-18be03916561', NULL, 6, 12, 2140, 154504, 19536, 0.23003679999999999, 31741, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (128, 132, '2026-10-24T03:20:29Z', '2026-10-24T03:21:14Z', 'done', NULL, 0, '36076d40da0557bd663cd08d15aef8d8fe0e15ff', 'main', 'claude-sonnet-5-5', '28723c43-61fd-4c96-a24f-1adaf945fe12', NULL, 10, 20, 4513, 342790, 44917, 0.259117, 45481, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (129, 133, '2026-10-24T03:21:14Z', '2026-10-24T03:21:38Z', 'done', NULL, 0, 'bcbd0f9c3616141f04cae255c7fd636a301d4dea', 'main', 'claude-sonnet-5-5', '28723c43-61fd-4c96-a24f-1adaf945fe12', 128, 6, 12, 2489, 317968, 13712, 0.3706758, 59087, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (130, 127, '2026-10-24T03:42:29Z', '2026-10-24T03:47:51Z', 'done', NULL, 0, 'b901da25b0db8d98eef96a18c3e1de0ce3d0c504', 'main', 'claude-opus-5-5', 'e0ebc1c7-acfd-4448-a58d-3da48e9d38f7', NULL, 22, 44, 27379, 1247818, 73933, 1.3887836000000005, 86507, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (131, 134, '2026-10-24T03:47:38Z', '2026-10-24T03:48:32Z', 'done', NULL, 0, '20290e1ab1f85ce2c9ba1484f02c79681a50c666', NULL, 'claude-opus-5-5', '669e211d-895c-4001-b04f-fc750a64b8ee', NULL, 6, 12, 5309, 194676, 33178, 0.4105872, 45479, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (132, 129, '2026-10-24T03:48:21Z', '2026-10-24T03:49:34Z', 'done', NULL, 0, '20290e1ab1f85ce2c9ba1484f02c79681a50c666', 'main', 'claude-opus-5-5', '0d6bd0c1-82fa-4733-9356-c584507432fe', NULL, 9, 18, 5145, 380246, 45042, 0.5393572, 57368, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (133, 139, '2026-10-24T03:49:26Z', '2026-10-24T03:50:08Z', 'done', NULL, 0, 'ff2d107d0fb1d8bdc6352c82f6d3eb305c716856', NULL, 'claude-opus-5-5', 'b6739ccd-f2ba-4e63-8c9e-f26193ac65a4', NULL, 5, 10, 2658, 137192, 23151, 0.2658464, 35386, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (134, 130, '2026-10-24T03:49:34Z', '2026-10-24T03:51:34Z', 'done', NULL, 0, 'ff2d107d0fb1d8bdc6352c82f6d3eb305c716856', 'main', 'claude-opus-5-5', '4bc26929-cc2c-432f-aa8d-e44cc8365ad3', NULL, 11, 20, 9905, 514998, 59102, 0.77399560000000012, 70972, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (135, 142, '2026-10-24T03:51:14Z', '2026-10-24T03:52:02Z', 'done', NULL, 0, '5fd33f7d0a27130a8c215e9807d516d165e8b3b0', NULL, 'claude-opus-5-5', '530d9778-cb0d-4db2-a1b0-bd4805c79f99', NULL, 9, 18, 4803, 328834, 35097, 0.44267480000000004, 47361, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (136, 135, '2026-10-24T03:51:34Z', '2026-10-24T03:52:17Z', 'done', NULL, 0, '5fd33f7d0a27130a8c215e9807d516d165e8b3b0', 'main', 'claude-sonnet-5-5', '7fd41c68-467b-49e2-81a7-1bd7234084ba', NULL, 8, 16, 4481, 252454, 26529, 0.17620339999999996, 38987, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (137, 143, '2026-10-24T03:52:17Z', '2026-10-24T03:53:13Z', 'done', NULL, 0, '1701ab9491117c6dbd7f76a3ffda3f07ba5ec30a', 'main', 'claude-sonnet-5-5', 'a93e8dcc-5b23-4a2a-b74f-b1e3ef3f5d37', NULL, 14, 28, 6998, 603077, 47585, 0.3206837, 60016, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (138, 144, '2026-10-24T03:53:13Z', '2026-10-24T03:53:57Z', 'done', NULL, 0, '0812cae4560fdb8329109e1222ea42b047860dff', 'main', 'claude-sonnet-5-5', 'a93e8dcc-5b23-4a2a-b74f-b1e3ef3f5d37', 137, 6, 12, 5638, 435564, 22009, 0.50868010000000008, 82082, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (139, 136, '2026-10-24T03:53:57Z', '2026-10-24T04:07:54Z', 'done', NULL, 0, '00614e0a469a487f12b3117848c3ca8a2cc9d885', 'main', 'claude-opus-5-5', 'fdb55323-fe84-427f-9876-59115077a69b', NULL, 58, 114, 80942, 7952953, 196718, 4.7836306000000013, 209260, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (140, 145, '2026-10-24T04:07:54Z', '2026-10-24T04:08:29Z', 'done', NULL, 0, '929c3e2c51222c34938d0f122d6ab884bab8a187', 'main', 'claude-sonnet-5-5', '74fd107f-6898-4c87-86e2-7cd8c1f979f5', NULL, 11, 22, 4396, 423122, 37110, 0.23475619999999997, 49494, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (141, 137, '2026-10-24T04:08:29Z', '2026-10-24T04:10:13Z', 'done', NULL, 0, 'de5592945148d93e7547fed5e63c4fa21e0972c3', 'main', 'claude-sonnet-5-5', '533d08ed-9843-4a15-b74f-727ec1cbc05f', NULL, 19, 38, 12699, 1161750, 77527, 0.553349, 90106, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (142, 140, '2026-10-24T04:10:13Z', '2026-10-24T04:11:21Z', 'done', NULL, 0, 'e6c8dc4368e87614b090909b9063d0f96d50815f', 'main', 'claude-sonnet-5-5', 'b741b511-3397-4df5-81bb-cba8f46bbe72', NULL, 17, 32, 8773, 699728, 42801, 0.3289708, 55247, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (143, 141, '2026-10-24T04:11:21Z', '2026-10-24T04:12:07Z', 'done', NULL, 0, '930f6ec2126739b516593c229503eabfc5011a74', 'main', 'claude-sonnet-5-5', 'b741b511-3397-4df5-81bb-cba8f46bbe72', 142, 6, 12, 4460, 381576, 14899, 0.4713484, 69940, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (144, 146, '2026-10-24T04:12:07Z', '2026-10-24T04:12:47Z', 'done', NULL, 0, 'f7b8cb09cfa842f327faffbf7e5da8efdb80ca4f', 'main', 'claude-sonnet-5-5', 'c39ed083-944b-402e-b42f-c77e01be9b85', NULL, 13, 24, 5010, 437861, 34567, 0.23220210000000005, 47160, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (145, 138, '2026-10-24T04:12:47Z', '2026-10-24T04:16:00Z', 'done', NULL, 0, '65a3f9bf61155f86110ee782ad89f0de4adeeeff', 'main', 'claude-sonnet-5-5', 'a6fcc78b-8eb0-4a47-98fa-e8c6b15fa435', NULL, 15, 28, 9508, 716350, 59408, 0.40440300000000012, 71887, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (146, 147, '2026-10-24T12:51:40Z', '2026-10-24T12:53:57Z', 'done', NULL, 0, 'a6ae9a8ebb7262921fd263b06776a313d0582bdc', NULL, 'claude-sonnet-5-5', '965dbdcc-173d-4f36-8318-7fcb025e1c53', NULL, 33, 56, 11481, 1656282, 82164, 0.60920620000000014, 82810, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (147, 128, '2026-10-24T13:58:29Z', '2026-10-24T14:00:04Z', 'done', NULL, 0, 'cc0ec9fe992e0ead0b83fbc7c0f28e6a06da2cbe', 'main', 'claude-opus-5-5', '4db5c3c7-7226-4056-93bd-30bc15df96a4', NULL, 11, 22, 8541, 483458, 62697, 0.7691756, 63381, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (148, 148, '2026-10-24T13:59:56Z', '2026-10-24T14:00:31Z', 'done', NULL, 0, 'a2326804f339293bcfa93a2327724677b489afdd', NULL, 'claude-opus-5-5', 'a72f46b4-8e04-4005-a1a6-dcac0fdc9866', NULL, 8, 16, 3180, 231253, 23308, 0.2963786, 35559, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (149, 149, '2026-10-24T14:00:28Z', NULL, 'running', NULL, NULL, 'a2326804f339293bcfa93a2327724677b489afdd', 'main', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 1465683);

INSERT INTO task_decision (task_id, decision_id) VALUES (2, 1);
INSERT INTO task_decision (task_id, decision_id) VALUES (4, 2);
INSERT INTO task_decision (task_id, decision_id) VALUES (4, 3);
INSERT INTO task_decision (task_id, decision_id) VALUES (5, 3);
INSERT INTO task_decision (task_id, decision_id) VALUES (6, 3);
INSERT INTO task_decision (task_id, decision_id) VALUES (7, 3);
INSERT INTO task_decision (task_id, decision_id) VALUES (8, 3);
INSERT INTO task_decision (task_id, decision_id) VALUES (9, 3);
INSERT INTO task_decision (task_id, decision_id) VALUES (10, 3);
INSERT INTO task_decision (task_id, decision_id) VALUES (11, 3);
INSERT INTO task_decision (task_id, decision_id) VALUES (12, 2);
INSERT INTO task_decision (task_id, decision_id) VALUES (14, 4);
INSERT INTO task_decision (task_id, decision_id) VALUES (34, 20);
INSERT INTO task_decision (task_id, decision_id) VALUES (57, 23);
INSERT INTO task_decision (task_id, decision_id) VALUES (57, 26);
INSERT INTO task_decision (task_id, decision_id) VALUES (63, 25);
INSERT INTO task_decision (task_id, decision_id) VALUES (65, 25);
INSERT INTO task_decision (task_id, decision_id) VALUES (66, 25);
INSERT INTO task_decision (task_id, decision_id) VALUES (67, 25);
INSERT INTO task_decision (task_id, decision_id) VALUES (127, 33);
INSERT INTO task_decision (task_id, decision_id) VALUES (128, 42);
INSERT INTO task_decision (task_id, decision_id) VALUES (130, 29);
INSERT INTO task_decision (task_id, decision_id) VALUES (130, 30);
INSERT INTO task_decision (task_id, decision_id) VALUES (130, 31);

INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (4, 3);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (4, 12);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (4, 13);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (5, 4);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (6, 5);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (7, 6);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (8, 7);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (9, 8);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (10, 9);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (11, 10);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (18, 17);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (19, 17);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (20, 19);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (21, 20);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (22, 21);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (24, 22);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (25, 24);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (26, 25);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (27, 24);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (28, 27);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (31, 21);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (32, 22);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (32, 31);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (33, 32);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (34, 33);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (36, 22);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (37, 36);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (38, 26);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (38, 36);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (39, 36);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (40, 36);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (41, 32);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (41, 34);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (41, 36);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (43, 17);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (44, 28);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (44, 45);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (45, 26);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (45, 27);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (45, 36);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (45, 40);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (45, 43);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (47, 19);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (47, 22);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (48, 36);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (48, 47);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (49, 18);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (49, 47);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (50, 33);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (50, 34);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (50, 41);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (50, 48);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (50, 49);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (51, 37);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (51, 38);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (51, 40);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (51, 41);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (51, 44);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (51, 45);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (51, 50);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (58, 57);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (59, 57);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (60, 58);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (60, 59);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (65, 63);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (65, 64);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (66, 63);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (66, 64);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (67, 63);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (67, 64);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (68, 65);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (68, 66);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (68, 67);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (71, 70);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (72, 70);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (73, 70);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (74, 70);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (75, 70);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (76, 70);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (81, 70);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (81, 80);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (82, 81);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (84, 70);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (84, 73);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (84, 80);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (84, 81);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (85, 71);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (85, 84);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (86, 72);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (86, 84);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (87, 73);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (87, 74);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (87, 84);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (89, 75);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (89, 80);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (89, 84);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (90, 89);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (92, 76);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (92, 80);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (92, 81);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (92, 84);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (93, 92);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (95, 79);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (95, 98);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (96, 95);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (96, 98);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (97, 70);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (97, 71);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (97, 72);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (97, 73);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (97, 74);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (97, 75);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (97, 76);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (98, 81);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (98, 82);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (98, 84);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (98, 85);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (98, 86);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (98, 87);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (98, 89);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (98, 90);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (98, 92);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (98, 93);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (98, 97);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (104, 103);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (105, 104);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (107, 103);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (107, 105);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (108, 107);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (109, 107);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (110, 103);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (112, 103);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (112, 104);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (112, 105);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (113, 112);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (114, 112);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (115, 112);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (116, 109);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (116, 112);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (117, 111);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (118, 104);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (119, 105);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (119, 118);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (120, 107);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (120, 109);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (120, 118);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (121, 107);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (121, 115);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (121, 118);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (122, 105);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (122, 118);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (127, 126);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (128, 127);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (129, 127);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (133, 132);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (135, 133);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (136, 135);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (136, 143);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (136, 144);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (137, 136);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (137, 145);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (138, 137);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (138, 146);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (140, 137);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (141, 140);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (145, 143);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (145, 144);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (146, 145);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (150, 149);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (151, 150);

INSERT INTO decision_supersedes (decision_id, superseded_id, note) VALUES (39, 15, '');
INSERT INTO decision_supersedes (decision_id, superseded_id, note) VALUES (44, 32, '');
INSERT INTO decision_supersedes (decision_id, superseded_id, note) VALUES (49, 43, '');
