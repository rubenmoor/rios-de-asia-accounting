-- Initial schema. Money: whole COP (INTEGER); foreign amounts: minor units;
-- rates: COP per unit in hundredths; dates: ISO text; months: YYYY-MM; own time: minutes.

CREATE TABLE bookings (
    id INTEGER PRIMARY KEY,
    airbnb_code TEXT UNIQUE,
    listing TEXT,
    guest_name TEXT,
    check_in TEXT NOT NULL CHECK (date(check_in) IS check_in),
    check_out TEXT NOT NULL CHECK (date(check_out) IS check_out),
    guests INTEGER CHECK (guests IS NULL OR guests > 0),
    notes TEXT,
    CHECK (check_out > check_in)
) STRICT;

CREATE TABLE booking_lines (
    id INTEGER PRIMARY KEY,
    booking_id INTEGER NOT NULL REFERENCES bookings (id) ON DELETE CASCADE,
    type TEXT NOT NULL CHECK (type IN (
        'Reservation', 'Adjustment', 'Resolution Adjustment',
        'Resolution Payout', 'Co-Host payout', 'Manual'
    )),
    date TEXT NOT NULL CHECK (date(date) IS date),
    currency TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)
                                  AND currency NOT GLOB '*[^A-Z]*'),
    amount_minor INTEGER NOT NULL,
    service_fee_minor INTEGER NOT NULL DEFAULT 0,
    cleaning_fee_minor INTEGER NOT NULL DEFAULT 0,
    gross_minor INTEGER,
    rate INTEGER CHECK (rate IS NULL OR rate > 0),
    amount_cop INTEGER,
    UNIQUE (booking_id, type, date, currency, amount_minor)
) STRICT;

CREATE INDEX booking_lines_booking_id ON booking_lines (booking_id);

CREATE TABLE exchange_rates (
    date TEXT NOT NULL CHECK (date(date) IS date),
    currency TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)
                                  AND currency NOT GLOB '*[^A-Z]*'),
    rate INTEGER NOT NULL CHECK (rate > 0),
    PRIMARY KEY (date, currency)
) STRICT;

CREATE TABLE recurring_expenses (
    id INTEGER PRIMARY KEY,
    description TEXT NOT NULL,
    amount INTEGER NOT NULL,
    category TEXT NOT NULL CHECK (category IN ('fixed', 'per_night', 'maintenance', 'tax')),
    start_month TEXT NOT NULL CHECK (date(start_month || '-01') IS start_month || '-01'),
    end_month TEXT CHECK (end_month IS NULL OR (
        date(end_month || '-01') IS end_month || '-01' AND end_month >= start_month
    ))
) STRICT;

CREATE TABLE expenses (
    id INTEGER PRIMARY KEY,
    date TEXT NOT NULL CHECK (date(date) IS date),
    amount INTEGER NOT NULL,
    category TEXT NOT NULL CHECK (category IN (
        'fixed', 'per_night', 'per_booking', 'maintenance', 'capex', 'tax'
    )),
    booking_id INTEGER REFERENCES bookings (id) ON DELETE RESTRICT,
    useful_life_days INTEGER,
    description TEXT,
    recurring_expense_id INTEGER REFERENCES recurring_expenses (id) ON DELETE SET NULL,
    CHECK (category <> 'per_booking' OR booking_id IS NOT NULL),
    CHECK ((category = 'capex' AND useful_life_days IS NOT NULL AND useful_life_days > 0)
           OR (category <> 'capex' AND useful_life_days IS NULL)),
    UNIQUE (recurring_expense_id, date)
) STRICT;

CREATE INDEX expenses_date ON expenses (date);

CREATE TABLE blocked_days (
    date TEXT PRIMARY KEY CHECK (date(date) IS date),
    reason TEXT NOT NULL CHECK (reason IN ('buffer', 'owner', 'maintenance', 'other')),
    note TEXT
) STRICT;

CREATE TABLE time_log (
    id INTEGER PRIMARY KEY,
    date TEXT NOT NULL CHECK (date(date) IS date),
    minutes INTEGER NOT NULL CHECK (minutes > 0),
    booking_id INTEGER REFERENCES bookings (id) ON DELETE SET NULL,
    description TEXT
) STRICT;

CREATE INDEX time_log_date ON time_log (date);

CREATE TABLE settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
) STRICT;

-- Per-booking totals derived from the lines. Foreign gross and fee are converted with each
-- line's rate (COP lines are in centavos, rate 100), rounded half away from zero (integer arithmetic only).
CREATE VIEW booking_totals AS
SELECT
    b.id AS booking_id,
    CAST(julianday(b.check_out) - julianday(b.check_in) AS INTEGER) AS nights,
    COALESCE(SUM(CASE WHEN l.type <> 'Co-Host payout' THEN l.amount_cop END), 0) AS net_payout,
    -COALESCE(SUM(CASE WHEN l.type = 'Co-Host payout' THEN l.amount_cop END), 0) AS cohost_cost,
    COALESCE(SUM(
        CASE WHEN l.type <> 'Co-Host payout' AND l.gross_minor IS NOT NULL
        THEN (l.gross_minor * l.rate * 2 + (CASE WHEN l.gross_minor * l.rate < 0 THEN -10000 ELSE 10000 END))
             / 20000 END
    ), 0) AS gross,
    COALESCE(SUM(
        CASE WHEN l.type <> 'Co-Host payout'
        THEN (l.service_fee_minor * l.rate * 2 + (CASE WHEN l.service_fee_minor * l.rate < 0 THEN -10000 ELSE 10000 END))
             / 20000 END
    ), 0) AS airbnb_fee,
    COALESCE(MAX(l.id IS NOT NULL AND l.amount_cop IS NULL), 0) AS needs_rate
FROM bookings b
LEFT JOIN booking_lines l ON l.booking_id = b.id
GROUP BY b.id;
