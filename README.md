# rios-de-asia-accounting

A small local bookkeeping app for one Airbnb apartment. It imports Airbnb's earnings CSV, lets you
add expenses, and shows on a dashboard whether the apartment makes money: income, costs, profit,
occupancy, average nightly rate and profit per hour you put in. Everything runs on your own
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

## Run and quit

```sh
rios-de-asia-accounting            # starts the app and opens the browser
rios-de-asia-accounting --no-browser --port 8080
```

Press **Quit** in the page header (or Ctrl-C in the terminal) to stop it. A backup is taken when it
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

- **Numbers:** class `num` (monospace, tabular, right-aligned); negatives also get `neg` (red ink).
- **Tables:** only through `DataTable`; pages add no table classes of their own. It renders `table sheet` (the `sheet` class in `index.css`: grid lines in the ledger rule colour, `base-200` header cells, zebra rows, row hover, heavier rule above footer rows) inside `overflow-x-auto`, with a decorative frame like a spreadsheet's: a letter row (A, B, C …) above the header and a row-number gutter on the left, both `aria-hidden`.
- **Key/value sheets:** a `table sheet` whose rows start with a `th` label (styled `base-200` by `sheet`); money values `num`.
- **Table footers (totals):** pass `<SheetFooterRow>` (from `DataTable.tsx`, adds the gutter cell) as `footer`; total cells get `num`.
- **Negative cells:** `negative?: (row) => boolean` on a `Column` adds `neg`; only the colour changes, never the text.
- **Headings:** `PageTitle` (h1) and `SectionTitle` (h2) from `components/Titles.tsx`, never hand-written heading classes.
- **Forms:** `Field` (label, muted hint line, `text-error` message with a warning mark) plus the inputs in `inputs.tsx` (full width; money, hours and rate are `num`). A form sits in a `FormSlip` (`components/FormSlip.tsx`): the journal entry slip, a bordered paper card with a header strip (`label`, optional `aria-hidden` `stamp`) and a red margin rule. The `inked` class is for read-only values shown as text.
- **Form actions:** `FormActions` is the ruled row under a form, primary first. `FormError` is the page-level error above a form (`alert alert-error` with icon).
- **Buttons:** `btn btn-primary` for Save/Apply, `btn btn-ghost` for Cancel/Back/Reset, `btn btn-error btn-outline btn-sm` for the Delete trigger (via `ConfirmDelete`, a small "Void entry" slip dialog; its Delete is `btn-error`, its Cancel `btn-ghost`). Filter bars (list pages, dashboard period) are a `Toolbar` (`components/Toolbar.tsx`): the formula-bar strip (`base-200`, bordered, `fx` mark) with `ToolbarField` short labels and `input-sm`/`select-sm` controls, Filter/Apply `btn-sm` (`btn-secondary` or `btn-primary`), the "New …" link as `action` (`btn-primary btn-sm`, pushed right), filter errors below the strip.
- **Errors:** page-level `FormError` / `alert alert-error`; field-level under the field (done by `Field`).
- **Hints:** `Field`'s `hint`. Muted notes: `opacity-70`.
- **Icons:** inline SVG components in `frontend/src/components/icons.tsx` (no icon fonts, no CDN).

## Import the Airbnb CSV

1. On airbnb.com open your Transaction history (under Earnings), choose all dates and download
   the CSV (menu names may change; it is the file with a "Confirmation code" column).
2. In the app open **Import**, choose the file under "Airbnb earnings CSV" and press **Preview**,
   look at what would change, then press **Import** (**Cancel** drops the upload).
   On the first import you are asked which of the listings in the file are your apartment.
3. Re-importing is safe: bookings are matched by confirmation code, known lines are skipped and
   only changes are applied. Your guests and notes are never overwritten.

From the command line: `rios-de-asia-accounting import airbnb.csv --listing "My listing" [--dry-run]`.

## Exchange rates

Airbnb pays in USD, the books are in COP. A booking needs a USD→COP rate for its payout date.

- Download the official TRM history from datos.gov.co ("Tasa de Cambio Representativa del Mercado
  - Historico", CSV) and load it with **Load rates** under "Exchange rates (TRM)" on the **Import** page, or run
  `rios-de-asia-accounting import-rates trm.csv`.
- Or type a single rate on the **Rates** page (**New rate**).

Bookings that still lack a rate are counted after each import.

## Backup

- When the app stops (Quit, Ctrl-C or a shutdown), and daily by the timer if you enabled the
  module above.
- Files are `books-YYYY-MM-DD.db` in the backup folder, by default `~/Dropbox/rios-de-asia-accounting`
  (override with `--backup-dir` or `RIOS_DE_ASIA_ACCOUNTING_BACKUP_DIR`). One file per day; the newest 30 are
  kept (Settings page, or `--keep`); other files in the folder are never touched.
- A backup is also taken before the database is upgraded to a newer version of the app.
- By hand: `rios-de-asia-accounting backup [--backup-dir DIR] [--keep N]`.

## Restore

1. Quit the app.
2. Copy the backup over the live database:
   `cp ~/Dropbox/rios-de-asia-accounting/books-2026-10-23.db ~/.local/share/rios-de-asia-accounting/books.db`
3. Start the app again.

## Where the data lives

The live database is `$XDG_DATA_HOME/rios-de-asia-accounting/books.db` (usually
`~/.local/share/rios-de-asia-accounting/books.db`). Override it with `rios-de-asia-accounting --db FILE ...` or the
environment variable `RIOS_DE_ASIA_ACCOUNTING_DB`. It must not be inside a Dropbox folder; only backups go
there.
