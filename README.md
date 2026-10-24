# rios-de-asia-accounting

A small local bookkeeping app for one Airbnb apartment. It imports Airbnb's earnings CSV, lets you
add expenses, and shows on a dashboard whether the apartment makes money: income, costs, profit,
occupancy and average nightly rate. Everything runs on your own
computer; the data is one SQLite file.

## Install

Run it without installing:

```sh
nix run github:rubenmoor/rios-de-asia-accounting
```

Or use the flake as an input (package and daily backup module):

```nix
inputs.rios-de-asia-accounting.url = "github:rubenmoor/rios-de-asia-accounting";
```

Home-manager example (`inputs.rios-de-asia-accounting.homeManagerModules.default` goes into the home-manager
modules; NixOS uses `nixosModules.default` and installs the timer for all users):

```nix
{ inputs, ... }: {
  imports = [ inputs.rios-de-asia-accounting.homeManagerModules.default ];
  home.packages = [ inputs.rios-de-asia-accounting.packages.x86_64-linux.default ];
  services.rios-de-asia-accounting-backup = {
    enable = true;
    backupDir = "/home/me/Dropbox/rios-de-asia-accounting";
    keep = 30;                # optional, default 30
    onCalendar = "daily";     # optional, default "daily"
    # dbPath = "/path/to/books.db";   # optional, default: see "Where the data lives"
  };
}
```

## Run

```sh
rios-de-asia-accounting            # starts the app and opens the browser
rios-de-asia-accounting --no-browser --port 8080
```

Stop it with Ctrl-C in the terminal (or `systemctl stop` for a service). A backup is taken when it
stops.

## Develop

The screens are a React app in `frontend/` that talks to the JSON API under `/api`. Two terminals:

```sh
rios-de-asia-accounting --no-browser --port 8080     # terminal 1: the server
cd frontend && npm install && npm run dev            # terminal 2: http://localhost:5173
```

The dev server proxies `/api` to the server on port 8080. `npm run build` writes the bundle to
`src/rios_de_asia_accounting/web/dist/`; the Flask server then serves it itself, at every path it
has no page for. Checks: `npm run typecheck`, `npm run lint`, `npm test`.

## Build

- `nix build` builds the app with the client bundle inside (`result/bin/rios-de-asia-accounting`);
  `nix flake check` builds it too and runs all checks.
- `cd frontend && npm run build` writes a local bundle to `src/rios_de_asia_accounting/web/dist/`
  (git-ignored) so a Python-only checkout can serve the screens.
- Where the checks run:
  - Python: `pytest`, `ruff check src tests`, `ruff format --check src tests` in the dev shell;
    pytest needs no bundle.
  - Client, in `frontend/`: `npm run typecheck`, `npm run lint`, `npm test`.
  - `nix flake check` runs all of them (pytest in the package build, ruff in `lint`, the
    `npm` checks in `frontend-lint`) plus the backup module test.

## Styling conventions

The look is one light daisyUI theme, `ledger` (`frontend/src/index.css`). Pages stick to these conventions so the design can change in one place:

- **Money:** figures are shown through `useDisplay().money(cents)` (`frontend/src/useDisplay.ts`; `AmountCell` and `showMoney` use it), never by calling `formatMoney` directly; charts convert their series with `convert`. Hover texts, edit forms and the booking line's "Original" and "Rate" columns keep showing what was typed.
- **Numbers:** class `num` (monospace, tabular, right-aligned); negatives also get `neg` (red ink).
- **Tables:** only through `DataTable`; pages add no table classes of their own. It renders `table sheet` (the `sheet` class in `index.css`: grid lines in the ledger rule colour, `base-200` header cells, zebra rows, row hover, heavier rule above footer rows) inside `overflow-x-auto`, with a decorative frame like a spreadsheet's: a letter row (A, B, C …) above the header and a row-number gutter on the left, both `aria-hidden`.
- **Key/value sheets:** a `table sheet` whose rows start with a `th` label (styled `base-200` by `sheet`); money values `num`.
- **Table footers (totals):** pass `<SheetFooterRow>` (from `DataTable.tsx`, adds the gutter cell) as `footer`; total cells get `num`.
- **Negative cells:** `negative?: (row) => boolean` on a `Column` adds `neg`; only the colour changes, never the text.
- **Headings:** `PageTitle` (h1) and `SectionTitle` (h2) from `components/Titles.tsx`, never hand-written heading classes.
- **Forms:** `Field` (label, muted hint line, `text-error` message with a warning mark) plus the inputs in `inputs.tsx` (full width; hours and numbers are `num`; money is `AmountInput`, an amount with a USD/COP/EUR select). A form sits in a `FormSlip` (`components/FormSlip.tsx`): the journal entry slip, a bordered paper card with a header strip (`label`, optional `aria-hidden` `stamp`) and a red margin rule. The `inked` class is for read-only values shown as text.
- **Form actions:** `FormActions` is the ruled row under a form, primary first. `FormError` is the page-level error above a form (`alert alert-error` with icon).
- **Buttons:** `btn btn-primary` for Save/Apply, `btn btn-ghost` for Cancel/Back/Reset, `btn btn-error btn-outline btn-sm` for the Delete trigger (via `ConfirmDelete`, a small "Void entry" slip dialog; its Delete is `btn-error`, its Cancel `btn-ghost`). Filter bars (list pages, dashboard period) are a `Toolbar` (`components/Toolbar.tsx`): the formula-bar strip (`base-200`, bordered, `fx` mark) with `ToolbarField` short labels and `input-sm`/`select-sm` controls, Filter/Apply `btn-sm` (`btn-secondary` or `btn-primary`), filter errors below the strip.
- **Entry row:** new Expenses and Recurring entries are typed in a row at the bottom of the sheet: pass a `SheetEntryRow` (gutter "+" mark, highlighted, `input-sm`/`select-sm` filling the cells) as `DataTable`'s `entry`. A "+" button (`btn btn-primary btn-sm btn-square`, `aria-label`) opens it, as the `Toolbar` `action` or, without a toolbar, above the sheet on the right. Inputs belong to a `<form>` through the `form` attribute (Enter saves, Escape cancels); errors show under each input via `FieldError`, page-level ones in `FormError`; dates default to today (local). Editing stays on its own page. Bookings keep their "Add a stay booked outside Airbnb" link.
- **Errors:** page-level `FormError` / `alert alert-error`; field-level under the field (done by `Field`).
- **Hints:** `Field`'s `hint`. Muted notes: `opacity-70`.
- **Icons:** inline SVG components in `frontend/src/components/icons.tsx` (no icon fonts, no CDN). `Logo` (the open-ledger mark) sits before the app name in the navbar.
- **Section icons:** one per nav entry in `icons.tsx` (`BookingsIcon`, `ExpensesIcon`, `RecurringIcon`, `SettingsIcon`; stroke, `currentColor`, `aria-hidden`, `className` prop). `nav.ts` entries carry `icon`, shown on the sheet tabs; every page of a section passes the same icon as `PageTitle`'s `icon` prop (`<PageTitle icon={<ExpensesIcon />}>`). The dashboard has no tab, so no icon.
- **Empty states:** `BlankLedgerDoodle` (icons.tsx, `aria-hidden`): `DataTable`'s empty row shows it small with a muted "The ledger is blank" caption above the unchanged `empty` text; the empty dashboard shows it larger on a `base-200` card beside its text.
- **Totals and stamp:** `total` (double underline, `border-bottom: 3px double`) on the figure cell of a footer total (Expenses). `stamp` is the rotated green rubber-stamp badge (`aria-hidden`, "Posted ✓") on the import summary; `ledger-list` rules a `ul` like ledger entries.
- **Favicon:** `frontend/src/assets/favicon.svg` plus `favicon-32.png` and `apple-touch-icon.png` (rendered once from the SVG with `rsvg-convert`), linked from `index.html` as `/src/assets/…`. They are not in `frontend/public/`: Flask serves only `/assets/*` as files and answers every other GET with `index.html`, so Vite must hash them into `/assets/`.

## Import the Airbnb CSV

1. On airbnb.com open your Transaction history (under Earnings), choose all dates and download
   the CSV (menu names may change; it is the file with a "Confirmation code" column).
2. In the app open **Bookings**, press **Import CSV**, choose the file and press **Preview**,
   look at what would change, then press **Import** (**Cancel** drops the upload).
   On the first import you are asked which of the listings in the file are your apartment.
3. Re-importing is safe: bookings are matched by confirmation code, known lines are skipped and
   only changes are applied. Your guests and notes are never overwritten.

From the command line: `rios-de-asia-accounting import airbnb.csv --listing "My listing" [--dry-run]`.

## Exchange rates

The books run on US dollars. Whenever an expense or Airbnb income is added in another currency, the
app fetches the exchange rate of its date and keeps both the amount you typed and the dollars.

- **Where from:** COP from the official TRM on datos.gov.co, EUR from the European Central Bank via
  Frankfurter (frankfurter.dev). Both are free and need no account. The rates are stored in the database,
  so each day is fetched once.
- **Which date:** income from Airbnb uses the booking's check-in, an expense its own date, a monthly
  expense the 1st of its month. The long-term rent in **Settings** uses the day you save it.
- **Typing amounts:** every money field has an amount and a currency (USD, COP or EUR).
- **Offline:** nothing is lost. An entry whose rate cannot be fetched is saved with the amount you typed
  and waits; it is left out of the figures and a notice counts such entries. The rates are tried again
  when the app starts, after each save and import, and when you press **Fetch rates now**. Rates cannot be
  typed or loaded from a file. Existing peso books are converted this way on the first start after the
  upgrade, so connect to the internet then.

## Display currency

The books are kept in US dollars, but every screen can show its figures in USD, COP or EUR.

- **Where:** the currency select in the page header, next to the navigation. It is remembered across reloads.
- **The rate line:** for COP and EUR the header adds, for example, "1 USD = 4.123,45 COP · rate of 2026-10-23":
  the rate every figure is multiplied by and the day it was valid. The rate is fetched once, when you
  switch, and kept until you switch again; choose the currency again to refresh it. USD shows no rate line.
- **Offline:** if no rate can be fetched, the select stays where it was and a warning says so.
- **Formats:** COP in whole pesos (1.234.567), USD and EUR with two decimals (1.234,56); the currency is
  named by its code, never a symbol. Money fields keep their own currency select.

## Backup

- While the app runs: right after it starts, then every hour if something changed since the last
  backup, and once more when it stops (Ctrl-C or a shutdown). The Settings page shows the last
  backup (time and file, or the error). Daily by the timer too, if you enabled the module above
  (optional).
- Files are `books-YYYY-MM-DD.db` in the backup folder, by default `~/Dropbox/rios-de-asia-accounting`
  (override with `--backup-dir` or `RIOS_DE_ASIA_ACCOUNTING_BACKUP_DIR`). One file per day; the newest 30 are
  kept (Settings page, or `--keep`); other files in the folder are never touched.
- A backup is also taken before the database is upgraded to a newer version of the app.
- By hand: `rios-de-asia-accounting backup [--backup-dir DIR] [--keep N]`.

## Restore

1. Stop the app.
2. Copy the backup over the live database:
   `cp ~/Dropbox/rios-de-asia-accounting/books-2026-10-23.db ~/.local/share/rios-de-asia-accounting/books.db`
3. Start the app again.

## Where the data lives

The live database is `$XDG_DATA_HOME/rios-de-asia-accounting/books.db` (usually
`~/.local/share/rios-de-asia-accounting/books.db`). Override it with `rios-de-asia-accounting --db FILE ...` or the
environment variable `RIOS_DE_ASIA_ACCOUNTING_DB`. It must not be inside a Dropbox folder; only backups go
there.
