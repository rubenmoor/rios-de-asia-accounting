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

INSERT INTO milestone (id, subject, status, body, created_at, implemented_at, queue_index) VALUES (1, 'first version build', 'open', 'build the app according to the idea specified in airbnb-bookkeeping-spec.md

* create an architecture-spec.md early on and have me decide on it before continuing
* apart from that, keep human decisions minimal, follow your own recommendations', '2026-10-23T19:11:39Z', NULL, 0);

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
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (7, 1, 'write the plan for part 5: metrics', 'plan', 'open', 1000, NULL, 'Write the plan for part 5 of `plan 1: masterplan` (section "5. Metrics"); suggested plan priority 600.

- Covers: metrics for any date range (occupancy, ADR, RevPAR, profit, variable cost per night, break-even occupancy, vs. long-term rental, profit per hour and after own time, remaining capex book value), the standard ranges, rolling 90-day series, expense breakdown by category, defined division-by-zero behaviour, hand-checked unit tests.
- Tasks require the allocation engine tasks of part 4.', '2026-10-23T19:19:30Z', NULL, 2, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (8, 1, 'write the plan for part 6: Airbnb CSV import', 'plan', 'open', 1000, NULL, 'Write the plan for part 6 of `plan 1: masterplan` (section "6. Airbnb CSV import"); suggested plan priority 700.

- Follow the CSV mapping in `architecture-spec.md`, checked against `airbnb_.csv` (BOM, `MM/DD/YYYY`, several rows per reservation, COP/USD/EUR).
- Covers: create or update bookings deduplicated by confirmation code, handling of payout and other rows as the spec says, an import summary (new, updated, skipped, problems), tests against `airbnb_.csv` or a trimmed fixture.
- Tasks require the schema tasks of part 3 (not the engine or metrics).', '2026-10-23T19:19:30Z', NULL, 2, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (9, 1, 'write the plan for part 7: data entry screens', 'plan', 'open', 1000, NULL, 'Write the plan for part 7 of `plan 1: masterplan` (section "7. Data entry screens"); suggested plan priority 450.

- Covers: create, list, edit, delete for bookings, expenses, recurring expenses, blocked days, time log; a settings screen; the CSV import reachable from the UI; validation matching the schema rules (e.g. capex needs a useful life).
- Tasks require the schema tasks of part 3, and the import screen requires the import tasks of part 6.', '2026-10-23T19:19:30Z', NULL, 2, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (10, 1, 'write the plan for part 8: dashboard and charts', 'plan', 'open', 1000, NULL, 'Write the plan for part 8 of `plan 1: masterplan` (section "8. Dashboard and charts"); suggested plan priority 400.

- Covers: metrics for the standard ranges side by side plus a custom range, a chart of rolling 90-day RevPAR, ADR and occupancy, expense breakdown by category for a chosen range; plain, readable presentation.
- Tasks require the metrics tasks of part 5 and, where they share UI scaffolding, the screens of part 7.', '2026-10-23T19:19:30Z', NULL, 2, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (11, 1, 'write the plan for part 9: backup, install and final check', 'plan', 'open', 1000, NULL, 'Write the plan for part 9 of `plan 1: masterplan` (section "9. Backup, install and final check"); suggested plan priority 300.

- Covers: `sqlite3 … ".backup …"` into a Dropbox folder as `books-YYYY-MM-DD.db`, keeping the last N, on app exit and via a daily systemd user timer shipped as a NixOS / home-manager module in the flake; restore and install/run/import/backup docs in the README; an end-to-end check (fresh DB, import `airbnb_.csv`, a few expenses, dashboard numbers verified by hand for one month).
- The end-to-end check requires the tasks of parts 6, 7 and 8.', '2026-10-23T19:19:30Z', NULL, 2, 0, NULL, 'main');
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
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (17, 3, 'Python project skeleton', 'work', 'open', NULL, NULL, 'Builds the empty app frame from `architecture-spec.md` (`decision 3: approve the architecture`): Python 3, Flask + Jinja2 + waitress, pytest, ruff. No DB, no config paths, no real pages yet.

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

Done when, inside `nix develop`: `pytest` passes, `ruff check` and `ruff format --check` are clean, and `PYTHONPATH=src python -m airbnb_books.cli --no-browser` serves the page on localhost (check with `curl`, then stop it by PID).', '2026-10-23T19:41:36Z', NULL, 14, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (18, 3, 'Nix package, app and flake checks', 'work', 'open', NULL, NULL, 'Packages the skeleton from `task 17: Python project skeleton` with Nix so it can be built, run and checked with the owner''s Nix setup.

- `flake.nix`, for all listed systems:
  - `packages.default` = `python3Packages.buildPythonApplication` from `pyproject.toml` (`pyproject = true`, `build-system = [ setuptools ]`, dependencies from nixpkgs, `nativeCheckInputs = [ pytestCheckHook ]` so the tests run in the build)
  - `apps.default` runs `bin/airbnb-books`
  - `checks.default` = the package; plus a ruff check derivation running `ruff check` and `ruff format --check` over the source, so `nix flake check` runs tests and lint
  - keep the existing `devShells.default` unchanged
- Out of scope: NixOS / home-manager module and backup (a later part of the masterplan).

Done when `nix build` succeeds (tests run in it), `nix flake check` passes, and `nix run . -- --no-browser` serves the page on localhost (check with `curl`, then stop it by PID).', '2026-10-23T19:41:36Z', NULL, 14, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (19, 4, 'Paths, connection and migrations runner', 'work', 'open', NULL, NULL, 'Part 1 of `plan 4: database schema and storage`: where the database file lives, how it is opened, and how it is created/upgraded. Follows `architecture-spec.md` sections 3, 5, 6, 7 (`decision 3: approve the architecture`). Builds on the skeleton of `task 17: Python project skeleton`.

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
- Done when `pytest`, `ruff check`, `ruff format --check` pass and `airbnb-books --db /tmp/x.db migrate` (or `PYTHONPATH=src python -m airbnb_books.cli …`) creates the file; delete `/tmp/x.db` afterwards.', '2026-10-23T19:42:16Z', NULL, 15, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (20, 4, 'Initial database schema', 'work', 'open', NULL, NULL, 'Part 2 of `plan 4: database schema and storage`: replace the placeholder `src/airbnb_books/storage/migrations/0001_init.sql` with the real schema. The full column list is in the plan body (section "Schema"); read it with `pm show p4`.

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

Done when the tests, `ruff check` and `ruff format --check` pass.', '2026-10-23T19:42:16Z', NULL, 15, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (21, 4, 'Model and repository: bookings, lines, exchange rates', 'work', 'open', NULL, NULL, 'Part 3 of `plan 4: database schema and storage`: the Python side for stays and currency conversion, so no code outside `storage/` writes SQL.

- `src/airbnb_books/model.py`: dataclasses `Booking` (incl. the totals from the `booking_totals` view and `needs_rate`), `BookingLine`, `ExchangeRate`.
- `src/airbnb_books/money.py`: `to_cop(amount_minor, rate) -> int` = amount_minor × rate / 10 000, rounded half away from zero, integer arithmetic only (no floats).
- `src/airbnb_books/storage/repo.py`:
  - bookings: create / get / list (by date range, by listing) / update / delete; find by Airbnb code;
  - a hand-entered booking is created together with its `Manual` line (amount in COP, rate 100); editing its amount edits that line;
  - add lines for the import, ignoring duplicates (the unique dedup key) and returning whether the line was new;
  - exchange rates CRUD; `rate_for(currency, date)` = latest rate on or before that date;
  - `recompute_lines()`: fills or updates `rate` / `amount_cop` of every non-COP line from `exchange_rates`; call it after any rate change.
- Tests (`tmp_path`): CRUD round trips, totals, rate lookup on/before the date, recompute after adding and after changing a rate, `to_cop` rounding incl. negatives and exact halves.
- Done when `pytest`, `ruff check`, `ruff format --check` pass.', '2026-10-23T19:42:16Z', NULL, 15, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (22, 4, 'Repository: expenses, recurring expenses, blocked days, time log, settings', 'work', 'open', NULL, NULL, 'Part 4 of `plan 4: database schema and storage`: the remaining tables in Python, plus one loader that hands the allocation engine everything it needs.

- `src/airbnb_books/model.py`: `Expense`, `RecurringExpense`, `BlockedDay`, `TimeEntry` (minutes, `decision 6: own time is stored in whole minutes`), `Settings` with typed fields and defaults: `hourly_value_cop` 0, `long_term_rent_cop_per_month` 0, `currency` "COP", `per_booking_allocation` "check_in" (or "spread"), `property_listings` [] , `backup_keep` 30.
- `src/airbnb_books/storage/repo.py`:
  - CRUD for each; list by date range;
  - `insert_generated_expense(...)`: inserts unless `(recurring_expense_id, date)` exists (for generating monthly rows, see `decision 9: monthly expenses generated from templates are dated the 1st and come back if deleted`; the generation itself is a later part);
  - `load_settings()` / `save_settings()`: defaults in code for missing keys, `property_listings` stored as JSON;
  - `load_inputs(conn)`: bookings with totals and co-host cost, expenses, blocked days, time log, settings, all as dataclasses.
- Constraint violations (`sqlite3.IntegrityError`) surface as one `ValidationError` with a readable message, for the screens later.
- Tests (`tmp_path`): CRUD round trips, settings defaults and round trip, generated-expense dedup, a constraint violation becomes `ValidationError`, `load_inputs` on a small DB.
- Done when `pytest`, `ruff check`, `ruff format --check` pass.', '2026-10-23T19:42:16Z', NULL, 15, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (23, 6, 'create tasks for plan 6: metrics', 'split', 'open', 1000, NULL, 'Split `plan 6: metrics` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-23T19:42:49Z', NULL, 7, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (24, 5, 'Day model, split helper and income/occupancy allocation', 'work', 'open', NULL, NULL, 'First step of `plan 5: daily allocation engine`: the per-day data type and the income/occupancy half of the engine. Rules are in the plan body ("Rules"); binding: `decision 7: the per-day view ends today; nothing after today is counted`, `decision 6: own time is stored in whole minutes`.

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

**Done when** `pytest`, `ruff check` and `ruff format --check` pass.', '2026-10-23T19:42:51Z', NULL, 16, 0, 'opus', 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (25, 5, 'Allocation cost rules: fixed, per-night, per-booking, co-host, capex, maintenance, tax', 'work', 'open', NULL, NULL, 'Second step of `plan 5: daily allocation engine`: fill the cost columns of `Day` in `allocate` (`allocation.py`). Rules in the plan body; binding: `decision 8: a per-night expense is spread over the occupied nights of its month`, `decision 7: the per-day view ends today; nothing after today is counted`.

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

**Done when** `pytest`, `ruff check` and `ruff format --check` pass.', '2026-10-23T19:42:51Z', NULL, 16, 0, 'opus', 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (26, 5, 'Recurring expense generation and load_days entry point', 'work', 'open', NULL, NULL, 'Last step of `plan 5: daily allocation engine`: monthly expenses from recurring templates, and the single call the metrics and web layers use. Binding: `decision 9: monthly expenses generated from templates are dated the 1st and come back if deleted`.

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

**Done when** `pytest`, `ruff check` and `ruff format --check` pass.', '2026-10-23T19:42:51Z', NULL, 16, 0, NULL, 'main');

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
- **Currencies:** each line keeps original currency and amount, the rate used and the derived integer COP; rates (COP per USD) are loaded by the user, from a hand-downloaded TRM CSV of datos.gov.co or typed in; latest rate on or before the row''s date; missing rates are flagged, rate changes recompute.', 'Before anything is built, the owner should agree on how the bookkeeping app will be made: which programming language and screen style it uses, how it is installed, where its data lives, and how it reads Airbnb''s export file. Approving lets the build start on this basis; asking for changes means the design document is revised first. One point needs particular attention: the Airbnb export contains several rooms and apartments, while the app was meant for a single property.', 'approve', NULL, '2026-10-23T19:23:57Z', '2026-10-23T19:30:24Z', 13, NULL, 'rule', NULL, '');
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

INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (1, 1, '2026-10-23T19:14:37Z', '2026-10-23T19:15:40Z', 'done', NULL, 0, 'cd3d42740dd5ea9c8707207210ebd4e93c9b80c8', NULL, 'claude-opus-5-5', '0b74794a-06e2-4f40-8b9d-b839a74c0101', NULL, 6, 12, 5937, 151146, 39344, 0.46376920000000005, 39881, 60, 1445179);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (2, 2, '2026-10-23T19:19:04Z', '2026-10-23T19:19:45Z', 'done', NULL, 0, 'c3af31b31bf19a0c813d5df39657354d2953594e', NULL, 'claude-opus-5-5', 'a4465501-56c2-4e5c-ada6-af51d0d966e0', NULL, 6, 12, 4235, 176178, 25654, 0.32521560000000005, 37524, 60, 1445179);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (3, 3, '2026-10-23T19:19:43Z', '2026-10-23T19:20:09Z', 'done', NULL, 0, 'c3af31b31bf19a0c813d5df39657354d2953594e', 'main', 'claude-opus-5-5', '01926aa8-ee58-49d7-91fc-650df71b6aec', NULL, 5, 10, 2222, 133821, 21726, 0.2450522, 34030, 60, 1445179);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (4, 4, '2026-10-23T19:20:09Z', '2026-10-23T19:20:33Z', 'blocked', NULL, 0, '6a3272656efbeb1bea37f1fc625c67460287cf82', 'main', 'claude-opus-5-5', '84de8f30-0785-4cd1-aef7-2d3866387edf', NULL, 8, 18, 1805, 241242, 24471, 0.2801884, 36595, 60, 1445179);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (5, 12, '2026-10-23T19:21:24Z', '2026-10-23T19:21:47Z', 'done', NULL, 0, '654e8a9c2e37d79153b5e55867d5c3b03396d2b6', NULL, 'claude-opus-5-5', '84937f15-3aa1-4610-bc16-56d19b29a803', NULL, 4, 8, 1712, 96033, 18932, 0.20493460000000002, 31072, 60, 1445179);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (6, 13, '2026-10-23T19:21:42Z', '2026-10-23T19:24:17Z', 'done', NULL, 0, '654e8a9c2e37d79153b5e55867d5c3b03396d2b6', 'main', 'claude-opus-5-5', 'fdbad895-093f-464b-9810-8678ba0124a4', NULL, 12, 24, 13704, 500149, 45430, 0.73764580000000013, 57973, 60, 1445179);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (7, 4, '2026-10-23T19:30:27Z', '2026-10-23T19:31:01Z', 'done', NULL, 0, '0766499f96e5ec1095e40bd31fac6b92b64ec68f', 'main', 'claude-opus-5-5', '869dd62e-2f9b-49dc-b80d-1f809d81f989', NULL, 5, 10, 2761, 142842, 26526, 0.2960364, 38881, 60, 1445179);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (8, 5, '2026-10-23T19:31:01Z', '2026-10-23T19:32:33Z', 'done', NULL, 0, '0b54e9390ae721fdc3a528419ebceb7f0a4c7cc1', 'main', 'claude-opus-5-5', 'd772841c-911f-47dd-91bf-deee0dd412b6', NULL, 10, 16, 8834, 289545, 36949, 0.530245, 48826, 60, 1445179);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (9, 6, '2026-10-23T19:35:06Z', '2026-10-23T19:36:53Z', 'done', NULL, 0, 'd28c4c716bb75498d9928ba2cf2c00cebbafe1bf', 'main', 'claude-opus-5-5', '2949abf9-e80f-4898-9528-6a9ed7e06b29', NULL, 8, 16, 8563, 312392, 43878, 0.5848264, 56408, 60, 1460586);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (10, 7, '2026-10-23T19:41:23Z', NULL, 'running', NULL, NULL, '8e1b463123b617d25b65d9c12fceae8d0d7586ca', 'main', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (11, 14, '2026-10-23T19:41:23Z', '2026-10-23T19:41:44Z', 'done', NULL, 0, '8e1b463123b617d25b65d9c12fceae8d0d7586ca', NULL, 'claude-opus-5-5', '7f9419d8-f86c-4ed0-b810-59070d227c1a', NULL, 4, 8, 2241, 96301, 19679, 0.2215442, 31832, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (12, 15, '2026-10-23T19:41:44Z', '2026-10-23T19:42:21Z', 'done', NULL, 0, '3a2623f7867eb0c18873799205de4e255470d830', NULL, 'claude-opus-5-5', 'c47d5de1-9425-4e8b-a177-ecaec82f9d8a', NULL, 4, 8, 4104, 109688, 27639, 0.3251616, 39925, 60, 1465683);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (13, 16, '2026-10-23T19:42:21Z', '2026-10-23T19:43:02Z', 'done', NULL, 0, '5f7f1a734c53ffaef29527306d43434131a15c4f', NULL, 'claude-opus-5-5', '5d7ed1a3-5407-4a3c-b7cb-49ee38acc8db', NULL, 5, 10, 2909, 146295, 26485, 0.299359, 38697, 60, 1465683);

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
