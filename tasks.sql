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
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (3, 1, 'write the plan for part 1: architecture spec', 'plan', 'open', 1000, NULL, 'Write the plan for part 1 of `plan 1: masterplan` (see its section "1. Architecture spec"); suggested plan priority 950.

- The plan has one work task (`--model opus`) that writes `architecture-spec.md` from `airbnb-bookkeeping-spec.md`, checked against the real sample `airbnb_.csv`.
- That work task must settle, with one recommendation each: tech stack and UI style, Nix packaging (flake package, dev shell, NixOS / home-manager module), code layout, test approach, DB location and migrations, and the Airbnb CSV mapping including how USD reservations (and EUR payouts) become integer COP.
- After writing the spec, that work task raises one human decision "approve the architecture" (`pm decision add`) and makes every still-open task of `plan 1: masterplan` wait for it (`pm task-pending-decision <task> <decision>`), so no other part is planned against an unapproved architecture. Spell this out in the work task''s body.
- **Ordering:** the other masterplan tasks have priority 1000 and would otherwise run before that work task. So once the plan''s split creates the work task, it must be required by `task 4: write the plan for part 2: project skeleton and Nix packaging` (`pm task requires 4 <work task id>`); tasks 5–11 already chain behind task 4. Say this in the plan body so its split does it.
- Done when the plan exists as described.', '2026-10-23T19:19:29Z', NULL, 2, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (4, 1, 'write the plan for part 2: project skeleton and Nix packaging', 'plan', 'open', 1000, NULL, 'Write the plan for part 2 of `plan 1: masterplan` (section "2. Project skeleton and Nix packaging"); suggested plan priority 920.

- Base it on the approved `architecture-spec.md`.
- Work tasks: source tree, build, test runner, linter/formatter; `flake.nix` keeps the existing dev shell (`pm`, git), adds the toolchain, an app package (`nix build`) and a runnable app (`nix run`); a trivial app that starts and a trivial test that passes.
- Done when the plan exists; its tasks are split afterwards.', '2026-10-23T19:19:29Z', NULL, 2, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (5, 1, 'write the plan for part 3: database schema and storage', 'plan', 'open', 1000, NULL, 'Write the plan for part 3 of `plan 1: masterplan` (section "3. Database schema and storage"); suggested plan priority 900.

- Base it on `architecture-spec.md` (incl. its currency handling) and `airbnb-bookkeeping-spec.md`.
- Covers: SQLite schema (`bookings`, `expenses`, `recurring_expenses`, `blocked_days`, `time_log`, `settings`, plus currency fields), migrations from an empty DB, default DB path outside Dropbox and overridable for tests, the spec''s constraints, settings defaults.
- Its first tasks require the skeleton tasks of part 2 (`--requires` on their ids, see `pm plan list` / `pm show`).', '2026-10-23T19:19:29Z', NULL, 2, 0, NULL, 'main');
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (6, 1, 'write the plan for part 4: daily allocation engine', 'plan', 'open', 1000, NULL, 'Write the plan for part 4 of `plan 1: masterplan` (section "4. Daily allocation engine"); suggested plan priority 650.

- Covers: the per-day `days` view, all allocation rules from the spec, idempotent generation of monthly expenses from recurring ones, an integer rounding rule so per-day amounts sum exactly, thorough unit tests (month lengths, leap years, stays across months, future bookings).
- Tasks require the schema tasks of part 3.
- Consider `--model opus` for the allocation core (subtle rules).', '2026-10-23T19:19:30Z', NULL, 2, 0, NULL, 'main');
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
INSERT INTO task (id, plan_id, subject, kind, status, priority, note, body, created_at, retired_at, created_by_task, web, model, worktree) VALUES (12, 2, 'create tasks for plan 2: architecture spec', 'split', 'open', 1000, NULL, 'Split `plan 2: architecture spec` into tasks and identify all decisions that need to be made. If the plan already has tasks, its
done and dropped ones stay as they are (pm refuses to change them): drop the open ones that no longer fit and add
tasks for what the plan asks beyond them. A task that writes a plan gets `--kind plan`. A task that needs another
task''s result (in this plan or another, in any work tree) requires it: `pm task add … --requires <task id>`, or
`pm task requires <task id> <prerequisite id>` for an existing one; priority is only a hint and orders nothing across
work trees. When you drop an open task that others require and add one in its place, drop it with
`--replaced-by <new task id>`.', '2026-10-23T19:20:02Z', NULL, 3, 0, NULL, NULL);

INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (1, 'Sign off the masterplan of milestone 1: first version build', 'answered', '["approve"]', '', 'This is the overall roadmap for building the first working version of a small, private bookkeeping app for one Airbnb apartment. The app turns every booking and every cost into amounts per calendar day, so it can answer whether hosting pays off, whether prices are set well, and how things are trending. The roadmap splits the build into parts, starting with a short architecture document the owner approves before anything else is built, and ending with a check against the real Airbnb export.

Approving lets the work described here go ahead.', 'approve', NULL, '2026-10-23T19:15:40Z', '2026-10-23T19:19:03Z', NULL, 'masterplan', 'rule', NULL, '');
INSERT INTO decision (id, subject, status, options, body, intro, answer, reason, created_at, closed_at, created_by_task, signoff, kind, decided_by_task, consequences) VALUES (2, 'Sign off plan 2: architecture spec', 'pending', '["approve"]', '', 'Before any code is written, the owner needs a short document that fixes the big technical choices for the bookkeeping app: what it is built with, what the screen looks like, how it is installed, where the data file lives, and how the Airbnb export is read, including how bookings paid in dollars become pesos. Writing this down first, and having the owner approve it, means every later piece is built on choices the owner has agreed to, instead of being reworked afterwards.

Approving lets the work described here go ahead.', NULL, NULL, '2026-10-23T19:20:03Z', NULL, NULL, 'plan', 'rule', NULL, '');

INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (1, 1, '2026-10-23T19:14:37Z', '2026-10-23T19:15:40Z', 'done', NULL, 0, 'cd3d42740dd5ea9c8707207210ebd4e93c9b80c8', NULL, 'claude-opus-5-5', '0b74794a-06e2-4f40-8b9d-b839a74c0101', NULL, 6, 12, 5937, 151146, 39344, 0.46376920000000005, 39881, 60, 1445179);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (2, 2, '2026-10-23T19:19:04Z', '2026-10-23T19:19:45Z', 'done', NULL, 0, 'c3af31b31bf19a0c813d5df39657354d2953594e', NULL, 'claude-opus-5-5', 'a4465501-56c2-4e5c-ada6-af51d0d966e0', NULL, 6, 12, 4235, 176178, 25654, 0.32521560000000005, 37524, 60, 1445179);
INSERT INTO run (id, task_id, started_at, ended_at, result, reason, exit_code, base_commit, worktree, model, session_id, continues_run, turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, context_tokens, cache_minutes, pid) VALUES (3, 3, '2026-10-23T19:19:43Z', NULL, 'running', NULL, NULL, 'c3af31b31bf19a0c813d5df39657354d2953594e', 'main', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 1445179);

INSERT INTO task_decision (task_id, decision_id) VALUES (2, 1);
INSERT INTO task_decision (task_id, decision_id) VALUES (12, 2);

INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (4, 3);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (5, 4);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (6, 5);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (7, 6);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (8, 7);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (9, 8);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (10, 9);
INSERT INTO task_prerequisite_tasks (task_id, prerequisite_id) VALUES (11, 10);
