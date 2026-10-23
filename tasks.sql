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
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (27, 6, 'Metrics: date ranges and per-range summary', 'work', 'open', NULL, NULL, 'Part of `plan 6: metrics`; read the plan''s "Rules" section, it is the spec for this task.

- Builds on `task 24: Day model, split helper and income/occupancy allocation` (`Day`, `split`); `Day` objects are built by hand in tests, so the cost rules of `task 25` are not needed.
- `src/airbnb_books/metrics.py` (pure: no DB, no clock):
  - `DateRange(start, end)` (inclusive), `standard_ranges(today, first_day)` (all-time, last 30 days, last 90 days, current month), `month_range(year, month)`, `custom(start, end)`; ranges are clipped to the days that exist.
  - `Metrics` dataclass and `summarize(days, rng, settings) -> Metrics`: nights, income, each cost column, total cost, profit, minutes, occupancy, ADR, RevPAR, variable cost per night, break-even occupancy (exact `Fraction`, `decision 11: break-even occupancy treats fixed, maintenance, capex and tax costs as fixed`), long-term rental benchmark and profit vs. it (`decision 12: the long-term rental benchmark is spread over the days of each month`), profit per hour, own-time value, profit after own time.
  - Money is `int` COP, rounded half away from zero with integer arithmetic (reuse `money.py` if it fits); ratios are `float`; undefined → `None` (`decision 10: a figure that cannot be computed is shown as empty, not as zero`).
- `tests/test_metrics.py`, small hand-checked data: 10-day example (occupancy/ADR/RevPAR/profit); break-even computed, ADR ≤ variable cost → None, no occupancy → None; benchmark over a full month = monthly figure, and across Feb/Mar of a leap year; profit per hour and after own time with and without minutes; empty range; range entirely before the first day; last 30 days with fewer than 30 days of data; current month on the 1st.
- Done when `pytest`, `ruff check` and `ruff format --check` pass.', '2026-10-23T19:43:18Z', NULL, 23, 0, 'opus', 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (28, 6, 'Metrics: rolling 90-day series, expense breakdown, capex book value', 'work', 'open', NULL, NULL, 'Part of `plan 6: metrics`; read the plan''s "Rules" section, it is the spec for this task. Adds to `src/airbnb_books/metrics.py` from the previous metrics task.

- `rolling_90(days) -> list[RollingPoint(date, revpar, adr, occupancy)]` per `decision 13: the rolling 90-day chart starts once 90 days of history exist`; linear time with running sums, not 90 × days; undefined values None.
- `expense_breakdown(days, rng) -> list[(category, amount, share)]`: the six cost columns in fixed order (co-host is inside per-booking), share of total cost as float, None when the total is 0.
- `capex_book_value(expenses, as_of) -> int`: Σ over capex expenses of amount − the part of `split(amount, useful_life_days)` on days ≤ as_of; purchases after as_of not counted; 0 after full life.
- Tests in `tests/test_metrics.py`: rolling on 89 days → empty; on 90 → one point equal to `summarize` over those days; on 200 days a few points each equal `summarize` of their window; a window with no available nights → None values; breakdown sums to total cost and shares sum to 1, all-zero → None shares; capex book value before, during (hand-checked, incl. a leap day), after the useful life, and with two purchases.
- Done when `pytest`, `ruff check` and `ruff format --check` pass.', '2026-10-23T19:43:18Z', NULL, 23, 0, NULL, 'main');
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
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (34, 7, 'Exchange-rate (TRM) import', 'work', 'open', NULL, NULL, 'Part 4 of `plan 7: Airbnb CSV import`: load the official Colombian peso/dollar rate history so stays paid in dollars get a value in pesos.

- The owner downloads the TRM history by hand from datos.gov.co ("Tasa de Cambio Representativa del Mercado – Histórico", CSV export). Look up its real column names, date format and number format there (web access) and note them in a comment in the parser.
- `src/airbnb_books/importer/trm_csv.py`:
  - parse → (date, COP per USD in hundredths, via `money.parse_minor` or equivalent exact parsing) using each row''s start-of-validity date; problems with CSV line numbers;
  - apply: upsert into `exchange_rates` for `USD` through `storage/repo.py`, then `repo.recompute_lines()`; summary: rates added, rates changed, lines recomputed, bookings still needing a rate.
- `src/airbnb_books/cli.py`: `airbnb-books import-rates <csv> [--currency USD]`, prints the summary.
- Fixture `tests/fixtures/trm_sample.csv`: a few weeks in the real format. Tests: parse; re-import changes nothing; a changed rate recomputes a booking''s COP amount; a bad row is a problem with its line number.
- Done when `pytest`, `ruff check`, `ruff format --check` pass.', '2026-10-23T19:45:01Z', NULL, 29, 1, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (35, 8, 'create tasks for plan 8: data entry screens', 'split', 'done', 1000, '2026-10-23, tasks 36, 37, 38, 39, 40, 41', 'Split `plan 8: data entry screens` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-23T19:46:33Z', '2026-10-23T19:47:27Z', 9, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (36, 8, 'Web frame: layout, form helpers, app on a real DB', 'work', 'open', NULL, NULL, 'First task of `plan 8: data entry screens`; read the plan''s "Ground rules" first. Builds the frame every data entry screen uses.

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

Done when `pytest`, `ruff check`, `ruff format --check` pass and `airbnb-books --db /tmp/x.db --no-browser` serves the pages (checked with `curl`, stopped by PID).', '2026-10-23T19:47:15Z', NULL, 35, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (37, 8, 'Booking screens', 'work', 'open', NULL, NULL, 'Part of `plan 8: data entry screens`; see its "Ground rules" and the "Bookings" bullet. Uses the frame and `web/forms.py` from `task 36: Web frame: layout, form helpers, app on a real DB`; only calls `repo`, never SQL.

- List: newest first, filter by date range and listing, a "needs exchange rate" mark per booking.
- Detail page: totals (net payout, gross, Airbnb fee, co-host cost, nights) and the booking''s lines read-only.
- New (hand-entered stay): check-in, check-out (> check-in), net payout in COP (≥ 0, stored as one `Manual` line by the repo), optional confirmation code (unique), listing (preset when the property has exactly one listing in settings), guest name, guests (> 0 or empty), notes.
- Edit per `decision 17: bookings from the Airbnb import: dates, listing and guest name are read-only in the edit form`: imported bookings only accept guests and notes; hand-entered ones every field including the amount.
- Saving a booking that overlaps another shows a warning flash, not an error.
- Delete: refused with a readable message while expenses point to it; for imported bookings the confirmation text says a re-import brings it back.
- Tests in `tests/test_web.py`: hand-entered booking created with its `Manual` line and correct net payout; edited amount changes the line; check-out ≤ check-in rejected; duplicate code rejected; imported booking (lines added through `repo` in the test) only accepts guests/notes; overlap warns; delete refused while an expense points to it; delete works otherwise.

Done when `pytest`, `ruff check`, `ruff format --check` pass and the pages work against a running `airbnb-books --db /tmp/x.db --no-browser` (checked with `curl`, stopped by PID).', '2026-10-23T19:47:15Z', NULL, 35, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (38, 8, 'Expense and recurring expense screens', 'work', 'open', NULL, NULL, 'Part of `plan 8: data entry screens`; see its "Ground rules" and the "Expenses" and "Recurring expenses" bullets. Uses the frame from `task 36: Web frame: layout, form helpers, app on a real DB`; only calls `repo` and `recurring`.

- Expenses: list filtered by date range and category, generated rows marked with (a link to) their template. Fields: date, amount (> 0), category, booking (picker; required for `per_booking`, hidden otherwise), useful life in days (required and > 0 for `capex`, hint "3 years ≈ 1095"; hidden otherwise), description. Hidden fields are ignored server-side for other categories (a tiny inline script or CSS may hide them; the form must still work without it).
- Recurring expenses: list; fields description, amount (> 0), category (`fixed`, `per_night`, `maintenance`, `tax`), start month, end month (empty or ≥ start). After every save, `generate_recurring(conn, today)` runs so due months appear at once.
- Template edits per `decision 16: changing a recurring expense template only affects months not yet generated`; the template''s page lists its generated expenses with links; deleting a template keeps them.
- Tests: capex without useful life rejected; per-booking without booking rejected; booking/useful life ignored for other categories; filter by category and dates; new template generates its due months; editing a template leaves generated rows unchanged; end month before start rejected; create/edit/delete for both.

Done when `pytest`, `ruff check`, `ruff format --check` pass and the pages work against a running `airbnb-books --db /tmp/x.db --no-browser` (checked with `curl`, stopped by PID).', '2026-10-23T19:47:15Z', NULL, 35, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (39, 8, 'Blocked days and time log screens', 'work', 'open', NULL, NULL, 'Part of `plan 8: data entry screens`; see its "Ground rules" and the "Blocked days" and "Time log" bullets. Uses the frame from `task 36: Web frame: layout, form helpers, app on a real DB`; only calls `repo`.

- Blocked days: list (newest first, date filter); add a range in one form (from, to ≥ from, reason `buffer`/`owner`/`maintenance`/`other`, note); days already blocked are skipped and reported in the flash; a blocked day inside a booking gives a warning. Edit reason/note of one day, delete one day.
- Time log (stored in minutes per `decision 6: own time is stored in whole minutes`): list with hours per entry and the total for the current filter; fields date, hours (> 0, typed per `decision 15: data entry forms: how money and hours are typed`), optional booking (picker), description.
- Tests: a range of 5 days with 2 already blocked adds 3 and reports 2; blocked day inside a booking warns; hours `1:30` stored as 90 minutes and shown as 1.5 h; zero hours rejected; total for a filter; edit and delete for both.

Done when `pytest`, `ruff check`, `ruff format --check` pass and the pages work against a running `airbnb-books --db /tmp/x.db --no-browser` (checked with `curl`, stopped by PID).', '2026-10-23T19:47:15Z', NULL, 35, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (40, 8, 'Settings and exchange-rate screens', 'work', 'open', NULL, NULL, 'Part of `plan 8: data entry screens`; see its "Ground rules" and the "Settings" and "Exchange rates" bullets. Uses the frame from `task 36: Web frame: layout, form helpers, app on a real DB`; only calls `repo`.

- Settings: hourly value of own time (COP, ≥ 0), long-term rental benchmark per month (COP, ≥ 0), per-booking allocation (`check_in` / `spread`), listings of this property (checkboxes of all listings found in bookings, plus a text field for another name; saved as the `property_listings` list), backups to keep (≥ 1); currency shown as COP, not editable. Defaults are shown on an empty DB.
- Exchange rates: list by currency and date; fields date, currency (3 letters, upper-cased, default USD), COP per unit (> 0, up to 2 decimals). Create, edit, delete; after any change call `repo.recompute_lines()` (unless the repo already does) and the flash says how many bookings still need a rate.
- Tests: settings round trip and defaults on an empty DB; negative value rejected; listing choice saved as the `property_listings` list; adding a rate fills the COP amount of a booking that needed one (booking with a USD line created through `repo`); changing the rate recomputes it; invalid currency rejected.

Done when `pytest`, `ruff check`, `ruff format --check` pass and the pages work against a running `airbnb-books --db /tmp/x.db --no-browser` (checked with `curl`, stopped by PID).', '2026-10-23T19:47:15Z', NULL, 35, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (41, 8, 'Import screen', 'work', 'open', NULL, NULL, 'Part of `plan 8: data entry screens`; see its "Ground rules" and the "Import" bullet. Uses the frame from `task 36: Web frame: layout, form helpers, app on a real DB` and the import code of `plan 7: Airbnb CSV import` (`importer`), never SQL.

- Upload the Airbnb CSV → preview of the import plan: new bookings, updated ones with what changed, skipped rows per reason and listing, problems with CSV line numbers, warnings → an "Import" button applies it, then shows the summary.
- When no property listings are chosen yet, the preview shows the listings found as checkboxes; the choice is sent with the apply and saved to settings.
- The uploaded file is kept in a temp directory under a random token between preview and apply (token validated, no path from the user); apply re-parses and re-plans the file; the file is deleted after apply.
- A second upload field loads the TRM exchange-rate CSV and shows its summary.
- Tests with `tests/fixtures/airbnb_sample.csv`: upload on an empty DB asks for listings and imports nothing; choosing listings then applying creates the bookings; uploading the same file again previews nothing new; a broken file shows the file error; the temp file is gone after apply; the TRM fixture upload shows its summary.

Done when `pytest`, `ruff check`, `ruff format --check` pass and the page works against a running `airbnb-books --db /tmp/x.db --no-browser` (checked with `curl -F`, stopped by PID).', '2026-10-23T19:47:16Z', NULL, 35, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (42, 9, 'create tasks for plan 9: dashboard and charts', 'split', 'done', 1000, '2026-10-23, tasks 43, 45, 44', 'Split `plan 9: dashboard and charts` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-23T19:47:43Z', '2026-10-23T19:48:28Z', 10, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (43, 9, 'SVG chart module', 'work', 'open', NULL, NULL, 'Part of `plan 9: dashboard and charts`. Our own small chart drawer, used by the dashboard: inline SVG, no JavaScript, no chart library, no CDN (`architecture-spec.md`, `decision 3: approve the architecture`).

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

**Done when** `pytest`, `ruff check` and `ruff format --check` pass.', '2026-10-23T19:48:11Z', NULL, 42, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (44, 9, 'Dashboard: rolling chart and expense breakdown', 'work', 'open', NULL, NULL, 'Part of `plan 9: dashboard and charts` (read its Layout section). Adds the charts and the capex row to the dashboard built by `task 45: Dashboard: metrics table and period form`, using `web/charts.py` and `metrics.rolling_90`, `metrics.expense_breakdown`, `metrics.capex_book_value`.

**What**
- Rolling chart: two stacked line charts sharing the date axis: money (ADR and RevPAR, COP) and occupancy (0–100 %); one point per day from `metrics.rolling_90`; `None` breaks the line. Fewer than 90 days of history → the text "the 90-day chart starts once 90 days of history exist" and no chart (`decision 13: the rolling 90-day chart starts once 90 days of history exist`).
- Expense breakdown for the custom range if set, else the chosen month (`decision 18: dashboard layout: which periods are shown and which period the cost breakdown uses`): horizontal bar chart plus a small table (category, amount, share %), the six categories in `metrics.expense_breakdown`''s order; all zero → "no costs in this period".
- Last row of the metrics table: remaining capex book value at each period''s end.

**Tests** in `tests/test_web.py`: under 90 days → the message and no chart; 120 days of data → two `<svg>` line charts containing the series labels; the breakdown follows the custom range when given, else the chosen month; the capex row matches `capex_book_value` at the period end.

**Done when** `pytest`, `ruff check` and `ruff format --check` pass and the dashboard works in the browser on a DB with `airbnb_.csv` imported (`airbnb-books --db /tmp/x.db --no-browser`, checked with `curl`, stopped by PID).', '2026-10-23T19:48:11Z', NULL, 42, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (45, 9, 'Dashboard: metrics table and period form', 'work', 'open', 410, NULL, 'Part of `plan 9: dashboard and charts` (read its Layout section; layout per `decision 18: dashboard layout: which periods are shown and which period the cost breakdown uses`). Replaces the placeholder route `/` from `task 36: Web frame: layout, form helpers, app on a real DB`. The page only calls `recurring.load_days`, `metrics` and `repo`, never SQL.

**What**
- `today`: `date.today()` in the route, overridable through the app config in tests; passed to `load_days` and `metrics`.
- Period form (one GET form at the top): month input (`?month=YYYY-MM`, default last month), from/to date inputs (`?from=…&to=…`), Apply, Reset link. Invalid input (bad date, from > to) → that column left out and one message, status 200, never a 500.
- Metrics table, one column per period: all-time, last 90 days, last 30 days, this month, chosen month, custom (only when set). Headers show the period''s dates.
- Rows: available nights, occupied nights, occupancy %, ADR, RevPAR, income, total cost, profit, variable cost per night, break-even occupancy %, long-term rental benchmark, profit vs. long-term rental, hours, profit per hour, profit after own time. (The capex book value row comes in `task 44: Dashboard: rolling chart and expense breakdown`.)
- Formatting: money with the `web/forms.py` formatter (thousands dots, "COP" in the header, not per cell); ratios `57.3 %` (one decimal, break-even above 100 % shown as is); hours one decimal; `None` as a dash (`decision 10: a figure that cannot be computed is shown as empty, not as zero`); negative profit with minus sign and red text.
- Notices above everything: "N bookings need an exchange rate" linking to the rates screen (`task 40: Settings and exchange-rate screens`); an empty DB shows "nothing here yet: import the Airbnb CSV or add a booking" with links instead of the table.

**Tests** in `tests/test_web.py`, temp DB with a booking, a fixed expense and a time entry (hand-checked numbers): all standard columns present; `?month=` and `?from/to` add/change columns; invalid custom range → message and 200; a booking with a USD line without a rate → the notice; empty DB → empty state; None shown as a dash.

**Done when** `pytest`, `ruff check` and `ruff format --check` pass and `/` renders in the browser (`airbnb-books --db /tmp/x.db --no-browser`, checked with `curl`, stopped by PID).', '2026-10-23T19:48:24Z', NULL, 42, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (46, 10, 'create tasks for plan 10: backup, install and final check', 'split', 'done', 1000, '2026-10-23, tasks 47, 48, 49, 50, 51', 'Split `plan 10: backup, install and final check` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-23T19:49:14Z', '2026-10-23T19:50:04Z', 11, 0, NULL, NULL);
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (47, 10, 'Backup module and backup command', 'work', 'open', NULL, NULL, 'Daily and on-demand copies of the live SQLite database into the backup folder (Dropbox by default). Rules: `decision 19: backups: which files are pruned, how many are kept, and what a failed backup does`.

- `backup.py`: `backup(db_path, backup_dir, keep, today)` → path written.
  - Uses `sqlite3.Connection.backup` (online backup, safe while the app runs) into a temp file inside `backup_dir`, then renames it to `books-YYYY-MM-DD.db` (same day overwrites).
  - Creates `backup_dir` if missing.
  - Then prunes: only files matching `books-YYYY-MM-DD.db`, newest `keep` kept, oldest deleted. Any other file is left alone. A failed backup deletes nothing.
- `cli.py`: subcommand `backup [--backup-dir] [--keep]` (backup dir and DB path resolved by `config.py`, `task 19: Paths, connection and migrations runner`). Keep = flag, else setting `backup_keep` (`task 22: Repository: expenses, recurring expenses, blocked days, time log, settings`), else 30. On failure: message on stderr, non-zero exit.
- `serve` and `migrate` pass the backup as `before_migrate` to `storage/db.migrate`; a failed backup there aborts the migration.
- `tests/test_backup.py`: the backup is a readable copy with the same rows; same-day overwrite; pruning keeps N and leaves foreign files alone; keep precedence (flag > setting > 30); migration hook called only for an existing (non-new) DB; failure → non-zero exit.

Done when the tests pass and `airbnb-books backup --backup-dir <tmp>` on a temp DB writes today''s file.', '2026-10-23T19:50:00Z', NULL, 46, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (48, 10, 'Backup on exit and Quit button', 'work', 'open', NULL, NULL, 'The app takes a backup whenever it stops, and gets a Quit button so the owner has a clean way to close it.

- `serve` takes a backup (`backup.py` from `task 47: Backup module and backup command`) when the server stops: Ctrl-C, SIGTERM, or the **Quit** button in the page header (layout from `task 36: Web frame: layout, form helpers, app on a real DB`).
- POST `/quit`: renders "airbnb-books has stopped, you can close this tab", then stops waitress cleanly (after the response is sent).
- A failed backup at exit is printed to stderr; the app still exits (`decision 19: backups: which files are pruned, how many are kept, and what a failed backup does`).
- Tests: `/quit` with the test client triggers the shutdown callback (inject it, don''t kill the test process); the exit path calls the backup exactly once, even if several stop signals arrive.

Done when the tests pass and, by hand: start with `--no-browser` on a temp DB and backup dir, `curl -X POST` the `/quit` URL, the process ends and today''s backup file exists.', '2026-10-23T19:50:00Z', NULL, 46, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (49, 10, 'NixOS and home-manager backup module', 'work', 'open', NULL, NULL, 'A Nix module that installs a daily systemd timer running `airbnb-books backup`, so backups happen even when the app isn''t opened.

- `nix/module.nix`, exposed in `flake.nix` as `homeManagerModules.default` and `nixosModules.default` (NixOS: `systemd.user` units, for all users). One file serves both.
- Options `services.airbnb-books-backup`: `enable`; `package` (default: this flake''s package from `task 18: Nix package, app and flake checks`); `backupDir`; `keep` (default 30); `dbPath` (default null = app default); `onCalendar` (default `"daily"`).
- `airbnb-books-backup.service`: oneshot, runs `airbnb-books backup --backup-dir … --keep …`, plus `--db …` when `dbPath` is set (command from `task 47: Backup module and backup command`).
- `airbnb-books-backup.timer`: `OnCalendar` from the option, `Persistent = true`, wanted by `timers.target`.
- A flake check that evaluates the NixOS module in a minimal `nixosSystem` and asserts the generated unit''s `ExecStart` and timer settings (no VM test). Don''t add home-manager as a flake input just for a check.

Done when `nix flake check` passes.', '2026-10-23T19:50:00Z', NULL, 46, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (50, 10, 'README for the owner', 'work', 'open', NULL, NULL, 'A short `README.md` for the owner: how to install, use, back up and restore the app.

Contents:
- What the app is (one paragraph).
- Install: `nix run`; or the flake as an input with the package and the backup module (`task 49: NixOS and home-manager backup module`), with a home-manager example.
- Run and quit (the Quit button, `task 48: Backup on exit and Quit button`).
- Import the Airbnb CSV: where to download it on Airbnb, the listings question on the first import, re-imports are safe (`task 41: Import screen`, `task 33: Command line Airbnb import`).
- Exchange rates: the TRM file from datos.gov.co, or typing one in (`task 34: Exchange-rate (TRM) import`).
- Backup: on exit, daily timer, where files go, how many are kept, `airbnb-books backup` by hand.
- **Restore**: close the app, copy `books-YYYY-MM-DD.db` over the live DB path, start the app.
- Where the DB lives and how to override it (flag / env var).

Done when every command in the README has been tried once in the dev shell against a temp DB and works as written.', '2026-10-23T19:50:00Z', NULL, 46, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (51, 10, 'End-to-end check with real data', 'work', 'open', NULL, NULL, 'Final run-through of the whole app, checking one month''s numbers independently of the app''s code.

- In the real app on a fresh temp DB: import `airbnb_.csv` (repo root) through the import screen, choose the listings, add the USD rates needed for one chosen month, add a few expenses (a recurring fixed cost, a per-night cost, a capex item with a useful life, a maintenance cost) and a time log entry; open the dashboard.
- Pick one month with several stays (one crossing a month boundary). Recompute its figures independently from the CSV rows and the expenses (a short throwaway script or by hand, not by calling the app''s code): nights, occupancy, income, costs by category, profit, ADR, RevPAR, profit per hour. They must match the dashboard exactly (integer COP).
- Then: Quit, check the backup file, restore it per the README (`task 50: README for the owner`) and see the same dashboard.
- Make it repeatable: `tests/test_e2e.py` does the same on `tests/fixtures/airbnb_sample.csv` (fake guest names; no real names in the repo) and asserts the hand-checked numbers for one month.
- Every mismatch or bug found becomes a follow-up task in the plan it belongs to; don''t fix it here.

Done when `tests/test_e2e.py` passes; the done note names the month checked and the result.', '2026-10-23T19:50:00Z', NULL, 46, 0, 'opus', 'main');

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
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (20, 'Grant task 34: Exchange-rate (TRM) import web access (WebSearch, WebFetch)', 'pending', '["approve"]', '', 'The next piece of work needs to look things up on the internet: search the web and read web pages. Approving allows that for this piece of work only.', NULL, NULL, '2026-10-23T19:58:13Z', NULL, NULL, 'web', 'rule', NULL, '');

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
