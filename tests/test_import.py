import csv
import io
from datetime import date
from pathlib import Path

import pytest

from airbnb_books.importer.airbnb_csv import (
    REQUIRED_COLUMNS,
    FileError,
    apply_import,
    parse,
    plan_import,
)
from airbnb_books.model import ExchangeRate
from airbnb_books.money import parse_minor
from airbnb_books.storage import repo
from airbnb_books.storage.db import connect, migrate

FIXTURE = Path(__file__).parent / "fixtures" / "airbnb_sample.csv"
HEADER = (
    "Date,Arriving by date,Type,Confirmation code,Booking date,Start date,End date,Nights,"
    "Guest,Listing,Details,Reference code,Currency,Amount,Paid out,Service fee,Fast pay fee,"
    "Cleaning fee,Gross earnings,Airbnb remitted tax,Earnings year\n"
)


def one(**kw):
    rec = {
        "Date": "01/10/2025",
        "Type": "Reservation",
        "Code": "HMX",
        "Start": "01/01/2025",
        "End": "01/04/2025",
        "Nights": "3",
        "Amount": "100.00",
        "Service": "3.00",
        "Cleaning": "10.00",
        "Gross": "113.00",
    }
    rec.update(kw)
    cols = [rec["Date"], "", rec["Type"], rec["Code"], "", rec["Start"], rec["End"], rec["Nights"]]
    cols += ["G", "Flat A", "", "", "USD", rec["Amount"], "", rec["Service"], "", rec["Cleaning"]]
    cols += [rec["Gross"], "", ""]
    out = io.StringIO()
    csv.writer(out, lineterminator="\n").writerow(cols)
    return out.getvalue()


def parse_text(text):
    return parse(io.StringIO(text))


def test_fixture_counts():
    p = parse(FIXTURE)
    assert p.problems == []
    assert p.payouts == 3
    assert len(p.rows) == 28
    types = {t: sum(r.type == t for r in p.rows) for t in {r.type for r in p.rows}}
    assert types == {
        "Reservation": 22,
        "Adjustment": 2,
        "Resolution Adjustment": 1,
        "Resolution Payout": 2,
        "Co-Host payout": 1,
    }
    assert sum(p.listings.values()) == 28
    assert len(p.listings) == 5


def test_fixture_has_bom_and_is_read_by_path():
    assert FIXTURE.read_bytes().startswith(b"\xef\xbb\xbf")
    assert parse(str(FIXTURE)).rows[0].date.year >= 2021


def test_fixture_values():
    p = parse(FIXTURE)
    adj = [r for r in p.rows if r.type == "Adjustment" and r.amount == -1]
    assert len(adj) == 1 and adj[0].service_fee == 0 and adj[0].gross is None
    cop = next(r for r in p.rows if r.code == "HMBYBENB5A")
    assert cop.service_fee == 178500 and cop.currency == "COP"
    long_stay = [r for r in p.rows if r.code == "HM9DCZPD4E"]
    assert len(long_stay) == 7
    assert {(r.start, r.end, r.nights) for r in long_stay} == {
        (date(2024, 9, 9), date(2025, 3, 16), 188)
    }


def test_bom_in_stream_and_path(tmp_path):
    f = tmp_path / "a.csv"
    f.write_bytes(b"\xef\xbb\xbf" + (HEADER + one()).encode())
    assert len(parse(f).rows) == 1


def test_comma_amounts():
    p = parse_text(HEADER + one(Amount="1,234.50", Service="1,000.05"))
    assert p.rows[0].amount == 123450
    assert p.rows[0].service_fee == 100005


def test_negative_and_empty_fields():
    p = parse_text(HEADER + one(Amount="-0.01", Service="", Cleaning="", Gross=""))
    r = p.rows[0]
    assert (r.amount, r.service_fee, r.cleaning_fee, r.gross) == (-1, 0, 0, None)
    p = parse_text(HEADER + one(Service="-0.00", Gross="-5.50"))
    assert p.rows[0].service_fee == 0 and p.rows[0].gross == -550


def test_dates_and_nights():
    r = parse_text(HEADER + one()).rows[0]
    assert (r.date, r.start, r.end, r.nights) == (
        date(2025, 1, 10),
        date(2025, 1, 1),
        date(2025, 1, 4),
        3,
    )


def test_missing_column():
    text = HEADER.replace("Cleaning fee,", "") + "\n"
    with pytest.raises(FileError, match="Cleaning fee"):
        parse_text(text)
    assert "Cleaning fee" in REQUIRED_COLUMNS


def test_unknown_type_and_payout():
    p = parse_text(HEADER + one(Type="Mystery") + one(Type="Payout") + one())
    assert [x.line for x in p.problems] == [2]
    assert "Mystery" in p.problems[0].message
    assert p.payouts == 1 and len(p.rows) == 1


@pytest.mark.parametrize(
    "kw, word",
    [
        ({"Start": "2025-01-01"}, "Start date"),
        ({"End": "13/01/2025"}, "End date"),
        ({"Date": ""}, "Date"),
        ({"Amount": "abc"}, "Amount"),
        ({"Amount": "1.234"}, "Amount"),
        ({"Service": "x"}, "Service fee"),
        ({"Nights": "4"}, "Nights"),
        ({"Nights": "n"}, "Nights"),
        ({"Code": ""}, "confirmation code"),
    ],
)
def test_problem_rows(kw, word):
    p = parse_text(HEADER + one() + one(**kw))
    assert len(p.rows) == 1
    assert [x.line for x in p.problems] == [3]
    assert word in p.problems[0].message


@pytest.mark.parametrize(
    "text, minor",
    [
        ("0", 0),
        ("12", 1200),
        ("12.5", 1250),
        ("1,234.50", 123450),
        ("-0.01", -1),
        ("-0.00", 0),
        ("1476880.34", 147688034),
        (" 7.10 ", 710),
        ("5.000", 500),
    ],
)
def test_parse_minor(text, minor):
    assert parse_minor(text) == minor


@pytest.mark.parametrize("text", ["", "abc", "1.234", "NaN", "Infinity", "1.2.3"])
def test_parse_minor_rejects(text):
    with pytest.raises(ValueError):
        parse_minor(text)


# --- plan and apply ---------------------------------------------------------------------------

MASTER = "Master bedroom in beautiful neighbourhood"
LARGE = "Large 4 bed 3 bath apartment near Provenza Poblado"
ALL_LISTINGS = [
    MASTER,
    LARGE,
    "Spacious luxury apartment surrounded by fresh air",
    "Enjoy a luxurious apartment in prime location",
    "nothing",
]
EXTRA_ROW = (
    "10/09/2026,,Adjustment,HMECDBYSMK,07/27/2026,10/07/2026,10/12/2026,5,Guest 2,"
    f"{LARGE},,,USD,-5.00,,,,0.00,,0.00,2026\n"
)
OVERLAP_ROW = (
    "10/09/2026,,Reservation,HMOVERLAP1,10/01/2026,10/09/2026,10/15/2026,6,Guest 9,"
    f"{MASTER},,,COP,600000.00,,20000.00,,0.00,620000.00,0.00,2026\n"
)


@pytest.fixture
def conn(tmp_path):
    c = connect(tmp_path / "t.db")
    migrate(c)
    return c


def fixture_text():
    return FIXTURE.read_text(encoding="utf-8-sig")


def run(conn, text=None, listings=ALL_LISTINGS):
    parsed = parse_text(text) if text is not None else parse(FIXTURE)
    return apply_import(conn, plan_import(conn, parsed, listings))


def test_first_import_creates_bookings_and_lines(conn):
    s = run(conn)
    assert (s.new, s.updated, s.lines_added) == (7, 0, 28)
    assert s.skipped_payouts == 3 and not s.problems
    assert len(repo.list_bookings(conn)) == 7
    b = repo.find_booking_by_code(conn, "HMECDBYSMK")
    assert (b.listing, b.guest_name) == (LARGE, "Guest 2")
    assert (b.check_in, b.check_out, b.nights) == (date(2026, 10, 7), date(2026, 10, 12), 5)
    assert b.guests is None and b.notes is None
    types = sorted(line.type for line in repo.list_lines(conn, b.id))
    assert types == ["Co-Host payout", "Reservation"]


def test_long_cop_stay_totals(conn):
    run(conn)
    b = repo.find_booking_by_code(conn, "HMMNWHZ252")
    assert b.nights == 266
    # 9 monthly reservations + 2 resolution payouts, each line rounded to whole pesos
    assert b.net_payout == 43_254_544
    assert not b.needs_rate and b.cohost_cost == 0


def test_usd_stay_totals_with_rate(conn):
    repo.set_exchange_rate(conn, ExchangeRate(date(2026, 10, 1), "USD", 400_000))  # 4000.00
    s = run(conn)
    b = repo.find_booking_by_code(conn, "HMECDBYSMK")
    assert b.net_payout == 4_374_080  # 1093.52 * 4000
    assert b.cohost_cost == 859_800  # 214.95 * 4000
    assert b.gross == 4_536_000  # 1134.00 * 4000
    assert b.airbnb_fee == 161_920  # 40.48 * 4000
    assert not b.needs_rate
    assert s.needing_rate > 0  # the older USD stays predate the rate


def test_second_import_changes_nothing(conn):
    run(conn)
    plan = plan_import(conn, parse(FIXTURE), ALL_LISTINGS)
    assert plan.new == [] and plan.updated == []
    assert plan.skipped_known_lines == 28
    s = apply_import(conn, plan)
    assert (s.new, s.updated, s.lines_added) == (0, 0, 0)


def test_extra_row_updates_one_booking(conn):
    run(conn)
    plan = plan_import(conn, parse_text(fixture_text() + EXTRA_ROW), ALL_LISTINGS)
    assert plan.new == [] and [u.code for u in plan.updated] == ["HMECDBYSMK"]
    assert plan.updated[0].changes == []
    s = apply_import(conn, plan)
    assert (s.new, s.updated, s.lines_added) == (0, 1, 1)
    b = repo.find_booking_by_code(conn, "HMECDBYSMK")
    assert len(repo.list_lines(conn, b.id)) == 3


def test_changed_guest_name_is_reported_and_updated(conn):
    run(conn)
    text = fixture_text().replace(",Guest 1,", ",Guest One,")
    plan = plan_import(conn, parse_text(text), ALL_LISTINGS)
    assert [u.code for u in plan.updated] == ["HMNDSJTM25"]
    assert [str(c) for c in plan.updated[0].changes] == ["guest name: Guest 1 -> Guest One"]
    s = apply_import(conn, plan)
    assert s.updated == 1 and s.lines_added == 0
    assert repo.find_booking_by_code(conn, "HMNDSJTM25").guest_name == "Guest One"


def test_booking_fields_follow_latest_reservation_row(conn):
    run(conn)
    # a later reservation row of the long stay with a shifted check-out wins
    row = (
        "08/22/2023,,Reservation,HMMNWHZ252,,11/20/2022,08/14/2023,267,Guest 5,"
        f"{ALL_LISTINGS[3]},,,COP,1000.00,,0.00,,0.00,1000.00,0.00,2023\n"
    )
    plan = plan_import(conn, parse_text(fixture_text() + row), ALL_LISTINGS)
    (u,) = plan.updated
    assert [c.field for c in u.changes] == ["check-out"]
    apply_import(conn, plan)
    assert repo.find_booking_by_code(conn, "HMMNWHZ252").check_out == date(2023, 8, 14)


def test_other_listing_is_skipped_and_counted(conn):
    s = run(conn, listings=[MASTER])
    assert s.new == 2  # HMNDSJTM25 and HMSEA9YJ3R
    assert s.skipped_listings[LARGE] == 2
    assert repo.find_booking_by_code(conn, "HMECDBYSMK") is None


def test_empty_setting_needs_a_choice_then_saves_it(conn):
    plan = plan_import(conn, parse(FIXTURE))
    assert plan.needs_listing_choice and set(plan.listings_found) == set(ALL_LISTINGS)
    s = apply_import(conn, plan)
    assert s.new == 0 and repo.list_bookings(conn) == []
    assert repo.load_settings(conn).property_listings == []

    s = apply_import(conn, plan_import(conn, parse(FIXTURE), [MASTER, LARGE]))
    assert s.new == 3
    assert repo.load_settings(conn).property_listings == [MASTER, LARGE]
    # later imports use the saved setting
    plan = plan_import(conn, parse(FIXTURE))
    assert not plan.needs_listing_choice and plan.new == []


def test_user_edits_survive_reimport(conn):
    run(conn)
    b = repo.find_booking_by_code(conn, "HMECDBYSMK")
    b.guests, b.notes = 2, "arrives late"
    repo.update_booking(conn, b)
    text = fixture_text().replace(",Guest 2,", ",Guest Two,") + EXTRA_ROW.replace(
        "Guest 2", "Guest Two"
    )
    run(conn, text)
    b = repo.find_booking_by_code(conn, "HMECDBYSMK")
    assert (b.guests, b.notes, b.guest_name) == (2, "arrives late", "Guest Two")


def test_usd_stay_without_rate_is_flagged_then_filled(conn):
    plan = plan_import(conn, parse(FIXTURE), ALL_LISTINGS)
    assert any("HMECDBYSMK" in w and "USD" in w for w in plan.warnings)
    s = apply_import(conn, plan)
    assert s.needing_rate == 3  # the three USD stays
    b = repo.find_booking_by_code(conn, "HMECDBYSMK")
    assert b.needs_rate and b.net_payout == 0
    repo.set_exchange_rate(conn, ExchangeRate(date(2024, 1, 1), "USD", 400_000))
    b = repo.find_booking_by_code(conn, "HMECDBYSMK")
    assert not b.needs_rate and b.net_payout == 4_374_080


def test_overlap_warning(conn):
    plan = plan_import(conn, parse_text(fixture_text() + OVERLAP_ROW), ALL_LISTINGS)
    overlaps = [w for w in plan.warnings if w.startswith("overlapping") and "HMOVERLAP1" in w]
    assert len(overlaps) == 1
    assert "HMECDBYSMK" in overlaps[0] and "HMOVERLAP1" in overlaps[0]
    assert len(plan.new) == 8
    assert apply_import(conn, plan).new == 8  # warnings do not block


def test_zero_night_stay_is_a_problem(conn):
    text = HEADER + one(End="01/01/2025", Nights="0")
    plan = plan_import(conn, parse_text(text), ["Flat A"])
    assert plan.new == [] and len(plan.problems) == 1
