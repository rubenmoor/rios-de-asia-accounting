# Airbnb Bookkeeping App — Spec

## Goal

Answer three questions for a single Airbnb apartment:

1. Is hosting worth it (all-time, and vs. a long-term rental)?
2. Are prices too low or too high (ADR vs. occupancy trade-off)?
3. How are things trending (rolling windows)?

Local-only, single user, single property.

## Core principle: everything is allocated per day

All income and costs are converted to amounts per calendar day. Every metric and
every time window is then a sum over a date range.

- **Booking income** → net payout ÷ number of nights, assigned to each stayed night.
  Counted only for nights on or before today.
- **Fixed monthly costs** → amount ÷ days in that month, assigned to every day.
- **Per-night costs** → assigned to each occupied night.
- **Per-booking costs** → assigned to the check-in date (or spread over the stay; configurable).
- **Capex** → cost ÷ useful life in days, assigned to every day from purchase date
  until fully amortized.
- **Maintenance** (small repairs) → full amount on the date incurred.
- **Blocked days** (cleaning buffers, owner use) → available = false; no income.

## Data model (SQLite)

### `bookings`
| field | type | notes |
|---|---|---|
| id | int | |
| airbnb_code | text | confirmation code, unique; used for import dedup |
| check_in | date | |
| check_out | date | exclusive |
| guests | int | |
| gross | int | COP |
| airbnb_fee | int | COP |
| net_payout | int | COP; source of truth for income |
| notes | text | |

### `expenses`
| field | type | notes |
|---|---|---|
| id | int | |
| date | date | |
| amount | int | COP |
| category | enum | `fixed`, `per_night`, `per_booking`, `maintenance`, `capex`, `tax` |
| booking_id | int? | for `per_booking` costs |
| useful_life_days | int? | required for `capex` |
| description | text | |

### `recurring_expenses`
Templates for fixed monthly costs (admin fee, internet, insurance, utilities base).
Fields: description, amount, category, start_month, end_month?. The app generates
`expenses` rows from these each month.

### `blocked_days`
date, reason (`buffer`, `owner`, `maintenance`, `other`). Blocked days are not available.

### `time_log`
date, hours, booking_id?, description. Own time spent on hosting.

### `settings`
Key-value: hourly value of own time, long-term rental benchmark (net COP/month),
currency, default per-booking allocation mode.

## Derived daily view

A view (or materialized table) `days` with one row per date:
`date, available, occupied, income, cost_fixed, cost_per_night, cost_per_booking,
cost_maintenance, cost_capex, cost_tax, hours, profit`.

## Metrics (for any date range)

- **Occupancy** = occupied nights ÷ available nights
- **ADR** = income ÷ occupied nights
- **RevPAR** = income ÷ available nights
- **Profit** = income − all costs
- **Variable cost per night** = (per-night + per-booking costs) ÷ occupied nights
- **Break-even occupancy** = fixed costs per day ÷ (ADR − variable cost per night)
- **Profit vs. long-term rental** = profit − benchmark for the same period
- **Profit per hour** = profit ÷ logged hours; and profit after valuing own time

Standard ranges: all-time, last 30 days, last 90 days, calendar month, custom.
Also: total capex not yet amortized (remaining book value).

## Features

### v1
- CRUD for bookings, expenses, recurring expenses, blocked days, time log
- Import Airbnb transaction-history CSV → bookings (dedup by confirmation code)
- Dashboard: metrics for the standard ranges side by side
- Chart: rolling 90-day RevPAR, ADR, occupancy over time
- Expense breakdown by category for a range

### Later
- Upcoming bookings (future nights) shown separately as "on the books"
- Seasonality view (by month of year)
- Price experiment notes: mark a date when prices changed, compare before/after
- Export to CSV

## Storage and backup

- Live database stays local (e.g. `~/.local/share/airbnb-books/books.db`), never opened
  from inside Dropbox.
- Backups via `sqlite3 books.db ".backup <dropbox>/airbnb-books/books-YYYY-MM-DD.db"`:
  on app exit and via a daily systemd user timer (NixOS module / home-manager).
- Keep the last N backups (e.g. 30).
- Restore = copy a backup over the live file while the app is closed.

## Conventions

- Money stored as integers in COP (no floats).
- Dates as ISO `YYYY-MM-DD`; check-out exclusive.
- Single property; no multi-user, no auth, no network access.

## Open decisions

- Tech stack and UI (desktop GUI, TUI, or local web server on localhost)
- Packaging: Nix flake with dev shell and app package
- Exact Airbnb CSV columns (check against a real export)
