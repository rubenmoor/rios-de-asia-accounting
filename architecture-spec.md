# Architecture spec — Airbnb bookkeeping app

How the app described in `airbnb-bookkeeping-spec.md` is built. One recommendation
per question; alternatives only where the choice matters. Name of the app and its
command: **`rios-de-asia-accounting`**.

## 1. Tech stack and UI

Binding: `decision 24: client-side framework: React with TypeScript, built by Vite, on top of a JSON API from the existing Python server` and `decision 25: In which order do the visual design update and the new client-side framework happen, and does the design work move onto the new screens?`.

- **Backend language:** Python 3 (the `python3` of nixpkgs). Short code, `sqlite3` in
  the standard library, every dependency already packaged in nixpkgs, easy to test.
- **Backend:** Flask (routes) served by waitress on `127.0.0.1`. It stays the
  **authoritative** side: parsing, validation, money and date rules live in Python;
  the client only shows data and sends what the user typed. It serves a **JSON API
  under `/api`** (resources, shapes and errors are in the "JSON API" section below)
  and the built client bundle.
- **UI: a single-page app in the normal browser.** `rios-de-asia-accounting` starts the
  server on a free port and opens the browser tab. The app is a classic web app whose
  server happens to run locally. The server never stops by itself: Ctrl-C or
  SIGTERM stops it (with a backup).
- **Client stack** (in `frontend/`, built by Vite):
  - React 19 with TypeScript in strict mode;
  - React Router, with the app's URLs: `/` (dashboard) and the `NAV` paths of
    `frontend/src/nav.ts` (`/bookings`, `/expenses`, `/recurring`,
    `/settings`), plus a not-found page; the Airbnb CSV import is a panel on the Bookings page;
  - TanStack Query for server data; `frontend/src/api.ts` is the only place that calls
    `fetch` (relative URLs, JSON in and out, an `ApiError` carrying status, field
    errors and text);
  - Tailwind CSS v4 and daisyUI 5 for styling, with one custom light daisyUI theme,
    `ledger` (`frontend/src/index.css`): no dark mode, no theme switcher
    (`decision 28: visual design: one light ledger theme, no dark mode`); the shared
    conventions are in README.md, "Styling conventions";
  - Biome for lint and format, Vitest for pure helpers (and the API error parsing).
- **Charts:** drawn in the client from the data of the JSON API (the dashboard plan
  picks the way to draw them); no library call goes to the network.
- **Network:** the server reaches the network only to fetch exchange rates (section 6, "Currencies");
  the page itself loads nothing from outside: no CDN, no web fonts, everything it needs is in the bundle.
- **Same-origin guard:** every write (`POST`, `PUT`, `PATCH`, `DELETE`) must come from
  the app's own origin; the server rejects others. The client only uses relative URLs.
- **Backend lint/format:** ruff.

Alternative worth knowing: Haskell or Rust would give a single typed binary, at the
cost of much more code for forms and charts. Not recommended for v1.

## 2. Nix packaging

All in the existing `flake.nix`:

- `frontend`: a `buildNpmPackage` derivation with `importNpmLock` from
  `frontend/package-lock.json` (offline build, nothing fetched at build time beyond
  the locked packages); it runs `npm run build` and its `dist` is the output.
- `packages.default`: `python3Packages.buildPythonApplication` from `pyproject.toml`;
  the `frontend` `dist` is copied into `src/rios_de_asia_accounting/web/dist` before
  the Python build, so the bundle ships as package data. Its check phase runs the
  tests (`pytestCheckHook`), so `nix build` and `nix flake check` run them too.
- `apps.default`: `nix run` starts the app with the bundle inside.
- `checks`: the existing ones plus `frontend-lint` (`biome check`, `tsc --noEmit`,
  `vitest run`).
- `devShells.default`: keeps `pm`, the `pm` dashboard and git; adds Python with the
  app's dependencies, pytest, ruff, `sqlite` (CLI, for poking at the DB) and `nodejs`
  (for `npm run dev` and the other frontend scripts).
- `homeManagerModules.default` and `nixosModules.default` (same options; the NixOS
  one sets up a **systemd user** service for all users):
  `services.rios-de-asia-accounting-backup = { enable; backupDir; keep ? 30; dbPath ? <default>; onCalendar ? "daily"; }`
  → a `rios-de-asia-accounting-backup.service` running `rios-de-asia-accounting backup` and a
  `.timer` with `Persistent = true`.

## 3. Code layout

```
pyproject.toml
flake.nix  flake.lock
frontend/
  package.json  package-lock.json
  vite.config.ts  tsconfig.json  biome.json
  src/
    main.tsx        entry: QueryClient, router, mount
    api.ts          fetch wrapper, API types, ApiError
    nav.ts          the navigation entries
    pages/          one component per screen
    components/     shared form kit, notices
    charts/         chart maths and the SVG line and bar charts
src/rios_de_asia_accounting/
  cli.py            entry point: `serve` (default), `backup`, `import <csv>`, `migrate`
  config.py         paths: DB, backup dir (env vars and flags)
  money.py          parsing amounts, `to_usd` (original minor units + rate → US cents), rounding
  model.py          plain dataclasses: Booking, Expense, Day, …
  storage/
    db.py           connection, migrations runner
    migrations/     0001_init.sql, 0002_….sql
    repo.py         all SQL lives here: CRUD, loading the inputs of the engine
  rates.py          fetch exchange rates (datos.gov.co, Frankfurter); parsing split from HTTP
  conversion.py     rate cache and coverage, converting waiting entries to US cents
  allocation.py     pure: bookings, expenses → list[Day]
  metrics.py        pure: list[Day] + range → metrics, rolling series, breakdown
  importer/
    airbnb_csv.py   parse the CSV → import plan; apply it through repo
  backup.py         SQLite online backup + pruning
  web/
    app.py          Flask: same-origin guard, JSON API under /api, bundle serving
    app_db.py       one DB connection per request
    forms.py        parsers and messages for typed input (`Form`, `parse_*`, `format_*`)
    api/            the JSON API: one blueprint, one module per resource
    dist/           built client bundle: git-ignored, package data (`web/dist/**/*`)
tests/
  fixtures/airbnb_sample.csv
  test_allocation.py  test_metrics.py  test_money.py  test_import.py
  test_storage.py     test_backup.py   test_forms.py   test_api_<resource>.py
  test_e2e.py         test_frontend_serving.py
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
- `web` only calls `repo`, `allocation`, `metrics`, `importer`. The client talks to the server only through `/api`.

Serving the bundle (Flask, in `web/app.py`):

- Assets are served at `/assets/…` from `web/dist`.
- Every `GET` that no Flask route matches and that is not under `/api` gets
  `web/dist/index.html` (a 404 handler, not a catch-all route), so the client router
  handles the screen URLs. Unknown `/api` paths stay a JSON 404.
- Without a built bundle (pytest, Python-only work) the fallback answers a short
  plain 404 "frontend not built"; tests never need the bundle.

Dev workflow:

- Two terminals: the server (`rios-de-asia-accounting --no-browser --port 8080`) and
  `npm run dev` in `frontend/` (Vite dev server on port 5173, serves the app at every
  URL).
- Vite proxies `/api` to the server on 8080 and rewrites the `Origin` header to the
  target so the same-origin guard passes; the guard is never weakened.
- `npm run build` in `frontend/` writes `web/dist`, so Flask serves the bundle itself.
- Frontend scripts: `dev`, `build`, `typecheck` (`tsc --noEmit`), `lint`
  (`biome check`), `test` (`vitest run`).

### JSON API

Code: package `web/api/`, one Flask blueprint at `/api`, one module per resource;
helpers in `web/api/common.py`. The API reuses the parsers of `web/forms.py`; the
client's TypeScript types mirror the endpoint list at the end of this section.

- **Input:** a write request sends a JSON object of strings exactly as typed
  (`{"net_payout": "1.234.567", "check_in": "2026-01-05"}`), multi-value fields as
  arrays of strings. It is read by `read_form()` into `Form(data, lists)`, so the
  parsers and messages are the server's. A body that is not such an object → `400`.
  File uploads are `multipart/form-data`.
- **Money:** inputs are an `amount` as typed plus a `currency` (`USD`, `COP` or `EUR`;
  `decision 39: money entry: an amount with a currency choice (USD, COP, EUR)`): COP whole
  pesos, USD and EUR up to 2 decimals (the last `.` or `,` followed by 1–2 digits at the end
  is the decimal mark). The `options` endpoints of forms with money carry `currencies` and
  `default_currency` (the currency of the most recently saved expense, `USD` when there is none).
- **Output values:** money as integer US cents (`amount`, `net_payout`, …), `null` while the entry
  waits for a rate; entries that were converted also carry what was typed (`original_minor`
  in minor units, `currency`) and the conversion (`rate`, currency units per USD × 1 000 000, and
  `rate_date`); dates `YYYY-MM-DD`, months `YYYY-MM`,
  ratios as plain numbers (0.42, not 42 %). A figure that cannot be computed is
  `null`, never `0` (`decision 10: a figure that cannot be computed is shown as empty, not as zero`).
  Display formatting is the client's (see the display currency below).
- **Reads (`GET`):** return the resource JSON directly. Options a form needs come
  with a small `GET /api/<resource>/options`.
- **Writes (`POST` create, `PUT` update, `DELETE`):** `200 {"data": <saved item or null>, "notices": [...]}`
  (`ok(data, notices)`).
- **Notices** (short messages shown above the screen): `{"level": "info" | "warning" | "error", "text": "…"}`
  with the server's texts.
- **Errors:** invalid input → `422 {"errors": {"<field>": "<message>"}}`, one message
  per field from the parsers, form-level errors (repo `ValidationError`) under key `""`
  (`invalid(form, exc)`). Everything else under `/api` is `{"error": "<text>"}`:
  `400` bad body, `403` cross-origin write, `404` unknown path or id, `405` bad method.
- **Same-origin guard:** applies to every non-`GET` method.

Endpoints (method, path, request → response):

- `GET /api/bookings?from=&to=&listing=` — filters optional (`from`/`to` are days;
  a bad one → `422 {"errors": {"from": …}}`) → list, newest check-in first, of
  `{id, check_in, check_out, guest_name, listing, nights, net_payout, waiting}`;
  `net_payout` is US cents, `null` when `waiting` (a line of the booking has no rate yet).
- `GET /api/bookings/<id>` — `{id, check_in, check_out, airbnb_code, listing, guest_name,
  guests, notes, nights, imported, waiting, net_payout, gross, airbnb_fee,
  cohost_cost, manual_amount, manual_currency, lines: [{date, type, currency, amount_minor,
  amount_usd, rate, rate_date}]}`; totals are US cents and `null` when `waiting`, `amount_usd`
  `null` (and `rate`, `rate_date`) for a line without rate, `manual_amount` and `manual_currency`
  (what was typed for the Manual line) `null` for imported bookings; `imported` = has
  Airbnb lines.
- `GET /api/bookings/options` — `{"listings": ["…"]}`.
- `POST /api/bookings` — `{check_in, check_out, amount, currency, airbnb_code?, listing?,
  guest_name?, guests?, notes?}` → `{data: <detail>, notices}` ("Booking saved." `info`;
  overlap `warning`; no rate yet `warning`, see "Currencies").
- `PUT /api/bookings/<id>` — same fields; an imported booking accepts only `guests` and
  `notes` (`decision 17: bookings from the Airbnb import: dates, listing and guest name are read-only in the edit form`)
  → as `POST`.
- `DELETE /api/bookings/<id>` — → `{data: null, notices: ["Booking deleted."]}`; refused
  while it has expenses → `422 {"errors": {"": "Booking not deleted: …. Delete its expenses first."}}`.
- `GET /api/expenses?from=&to=&category=` — filters optional (bad value → `422`) → list,
  newest first, of `{id, date, amount, category, booking_id, useful_life_days,
  description, recurring_expense_id, original_minor, currency, rate, rate_date, waiting}`
  (`amount` US cents, `null` when `waiting`).
- `GET /api/expenses/<id>` — one such item.
- `GET /api/expenses/options` — `{"categories": ["fixed", …], "bookings": [{"id", "label"}]}`
  (newest booking first).
- `POST /api/expenses`, `PUT /api/expenses/<id>` — `{date, amount, currency, category, description?,
  booking_id? (per_booking, required there), useful_life_days? (capex, required there)}`
  → `{data: <item>, notices: ["Expense saved."]}` (a `warning` instead when no rate could be
  fetched: the expense is saved and waits).
- `DELETE /api/expenses/<id>` — → `{data: null, notices: ["Expense deleted."]}`.
- `GET /api/recurring` — list of `{id, description, amount_minor, currency, category, start_month,
  end_month}` (the template keeps its amount in its own currency, unconverted; months `YYYY-MM`, `end_month` may be `null`).
- `GET /api/recurring/options` — `{"categories": [...]}`.
- `GET /api/recurring/<id>` — the item plus `generated`: its expenses (expense items, newest first).
- `POST /api/recurring`, `PUT /api/recurring/<id>` — `{description, amount, currency, category,
  start_month, end_month?}` → `{data: <item with generated>, notices: ["Recurring expense
  saved; N expense(s) generated."]}`; only months not yet generated are affected
  (`decision 16: changing a recurring expense template only affects months not yet generated`).
- `DELETE /api/recurring/<id>` — → `{data: null, notices: ["Recurring expense deleted;
  the expenses it generated are kept."]}`.
- `GET /api/rates/waiting` — `{waiting}`: how many entries (expenses, bookings with a waiting line,
  the long-term rent) wait for a rate.
- `POST /api/rates/fetch` — fetches the rates of all waiting or provisional entries now (the "Fetch
  rates now" button) → `{data: {waiting}, notices: [<info "All entries are converted to USD." or
  warning "N entries wait for an exchange rate …">]}`. There are no endpoints to type or list rates.
- `GET /api/settings` — `{long_term_rent_usd, long_term_rent_entered,
  per_booking_allocation, backup_keep, listings, last_backup}` (`listings` array of strings; the rent
  is US cents, `null` while it waits for a rate, `long_term_rent_entered` is `{original_minor,
  currency, date, rate, rate_date}` as typed (`decision 41: settings amounts are stored in USD and typed in any currency at the rate of the day they are saved`);
  `last_backup` is `{time, file, error}` of the latest backup attempt, `null` before the first;
  `decision 45: backups while the app runs: at start, then every hour when something changed, plus at stop`).
- `GET /api/settings/options` — `{"allocations": ["check_in", "spread"], "listings": [names known from bookings], "currencies", "default_currency"}`.
- `PUT /api/settings` — `{long_term_rent, long_term_rent_currency, per_booking_allocation,
  backup_keep, listings: [..]}` → `{data: <settings>, notices: ["Settings saved."]}`.
- `GET /api/display` — `{currency, rate, rate_date, currencies}`: the display currency and its rate
  (currency units per USD × 1 000 000; USD: `1000000`, `rate_date` `null`).
- `PUT /api/display` — `{currency}` (`USD`, `COP` or `EUR`, else `422`) → `{data: <display>, notices}`. USD needs
  no rate; otherwise today's rate is fetched (`rate_on`) and stored with the currency
  (`decision 48: display currency: kept in settings with the rate fetched when it was chosen, switched and shown in the page header`).
  If no rate can be had nothing is saved, the answer is the unchanged display and a `warning` notice.
- `GET /api/dashboard?month=&from=&to=` — periods chosen by query parameters
  (`decision 18: dashboard layout: which periods are shown and which period the cost breakdown uses`)
  → `{form: {month, from, to}, waiting, empty, columns: [{label, start, end}],
  rows: [{key, label, kind: int|pct|money, values}], rolling_90: [{date, adr, revpar, occupancy}],
  breakdown: {start, end, items: [{key, label, amount, share}]} | null, notices}`. `form` holds the
  effective choices (`month` `YYYY-MM`, default last month, or the raw text when invalid). One value per
  column, `null` where uncomputable (`decision 10: a figure that cannot be computed is shown as empty, not as zero`);
  `pct` is a ratio, `money` US cents. Rows end with `capex_book_value`.
  `rolling_90` is empty before 90 days of history (`decision 13: the rolling 90-day chart starts once 90 days of history exist`);
  `empty` (no data at all) leaves `columns`, `rows` empty and `breakdown` `null`. Invalid periods are `error` notices, not `422`.
- `POST /api/import/airbnb` — `multipart/form-data` with `file` → `{data: {token, needs_listing_choice,
  listings_found: [{listing, rows}], listings, new: [booking], updated: [booking], skipped: {payouts,
  known_lines, listings: [{listing, rows}]}, problems: [{line, message}], warnings}, notices: []}`, where
  `booking` is `{code, listing, guest, check_in, check_out, lines, changes: [{field, old, new}]}`; no or
  unreadable file → `422 {errors: {file}}`. Nothing is imported yet; the upload is kept under `token`.
- `POST /api/import/airbnb/apply` — `{token, listings?: [..], other_listing?}` → `{data: {new, updated,
  lines_added, waiting, skipped, problems, warnings}, notices: []}`; no listing chosen while one is
  needed → `422 {errors: {listings}, preview: <the data of the upload step>}`; unknown or gone `token` →
  `422 {errors: {token}}` (a malformed token is `404`).
- `DELETE /api/import/airbnb/<token>` — drops the kept upload → `{data: null, notices: ["Import cancelled; nothing was changed."]}`.

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
- Web: a few tests with Flask's test client on the JSON API (one file per resource),
  the bundle fallback, and an end-to-end scenario with hand-computed numbers
  (`tests/test_e2e.py`), all driven through `/api`.
- Frontend: `npm run typecheck`, `npm run lint` and `npm test` (Vitest, only pure
  helpers such as the API error parsing) in `frontend/`; run by the `frontend-lint`
  check in `nix flake check`.

## 5. Database location and migrations

- **Default path:** `$XDG_DATA_HOME/rios-de-asia-accounting/books.db`
  (`~/.local/share/rios-de-asia-accounting/books.db` when unset). Never inside Dropbox.
- **Override:** `--db <path>` or env `RIOS_DE_ASIA_ACCOUNTING_DB`; tests always use a temp file.
- **Backup dir:** `--backup-dir` or env `RIOS_DE_ASIA_ACCOUNTING_BACKUP_DIR`, default
  `~/Dropbox/rios-de-asia-accounting`; keep the last 30 (`--keep`).
- **Backups** use SQLite's online backup API (Python's `Connection.backup`, the same
  mechanism as `sqlite3 … ".backup"`), file `books-YYYY-MM-DD.db`; a second backup on
  the same day overwrites that day's file. Taken by a background thread of `serve` right after start and then
  every hour, skipped when nothing was written since the last one (`decision 45: backups while the app runs: at start, then every hour when something changed, plus at stop`),
  once more on server shutdown (Ctrl-C, SIGTERM), and by the optional timer. A failure goes to stderr and
  to `last_backup`; the app keeps running.
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
  original amount, rate, rate date, amount in US cents, plus service fee / cleaning fee / gross in
  the original currency and, converted, in US cents).
- Booking totals are sums over its lines:
  `net_payout` = Σ `Amount` in US cents of all lines except co-host payouts, `gross` = Σ `Gross earnings`
  in US cents, `airbnb_fee` = Σ `Service fee` in US cents (the `booking_totals` view, which also says
  whether a line is `waiting`). `check_in`/`check_out` from the dates.
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

Reservations are in COP and USD; payouts in EUR (and USD to PayPal). The books run on
**US cents** (`decision 34: money is stored in US cents, and every converted entry keeps what was typed`).

- Every converted entry (booking line, expense) keeps **what was typed** (original amount in
  minor units, currency), **the rate** (currency units per USD × 1 000 000) **and its date**, and the
  derived USD amount: `usd = original × 1 000 000 ÷ rate`, rounded half away from zero. USD entries
  use rate 1 000 000 and need no fetch. Recurring templates and the long-term rent keep their amount
  in the currency typed.
- **Where rates come from** (`decision 35: exchange rates: TRM from datos.gov.co for COP, ECB via Frankfurter for EUR, cached per day`),
  both without a key, fetched by date range with Python's `urllib` (10 s timeout, a User-Agent;
  `rates.py`):
  - COP: the official TRM from datos.gov.co, dataset `32sa-8pi3`, SODA JSON API
    (`https://www.datos.gov.co/resource/32sa-8pi3.json`); a rate is valid from `vigenciadesde` to
    `vigenciahasta` (weekends and holidays carry the Friday rate).
  - EUR: the ECB's reference rates through Frankfurter v2
    (`https://api.frankfurter.dev/v2/rates`, `base=USD`, `quotes=EUR`, `providers=ECB`); working days only.
  Network, HTTP and format problems are one error, `RateUnavailable`.
- **Cache:** table `exchange_rates` (date, currency, rate), plus `rate_coverage` (currency, the day
  up to which the source has answered). The rate for a day is the latest cached one on or before it. A
  miss fetches a range for all missing days of the currency at once and stores the answer; the same range
  is not asked again within five minutes unless the user presses "Fetch rates now".
- **Reference date** (`decision 36: reference date of a conversion: check-in for Airbnb income, the entry's own date for expenses`):
  every line of a booking (Airbnb or hand-entered) uses the booking's check-in; an expense its date; a
  generated monthly expense the 1st of its month; the long-term rent the day it was saved. Changing that
  date, the amount or the currency converts the entry again.
- **Waiting entries** (`decision 37: when no exchange rate can be fetched, entries are saved and wait for their rate`):
  saving and importing never fail for lack of a rate. The entry is stored with its original amount and
  USD empty (`NULL`), is left out of allocation and metrics, and a `warning` notice says so; the
  dashboard, bookings and expenses screens show how many wait, with a "Fetch rates now" button. Conversion
  is retried (`convert_waiting`) when the app starts (after migrating and generating recurring expenses),
  before the dashboard is built, after each save and Airbnb import, and by `POST /api/rates/fetch`. An entry
  dated after the coverage (a future check-in, today's EUR rate before the ECB publishes it) is converted
  with the latest known rate and converted again once coverage reaches its day.
- **Migration of the peso books** (`decision 38: existing peso books are converted by the app itself after the migration`):
  `0004_usd.sql` keeps every old amount as the original (COP, or the line's own currency), sets USD empty
  and drops the old typed rates; the next start converts them through the steps above. There is no
  one-off command. Offline, those entries wait until a connection exists
  (`decision 40: the Rates page, typed rates and the TRM file import go; no offline fallback`: there is no
  screen, CSV import or CLI command to enter rates by hand).
- **Money entry:** an amount and a currency choice, on expenses, recurring templates, hand-entered
  bookings and the settings.
- **Display currency** (`decision 46: display currency: amounts are converted in the browser, the server keeps answering in USD`,
  `decision 47: display currency: number formats per currency`, decision 48): the API keeps answering in US
  cents. Settings keys `currency` (default `USD`; `0005_display_currency.sql` resets old values) and
  `display_rate` (JSON `{rate, rate_date}`, absent for USD) hold the choice and the rate fetched when it was
  made, kept until the next switch. The client (`useDisplay()`, query key `["display"]`; `format.ts`
  `toDisplay`, `formatDisplay`) multiplies cents by that rate, rounded half away from zero, and formats:
  COP whole pesos, USD and EUR two decimals, `.` for thousands and `,` for decimals, the code never a symbol.
  Chart series are converted before plotting. A USD / COP / EUR select in the page header switches it
  (`PUT /api/display`) and shows "1 USD = 4.123,45 COP · rate of 2026-10-23" (hidden for USD). Hover texts,
  edit forms and the booking line's original amount and rate keep showing what was typed.
- **EUR payouts are not used**: they are transfers of earnings already counted in
  the reservation rows, bundle several stays, and are converted by Airbnb at its own
  rate. Using them would count income twice.

## 7. Schema additions to the product spec

- `bookings`: + `listing`, `guest_name`; `gross`, `airbnb_fee`, `net_payout` become
  sums derived from `booking_lines` for imported bookings (stays booked outside Airbnb, entered by hand,
  get one line of type `Manual`).
- New tables `booking_lines`, `exchange_rates` and `rate_coverage` as above; `expenses` keeps
  `amount` (US cents, nullable) + `original_minor`, `currency`, `rate`, `rate_date`.
- `settings`: + `currency`, `display_rate`, `property_listings`, `backup_keep`, `long_term_rent_usd` and `long_term_rent_entered`
  instead of the COP rent.
- Co-host payout lines are a per-booking cost: the allocation engine adds them to
  `cost_per_booking` (check-in or spread, like other per-booking costs), so they show
  in the cost breakdown and in variable cost per night, and are left out while waiting for a rate.
