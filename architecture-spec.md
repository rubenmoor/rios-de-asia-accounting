# Architecture spec — Airbnb bookkeeping app

How the app described in `airbnb-bookkeeping-spec.md` is built. One recommendation
per question; alternatives only where the choice matters. Name of the app and its
command: **`rios-de-asia-accounting`**.

## 1. Tech stack and UI

- **Language:** Python 3 (the `python3` of nixpkgs). Short code, `sqlite3` in the
  standard library, every dependency already packaged in nixpkgs, easy to test.
- **UI: a local web server on `127.0.0.1`**, opened in the normal browser.
  `rios-de-asia-accounting` starts the server on a free port and opens the browser tab;
  Ctrl-C (or closing via a "Quit" button) stops it. Forms and tables work best in a
  browser; no GUI toolkit to package, no TUI limits for charts.
- **Libraries:** Flask (routes), Jinja2 (HTML templates), waitress (the server).
  Plain HTML forms and server-rendered pages; no JavaScript framework, no build
  step, no CDN, no network access.
- **Charts:** drawn by our own small module as **inline SVG** on the server (line
  chart for the rolling 90-day series, bar chart for the expense breakdown). No
  chart library, works offline.
- **Lint/format:** ruff.

Alternative worth knowing: Haskell or Rust would give a single typed binary, at the
cost of much more code for forms and charts. Not recommended for v1.

## 2. Nix packaging

All in the existing `flake.nix`:

- `packages.default`: `python3Packages.buildPythonApplication` from `pyproject.toml`;
  its check phase runs the tests (`pytestCheckHook`), so `nix build` and
  `nix flake check` run them too.
- `apps.default`: `nix run` starts the app.
- `devShells.default`: keeps `pm`, the `pm` dashboard and git; adds Python with the
  app's dependencies, pytest, ruff and `sqlite` (CLI, for poking at the DB).
- `homeManagerModules.default` and `nixosModules.default` (same options; the NixOS
  one sets up a **systemd user** service for all users):
  `services.rios-de-asia-accounting-backup = { enable; backupDir; keep ? 30; dbPath ? <default>; onCalendar ? "daily"; }`
  → a `rios-de-asia-accounting-backup.service` running `rios-de-asia-accounting backup` and a
  `.timer` with `Persistent = true`.

## 3. Code layout

```
pyproject.toml
src/rios_de_asia_accounting/
  cli.py            entry point: `serve` (default), `backup`, `import <csv>`, `migrate`
  config.py         paths: DB, backup dir (env vars and flags)
  money.py          parsing amounts, currency → COP, rounding
  model.py          plain dataclasses: Booking, Expense, BlockedDay, Day, …
  storage/
    db.py           connection, migrations runner
    migrations/     0001_init.sql, 0002_….sql
    repo.py         all SQL lives here: CRUD, loading the inputs of the engine
  allocation.py     pure: bookings, expenses, blocked days, time log → list[Day]
  metrics.py        pure: list[Day] + range → metrics, rolling series, breakdown
  importer/
    airbnb_csv.py   parse the CSV → import plan; apply it through repo
  backup.py         SQLite online backup + pruning
  web/
    app.py          Flask routes (CRUD screens, import, dashboard)
    charts.py       SVG line and bar charts
    templates/      Jinja2 templates
tests/
  fixtures/airbnb_sample.csv
  test_allocation.py  test_metrics.py  test_money.py  test_import.py
  test_storage.py     test_backup.py   test_web.py
nix/
  module.nix        shared by the home-manager and the NixOS module
```

Boundaries:

- **Only `storage/` writes SQL.** Everything else gets and returns dataclasses.
- **`allocation` and `metrics` are pure** (no DB, no clock: "today" is a parameter),
  so they are tested with small hand-made inputs.
- The per-day view `days` from the product spec is **computed in Python on demand**
  (a few thousand days — instant), not stored. This keeps the integer rounding rule
  in one place: an amount split over *n* days gives each day `amount // n`, and the
  first `amount % n` days get one more, so the days always sum to the exact amount.
- `importer` turns a file into a plan (new / updated / skipped / problems), shown to
  the user before it is applied.
- `web` only calls `repo`, `allocation`, `metrics`, `importer`, `charts`.

## 4. Tests

- **pytest**, run by `pytest` in the dev shell and by `nix build` / `nix flake check`.
- Unit tests for allocation (month lengths, leap years, stays across months, future
  nights not counted, rounding sums) and metrics (hand-checked small data, division
  by zero) on in-memory inputs.
- Storage and import tests on a temporary DB (pytest `tmp_path`).
- Import fixture: `tests/fixtures/airbnb_sample.csv`, a trimmed copy of `airbnb_.csv`
  that keeps one example of every case below (BOM, monthly rows of a long stay,
  co-host payout, adjustment, resolution rows, payout rows, COP and USD, `1,785.00`).
  Guest names in the fixture are replaced with fake ones.
- Web: a few smoke tests with Flask's test client (each page renders, a form posts).

## 5. Database location and migrations

- **Default path:** `$XDG_DATA_HOME/rios-de-asia-accounting/books.db`
  (`~/.local/share/rios-de-asia-accounting/books.db` when unset). Never inside Dropbox.
- **Override:** `--db <path>` or env `RIOS_DE_ASIA_ACCOUNTING_DB`; tests always use a temp file.
- **Backup dir:** `--backup-dir` or env `RIOS_DE_ASIA_ACCOUNTING_BACKUP_DIR`, default
  `~/Dropbox/rios-de-asia-accounting`; keep the last 30 (`--keep`).
- **Backups** use SQLite's online backup API (Python's `Connection.backup`, the same
  mechanism as `sqlite3 … ".backup"`), file `books-YYYY-MM-DD.db`; a second backup on
  the same day overwrites that day's file. Run on server shutdown and by the timer.
- **Migrations:** numbered SQL files in `storage/migrations/`; the DB's
  `PRAGMA user_version` is the last applied number. On every start the app applies
  the missing ones, each in a transaction, after taking a backup if the DB is not
  new. Migrations are never edited once released; fixes are new files.
- `PRAGMA foreign_keys = ON`; dates as ISO text; money as INTEGER.

## 6. Airbnb CSV import

Checked against `airbnb_.csv` (144 rows, 10/2021 – 10/2026).

### File format

- UTF-8 **with BOM** (read with `utf-8-sig`), comma separated, quoted fields, header:
  `Date, Arriving by date, Type, Confirmation code, Booking date, Start date,
  End date, Nights, Guest, Listing, Details, Reference code, Currency, Amount,
  Paid out, Service fee, Fast pay fee, Cleaning fee, Gross earnings,
  Airbnb remitted tax, Earnings year`.
- Columns are found **by header name**, not position; a missing required column is
  an error.
- Dates `MM/DD/YYYY` → ISO. Empty fields are allowed (payout rows have most empty).
- Amounts are decimals with a dot and **sometimes a thousands comma** (`1,785.00`,
  even in COP): strip the commas, parse as exact decimal, never as float.
- `End date` − `Start date` = `Nights` in every row: `End date` is the exclusive
  check-out.

### Row types

| Type (count in sample) | What it is | Import |
|---|---|---|
| `Reservation` (67) | earnings for a stay; **long stays get one row per month**, same code and dates | booking line |
| `Adjustment` (2) | correction of a stay (e.g. partial refund) | booking line |
| `Resolution Adjustment` (2) | money taken back after a resolution case | booking line |
| `Resolution Payout` (2) | AirCover reimbursement (e.g. damage) | booking line |
| `Co-Host payout` (4) | the co-host's share, negative | booking line, but counted as a **per-booking cost**, not as less income |
| `Payout` (67) | bank / PayPal transfer of already-counted earnings (EUR, USD) | **ignored**, only counted in the summary |
| anything else | unknown | not imported, listed as a problem |

### Several rows per confirmation code

- One booking per confirmation code. The rows of a code are stored as
  **booking lines** (new table `booking_lines`: booking, type, date, currency,
  original amount, rate, amount in COP, plus service fee / cleaning fee / gross in
  the original currency).
- Booking totals are sums over its lines:
  `net_payout` = Σ `Amount` in COP of all lines except co-host payouts, `gross` = Σ `Gross earnings` in COP,
  `airbnb_fee` = Σ `Service fee` in COP. `check_in`/`check_out` from the dates.
- **Dedup and re-import:** a line is identified by (code, type, date, amount). A
  re-import adds unknown lines and leaves known ones alone, so importing the same or an
  overlapping export twice changes nothing. Fields the user edited on the booking
  (notes, guests) are kept.
- The CSV has a guest **name**, not a guest count: `guests` stays empty (editable);
  the name goes into a new `guest_name` column.
- Overlapping stays within the imported listings are reported as warnings, not
  errors.

### Listings — the export has more than one

The sample contains **7 listings** (rooms and whole apartments, several active at
the same time), while the product spec is single-property. Recommendation: the
booking stores its `listing` name; a setting **"listings of this property"** says
which listings count. The first import shows the listings found and asks which ones
to keep; rows of other listings are skipped and counted in the summary.
Alternative (not v1): real multi-property support with costs per property.

### Currencies

Reservations are in COP and USD; payouts in EUR (and USD to PayPal); the app
reports in integer COP.

- Each booking line keeps **original currency, original amount** (integer minor
  units, e.g. US cents), **the rate used, and the derived integer COP**.
  COP lines: rate 1, amount rounded half away from zero to whole pesos.
- Rates live in a new table **`exchange_rates`** (date, currency, COP per unit as
  an integer in hundredths, e.g. 4123.45 → 412345). The rate for a line is the
  latest one **on or before the line's `Date`** (the day Airbnb released that money).
- **Where rates come from:** the app has no network access, so the user loads them:
  either by importing the official Colombian TRM history as CSV (downloaded by hand
  from datos.gov.co, "Tasa de Cambio Representativa del Mercado – Histórico"), or by
  typing a rate in the exchange-rate screen. One TRM file covers all years.
- A USD line with no rate on or before its date is imported with COP empty; the
  booking is flagged "needs exchange rate", the dashboard shows how many there are,
  and adding rates recomputes the COP of those lines. Changing a rate recomputes
  every line that uses it.
- **EUR payouts are not used**: they are transfers of earnings already counted in
  the reservation rows, bundle several stays, and are converted by Airbnb at its own
  rate. Using them would count income twice.

## 7. Schema additions to the product spec

- `bookings`: + `listing`, `guest_name`; `gross`, `airbnb_fee`, `net_payout` become
  sums derived from `booking_lines` for imported bookings (bookings entered by hand
  get one line of type `Manual`).
- New tables `booking_lines` and `exchange_rates` as above.
- `settings`: + `property_listings`, `backup_keep`; `currency` stays `COP`.
- Co-host payout lines are a per-booking cost: the allocation engine adds them to
  `cost_per_booking` (check-in or spread, like other per-booking costs), so they show
  in the cost breakdown and in variable cost per night, and follow rate changes.
