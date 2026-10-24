-- The books run on US cents (decision 34). Every converted entry keeps what was typed:
-- original amount in minor units, currency, rate (currency units per USD x 1 000 000) and
-- the rate's date; the USD amount is NULL while the entry waits for a rate (decision 37).
-- Old peso amounts become COP originals waiting for a rate; the app converts them on its
-- next start (decision 38). Old rates (COP per unit in hundredths) are dropped.

DROP VIEW booking_totals;

-- expenses: rebuilt, since `amount` becomes nullable
CREATE TABLE expenses_usd (
    id INTEGER PRIMARY KEY,
    date TEXT NOT NULL CHECK (date(date) IS date),
    amount INTEGER,
    original_minor INTEGER NOT NULL,
    currency TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)
                                  AND currency NOT GLOB '*[^A-Z]*'),
    rate INTEGER CHECK (rate IS NULL OR rate > 0),
    rate_date TEXT CHECK (rate_date IS NULL OR date(rate_date) IS rate_date),
    category TEXT NOT NULL CHECK (category IN (
        'fixed', 'per_night', 'per_booking', 'maintenance', 'capex', 'tax'
    )),
    booking_id INTEGER REFERENCES bookings (id) ON DELETE RESTRICT,
    useful_life_days INTEGER,
    description TEXT,
    recurring_expense_id INTEGER REFERENCES recurring_expenses (id) ON DELETE SET NULL,
    CHECK ((amount IS NULL) = (rate IS NULL) AND (rate IS NULL) = (rate_date IS NULL)),
    CHECK (category <> 'per_booking' OR booking_id IS NOT NULL),
    CHECK ((category = 'capex' AND useful_life_days IS NOT NULL AND useful_life_days > 0)
           OR (category <> 'capex' AND useful_life_days IS NULL)),
    UNIQUE (recurring_expense_id, date)
) STRICT;

INSERT INTO expenses_usd (id, date, original_minor, currency, category, booking_id,
                          useful_life_days, description, recurring_expense_id)
SELECT id, date, amount * 100, 'COP', category, booking_id, useful_life_days, description,
       recurring_expense_id
FROM expenses;

DROP TABLE expenses;
ALTER TABLE expenses_usd RENAME TO expenses;
CREATE INDEX expenses_date ON expenses (date);

-- recurring templates keep their amount in their own currency, unconverted
ALTER TABLE recurring_expenses RENAME COLUMN amount TO amount_minor;
ALTER TABLE recurring_expenses ADD COLUMN currency TEXT NOT NULL DEFAULT 'USD'
    CHECK (length(currency) = 3 AND currency = upper(currency) AND currency NOT GLOB '*[^A-Z]*');
UPDATE recurring_expenses SET amount_minor = amount_minor * 100, currency = 'COP';

-- booking lines: USD per line, converted at the booking's check-in (decision 36)
ALTER TABLE booking_lines DROP COLUMN amount_cop;
ALTER TABLE booking_lines ADD COLUMN amount_usd INTEGER;
ALTER TABLE booking_lines ADD COLUMN service_fee_usd INTEGER;
ALTER TABLE booking_lines ADD COLUMN gross_usd INTEGER;
ALTER TABLE booking_lines ADD COLUMN rate_date TEXT
    CHECK (rate_date IS NULL OR date(rate_date) IS rate_date);
UPDATE booking_lines SET rate = NULL;

-- rates: currency units per USD x 1 000 000, as fetched (decision 35)
DELETE FROM exchange_rates;

-- the day up to which each currency's source has answered
CREATE TABLE rate_coverage (
    currency TEXT PRIMARY KEY CHECK (length(currency) = 3 AND currency = upper(currency)
                                     AND currency NOT GLOB '*[^A-Z]*'),
    through TEXT NOT NULL CHECK (date(through) IS through)
) STRICT;

-- settings: the long-term rent in US cents plus what was typed (decision 41)
INSERT INTO settings (key, value)
SELECT 'long_term_rent_entered', json_object(
    'original_minor', CAST(value AS INTEGER) * 100, 'currency', 'COP',
    'date', NULL, 'rate', NULL, 'rate_date', NULL)
FROM settings WHERE key = 'long_term_rent_cop_per_month' AND CAST(value AS INTEGER) <> 0;
DELETE FROM settings WHERE key = 'long_term_rent_cop_per_month';

-- Per-booking totals in US cents, summed from the lines' USD columns; lines waiting for a
-- rate count as nothing and set `waiting`.
CREATE VIEW booking_totals AS
SELECT
    b.id AS booking_id,
    CAST(julianday(b.check_out) - julianday(b.check_in) AS INTEGER) AS nights,
    COALESCE(SUM(CASE WHEN l.type <> 'Co-Host payout' THEN l.amount_usd END), 0) AS net_payout,
    -COALESCE(SUM(CASE WHEN l.type = 'Co-Host payout' THEN l.amount_usd END), 0) AS cohost_cost,
    COALESCE(SUM(CASE WHEN l.type <> 'Co-Host payout' THEN l.gross_usd END), 0) AS gross,
    COALESCE(SUM(CASE WHEN l.type <> 'Co-Host payout' THEN l.service_fee_usd END), 0)
        AS airbnb_fee,
    COALESCE(MAX(l.id IS NOT NULL AND l.amount_usd IS NULL), 0) AS waiting
FROM bookings b
LEFT JOIN booking_lines l ON l.booking_id = b.id
GROUP BY b.id;
